import Foundation
import simd

enum DrivingLessonKind: String, CaseIterable, Codable {
    case braking, trailBraking, wetExit

    var title: String {
        switch self {
        case .braking: return "起步与定点停车"
        case .trailBraking: return "松刹入弯"
        case .wetExit: return "湿地出弯"
        }
    }

    var subtitle: String {
        switch self {
        case .braking: return "直线油门与制动"
        case .trailBraking: return "从刹车过渡到转向"
        case .wetExit: return "弯中留出抓地，回正后加速"
        }
    }

    var instructions: [String] {
        switch self {
        case .braking: return ["保持直线，起步后达到 65 km/h。", "到达制动点后松开油门，刹车直到在停车区内停稳。"]
        case .trailBraking: return ["进入右弯前先短暂制动。", "转向时逐渐松开刹车，以至少 48 km/h 通过终点。"]
        case .wetExit: return ["跟随湿地右弯，开始回正时逐渐加油。", "避免持续打滑，以至少 58 km/h 通过终点。"]
        }
    }

    var circuitKind: CircuitKind {
        switch self {
        case .braking: return .grand
        case .trailBraking: return .north
        case .wetExit: return .sprint
        }
    }

    var condition: TrackCondition { self == .wetExit ? .wet : .dry }
    var vehicleKind: VehicleKind {
        switch self {
        case .braking: return .porsche
        case .trailBraking: return .porsche
        case .wetExit: return .centenario
        }
    }
    var tyres: TyreSetup { TyreSetup(compound:self == .wetExit ? .wet : .medium) }
    var assists: DrivingAssists { DrivingAssists(automatic:true,absLevel:3,tcLevel:3) }

    var startProgress: Double {
        switch self {
        case .braking: return 236
        case .trailBraking: return 210
        case .wetExit: return 378
        }
    }

    var finishProgress: Double {
        switch self {
        case .braking: return 326
        case .trailBraking: return 293
        case .wetExit: return 444
        }
    }

    var stopZone: ClosedRange<Double>? { self == .braking ? 300...326 : nil }
    var firstCoachingMark: Double? {
        switch self {
        case .braking: return 276
        case .trailBraking: return 231
        case .wetExit: return 396
        }
    }
    var requiredSpeedKPH: Double {
        switch self {
        case .braking: return 65
        case .trailBraking: return 48
        case .wetExit: return 58
        }
    }

    fileprivate var startSpeed: Double {
        switch self {
        case .braking: return 0
        case .trailBraking: return 25
        case .wetExit: return 12
        }
    }

    fileprivate var timeLimit: Double {
        switch self {
        case .braking: return 24
        case .trailBraking: return 15
        case .wetExit: return 18
        }
    }
}

enum DrivingLessonMedal: Int, Codable, Comparable {
    case bronze = 1, silver, gold

    static func < (lhs: Self,rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .bronze: return "铜牌"
        case .silver: return "银牌"
        case .gold: return "金牌"
        }
    }
}

enum DrivingLessonFailure: Equatable {
    case trackLimits, wrongWay, timeout, overshot, tooSlow, technique, lostGrip, earlyPower

    var label: String {
        switch self {
        case .trackLimits: return "驶出练习路线"
        case .wrongWay: return "请沿正向行驶"
        case .timeout: return "超出练习时限"
        case .overshot: return "驶过了停车区"
        case .tooSlow: return "未达到所需速度"
        case .technique: return "带少量刹车开始转向，然后松开"
        case .lostGrip: return "弯中持续打滑，请更缓地给油"
        case .earlyPower: return "弯中全油门过早，回正后再加大油门"
        }
    }
}

enum DrivingLessonOutcome: Equatable {
    case passed(DrivingLessonMedal)
    case failed(DrivingLessonFailure)

    var label: String {
        switch self {
        case .passed(let medal): return medal.label
        case .failed(let reason): return reason.label
        }
    }
}

enum DrivingLessonStop: Equatable {
    /// Along-course position relative to the centre. Positive is farther down the track.
    case inBox(offsetFromCentreMetres: Double)
    case shortOfBox(distanceMetres: Double)
    case crossedBoxEnd(speedKPH: Double)
}

enum DrivingLessonFeedback: Equatable {
    case braking(DrivingLessonStop?)
    case trailBraking(brakeOverlapSeconds: Double, cleanReleaseSeconds: Double, progressiveReleaseSeconds: Double)
    case wetExit(earlyFullThrottleSeconds: Double, poweredSlipSeconds: Double)
}

struct DrivingLessonRecord: Codable, Equatable {
    let medal: DrivingLessonMedal
    let time: Double
    let peakSpeedKPH: Double
    let exitSpeedKPH: Double?

    var isValid: Bool {
        (0.1...60).contains(time) && (0...360).contains(peakSpeedKPH) &&
            (exitSpeedKPH.map { (0...peakSpeedKPH+0.01).contains($0) } ?? true)
    }

    func improves(_ previous: Self?) -> Bool {
        guard isValid else { return false }
        guard let previous else { return true }
        return medal > previous.medal || (medal == previous.medal && time < previous.time)
    }
}

private struct ProgressiveBrakeRelease {
    private var previousPedal = 0.0
    private var previousPressure = 0.0
    private var duration = 0.0
    private var quietTime = 0.0
    private var startPedal = 0.0
    private var startPressure = 0.0
    private(set) var longest = 0.0

    mutating func observe(_ dt: Double,pedal: Double,pressure: Double,turning: Bool) {
        let pedalFall = previousPedal-pedal
        let pressureFall = previousPressure-pressure
        previousPedal = pedal
        previousPressure = pressure
        // The keyboard pedal returns at 19 travel units per second. An
        // immediate controller release or a fresh application ends a taper.
        guard turning,pedal > 0.015,pressure > 0.020,(-0.003...20.5*dt).contains(pedalFall) else {
            endTaper()
            return
        }
        if pedalFall > 0.04*dt && pressureFall > 0.02*dt {
            if duration == 0 {
                startPedal = pedal+pedalFall
                startPressure = pressure+pressureFall
            }
            quietTime = 0
            duration += dt
            // Require a net decrease so minor movement around a fixed command
            // cannot add up to a reported taper.
            if duration >= 0.016 && startPedal-pedal >= 0.024 && startPressure-pressure >= 0.004 {
                longest = max(longest,duration)
            }
        } else {
            // Keep a short interruption in the same taper without crediting
            // time spent holding the pedal or waiting for pressure to fall.
            quietTime += dt
            if quietTime > 0.025 { endTaper() }
        }
    }

    private mutating func endTaper() {
        duration = 0
        quietTime = 0
    }
}

struct DrivingLessonRun {
    let kind: DrivingLessonKind
    private(set) var elapsed = 0.0
    private(set) var peakSpeedKPH = 0.0
    private(set) var exitSpeedKPH: Double?
    private(set) var result: DrivingLessonOutcome?
    private(set) var hasStarted = false
    private var previousProgress: Double
    private var outsideTime = 0.0
    private var wrongWayTime = 0.0
    private var stationaryTime = 0.0
    private var shortStopTime = 0.0
    private var stop: DrivingLessonStop?
    private var brakeOverlap = 0.0
    private var brakeReleasedTime = 0.0
    private var currentBrakeRelease = 0.0
    private var longestBrakeRelease = 0.0
    private var progressiveBrakeRelease = ProgressiveBrakeRelease()
    private var slidingTime = 0.0
    private var earlyFullThrottle = 0.0
    private var slowestTurnSpeedKPH = Double.infinity

    init(kind: DrivingLessonKind) {
        self.kind = kind
        previousProgress = kind.startProgress
    }

    /// Finalized observations are kept with the attempt. Personal-best records retain their current format.
    var feedback: DrivingLessonFeedback? {
        guard result != nil else { return nil }
        switch kind {
        case .braking: return .braking(stop)
        case .trailBraking:
            return .trailBraking(brakeOverlapSeconds:brakeOverlap,cleanReleaseSeconds:longestBrakeRelease,
                                 progressiveReleaseSeconds:progressiveBrakeRelease.longest)
        case .wetExit: return .wetExit(earlyFullThrottleSeconds:earlyFullThrottle,poweredSlipSeconds:slidingTime)
        }
    }

    @discardableResult
    func prepare(_ vehicle: inout Vehicle,circuit: Circuit) -> Bool {
        guard circuit.kind == kind.circuitKind, circuit.condition == kind.condition else { return false }
        let sample = circuit.sample(at:kind.startProgress)
        vehicle.kind = kind.vehicleKind
        vehicle.reset(at:sample)
        vehicle.service(setup:kind.tyres)
        if kind.startSpeed > 0 {
            let gear = kind == .trailBraking ? 3 : 2
            vehicle.gear = gear
            vehicle.velocity = sample.tangent*kind.startSpeed
            let wheelSpeed = kind.startSpeed/vehicle.wheelRadius
            vehicle.rpm = wheelSpeed*vehicle.gearRatios[gear-1]*vehicle.kind.finalDrive*60/(2 * .pi)
            let temperature = kind.tyres.compound.optimum
            for index in vehicle.wheels.indices {
                vehicle.wheels[index].angularVelocity = wheelSpeed
                vehicle.wheels[index].temperature = temperature
                vehicle.wheels[index].coreTemperature = (temperature+26)/2
            }
        }
        return true
    }

    func progress(at location: TrackLocation) -> Double {
        clamp((location.progress-kind.startProgress)/(kind.finishProgress-kind.startProgress),0,1)
    }

    func status(at location: TrackLocation) -> String {
        if let result { return result.label }
        let station = location.progress
        switch kind {
        case .braking:
            if !hasStarted { return "踩油门起步 · 目标 65 km/h" }
            if peakSpeedKPH < kind.requiredSpeedKPH { return "加速至 65 km/h" }
            if let mark = kind.firstCoachingMark, station < mark {
                return "保持直线 · 距制动点 \(Int(ceil(mark-station))) 米"
            }
            if let zone = kind.stopZone {
                if zone.contains(station) { return "已进入停车区 · 停稳" }
                if station < zone.lowerBound { return "现在开始制动 · 距停车区 \(Int(ceil(zone.lowerBound-station))) 米" }
            }
            return "保持直线制动"
        case .trailBraking:
            if station < (kind.firstCoachingMark ?? kind.startProgress) { return "直线制动 · 准备右转" }
            if brakeOverlap < 0.14 { return "少量带刹 · 开始右转" }
            if brakeReleasedTime < 0.16 { return "逐渐松开刹车" }
            return "保持路线 · 穿过终点"
        case .wetExit:
            return station < (kind.firstCoachingMark ?? kind.startProgress) ? "沿湿地右弯 · 轻给油" : "逐步回正加速 · 终点至少 58 km/h"
        }
    }

    mutating func step(_ dt: Double,vehicle: Vehicle,input: DrivingInput,location: TrackLocation,circuit: Circuit) {
        guard result == nil, dt.isFinite, (0...0.1).contains(dt), dt > 0,
              circuit.kind == kind.circuitKind, circuit.condition == kind.condition else { return }
        guard vehicle.speed.isFinite, location.progress.isFinite, location.distance.isFinite else {
            result = .failed(.trackLimits)
            return
        }
        if !hasStarted {
            guard kind != .braking || input.throttle > 0.04 || vehicle.speed > 0.5 else { return }
            hasStarted = true
        }
        let station = location.progress
        let change = station-previousProgress
        previousProgress = station
        guard abs(change) <= max(3,vehicle.speed*dt*2+1) else {
            result = .failed(.trackLimits)
            return
        }
        elapsed += dt
        peakSpeedKPH = max(peakSpeedKPH,vehicle.speedKPH)
        let along = simd_dot(vehicle.velocity,location.tangent)
        let heading = simd_dot(vehicle.forward,location.tangent)
        let stopZone = kind.stopZone
        let stoppedInLane = stopZone != nil && vehicle.speedKPH < 2 && input.throttle < 0.08 &&
            location.distance < circuit.width/2-0.7
        if let stopZone {
            let short = station < stopZone.lowerBound && stoppedInLane && peakSpeedKPH >= kind.requiredSpeedKPH
            shortStopTime = short ? shortStopTime+dt : 0
        }
        wrongWayTime = along < -2 || (vehicle.speed > 2 && heading < -0.25) ? wrongWayTime+dt : 0
        outsideTime = location.distance > circuit.width/2+0.35 ? outsideTime+dt : 0
        if wrongWayTime > 0.35 || station < kind.startProgress-9 { result = .failed(.wrongWay) }
        else if outsideTime > 0.22 || vehicle.allWheelsOutside { result = .failed(.trackLimits) }
        else if elapsed > kind.timeLimit {
            if let stopZone, shortStopTime >= 0.45 {
                stop = .shortOfBox(distanceMetres:stopZone.lowerBound-station)
            }
            result = .failed(.timeout)
        }
        guard result == nil else { return }

        switch kind {
        case .braking:
            guard let zone = stopZone else { return }
            if station > zone.upperBound {
                stop = .crossedBoxEnd(speedKPH:vehicle.speedKPH)
                result = .failed(.overshot)
                return
            }
            stationaryTime = zone.contains(station) && stoppedInLane ? stationaryTime+dt : 0
            if stationaryTime >= 0.45 {
                exitSpeedKPH = vehicle.speedKPH
                let stopError = station-(zone.lowerBound+zone.upperBound)/2
                stop = .inBox(offsetFromCentreMetres:stopError)
                if peakSpeedKPH < kind.requiredSpeedKPH { result = .failed(.tooSlow) }
                else {
                    let errorFromCentre = abs(stopError)
                    result = .passed(errorFromCentre <= 3.5 ? .gold : errorFromCentre <= 7 ? .silver : .bronze)
                }
            }
        case .trailBraking:
            let inTurn = station >= (kind.firstCoachingMark ?? kind.startProgress) && station < kind.finishProgress-12
            let turning = inTurn && abs(vehicle.lateralG) > 0.08 && abs(vehicle.steeringAngle) > 0.012
            if inTurn {
                if vehicle.brakeLinePressure >= 0.032 && turning { brakeOverlap += dt }
                slowestTurnSpeedKPH = min(slowestTurnSpeedKPH,vehicle.speedKPH)
            }
            progressiveBrakeRelease.observe(dt,pedal:input.brake,pressure:vehicle.brakeLinePressure,turning:turning)
            // Measure the longest uninterrupted interval after the line pressure
            // is below 2%. The accumulated time still determines eligibility.
            if brakeOverlap >= 0.14 && vehicle.brakeLinePressure < 0.020 {
                brakeReleasedTime += dt
                currentBrakeRelease += dt
                longestBrakeRelease = max(longestBrakeRelease,currentBrakeRelease)
            } else {
                currentBrakeRelease = 0
            }
            if station >= kind.finishProgress && change > 0 && along > 0 {
                exitSpeedKPH = vehicle.speedKPH
                if brakeOverlap < 0.14 || brakeReleasedTime < 0.16 || vehicle.brakeLinePressure > 0.035 ||
                    slowestTurnSpeedKPH > kind.startSpeed*3.6-10 {
                    result = .failed(.technique)
                } else if vehicle.speedKPH < kind.requiredSpeedKPH { result = .failed(.tooSlow) }
                else {
                    let controlled = vehicle.speedKPH >= 60 && vehicle.speedKPH <= 82
                    result = .passed(controlled && brakeOverlap >= 0.48 ? .gold : brakeOverlap >= 0.28 ? .silver : .bronze)
                }
            }
        case .wetExit:
            if station < (kind.firstCoachingMark ?? kind.startProgress) && vehicle.engineThrottle > 0.80 {
                earlyFullThrottle += dt
            }
            if input.throttle > 0.22 {
                let driven = vehicle.wheels.suffix(2)
                let spin = driven.contains { $0.normalLoad > 100 && $0.slipRatio > 0.19 }
                let sideSlip = abs(simd_dot(vehicle.velocity,vehicle.modelX))/max(4,vehicle.speed)
                if spin || sideSlip > 0.17 { slidingTime += dt }
            }
            if station >= kind.finishProgress && change > 0 && along > 0 {
                exitSpeedKPH = vehicle.speedKPH
                if slidingTime > 0.95 { result = .failed(.lostGrip) }
                else if earlyFullThrottle > 0.65 { result = .failed(.earlyPower) }
                else if vehicle.speedKPH < kind.requiredSpeedKPH { result = .failed(.tooSlow) }
                else { result = .passed(slidingTime < 0.12 && vehicle.speedKPH >= 66 ? .gold : slidingTime < 0.38 ? .silver : .bronze) }
            }
        }
    }
}

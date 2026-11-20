import Foundation
import simd

struct RacePlayback: Equatable {
    enum Rate: Double, CaseIterable {
        case half = 0.5, normal = 1, double = 2
        var label: String { self == .half ? "0.5×" : (self == .normal ? "1×" : "2×") }
        var next: Self {
            switch self {
            case .half: return .normal
            case .normal: return .double
            case .double: return .half
            }
        }
    }

    let interval: ClosedRange<Double>
    private(set) var time: Double
    var isPlaying = true
    var rate = Rate.normal

    init(interval: ClosedRange<Double>) {
        self.interval = interval
        time = interval.lowerBound
    }

    var elapsed: Double { time-interval.lowerBound }
    var duration: Double { interval.upperBound-interval.lowerBound }
    var fraction: Double { duration > 0 ? elapsed/duration : 0 }
    var playsSound: Bool { isPlaying && rate == .normal }

    mutating func togglePlay() {
        if isPlaying { isPlaying = false }
        else {
            if time == interval.upperBound { time = interval.lowerBound }
            isPlaying = true
        }
    }

    mutating func advance(_ dt: Double) {
        guard isPlaying, dt.isFinite, dt > 0 else { return }
        time = min(interval.upperBound,time+dt*rate.rawValue)
        if time == interval.upperBound { isPlaying = false }
    }

    mutating func seek(fraction: Double) {
        guard fraction.isFinite else { return }
        seek(to:interval.lowerBound+duration*clamp(fraction,0,1))
    }

    mutating func skip(_ seconds: Double) { seek(to:time+seconds) }

    private mutating func seek(to time: Double) {
        guard time.isFinite else { return }
        self.time = clamp(time,interval.lowerBound,interval.upperBound)
        if self.time == interval.upperBound { isPlaying = false }
    }
}

/// A rolling, in-memory record of the render state of a race.
struct RaceReplay {
    static let samplesPerSecond = 20.0
    static let durationLimit = 90.0
    // Keep an earlier frame for interpolation at the edge of the window.
    private static let capacity = Int(durationLimit * samplesPerSecond) + 2

    struct Frame {
        let time: Double
        let player: Vehicle
        let rivals: [Vehicle]
        let playerAudio: Audio
        let rivalAudio: [Audio]
        let playerRoad: RoadSound
        let controls: Controls
    }

    struct Controls {
        let brakeTravel: Float
        let linePressure: Float
        let absActive: Bool

        init(vehicle: Vehicle) {
            brakeTravel = Float(vehicle.brakePedalTravel)
            linePressure = Float(vehicle.brakeLinePressure)
            absActive = vehicle.absActive
        }

        private init(brakeTravel: Float,linePressure: Float,absActive: Bool) {
            self.brakeTravel = brakeTravel
            self.linePressure = linePressure
            self.absActive = absActive
        }

        func interpolated(to later: Self,fraction: Float) -> Self {
            Self(brakeTravel:brakeTravel+(later.brakeTravel-brakeTravel)*fraction,
                        linePressure:linePressure+(later.linePressure-linePressure)*fraction,
                        absActive:fraction < 0.5 ? absActive : later.absActive)
        }
    }

    struct Audio {
        let powertrain: PowertrainSound
        let tyres: DistantTyres
        let throttle: Double
        let ignition: Double

        init(vehicle: Vehicle,tyres: DistantTyres) {
            self.tyres = tyres
            powertrain = vehicle.powertrainSound
            throttle = vehicle.engineThrottle
            ignition = vehicle.ignitionFraction
        }

        private init(powertrain: PowertrainSound,tyres: DistantTyres,throttle: Double,ignition: Double) {
            self.tyres = tyres
            self.powertrain = powertrain
            self.throttle = throttle
            self.ignition = ignition
        }

        func interpolated(to next: Audio,fraction: Double) -> Audio {
            func mix(_ a: Double,_ b: Double) -> Double { a+(b-a)*fraction }
            let drive = PowertrainSound(driveLoad:mix(powertrain.driveLoad,next.powertrain.driveLoad),
                overrun:mix(powertrain.overrun,next.powertrain.overrun),shaftRPM:mix(powertrain.shaftRPM,next.powertrain.shaftRPM),
                inGear:fraction < 0.5 ? powertrain.inGear : next.powertrain.inGear,
                shiftEngagement:mix(powertrain.shiftEngagement,next.powertrain.shiftEngagement),
                regeneration:mix(powertrain.regeneration,next.powertrain.regeneration))
            return Audio(powertrain:drive,tyres:tyres.interpolated(to:next.tyres,fraction:fraction),
                         throttle:mix(throttle,next.throttle),ignition:mix(ignition,next.ignition))
        }
    }

    private struct Pose {
        let transform: VehicleRenderSample
        let hasElevation: Bool
        let braking: Bool
        let gear: Int8
        let rpm: Float
        let damage: VehicleDamage
        let wheelTravel: SIMD4<Double>
        let wheelLoad: SIMD4<Float>
        let wheelSpray: SIMD4<Float>
        let tyreDamage: SIMD4<Float>
        let audio: Audio

        init(_ car: Vehicle,tyres: DistantTyres? = nil) {
            transform = car.renderSample
            hasElevation = car.hasRoadElevationSample
            braking = car.brakeLightsActive
            gear = Int8(clamping:car.gear)
            rpm = Float(car.rpm)
            damage = car.damage
            let (a,b,c,d) = (car.wheels[0],car.wheels[1],car.wheels[2],car.wheels[3])
            audio = Audio(vehicle:car,tyres:tyres ?? TyreSound(vehicle:car).distant)
            wheelTravel = SIMD4(a.accumulatedRotation,b.accumulatedRotation,c.accumulatedRotation,d.accumulatedRotation)
            wheelLoad = SIMD4(Float(a.normalLoad),Float(b.normalLoad),Float(c.normalLoad),Float(d.normalLoad))
            wheelSpray = SIMD4(Float(a.spray),Float(b.spray),Float(c.spray),Float(d.spray))
            func tyre(_ wheel: WheelState) -> Float { wheel.punctured ? -1 : Float(wheel.flatSpot) }
            tyreDamage = SIMD4(tyre(a),tyre(b),tyre(c),tyre(d))
        }

        func vehicle(toward later: Pose, fraction: Double) -> (car: Vehicle,audio: Audio) {
            let nearer = fraction < 0.5 ? self : later
            let a = transform, b = later.transform
            let phase: VehicleRenderSample
            let loads: SIMD4<Float>, spray: SIMD4<Float>
            let engineSpeed: Float
            let sound: Audio
            if a.kind == b.kind {
                let share = Float(fraction)
                let headingDifference = b.heading-a.heading
                let circle = 2 * Double.pi
                var rotations = a.wheelRotations
                for wheel in 0..<4 {
                    let difference = b.wheelRotations[wheel]-a.wheelRotations[wheel]
                    let travel = later.wheelTravel[wheel]-wheelTravel[wheel]
                    // A tyre can turn more than half a revolution between
                    // samples. Recover the correct number of full turns.
                    let turns = ((travel-difference)/circle).rounded()
                    let angle = rotations[wheel]+(difference+turns*circle)*fraction
                    rotations[wheel] = angle.truncatingRemainder(dividingBy:circle)
                }
                phase = VehicleRenderSample(kind:a.kind,position:a.position+(b.position-a.position)*fraction,
                    velocity:a.velocity+(b.velocity-a.velocity)*fraction,
                    heading:a.heading+atan2(sin(headingDifference),cos(headingDifference))*fraction,
                    attitude:a.attitude+(b.attitude-a.attitude)*fraction,
                    steering:a.steering+(b.steering-a.steering)*fraction,
                    rearSteering:a.rearSteering+(b.rearSteering-a.rearSteering)*fraction,
                    roadElevation:a.roadElevation+(b.roadElevation-a.roadElevation)*fraction,
                    wheelRotations:rotations,wheelHeights:a.wheelHeights+(b.wheelHeights-a.wheelHeights)*fraction)
                loads = wheelLoad+(later.wheelLoad-wheelLoad)*share
                spray = wheelSpray+(later.wheelSpray-wheelSpray)*share
                engineSpeed = rpm+(later.rpm-rpm)*share
                sound = audio.interpolated(to:later.audio,fraction:fraction)
            } else {
                phase = nearer.transform
                loads = nearer.wheelLoad
                spray = nearer.wheelSpray
                engineSpeed = nearer.rpm
                sound = nearer.audio
            }
            var car = Vehicle()
            car.applyReplayPose(phase,hasElevation:nearer.hasElevation,braking:nearer.braking,spray:SIMD4<Double>(spray))
            car.gear = Int(nearer.gear)
            car.rpm = Double(engineSpeed)
            car.damage = nearer.damage
            for wheel in car.wheels.indices {
                car.wheels[wheel].normalLoad = Double(loads[wheel])
                car.wheels[wheel].flatSpot = Double(max(0,nearer.tyreDamage[wheel]))
                car.wheels[wheel].punctured = nearer.tyreDamage[wheel] < 0
            }
            return (car,sound)
        }
    }

    private struct Sample {
        let time: Double
        let player: Pose
        let firstRival: Pose?
        let secondRival: Pose?
        let thirdRival: Pose?
        let playerRoad: RoadSound
        let controls: Controls

        init(time: Double, player: Vehicle, rivals: [Vehicle]) {
            self.time = time
            playerRoad = RoadSound(vehicle:player)
            self.player = Pose(player,tyres:playerRoad.tyres.distant)
            // Fixed slots avoid allocating an array for each recorded frame.
            firstRival = rivals.count > 0 ? Pose(rivals[0]) : nil
            secondRival = rivals.count > 1 ? Pose(rivals[1]) : nil
            thirdRival = rivals.count > 2 ? Pose(rivals[2]) : nil
            controls = Controls(vehicle:player)
        }

        func frame(toward newer: Sample, at time: Double) -> Frame {
            let fraction = newer.time > self.time ? (time-self.time)/(newer.time-self.time) : 0
            func rival(_ first: Pose?,_ second: Pose?) -> (car: Vehicle,audio: Audio)? {
                if let first, let second { return first.vehicle(toward:second,fraction:fraction) }
                let nearer = fraction < 0.5 ? first : second
                return nearer.map { $0.vehicle(toward:$0,fraction:0) }
            }
            let driver = player.vehicle(toward:newer.player,fraction:fraction)
            let field = [rival(firstRival,newer.firstRival),rival(secondRival,newer.secondRival),
                         rival(thirdRival,newer.thirdRival)].compactMap { $0 }
            return Frame(time:time,player:driver.car,rivals:field.map(\.car),
                         playerAudio:driver.audio,rivalAudio:field.map(\.audio),
                         playerRoad:playerRoad.interpolated(to:newer.playerRoad,fraction:fraction),
                         controls:controls.interpolated(to:newer.controls,fraction:Float(fraction)))
        }
    }

    private var samples: [Sample] = []
    private var firstIndex = 0
    private var nextSampleTime = 0.0
    private var contacts: [(time: Double, sound: ContactSound)] = []

    mutating func recordContact(_ sound: ContactSound, at time: Double) {
        guard time.isFinite, time >= 0, sound.closingSpeed.isFinite, sound.closingSpeed > 1.5,
              sound.position.x.isFinite, sound.position.y.isFinite,
              contacts.last.map({ time > $0.time }) ?? true else { return }
        // The live impact cooldown admits at most one event every 0.4 seconds.
        contacts.append((time,sound))
    }

    func playContacts(after start: Double, through end: Double, _ play: (ContactSound) -> Void) {
        guard let last = contacts.last, last.time > start, end > start else { return }
        for event in contacts where event.time > start && event.time <= end { play(event.sound) }
    }

    var sampleCount: Int { samples.count }
    var hasFootage: Bool { sampleCount > 1 }
    var startTime: Double? {
        endTime.map { max($0-Self.durationLimit,samples[firstIndex].time) }
    }
    var endTime: Double? { samples.isEmpty ? nil : samples[storageIndex(sampleCount-1)].time }
    var duration: Double {
        guard let startTime, let endTime else { return 0 }
        return endTime-startTime
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity:true)
        contacts.removeAll(keepingCapacity:true)
        firstIndex = 0
        nextSampleTime = 0
    }

    mutating func record(time: Double, player: Vehicle, rivals: @autoclosure () -> [Vehicle], final: Bool = false) {
        guard time.isFinite, time >= 0, final || time+1e-8 >= nextSampleTime else { return }
        if let previous = endTime, time <= previous {
            if final && time == previous {
                samples[storageIndex(sampleCount-1)] = Sample(time:time,player:player,rivals:rivals())
            }
            return
        }

        let sample = Sample(time:time,player:player,rivals:rivals())
        if sampleCount == Self.capacity {
            samples[firstIndex] = sample
            firstIndex = (firstIndex+1) % Self.capacity
        } else {
            if samples.isEmpty { samples.reserveCapacity(Self.capacity) }
            samples.append(sample)
        }
        nextSampleTime = (floor((time+1e-8)*Self.samplesPerSecond)+1)/Self.samplesPerSecond
        if let first = contacts.first, first.time < time-Self.durationLimit {
            contacts.removeAll { $0.time < time-Self.durationLimit }
        }
    }

    /// Retrieve an interpolated frame by absolute race time. Scrubbing beyond
    /// the retained time range stays at the corresponding endpoint.
    func frame(at time: Double) -> Frame? {
        guard let startTime, let endTime, time.isFinite else { return nil }
        let time = clamp(time,startTime,endTime)
        var low = 0, high = sampleCount-1
        while low < high {
            let middle = (low+high)/2
            if samples[storageIndex(middle)].time < time { low = middle+1 }
            else { high = middle }
        }
        let newer = samples[storageIndex(low)]
        return samples[storageIndex(max(0,low-1))].frame(toward:newer,at:time)
    }

    private func storageIndex(_ index: Int) -> Int {
        (firstIndex+index) % Self.capacity
    }
}

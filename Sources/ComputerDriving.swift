import Foundation
import simd

struct TrafficCar {
    var vehicle: Vehicle
    let pace: Double
    let lane: Double
    var pass = PassingPlan()
    var previousPose: VehicleRenderSample?
    var cooldownSpeed: Double?
}

struct PassingPlan {
    private(set) var lane = 0.0
    private(set) var committedSide = 0.0
    private var targetPosition: SIMD2<Double>?
    private var clearTime = 0.0
    private var decisionClock = 0.0

    mutating func update(_ dt: Double, car: Vehicle, location: TrackLocation, circuit: Circuit,
                         line: RacingLine, baseLane: Double, pace: Double, traffic: [Vehicle]) {
        decisionClock += dt
        if decisionClock >= 0.10 {
            let elapsed = decisionClock
            decisionClock = 0
            decide(elapsed,car:car,location:location,circuit:circuit,line:line,baseLane:baseLane,pace:pace,traffic:traffic)
        }
        let target = committedSide == 0 ? baseLane : baseLane + committedSide*3.6
        lane += (target-lane) * (1-exp(-dt*3.0))
    }

    private mutating func decide(_ dt: Double, car: Vehicle, location: TrackLocation, circuit: Circuit,
                                 line: RacingLine, baseLane: Double, pace: Double, traffic: [Vehicle]) {
        let forward = location.tangent, right = SIMD2(forward.y,-forward.x)
        let carSpeed = max(0,simd_dot(car.velocity,forward))
        let headingAligned = simd_dot(car.forward,forward) > 0.9
        let currentLine = simd_dot(line.sample(at:location.progress).position-location.point,right)
        let nearby = traffic.compactMap { other -> (position: SIMD2<Double>, along: Double, lateral: Double, speed: Double, movingSide: Double)? in
            let vector = other.position-car.position
            let along = simd_dot(vector,forward), lateral = simd_dot(vector,right)+location.lateral
            guard (-21...58).contains(along), abs(lateral) < circuit.width/2+1 else { return nil }
            return (other.position,along,lateral,max(0,simd_dot(other.velocity,forward)),simd_dot(other.velocity,right))
        }
        if committedSide != 0 {
            let opponent = nearby.filter { abs($0.lateral-(currentLine+baseLane)) < 2.6 }.min {
                simd_distance($0.position,targetPosition ?? car.position) < simd_distance($1.position,targetPosition ?? car.position)
            }
            if let opponent { targetPosition = opponent.position }
            clearTime = (opponent?.along ?? -20) < -9 ? clearTime+dt : 0
            if clearTime > 0.85 || !headingAligned || location.distance > circuit.width/2+1 {
                committedSide = 0; clearTime = 0; targetPosition = nil
            }
            return
        }
        guard circuit.condition == .dry, carSpeed > 10, headingAligned, location.distance < circuit.width/2-1.0,
              !circuit.pitLane.contains(location) else { return }
        let look = clamp(carSpeed*4,58,125)
        let aheadSample = circuit.sample(at:location.progress+look)
        guard [0.25,0.5,0.75,1.0].allSatisfy({
            simd_dot(forward,circuit.sample(at:location.progress+look*$0).tangent) > 0.989
        }) else { return }
        let expectedSpeed = line.sample(at:location.progress+look).targetSpeed*pace
        guard expectedSpeed >= carSpeed-1.5,
              let leader = nearby.filter({
                  $0.along > 6 && $0.along < max(19,carSpeed*1.4) &&
                  expectedSpeed-$0.speed > 12 && $0.speed < expectedSpeed*0.67 &&
                  (expectedSpeed-$0.speed)*2.4 > $0.along &&
                  abs($0.lateral-(currentLine+baseLane)) < 1.95
              }).min(by: { $0.along < $1.along }),
              expectedSpeed-leader.speed > 3.0 else { return }
        let futureLine = simd_dot(line.sample(at:aheadSample.distance).position-aheadSample.point,aheadSample.right)
        let halfWidth = circuit.width/2-1.32
        let free = [-1.0,1.0].compactMap { side -> (Double,Double)? in
            let here = clamp(currentLine+3.6*side,-halfWidth,halfWidth)
            let future = clamp(futureLine+3.6*side,-halfWidth,halfWidth)
            guard abs(here-leader.lateral) > 2.5, abs(future-leader.lateral) > 2.5 else { return nil }
            guard !nearby.contains(where: { other in
                let gapInOneSecond = other.along + other.speed-carSpeed
                let predictedSide = other.lateral + clamp(other.movingSide,-2,2)
                let nearNow = (-11...33).contains(other.along) && abs(other.lateral-here) < 2.2
                let nearThen = (-9...37).contains(gapInOneSecond) && abs(predictedSide-future) < 2.2
                return nearNow || nearThen
            }) else { return nil }
            return (side,min(abs(here-leader.lateral),abs(future-leader.lateral)))
        }.max { $0.1 < $1.1 }
        if let free { committedSide = free.0; targetPosition = leader.position }
    }
}

struct ComputerDriver {
    static func wantsControl(_ input: DrivingInput) -> Bool {
        input.throttle > 0.12 || input.brake > 0.12 || abs(input.steering) > 0.22
    }

    static func canDrive(_ vehicle: Vehicle, at location: TrackLocation, on circuit: Circuit) -> Bool {
        vehicle.gear > 0 && location.distance < circuit.width/2 + 1 && simd_dot(vehicle.forward, location.tangent) > 0.25
    }

    static func input(for car: Vehicle, at location: TrackLocation, circuit: Circuit, line: RacingLine,
                      pace: Double, lane: Double = 0, traffic: [Vehicle] = [],
                      brakeCurve: BrakeCurve = .progressive, steeringCurve: SteeringCurve = .standard,
                      maximumSpeed: Double = .infinity) -> DrivingInput {
        let alignment = simd_dot(car.forward,location.tangent)
        if location.distance > circuit.width/2+0.35 || alignment < 0.32 {
            return recover(car,at:location,circuit:circuit,traffic:traffic,brakeCurve:brakeCurve)
        }
        let lookAhead = clamp(5 + car.speed*0.37, 5, 22)
        let aimProgress = location.progress + lookAhead
        let sample = circuit.sample(at:aimProgress)
        let rawAim = line.sample(at:aimProgress).position + sample.right*lane
        let offset = simd_dot(rawAim-sample.point,sample.right)
        let safeWidth = circuit.width/2-1.32
        let aim = abs(lane) > 1 ? rawAim + sample.right*(clamp(offset,-safeWidth,safeWidth)-offset) : rawAim
        let direction = aim-car.position
        let right = -simd_dot(direction, car.modelX)
        let pursuit = atan(2*car.wheelbase*right/max(1, simd_length_squared(direction)))
        let requested = clamp((pursuit + car.yawRate*0.075)/car.steeringLimit, -1, 1)
        // Invert the same nonlinear input curve used by the vehicle solver.
        var low = 0.0, high = 1.0
        for _ in 0..<10 {
            let mid = (low+high)/2
            if Vehicle.steeringResponse(mid,curve:steeringCurve) < abs(requested) {low = mid} else {high = mid}
        }
        let steering = copysign((low+high)/2, requested)
        let preview = min(7, 1+car.speed*0.16)
        var target = min(maximumSpeed,line.sample(at:location.progress+preview).targetSpeed*pace)
        // Keep a following gap when another car occupies the intended corridor.
        for other in traffic {
            let offset = other.position-car.position
            let ahead = simd_dot(offset, car.forward)
            let lateral = -simd_dot(offset, car.modelX)
            let aimOffset = right * clamp(ahead/max(lookAhead,1), 0, 1)
            if ahead > 0 && ahead < max(18,car.speed*1.3) && abs(lateral-aimOffset) < 2.05 {
                let frontSpeed = max(0,simd_dot(other.velocity,car.forward))
                target = min(target,max(0,frontSpeed+(ahead-5-car.speed*0.45)*0.85))
            }
        }
        let error = target-car.speed
        let demand = clamp((-error-0.45)*0.19,0,1)
        return DrivingInput(throttle: clamp(error*0.20,0,1),
                            brake: Vehicle.brakeTravel(for:demand,curve:brakeCurve), steering: steering)
    }

    private static func recover(_ car: Vehicle,at location: TrackLocation,circuit: Circuit,
                                traffic: [Vehicle],brakeCurve: BrakeCurve) -> DrivingInput {
        let aim = circuit.sample(at:location.progress+clamp(5+car.speed*0.4,5,11)).point
        let direction = aim-car.position
        let headingError = atan2(-simd_dot(direction,car.modelX),simd_dot(direction,car.forward))
        let steering = clamp(headingError/0.52,-1,1)
        let speed = car.speed
        var target = 3.0+4.0*max(0,cos(headingError))
        // Leave traffic on the asphalt room to pass before committing to the
        // return. A car behind the recovery path is equally relevant here.
        if location.distance > circuit.width/2 {
            let tangent = location.tangent
            if traffic.contains(where: { other in
                let offset = other.position-location.point
                let along = simd_dot(offset,tangent)
                let side = abs(simd_dot(offset,SIMD2(tangent.y,-tangent.x)))
                return (-18...10).contains(along) && side < circuit.width/2+0.4 &&
                    simd_dot(other.velocity,tangent) > 4
            }) { target = 0 }
        }
        let error = target-speed
        let throttle = clamp(error*0.15,0,0.42)
        let pressure = clamp(-error*0.11,0,target == 0 ? 0.8 : 0.55)
        return DrivingInput(throttle:throttle,brake:Vehicle.brakeTravel(for:pressure,curve:brakeCurve),steering:steering)
    }
}

struct TrafficContact {
    let normal: SIMD2<Double> // From the first car toward the second.
    let closingSpeed: Double

    static func resolve(_ first: inout Vehicle, _ second: inout Vehicle) -> TrafficContact? {
        guard simd_distance(first.position, second.position) < 4.6 else {return nil}
        // Three overlapping circles approximate each footprint while keeping
        // side-by-side clearance narrower than front-to-back clearance.
        var depth = 0.0
        var normal = first.forward
        var contactPoint = (first.position + second.position) / 2
        for front in [-1.22,0,1.22] {
            for rear in [-1.22,0,1.22] {
                let firstCentre = first.position + first.forward * front
                let secondCentre = second.position + second.forward * rear
                let separation = secondCentre - firstCentre
                let distance = simd_length(separation)
                if 1.96-distance > depth {
                    depth = 1.96-distance
                    normal = distance > 0.001 ? separation/distance : first.forward
                    contactPoint = (firstCentre + secondCentre) / 2
                }
            }
        }
        guard depth > 0 else {return nil}
        let firstArm = contactPoint - first.position
        let secondArm = contactPoint - second.position
        // +Y yaw rotates local forward toward local +X. The lever arm uses that convention.
        let firstLever = firstArm.y * normal.x - firstArm.x * normal.y
        let secondLever = secondArm.y * normal.x - secondArm.x * normal.y
        let firstShare = second.mass/(first.mass+second.mass)
        first.position -= normal*depth*firstShare
        second.position += normal*depth*(1-firstShare)
        let closing = max(0,simd_dot(first.velocity-second.velocity, normal)
                            + first.yawRate * firstLever - second.yawRate * secondLever)
        let effectiveInverseMass = 1/first.mass + 1/second.mass
            + firstLever*firstLever/first.yawInertia + secondLever*secondLever/second.yawInertia
        let impulse = 1.08 * closing / effectiveInverseMass
        first.velocity -= normal * (impulse / first.mass)
        second.velocity += normal * (impulse / second.mass)
        first.yawRate -= impulse * firstLever / first.yawInertia
        second.yawRate += impulse * secondLever / second.yawInertia
        return TrafficContact(normal: normal, closingSpeed: closing)
    }
}

struct SideTraffic {
    var left = false
    var right = false

    init(left: Bool = false,right: Bool = false) {
        self.left = left
        self.right = right
    }

    init(player: Vehicle, opponents: [TrafficCar]) {
        for opponent in opponents {
            let offset = opponent.vehicle.position - player.position
            let longitudinal = simd_dot(offset, player.forward)
            let lateral = -simd_dot(offset, player.modelX)
            guard (1.1...4.5).contains(abs(lateral)) else { continue }
            let adjacent = (-6.0...3.5).contains(longitudinal)
            let relativeVelocity = opponent.vehicle.velocity-player.velocity
            let closeRate = simd_dot(relativeVelocity,player.forward)
            let incoming = (-16.0 ..< -6.0).contains(longitudinal) && closeRate > 3 &&
                simd_dot(opponent.vehicle.forward,player.forward) > 0.55 &&
                longitudinal+0.45*closeRate >= -6
            guard adjacent || incoming else { continue }
            if lateral < 0 { left = true } else { right = true }
        }
    }
}

struct SideTrafficHold {
    private var remaining = SIMD2<Double>.zero

    mutating func update(_ warning: SideTraffic,dt: Double,active: Bool) -> SideTraffic {
        guard active else {
            remaining = .zero
            return SideTraffic()
        }
        remaining.x = warning.left ? 0.19 : max(0,remaining.x-dt)
        remaining.y = warning.right ? 0.19 : max(0,remaining.y-dt)
        return SideTraffic(left:remaining.x>0,right:remaining.y>0)
    }
}

struct ComputerTraffic {
    private static let stepInterval = 1.0/120
    private(set) var cars: [TrafficCar] = []
    private var stepClock = 0.0
    private var lastStep = ComputerTraffic.stepInterval
    private var passesEnabled = false

    func displayVehicles(remainder: Double) -> [Vehicle] {
        let fraction = (stepClock+remainder)/lastStep
        return cars.map { car in
            guard let previous = car.previousPose else { return car.vehicle }
            return car.vehicle.displayPose(previous:previous,fraction:fraction)
        }
    }

    mutating func startCooldown(forRivalsFinishedIn race: SprintRace) {
        for index in cars.indices where cars[index].cooldownSpeed == nil {
            if race.entries.indices.contains(index+1), race.entries[index+1].finishTime != nil {
                cars[index].cooldownSpeed = max(19.5,cars[index].vehicle.speed)
            }
        }
    }

    mutating func reset(count: Int, kind: VehicleKind, circuit: Circuit, from progress: Double) {
        stepClock = 0
        passesEnabled = false
        cars = (0..<clamp(count,0,3)).map { index in
            let sample = circuit.sample(at: progress+13+Double(index)*11)
            var car = Vehicle(); car.kind = kind; car.reset(at: sample)
            if circuit.condition == .wet { car.service(setup:TyreSetup(compound:.wet)) }
            let lane = [-0.72,0.72,0.0][index]
            car.position += sample.right*lane
            return TrafficCar(vehicle: car, pace: [0.72,0.78,0.84][index], lane: lane)
        }
    }

    mutating func lineUp(count: Int, kind: VehicleKind, circuit: Circuit) {
        stepClock = 0
        passesEnabled = true
        cars = (0..<clamp(count,1,3)).map { index in
            var car = Vehicle()
            car.kind = kind
            car.reset(at: circuit.gridSlot(index))
            if circuit.condition == .wet { car.service(setup: TyreSetup(compound: .wet)) }
            return TrafficCar(vehicle: car, pace: [0.84,0.78,0.82][index], lane: [0.64,-0.64,0][index])
        }
    }

    mutating func step(_ dt: Double, player: inout Vehicle, circuit: Circuit, line: RacingLine) -> TrafficContact? {
        guard !cars.isEmpty else {return nil}
        stepClock += dt
        if stepClock >= Self.stepInterval {
            let elapsed = stepClock
            stepClock = 0
            lastStep = elapsed
            let snapshot = cars.map(\.vehicle)
            for index in cars.indices {
                var car = snapshot[index]
                cars[index].previousPose = car.renderSample
                let location = circuit.nearest(to: car.position)
                let others = snapshot.indices.filter { $0 != index }.map { snapshot[$0] }+[player]
                let drivingLane: Double
                let speedLimit: Double
                if let previousLimit = cars[index].cooldownSpeed {
                    speedLimit = max(19.5,previousLimit-1.45*elapsed)
                    cars[index].cooldownSpeed = speedLimit
                    drivingLane = cars[index].pass.lane
                } else if passesEnabled {
                    let pace = cars[index].pace, baseLane = cars[index].lane
                    cars[index].pass.update(elapsed,car:car,location:location,circuit:circuit,line:line,
                                            baseLane:baseLane,pace:pace,traffic:others)
                    drivingLane = cars[index].pass.lane
                    speedLimit = .infinity
                } else {
                    drivingLane = cars[index].lane
                    speedLimit = .infinity
                }
                let command = ComputerDriver.input(for: car, at: location, circuit: circuit, line: line,
                                                   pace:cars[index].pace,lane:drivingLane,traffic:others,maximumSpeed:speedLimit)
                car.step(elapsed, input: command, assists: DrivingAssists(), roadDistance: location.distance,
                         roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress,
                         kerbsEnabled: circuit.hasKerb(at: location.progress),
                         roadContacts:circuit.wheelContacts(at:car.contactPoints),wake:AirWake.behind(car,leaders:others))
                let current = circuit.nearest(to: car.position)
                if current.distance > 15 {
                    let normal = (car.position-current.point)/current.distance
                    car.position = current.point+normal*15
                    _ = car.hitBarrier(outward:normal)
                }
                cars[index].vehicle = car
            }
            for i in cars.indices {
                for j in cars.indices where j > i {
                    var first = cars[i].vehicle, second = cars[j].vehicle
                    if TrafficContact.resolve(&first,&second) != nil {
                        cars[i].vehicle = first; cars[j].vehicle = second
                    }
                }
            }
        }
        var strongest: TrafficContact?
        for index in cars.indices {
            if let contact = TrafficContact.resolve(&player,&cars[index].vehicle),
               contact.closingSpeed > (strongest?.closingSpeed ?? 0) {strongest = contact}
        }
        return strongest
    }
}

/// Offline race timing. Entrant 0 is the driver; the remaining indices are stable
/// for the duration of the session, even as their displayed positions change.
struct SprintRace {
    struct Entry {
        fileprivate var progress: Double
        fileprivate var travelled: Double
        fileprivate var nextGate = 1
        fileprivate(set) var laps = 0
        fileprivate(set) var finishTime: Double?
        fileprivate(set) var runningOffTrack = false
        fileprivate var timeOutside = 0.0
        fileprivate var pitOverspeedTime = 0.0
        fileprivate var pitViolation = false
        fileprivate(set) var penalties = 0
        var classifiedTime: Double? { finishTime.map { $0 + 2 * Double(penalties) } }
    }

    let lapCount: Int
    private(set) var entries: [Entry]
    private(set) var countdown = 3.0
    private(set) var elapsed = 0.0
    private(set) var assisted = false
    private var trackLength: Double

    init(lapCount: Int = 2, positions: [Double], trackLength: Double) {
        self.lapCount = lapCount
        self.trackLength = trackLength
        entries = positions.map { Entry(progress: $0, travelled: $0) }
    }

    var order: [Int] {
        entries.indices.sorted {
            let a = entries[$0], b = entries[$1]
            if let finish = a.classifiedTime {
                if let other = b.classifiedTime { return finish == other ? $0 < $1 : finish < other }
                return true
            }
            if b.finishTime != nil { return false }
            if a.laps != b.laps { return a.laps > b.laps }
            return a.travelled == b.travelled ? $0 < $1 : a.travelled > b.travelled
        }
    }
    var driverPosition: Int { (order.firstIndex(of: 0) ?? 0) + 1 }
    var playerFinished: Bool { entries.first?.finishTime != nil }
    var showGo: Bool { countdown == 0 && elapsed < 1.15 }
    var finished: Bool { entries.allSatisfy { $0.finishTime != nil } }
    var countdownSeconds: Int { Int(ceil(max(0,countdown - 1e-6))) }

    mutating func advanceCountdown(_ dt: Double) {
        countdown = max(0, countdown - dt)
        if countdown < 0.000_001 { countdown = 0 }
    }

    @discardableResult
    mutating func observePitSpeed(_ dt: Double,index: Int,inLane: Bool,limited: Bool,speed: Double) -> Bool {
        guard dt > 0, countdown == 0, entries.indices.contains(index), entries[index].finishTime == nil else {
            return false
        }
        if !inLane {
            entries[index].pitOverspeedTime = 0
            entries[index].pitViolation = false
            return false
        }
        guard limited, speed > PitLane.speedLimit+0.75 else {
            entries[index].pitOverspeedTime = 0
            return false
        }
        guard !entries[index].pitViolation else { return false }
        entries[index].pitOverspeedTime += dt
        guard entries[index].pitOverspeedTime+1e-9 >= 0.35 else { return false }
        entries[index].pitViolation = true
        entries[index].penalties += 1
        return true
    }

    mutating func step(_ dt: Double, locations: [TrackLocation], assisted: Bool, width: Double,
                       outside: [Bool]? = nil) {
        guard dt > 0, countdown == 0, locations.count == entries.count, !finished else { return }
        let actualOutside = outside?.count == entries.count ? outside : nil
        let previousTime = elapsed
        elapsed += dt
        self.assisted = self.assisted || (assisted && !playerFinished)
        for index in entries.indices where entries[index].finishTime == nil {
            let location = locations[index], old = entries[index].progress
            let rawDelta = location.progress - old
            let delta = rawDelta > trackLength/2 ? rawDelta - trackLength :
                (rawDelta < -trackLength/2 ? rawDelta + trackLength : rawDelta)
            entries[index].progress = location.progress
            entries[index].runningOffTrack = actualOutside?[index] ?? (location.distance > width/2 + 0.85)
            if entries[index].runningOffTrack {
                entries[index].timeOutside += dt
                if entries[index].timeOutside + 1e-9 >= 1.5 {
                    entries[index].penalties += 1
                    entries[index].timeOutside = max(0,entries[index].timeOutside-1.5)
                }
            } else {
                entries[index].timeOutside = 0
            }
            // A projection jump must not earn race distance or clear a gate.
            guard abs(delta) <= 120*dt + 1.0 else { continue }
            entries[index].travelled += delta
            guard delta > 0 else { continue }
            let gate = Double(entries[index].nextGate) * trackLength / 4
            let toGate = gate - old
            if toGate >= 0 && delta >= toGate {
                if entries[index].nextGate == 4 {
                    entries[index].nextGate = 1
                    entries[index].laps += 1
                    if entries[index].laps == lapCount {
                        entries[index].finishTime = previousTime + dt * (toGate/delta)
                    }
                } else { entries[index].nextGate += 1 }
            }
        }
    }
}

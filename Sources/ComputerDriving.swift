import Foundation
import simd

private let stoppedObstacleSpeedSquared = 0.8 * 0.8

struct TrafficCar {
    var vehicle: Vehicle
    let pace: Double
    let lane: Double
    var pass = PassingPlan()
    var previousPose: VehicleRenderSample?
    var cooldownSpeed: Double?
    var blueFlag = BlueFlagYield()
    var dryingPace = RivalDryingPace()
    fileprivate var pitStop: RivalPitStop?
    fileprivate var pitAttemptLap: Int?
    var pitStatus: RivalPitStatus? { pitStop?.status }

    init(vehicle: Vehicle,pace: Double,lane: Double) {
        self.vehicle = vehicle
        self.pace = pace
        self.lane = lane
    }
}

struct PassingPlan {
    private(set) var lane = 0.0
    private(set) var committedSide = 0.0
    private var targetPosition: SIMD2<Double>?
    private var clearTime = 0.0
    private var passTime = 0.0
    private var decisionClock = 0.0
    private var stationaryCandidate: SIMD2<Double>?
    private var stationaryTime = 0.0
    private var detouringAroundStoppedCar = false
    var speedLimit: Double { detouringAroundStoppedCar ? 13 : .infinity }

    mutating func update(_ dt: Double, car: Vehicle, location: TrackLocation, circuit: Circuit,
                         line: RacingLine, baseLane: Double, pace: Double, traffic: [Vehicle]) {
        decisionClock += dt
        if decisionClock >= 0.10 {
            let elapsed = decisionClock
            decisionClock = 0
            decide(elapsed,car:car,location:location,circuit:circuit,line:line,baseLane:baseLane,pace:pace,traffic:traffic)
        }
        let target = committedSide == 0 ? baseLane : baseLane + committedSide*3.6
        // A fast car needs more distance to move across the same lane width.
        let sideChangeRate = 2.9 - 1.65*clamp((car.speed-12)/25,0,1)
        lane += (target-lane) * (1-exp(-dt*sideChangeRate))
    }

    private mutating func decide(_ dt: Double, car: Vehicle, location: TrackLocation, circuit: Circuit,
                                 line: RacingLine, baseLane: Double, pace: Double, traffic: [Vehicle]) {
        let forward = location.tangent, right = SIMD2(forward.y,-forward.x)
        let carSpeed = max(0,simd_dot(car.velocity,forward))
        let headingAligned = simd_dot(car.forward,forward) > 0.9
        let currentLine = simd_dot(line.sample(at:location.progress).position-location.point,right)
        let nearby = traffic.compactMap { other -> (position: SIMD2<Double>, along: Double, lateral: Double,
                                                    speed: Double, movingSide: Double, stopped: Bool)? in
            let vector = other.position-car.position
            let along = simd_dot(vector,forward), lateral = simd_dot(vector,right)+location.lateral
            guard (-21...58).contains(along), abs(lateral) < circuit.width/2+1 else { return nil }
            return (other.position,along,lateral,max(0,simd_dot(other.velocity,forward)),
                    simd_dot(other.velocity,right),simd_length_squared(other.velocity) < stoppedObstacleSpeedSquared)
        }
        if committedSide != 0 {
            passTime += dt
            let opponent = nearby.filter { abs($0.lateral-(currentLine+baseLane)) < 2.6 }.min {
                simd_distance($0.position,targetPosition ?? car.position) < simd_distance($1.position,targetPosition ?? car.position)
            }
            if let opponent { targetPosition = opponent.position }
            clearTime = (opponent?.along ?? -20) < -9 ? clearTime+dt : 0
            let turnPreview = clamp(carSpeed*1.7,24,55)
            let turnAhead = [0.5,1.0].contains { fraction in
                simd_dot(forward,circuit.sample(at:location.progress+turnPreview*fraction).tangent) < 0.975
            }
            // Check the space swept during the return, including cars
            // approaching from behind or moving back onto the line.
            let mergeClear = !nearby.contains { other in
                let forecast = other.along + 1.5*(other.speed-carSpeed)
                let alongside = min(other.along,forecast) < 9 && max(other.along,forecast) > -9
                let side = other.lateral-(currentLine+baseLane)
                let sideForecast = side+0.85*other.movingSide
                return alongside && min(side,sideForecast) < 2.35 && max(side,sideForecast) > -2.35
            }
            let wantsToReturn = clearTime > 0.85 || turnAhead || passTime > 6
            if (wantsToReturn && mergeClear) ||
               !headingAligned || location.distance > circuit.width/2+1 {
                committedSide = 0; clearTime = 0; passTime = 0; targetPosition = nil
                detouringAroundStoppedCar = false
            }
            return
        }
        let wet = circuit.condition == .wet
        guard (wet || carSpeed > 10), headingAligned, location.distance < circuit.width/2-1.0,
              !circuit.pitLane.contains(location) else {
            stationaryCandidate = nil
            stationaryTime = 0
            return
        }
        let look = clamp(carSpeed*4,wet ? 45 : 58,125)
        let expectedSpeed = wet ? 0 : line.sample(at:location.progress+look).targetSpeed*pace
        let leader = nearby.filter { other in
            guard abs(other.lateral-(currentLine+baseLane)) < 1.95 else { return false }
            if wet {
                return other.stopped && other.along > 2.1 && other.along < max(34,carSpeed*2.1)
            }
            return expectedSpeed >= carSpeed-1.5 &&
                other.along > 6 && other.along < max(19,carSpeed*1.4) &&
                carSpeed-other.speed > 3 && expectedSpeed-other.speed > 12 && other.speed < expectedSpeed*0.67 &&
                (expectedSpeed-other.speed)*2.4 > other.along
        }.min(by: { $0.along < $1.along })
        guard let leader, [0.25,0.5,0.75,1.0].allSatisfy({
            simd_dot(forward,circuit.sample(at:location.progress+look*$0).tangent) > 0.989
        }) else {
            stationaryCandidate = nil
            stationaryTime = 0
            return
        }
        if wet {
            let sameCar = stationaryCandidate.map { simd_distance($0,leader.position) < 1.1 } ?? false
            stationaryTime = sameCar ? stationaryTime+dt : dt
            stationaryCandidate = leader.position
            // A brief crawl at launch or during a spin will not start a pass.
            guard stationaryTime >= 0.5 else { return }
        }
        let aheadSample = circuit.sample(at:location.progress+look)
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
        if let free {
            committedSide = free.0
            targetPosition = leader.position
            detouringAroundStoppedCar = wet
            stationaryCandidate = nil
            stationaryTime = 0
        }
    }
}

enum BlueFlagTraffic {
    static func approach(to entrant: Int, race: SprintRace, field: [Vehicle],
                         location: TrackLocation, circuit: Circuit,
                         locations: [TrackLocation]? = nil) -> (entrantIndex: Int,distance: Double)? {
        guard race.countdown == 0, race.checkeredTime == nil, race.entries.count == field.count, field.indices.contains(entrant),
              race.entries[entrant].status == .racing, location.distance <= circuit.width/2,
              !circuit.pitLane.contains(location) else { return nil }
        let car = field[entrant]
        let forward = location.tangent
        guard simd_dot(car.forward,forward) > 0.25 else { return nil }
        let right = SIMD2(forward.y,-forward.x)
        let speed = max(0,simd_dot(car.velocity,forward))
        let reach = clamp(28+speed*1.5,38,58)
        let laps = race.entries[entrant].laps
        let knownLocations = locations?.count == field.count ? locations : nil
        var nearest: (entrantIndex: Int,distance: Double)?
        for index in field.indices where race.entries[index].status == .racing && race.entries[index].laps > laps {
            let other = field[index]
            let relative = car.position-other.position
            let gap = simd_dot(relative,forward)
            guard gap > 5, gap < reach, abs(simd_dot(relative,right)) < 5,
                  simd_dot(other.forward,forward) > 0.75,
                  simd_dot(other.velocity,forward) > speed-1.1 else { continue }
            let behind = knownLocations?[index] ?? circuit.nearest(to:other.position)
            let routeGap = (location.progress-behind.progress+circuit.length)
                .truncatingRemainder(dividingBy:circuit.length)
            guard routeGap > 4, routeGap < reach, behind.distance <= circuit.width/2,
                  !circuit.pitLane.contains(behind), routeGap < (nearest?.distance ?? .infinity) else { continue }
            nearest = (index,routeGap)
        }
        return nearest
    }
}

struct BlueFlagYield {
    private var chaser: Int?
    private var side = 0.0
    private var scanClock = 0.0
    private var yieldTime = 0.0
    private var targetSpeed = 0.0
    private(set) var offset = 0.0
    private(set) var speedLimit = Double.infinity
    var engaged: Bool { chaser != nil || abs(offset) > 0.03 }

    mutating func update(_ dt: Double, for entrant: Int, field: [Vehicle], race: SprintRace,
                         location: TrackLocation, circuit: Circuit, line: RacingLine, baseLane: Double,
                         passing: Bool) {
        let car = field[entrant]
        guard race.entries[entrant].status == .racing else {
            self = BlueFlagYield()
            return
        }
        scanClock += dt
        if scanClock >= 0.10 {
            let elapsed = scanClock
            scanClock = 0
            decide(elapsed,for:entrant,field:field,race:race,car:car,location:location,
                   circuit:circuit,line:line,baseLane:baseLane,passing:passing)
        }
        if side != 0 || offset != 0 {
            offset += (side*3.75-offset)*(1-exp(-1.45*dt))
        }
        if chaser != nil {
            speedLimit = ComputerDriver.cooldownLimit(from:speedLimit,elapsed:dt,target:targetSpeed)
        } else {
            speedLimit = .infinity
            if abs(offset) < 0.03 { offset = 0 }
        }
    }

    private mutating func decide(_ dt: Double, for entrant: Int, field: [Vehicle], race: SprintRace,
                                 car: Vehicle, location: TrackLocation, circuit: Circuit, line: RacingLine,
                                 baseLane: Double, passing: Bool) {
        let forward = location.tangent
        let right = SIMD2(forward.y,-forward.x)
        let speed = max(0,simd_dot(car.velocity,forward))
        let halfWidth = circuit.width/2-1.50

        func clear(_ lane: Double,_ range: ClosedRange<Double>) -> Bool {
            !field.indices.contains { index in
                guard index != entrant else { return false }
                let other = field[index]
                let relative = other.position-car.position
                let along = simd_dot(relative,forward)
                let lateral = simd_dot(relative,right)+location.lateral
                let relativeVelocity = other.velocity-car.velocity
                let forecastAlong = along+1.15*simd_dot(relativeVelocity,forward)
                let forecastLateral = lateral+clamp(1.15*simd_dot(other.velocity,right),-2.4,2.4)
                return (min(along,forecastAlong) <= range.upperBound && max(along,forecastAlong) >= range.lowerBound) &&
                    min(lateral,forecastLateral) < lane+2.45 && max(lateral,forecastLateral) > lane-2.45
            }
        }

        if let chaser {
            yieldTime += dt
            let lead = simd_dot(field[chaser].position-car.position,forward)
            let mustReturn = lead > 12 || abs(lead) > 65 || yieldTime > 8 || race.entries[chaser].status != .racing
            if mustReturn && clear(simd_dot(line.sample(at:location.progress).position-location.point,right)+baseLane,-10...16) {
                self.chaser = nil
                yieldTime = 0
                side = 0
            }
            return
        }

        guard !passing, abs(offset) < 0.35, speed > 7,
              location.distance < circuit.width/2-1,
              abs(simd_dot(car.velocity,right)) < 2.5, simd_dot(car.forward,forward) > 0.93,
              !circuit.pitLane.contains(location) else { return }
        guard let pursuit = BlueFlagTraffic.approach(to:entrant,race:race,field:field,location:location,circuit:circuit) else {
            return
        }
        let preview = clamp(speed*2.3,33,56)
        guard [0.33,0.66,1].allSatisfy({
            simd_dot(forward,circuit.sample(at:location.progress+preview*$0).tangent) > 0.991
        }) else { return }
        let lineOffset = simd_dot(line.sample(at:location.progress).position-location.point,right)
        let ahead = circuit.sample(at:location.progress+preview)
        let aheadLine = simd_dot(line.sample(at:ahead.distance).position-ahead.point,ahead.right)
        // The racing line can move toward a verge beyond the straight.
        // Reserve room for the full pass before choosing that side.
        let passDistance = clamp(speed*8.9,122,174)
        let laterLines = [0.20,0.40,0.60,0.80,1.0].map { fraction in
            let sample = circuit.sample(at:location.progress+passDistance*fraction)
            return simd_dot(line.sample(at:sample.distance).position-sample.point,sample.right)
        }
        let clearanceOffsets = [lineOffset,aheadLine]+laterLines
        let choice = [-1.0,1.0].compactMap { side -> (Double,Double)? in
            let lane = baseLane+side*3.75
            let here = clamp(lineOffset+lane,-halfWidth,halfWidth)
            let there = clamp(aheadLine+lane,-halfWidth,halfWidth)
            let width = clearanceOffsets.map {
                abs(clamp($0+lane,-halfWidth,halfWidth)-$0)
            }.min() ?? 0
            guard width >= 3.1, clear(here,-12...31), clear(there,-8...35) else { return nil }
            return (side,width-0.18*abs(here-location.lateral))
        }.max { $0.1 < $1.1 }
        guard let choice else { return }
        chaser = pursuit.entrantIndex
        side = choice.0
        targetSpeed = clamp(speed*0.87,9.5,17.0)
        speedLimit = speed
        yieldTime = 0
    }
}

struct ComputerDriver {
    static let playerCooldownTargetSpeed = 18.0 // 64.8 km/h

    static func cooldownLimit(from previousLimit: Double, elapsed: Double, target: Double) -> Double {
        max(target, previousLimit - 1.45 * max(0, elapsed))
    }

    static func wantsControl(_ input: DrivingInput) -> Bool {
        input.throttle > 0.12 || input.brake > 0.12 || abs(input.steering) > 0.22
    }

    static func canDrive(_ vehicle: Vehicle, at location: TrackLocation, on circuit: Circuit) -> Bool {
        vehicle.gear > 0 && location.distance < circuit.width/2 + 1 && simd_dot(vehicle.forward, location.tangent) > 0.25
    }

    static func input(for car: Vehicle, at location: TrackLocation, circuit: Circuit, line: RacingLine,
                      pace: Double, lane: Double = 0, traffic: [Vehicle] = [],
                      brakeCurve: BrakeCurve = .progressive, steeringCurve: SteeringCurve = .standard,
                      maximumSpeed: Double = .infinity, keepRoomForWetDetour: Bool = false) -> DrivingInput {
        let alignment = simd_dot(car.forward,location.tangent)
        if location.distance > circuit.width/2+0.35 || alignment < 0.32 {
            return recover(car,at:location,circuit:circuit,traffic:traffic,brakeCurve:brakeCurve)
        }
        let launchLookAhead = 3.4*clamp(1-car.speed/21,0,1)
        // Preview steering farther ahead in the wet to avoid sharp
        // corrections while the chassis is still braking on low grip.
        let wetSteering = circuit.condition == .wet
        let lookAhead = clamp(5+car.speed*(wetSteering ? 0.46 : 0.37)+launchLookAhead,5,wetSteering ? 25 : 22)
        let aimProgress = location.progress + lookAhead
        let sample = circuit.sample(at:aimProgress)
        let rawAim = line.sample(at:aimProgress).position + sample.right*lane
        let offset = simd_dot(rawAim-sample.point,sample.right)
        let safeWidth = circuit.width/2-1.32-0.90*clamp((car.speed-10)/26,0,1)
        let aim = abs(lane) > 1 ? rawAim + sample.right*(clamp(offset,-safeWidth,safeWidth)-offset) : rawAim
        let steering = steering(for:car,toward:aim,curve:steeringCurve)
        let preview = min(7, 1+car.speed*0.16)
        var target = min(maximumSpeed,line.sample(at:location.progress+preview).targetSpeed*pace)
        // Keep a following gap when another car occupies the intended corridor.
        let wetGridConvergence = keepRoomForWetDetour && car.distanceTravelled < 30 && abs(lane) < 1
        for other in traffic {
            let offset = other.position-car.position
            let ahead = simd_dot(offset, car.forward)
            let stationaryObstacle = keepRoomForWetDetour && simd_length_squared(other.velocity) < stoppedObstacleSpeedSquared
            // Start braking earlier so a queued car still has room to steer
            // around the obstacle if an adjacent corridor opens.
            let followingRange = stationaryObstacle ? max(30,car.speed*2.15) : max(18,car.speed*1.3)
            guard ahead > 0, ahead < followingRange else { continue }
            let lateral = -simd_dot(offset, car.modelX)
            let aimOffset = steering.aimOffset * clamp(ahead/max(lookAhead,1), 0, 1)
            let frontSpeed = max(0,simd_dot(other.velocity,car.forward))
            let corridorOffset = lateral-aimOffset
            let lateralRate = -simd_dot(other.velocity-car.velocity,car.modelX)
            let merging = ahead < max(8,car.speed*0.75) && frontSpeed < car.speed &&
                abs(corridorOffset+0.5*lateralRate) < 2.3
            // On a wet start, two staggered cars may still be converging
            // after the car ahead starts accelerating away.
            let gridMerge = wetGridConvergence && ahead < 6 && abs(lateralRate) > 0.45 &&
                corridorOffset*lateralRate < 0 && abs(corridorOffset+lateralRate) < 2.3
            if abs(corridorOffset) < 2.05 || merging || gridMerge {
                let buffer = stationaryObstacle ? 10.5 : 5
                target = min(target,max(0,frontSpeed+(ahead-buffer-car.speed*0.45)*0.85))
            }
        }
        let error = target-car.speed
        let demand = clamp((-error-0.45)*0.19,0,1)
        // Leave lateral grip for cornering and for closing the offset from a
        // staggered grid slot. Ease back into power as the car settles.
        let cornerDemand = abs(tan(steering.pursuit))*car.speed*car.speed/car.wheelbase
        let bodySlip = abs(steering.slip)
        let lineOffset = simd_dot(line.sample(at:location.progress).position-location.point,
                                   SIMD2(location.tangent.y,-location.tangent.x)) + lane
        let mergeLoad = clamp(abs(location.lateral-lineOffset)/2,0,1)*clamp((26-car.speed)/15,0,1)
        let throttleReserve = min(1-0.56*mergeLoad,clamp(1.10-cornerDemand/7,0.28,1),
                                  clamp(1.08-bodySlip*5.4,0.14,1))
        return DrivingInput(throttle: clamp(error*0.20,0,throttleReserve),
                            brake: Vehicle.brakeTravel(for:demand,curve:brakeCurve), steering: steering.input)
    }

    fileprivate static func steering(for car: Vehicle,toward aim: SIMD2<Double>,curve: SteeringCurve)
        -> (input: Double,pursuit: Double,slip: Double,aimOffset: Double) {
        let direction = aim-car.position
        let right = -simd_dot(direction,car.modelX)
        let pursuit = atan(2*car.wheelbase*right/max(1,simd_length_squared(direction)))
        let slip = simd_dot(car.velocity,car.modelX)/max(4,car.speed)
        let stabilization = copysign(0.45*max(0,abs(slip)-0.055),slip)
        let requested = clamp((pursuit+car.yawRate*0.075-stabilization)/car.steeringLimit,-1,1)
        // Invert the same nonlinear input curve used by the vehicle solver.
        var low = 0.0, high = 1.0
        for _ in 0..<10 {
            let middle = (low+high)/2
            if Vehicle.steeringResponse(middle,curve:curve) < abs(requested) { low = middle }
            else { high = middle }
        }
        return (copysign((low+high)/2,requested),pursuit,slip,right)
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
    let point: SIMD2<Double>

    static func resolve(_ first: inout Vehicle, _ second: inout Vehicle) -> TrafficContact? {
        let firstBody = first.kind.bodyEnvelope, secondBody = second.kind.bodyEnvelope
        let reach = max(firstBody.y,firstBody.z)+max(secondBody.y,secondBody.z)
        guard simd_distance_squared(first.position,second.position) < reach*reach else { return nil }
        // Three overlapping circles approximate each footprint while keeping
        // side-by-side clearance narrower than front-to-back clearance.
        var depth = 0.0
        var normal = first.forward
        var contactPoint = (first.position + second.position) / 2
        let radii = firstBody.x+secondBody.x
        let secondOffsets = [secondBody.x-secondBody.z,0,secondBody.y-secondBody.x]
        for firstOffset in [firstBody.x-firstBody.z,0,firstBody.y-firstBody.x] {
            let firstCentre = first.position + first.forward * firstOffset
            for secondOffset in secondOffsets {
                let secondCentre = second.position + second.forward * secondOffset
                let separation = secondCentre - firstCentre
                let distance = simd_length(separation)
                if radii-distance > depth {
                    depth = radii-distance
                    normal = distance > 0.001 ? separation/distance : first.forward
                    contactPoint = (firstCentre+secondCentre+normal*(firstBody.x-secondBody.x))/2
                }
            }
        }
        guard depth > 0 else {return nil}
        let firstArm = contactPoint - first.centreOfGravityPosition
        let secondArm = contactPoint - second.centreOfGravityPosition
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
        return TrafficContact(normal:normal,closingSpeed:closing,point:contactPoint)
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

struct RivalDryingPace {
    private static let sampleInterval = 0.10
    private var timeSinceSample = 0.0
    private(set) var scale = 1.0

    mutating func update(_ dt: Double, car: Vehicle, location: TrackLocation, circuit: Circuit,
                         line: RacingLine, lane: Double, drying: TrackDrying?) -> Double {
        guard circuit.condition == .wet, let drying, drying.elapsed > 0,
              car.speed > 12, car.distanceTravelled > 45, location.distance < circuit.width/2-1.4 else {
            timeSinceSample = 0
            scale = 1
            return scale
        }
        timeSinceSample += dt
        guard timeSinceSample+1e-9 >= Self.sampleInterval else { return scale }
        timeSinceSample = max(0,timeSinceSample-Self.sampleInterval)
        let forecast = Self.forecast(car:car,location:location,circuit:circuit,line:line,lane:lane,drying:drying)
        scale = min(forecast,scale+0.004)
        return scale
    }

    private static func forecast(car: Vehicle, location: TrackLocation, circuit: Circuit,
                                 line: RacingLine, lane: Double, drying: TrackDrying) -> Double {
        let right = SIMD2(location.tangent.y,-location.tangent.x)
        let desired = simd_dot(line.sample(at:location.progress).position-location.point,right)+lane
        let centreError = clamp(location.lateral-desired,-1.0,1.0)
        let horizon = clamp(car.speed*1.1,19,36)
        let compound = car.wheels[0].setup.compound
        let halfTrack = car.trackWidth/2
        let edge = circuit.width/2-0.45
        var gripRatio = Double.infinity
        for fraction in [0.42,0.72,1.0] {
            let station = location.progress+horizon*fraction
            let sample = circuit.sample(at:station)
            let point = line.sample(at:station).position
            let lateral = simd_dot(point-sample.point,sample.right)+lane+centreError*(1-fraction)
            guard abs(lateral)+halfTrack < edge else { return 1 }
            for offset in [-halfTrack,halfTrack] {
                let cross = lateral+offset
                let fixedFilm = circuit.waterDepth(at:station,lateral:cross)
                let liveFilm = drying.depth(from:fixedFilm,at:station,lateral:cross)
                let fixedGrip = compound.wetGrip(waterDepth:fixedFilm,speed:car.speed)
                let liveGrip = compound.wetGrip(waterDepth:liveFilm,speed:car.speed)
                gripRatio = min(gripRatio,liveGrip/fixedGrip)
            }
        }
        // Cornering demand follows speed squared. Use only part of the
        // smallest gain under either tyre path and keep the allowance bounded.
        return 1+min(0.03,0.65*max(0,sqrt(gripRatio)-1))
    }
}

enum RivalPitStatus: Equatable {
    case entering
    case servicing(remaining: Double)
    case leaving
}

struct RivalPitStop {
    private enum Phase {
        case entering
        case servicing(PitServicePlan,remaining: Double)
        case leaving
        case merging
    }

    private static let entryWindow = -207.0 ... -148.0
    private static let mergeDistance = 57.0
    private var phase = Phase.entering
    private let approachStart: Double
    private var settled = 0.0

    init(approachStart: Double) { self.approachStart = approachStart }

    var status: RivalPitStatus {
        switch phase {
        case .entering: return .entering
        case let .servicing(_,remaining): return .servicing(remaining:remaining)
        case .leaving,.merging: return .leaving
        }
    }

    static func work(for car: Vehicle) -> PitServiceWork? {
        var punctures = 0
        for wheel in car.wheels where wheel.punctured { punctures += 1 }
        let damage = car.damage
        let repairs = damage.engine >= 0.42 || damage.front >= 0.70 ||
            damage.rear >= 0.70 || damage.suspension.contains { $0 >= 0.50 }
        guard punctures <= 1,car.powerFactor >= 0.38 else { return nil }
        if punctures > 0 { return repairs ? .both : .tyres }
        return repairs ? .repairs : nil
    }

    static func canEnter(car: Vehicle,location: TrackLocation,circuit: Circuit,others: [Vehicle]) -> Bool {
        let pit = circuit.pitLane
        guard car.gear > 0,entryWindow.contains(pit.localProgress(location.progress)),location.distance < circuit.width/2-1,
              simd_dot(car.forward,location.tangent) > 0.72,!bayOccupied(pit,on:circuit,others:others) else { return false }
        return !others.contains { other in
            let delta = other.position-car.position
            let left = simd_dot(delta,car.modelX)
            guard left >= 0.2,left < 5 else { return false }
            let ahead = simd_dot(delta,location.tangent)
            return ahead > -max(9,(other.speed-car.speed)*1.15) && ahead < 11
        }
    }

    private static func bayOccupied(_ pit: PitLane,on circuit: Circuit,others: [Vehicle]) -> Bool {
        others.contains { other in
            let location = circuit.nearest(to:other.position)
            return pit.hasAsphalt(at:location) &&
                abs(pit.localProgress(location.progress)-PitLane.boxProgress) < 5 &&
                abs(location.lateral-pit.lateral(at:PitLane.boxProgress)) < 1.7
        }
    }

    mutating func input(_ dt: Double,car: inout Vehicle,at location: TrackLocation,circuit: Circuit,
                        line: RacingLine,lane: Double,pace: Double,others: [Vehicle],
                        work: PitServiceWork?,speedLimit: Double) -> DrivingInput? {
        let pit = circuit.pitLane
        let progress = pit.localProgress(location.progress)
        let inBox = pit.inServiceBox(location)
        let drivablePit = pit.hasAsphalt(at:location) || abs(location.lateral-pit.lateral(at:progress)) < PitLane.halfWidth+1.8
        if progress > PitLane.exit+Self.mergeDistance+12 ||
            ((PitLane.limitEntry...PitLane.limitExit).contains(progress) && !drivablePit) {
            if case .servicing = phase { car.gear = 1 }
            return nil
        }
        if case .entering = phase, work == nil || progress >= PitLane.boxProgress+3.2 {
            if progress < PitLane.entry { return nil }
            phase = .leaving
        }
        if case let .servicing(plan,remaining) = phase {
            if work != nil && inBox && car.speed < 0.55 {
                if remaining > dt+1e-9 {
                    phase = .servicing(plan,remaining:remaining-dt)
                    return DrivingInput(brake:1)
                }
                car.completePitService(plan)
            }
            // An interrupted stop retains its wear and damage. The car
            // uses the pit lane to depart from wherever it is now.
            car.gear = 1
            phase = .leaving
        }

        let target: Double
        switch phase {
        case .entering:
            let occupied = Self.bayOccupied(pit,on:circuit,others:others)
            let stop = occupied ? PitLane.boxProgress-10 : PitLane.boxProgress
            var entrySpeed = min(19.5,sqrt(11.6*11.6+2*1.35*max(0,-114-progress)))
            if circuit.condition == .wet && (car.wheels[0].punctured || car.wheels[1].punctured) {
                // A punctured steering axle needs more time to follow the
                // wet branch. Brake before it and release the cap in the pit.
                let ahead = max(0,PitLane.entry-8-progress)
                let after = max(0,progress-(PitLane.limitEntry+4))
                let crossingSpeed = 8.6
                entrySpeed = min(entrySpeed,sqrt(crossingSpeed*crossingSpeed+2*1.35*(ahead+after)))
            }
            target = min(entrySpeed,sqrt(2*1.55*max(0,stop-progress-0.55)))
            settled = !occupied && inBox && car.speed < 0.50 ? settled+dt : 0
            if settled >= 0.20, let work {
                let plan = PitServicePlan(work:work,damage:car.damage,tyreSetup:car.wheels[0].setup)
                phase = .servicing(plan,remaining:plan.duration)
                car.gear = 0
                return DrivingInput(brake:1)
            }
        case .servicing:
            return DrivingInput(brake:1)
        case .leaving:
            var exitTarget = PitLane.speedLimit-1
            if progress < PitLane.boxProgress && Self.bayOccupied(pit,on:circuit,others:others) {
                exitTarget = min(exitTarget,sqrt(2*1.55*max(0,PitLane.boxProgress-10-progress-0.55)))
            }
            if progress > PitLane.limitExit-20 {
                if Self.mergeOccupied(progress:progress,car:car,pit:pit,circuit:circuit,others:others) {
                    let hold = PitLane.limitExit+11
                    exitTarget = min(exitTarget,sqrt(2*1.5*max(0,hold-progress-0.8)))
                } else if progress > PitLane.limitExit+6 {
                    phase = .merging
                }
            }
            target = exitTarget
        case .merging:
            if progress >= PitLane.exit+Self.mergeDistance-3 && location.distance < circuit.width/2-1 { return nil }
            target = min(22,line.sample(at:location.progress+5).targetSpeed*pace)
        }

        let distance = location.progress+clamp(3+car.speed*0.45,3,13)
        let aim = route(at:distance,pit:pit,circuit:circuit,line:line,lane:lane)
        let steering = ComputerDriver.steering(for:car,toward:aim,curve:.standard).input
        let occupiedLaneLimit = laneTrafficSpeed(progress:progress,pit:pit,circuit:circuit,line:line,lane:lane,others:others)
        let error = min(target,speedLimit,occupiedLaneLimit)-car.speed
        let pressure = clamp((-error-0.12)*0.22,0,1)
        let command = DrivingInput(throttle:clamp(error*0.27,0,0.54),
                                   brake:Vehicle.brakeTravel(for:pressure),steering:steering)
        return pit.isLimited(location) ? pitLimitedInput(command,speed:car.speed,limit:PitLane.speedLimit-0.5) : command
    }

    private func laneTrafficSpeed(progress: Double,pit: PitLane,circuit: Circuit,line: RacingLine,
                                  lane: Double,others: [Vehicle]) -> Double {
        guard (approachStart...(PitLane.exit+Self.mergeDistance)).contains(progress) else { return .infinity }
        var target = Double.infinity
        for other in others {
            let location = circuit.nearest(to:other.position)
            let gap = pit.localProgress(location.progress)-progress
            guard gap > 0,gap < 35 else { continue }
            if !pit.contains(location) {
                guard progress < PitLane.limitEntry || progress >= PitLane.limitExit else { continue }
                let aim = route(at:location.progress,pit:pit,circuit:circuit,line:line,lane:lane)
                let right = SIMD2(location.tangent.y,-location.tangent.x)
                guard abs(simd_dot(other.position-aim,right)) < 2.6 else { continue }
            }
            let speed = max(0,simd_dot(other.velocity,location.tangent))
            target = min(target,sqrt(speed*speed+2*1.8*max(0,gap-6)))
        }
        return target
    }

    private static func mergeOccupied(progress: Double,car: Vehicle,pit: PitLane,circuit: Circuit,
                                      others: [Vehicle]) -> Bool {
        let mergeStart = PitLane.exit-25
        let mergeEnd = PitLane.exit+mergeDistance
        let releaseTime = (mergeEnd-progress)/max(12,car.speed)+1.1
        return others.contains { other in
            let location = circuit.nearest(to:other.position)
            let station = pit.localProgress(location.progress)
            guard !pit.contains(location),location.distance < circuit.width/2+1.2,
                  station <= mergeEnd+9 else { return false }
            return station+max(12,simd_dot(other.velocity,location.tangent))*releaseTime >= mergeStart
        }
    }

    private func route(at station: Double,pit: PitLane,circuit: Circuit,line: RacingLine,lane: Double) -> SIMD2<Double> {
        let sample = circuit.sample(at:station)
        let progress = pit.localProgress(station)
        let path = sample.point+sample.right*pit.lateral(at:progress)
        if (PitLane.entry...PitLane.exit).contains(progress) { return path }
        let normal = line.sample(at:station).position+sample.right*lane
        let entry = progress < PitLane.entry
        let fraction = entry ? (progress-approachStart)/(PitLane.entry-approachStart) :
            (progress-PitLane.exit)/Self.mergeDistance
        let x = clamp(fraction,0,1)
        let blend = x*x*(3-2*x)
        return entry ? normal+(path-normal)*blend : path+(normal-path)*blend
    }
}

struct ComputerTraffic {
    private static let stepInterval = 1.0/120
    private static let sprintPaces = [0.84,0.78,0.82]
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

    static func sprintPace(for rival: Int, scale: Double = 1) -> Double {
        let difficulty = scale.isFinite ? clamp(scale,0.8,1.15) : 1
        return sprintPaces[clamp(rival,0,sprintPaces.count-1)]*difficulty
    }

    mutating func lineUp(count: Int, kind: VehicleKind, circuit: Circuit,
                         paceScale: Double = 1, playerGridSlot: Int? = nil,
                         rivalGridOrder: [Int]? = nil) {
        stepClock = 0
        passesEnabled = true
        let rivalCount = clamp(count,1,Self.sprintPaces.count)
        let playerSlot = clamp(playerGridSlot ?? rivalCount,0,rivalCount)
        let identities = Array(0..<rivalCount)
        let ordered = rivalGridOrder?.sorted() == identities ? rivalGridOrder : nil
        cars = (0..<rivalCount).map { index in
            let rank = ordered?.firstIndex(of:index) ?? index
            let gridSlot = rank < playerSlot ? rank : rank + 1
            var car = Vehicle()
            car.kind = kind
            car.reset(at: circuit.gridSlot(gridSlot))
            if circuit.condition == .wet { car.service(setup: TyreSetup(compound: .wet)) }
            return TrafficCar(vehicle: car, pace: Self.sprintPace(for:index,scale:paceScale),
                              lane: [0.64,-0.64,0][index])
        }
    }

    mutating func step(_ dt: Double, player: inout Vehicle, circuit: Circuit, line: RacingLine,
                       drying: TrackDrying? = nil,race: SprintRace? = nil) -> TrafficContact? {
        guard !cars.isEmpty else {return nil}
        stepClock += dt
        if stepClock >= Self.stepInterval {
            let elapsed = stepClock
            stepClock = 0
            lastStep = elapsed
            let snapshot = cars.map(\.vehicle)
            let timing = race.flatMap { standings in
                standings.countdown == 0 && !standings.finished && standings.entries.count == snapshot.count+1
                    ? standings : nil
            }
            let field = timing == nil ? [] : [player]+snapshot
            var pitOwner = cars.firstIndex { $0.pitStop != nil }
            for index in cars.indices {
                var car = snapshot[index]
                cars[index].previousPose = car.renderSample
                let location = circuit.nearest(to: car.position)
                let others = snapshot.indices.filter { $0 != index }.map { snapshot[$0] }+[player]
                let drivingLane: Double
                let speedLimit: Double
                if let previousLimit = cars[index].cooldownSpeed {
                    speedLimit = ComputerDriver.cooldownLimit(from:previousLimit,elapsed:elapsed,target:19.5)
                    cars[index].cooldownSpeed = speedLimit
                    drivingLane = cars[index].pass.lane
                } else if passesEnabled {
                    let pace = cars[index].pace, baseLane = cars[index].lane
                    if timing == nil && cars[index].blueFlag.engaged { cars[index].blueFlag = BlueFlagYield() }
                    if !cars[index].blueFlag.engaged {
                        cars[index].pass.update(elapsed,car:car,location:location,circuit:circuit,line:line,
                                                baseLane:baseLane,pace:pace,traffic:others)
                    }
                    let lane = cars[index].pass.lane
                    if let timing {
                        let passing = cars[index].pass.committedSide != 0
                        cars[index].blueFlag.update(elapsed,for:index+1,field:field,race:timing,
                                                    location:location,circuit:circuit,line:line,
                                                    baseLane:lane,passing:passing)
                        drivingLane = lane+cars[index].blueFlag.offset
                        speedLimit = min(cars[index].pass.speedLimit,cars[index].blueFlag.speedLimit)
                    } else {
                        drivingLane = lane
                        speedLimit = cars[index].pass.speedLimit
                    }
                } else {
                    drivingLane = cars[index].lane
                    speedLimit = .infinity
                }
                let pace = cars[index].pace
                let entry = timing?.entries[index+1]
                let racing = entry?.status == .racing && cars[index].cooldownSpeed == nil
                let clearRunning = racing &&
                    cars[index].pass.committedSide == 0 && !cars[index].blueFlag.engaged && !speedLimit.isFinite
                let work = passesEnabled && racing && timing?.checkeredTime == nil ? RivalPitStop.work(for:car) : nil
                if pitOwner == nil, work != nil, clearRunning, let lap = entry?.laps,
                   cars[index].pitAttemptLap != lap,
                   RivalPitStop.canEnter(car:car,location:location,circuit:circuit,others:others) {
                    let approach = circuit.pitLane.localProgress(location.progress)
                    cars[index].pitStop = RivalPitStop(approachStart:approach)
                    cars[index].pitAttemptLap = lap
                    pitOwner = index
                }
                var pitCommand: DrivingInput?
                if var stop = cars[index].pitStop {
                    pitCommand = stop.input(elapsed,car:&car,at:location,circuit:circuit,line:line,
                        lane:cars[index].lane,pace:pace,others:others,work:work,
                        speedLimit:cars[index].cooldownSpeed ?? .infinity)
                    cars[index].pitStop = pitCommand == nil ? nil : stop
                    if pitCommand == nil { pitOwner = nil }
                }
                let limping = work?.repairsDamage == true
                let dryingScale = cars[index].dryingPace.update(elapsed,car:car,location:location,
                    circuit:circuit,line:line,lane:drivingLane,drying:clearRunning && work == nil && pitCommand == nil ? drying : nil)
                let command = pitCommand ?? ComputerDriver.input(for:car,at:location,circuit:circuit,line:line,
                    pace:pace*dryingScale*(limping ? 0.73 : 1),lane:drivingLane,traffic:others,
                    maximumSpeed:limping ? min(speedLimit,23) : speedLimit,
                    keepRoomForWetDetour:passesEnabled && circuit.condition == .wet)
                car.step(elapsed, input: command, assists: DrivingAssists(), roadDistance: location.distance,
                         roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress,
                         kerbsEnabled: circuit.hasKerb(at: location.progress),
                         roadContacts:circuit.wheelContacts(at:car.contactPoints,drying:drying),wake:AirWake.behind(car,leaders:others))
                let current = circuit.nearest(to: car.position)
                _ = car.constrainToGuardRail(at:current)
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

struct RaceLap: Codable, Equatable {
    let time: Double
    let clean: Bool
}

/// Offline race timing. Entrant 0 is the driver; the remaining indices are stable
/// for the duration of the session, even as their displayed positions change.
struct SprintRace {
    static let lapOptions = [2,3,5,8]
    static let defaultLapCount = 2
    static let lapHistoryLimit = 8

    enum Status: String, Codable {
        case racing, finished, retired, timedOut
    }

    enum RunningGap: Equatable {
        case distance(Double)
        case timed(Double)
        case laps(Int)
    }

    struct Classification: Codable, Equatable {
        let index: Int
        let position: Int
        let status: Status
        let laps: Int
        let finishTime: Double?
        let penaltySeconds: Double
        let classifiedTime: Double?
        let bestLap: Double?
    }

    struct Entry {
        fileprivate var progress: Double
        fileprivate var travelled: Double
        fileprivate var nextGate = 1
        fileprivate(set) var status = Status.racing
        fileprivate(set) var laps = 0
        fileprivate(set) var finishTime: Double?
        fileprivate(set) var runningOffTrack = false
        fileprivate var timeOutside = 0.0
        fileprivate var pitOverspeedTime = 0.0
        fileprivate var pitViolation = false
        fileprivate var stoppedClearTime = 0.0
        fileprivate(set) var penalties = 0
        fileprivate var lastCrossingTime: Double?
        fileprivate var checkpointTimes: [Double?] = []
        fileprivate var lapCompromised = false
        fileprivate(set) var bestLap: Double?
        fileprivate(set) var lapHistory: [RaceLap] = []
        var penaltySeconds: Double { 2 * Double(penalties) }
        var classifiedTime: Double? { finishTime.map { $0 + penaltySeconds } }
    }

    let lapCount: Int
    private(set) var entries: [Entry]
    private(set) var countdown = 3.0
    private(set) var elapsed = 0.0
    private(set) var checkeredTime: Double?
    private(set) var longestCleanLap: Double?
    private(set) var assisted = false
    private let trackLength: Double

    init(lapCount: Int = SprintRace.defaultLapCount, positions: [Double], trackLength: Double) {
        self.lapCount = max(1,lapCount)
        self.trackLength = trackLength
        entries = positions.map { Entry(progress: $0, travelled: $0) }
    }

    var order: [Int] {
        entries.indices.sorted {
            let a = entries[$0], b = entries[$1]
            if let finish = a.classifiedTime {
                if let other = b.classifiedTime {
                    if a.laps != b.laps { return a.laps > b.laps }
                    if finish != other { return finish < other }
                    if a.finishTime != b.finishTime, let first = a.finishTime, let second = b.finishTime {
                        return first < second
                    }
                    return $0 < $1
                }
                return true
            }
            if b.finishTime != nil { return false }
            if (a.status == .racing) != (b.status == .racing) { return a.status == .racing }
            if a.laps != b.laps { return a.laps > b.laps }
            return a.travelled == b.travelled ? $0 < $1 : a.travelled > b.travelled
        }
    }
    var classifications: [Classification] {
        order.enumerated().map { place,index in
            let entry = entries[index]
            return Classification(index:index,position:place+1,status:entry.status,laps:entry.laps,
                                  finishTime:entry.finishTime,penaltySeconds:entry.penaltySeconds,
                                  classifiedTime:entry.classifiedTime,bestLap:entry.bestLap)
        }
    }
    var playerClassification: Classification? { classifications.first { $0.index == 0 } }
    var playerLaps: [RaceLap] { entries.first?.lapHistory ?? [] }
    var driverPosition: Int { (order.firstIndex(of: 0) ?? 0) + 1 }
    var driverGapAhead: RunningGap? {
        let ranked = order
        guard countdown == 0, let place = ranked.firstIndex(of:0), place > 0 else { return nil }
        let driver = entries[0]
        let leader = entries[ranked[place-1]]
        guard driver.status == .racing, leader.status == .racing else { return nil }
        let distance = max(0,leader.travelled-driver.travelled)
        if trackLength > 0 && distance >= trackLength {
            return .laps(Int(min(Double(lapCount),floor(distance/trackLength))))
        }
        let checkpoint = driver.checkpointTimes.count-1
        // After a pass between checkpoints, the live order can change before
        // there is a comparable time for the new pair of cars.
        if let crossed = driver.checkpointTimes.last ?? nil, leader.checkpointTimes.indices.contains(checkpoint),
           let led = leader.checkpointTimes[checkpoint], crossed >= led {
            return .timed(crossed-led)
        }
        return .distance(distance)
    }
    var playerFinished: Bool { entries.first?.status == .finished }
    var playerDone: Bool { entries.first.map { $0.status != .racing } ?? false }
    var showGo: Bool { countdown == 0 && elapsed < 1.15 && !finished }
    var finished: Bool { entries.allSatisfy { $0.status != .racing } }
    var countdownSeconds: Int { Int(ceil(max(0,countdown - 1e-6))) }

    mutating func advanceCountdown(_ dt: Double) {
        guard dt.isFinite, dt > 0, !finished else { return }
        countdown = max(0, countdown - dt)
        if countdown < 0.000_001 { countdown = 0 }
    }

    @discardableResult
    mutating func retire(index: Int) -> Bool {
        guard entries.indices.contains(index), entries[index].status == .racing else { return false }
        entries[index].status = .retired
        entries[index].runningOffTrack = false
        return true
    }

    mutating func closeOutStoppedRivals(_ dt: Double,rivals: [TrafficCar],locations: [TrackLocation],
                                        circuit: Circuit,finishRolloutComplete: Bool) {
        guard dt.isFinite, dt > 0, countdown == 0,
              entries.count == rivals.count+1, locations.count == entries.count else { return }
        let dwell = 2.5
        var canClose = checkeredTime != nil && playerDone && finishRolloutComplete
        for index in rivals.indices where entries[index+1].status == .racing {
            let entrant = index+1
            let elapsed = entries[entrant].stoppedClearTime
            if Self.isStoppedClear(rivals[index],at:locations[entrant],on:circuit) {
                if elapsed < dwell { entries[entrant].stoppedClearTime = min(dwell,elapsed+dt) }
            } else if elapsed > 0 {
                entries[entrant].stoppedClearTime = 0
            }
            if entries[entrant].stoppedClearTime+1e-9 < dwell { canClose = false }
        }
        // Settling the entire remaining field together leaves the race order
        // and traffic decisions unchanged while any other driver is still racing.
        guard canClose else { return }
        for entrant in entries.indices where entries[entrant].status == .racing { retire(index:entrant) }
    }

    private static func isStoppedClear(_ rival: TrafficCar,at location: TrackLocation,on circuit: Circuit) -> Bool {
        let car = rival.vehicle
        guard rival.pitStatus == nil, simd_length_squared(car.velocity) < 0.25*0.25,
              location.distance > circuit.width/2+3.2 else { return false }
        let pit = circuit.pitLane
        let progress = pit.localProgress(location.progress)
        guard !pit.hasAsphalt(at:location),
              !(location.lateral < 0 && (PitLane.entry-18...PitLane.exit+18).contains(progress)) else { return false }
        let right = SIMD2(location.tangent.y,-location.tangent.x)
        let fromRoad = location.lateral < 0 ? -right : right
        guard location.distance > circuit.width/2+car.projectedBodyReach(toward:-fromRoad) else { return false }
        if car.powerFactor < 0.32 && (car.damage.engine > 0.62 || car.coolantTemperature > 130) { return true }
        var punctures = 0
        for wheel in car.wheels where wheel.punctured {
            punctures += 1
            if punctures == 2 { return true }
        }
        return false
    }

    mutating func finalizeUnfinished() {
        guard playerDone || checkeredTime != nil else { return }
        for index in entries.indices where entries[index].status == .racing {
            entries[index].status = .timedOut
            entries[index].runningOffTrack = false
        }
    }

    @discardableResult
    mutating func observePitSpeed(_ dt: Double,index: Int,inLane: Bool,limited: Bool,speed: Double) -> Bool {
        guard dt.isFinite, dt > 0, countdown == 0, entries.indices.contains(index), entries[index].status == .racing else {
            return false
        }
        if !inLane {
            entries[index].pitOverspeedTime = 0
            entries[index].pitViolation = false
            return false
        }
        entries[index].lapCompromised = true
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
        guard dt.isFinite, dt > 0, countdown == 0, locations.count == entries.count, !finished else { return }
        let actualOutside = outside?.count == entries.count ? outside : nil
        let previousTime = elapsed
        elapsed += dt
        self.assisted = self.assisted || (assisted && !playerDone)
        var winningCrossing: Double?
        for index in entries.indices where entries[index].status == .racing {
            let location = locations[index], old = entries[index].progress
            guard location.progress.isFinite else { continue }
            let rawDelta = location.progress - old
            let delta = rawDelta > trackLength/2 ? rawDelta - trackLength :
                (rawDelta < -trackLength/2 ? rawDelta + trackLength : rawDelta)
            entries[index].progress = location.progress
            entries[index].runningOffTrack = actualOutside?[index] ?? (location.distance > width/2 + 0.85)
            if entries[index].runningOffTrack {
                entries[index].lapCompromised = true
                entries[index].timeOutside += dt
                if entries[index].timeOutside + 1e-9 >= 1.5 {
                    entries[index].penalties += 1
                    entries[index].timeOutside = max(0,entries[index].timeOutside-1.5)
                }
            } else {
                entries[index].timeOutside = 0
            }
            // A projection jump must not earn race distance or clear a gate.
            guard abs(delta) <= 120*dt + 1.0 else {
                entries[index].lapCompromised = true
                continue
            }
            entries[index].travelled += delta
            guard delta > 0 else { continue }
            let gate = Double(entries[index].nextGate) * trackLength / 4
            let toGate = gate - old
            if toGate > 0 && delta >= toGate {
                let crossingTime = previousTime + dt * (toGate/delta)
                entries[index].checkpointTimes.append(entries[index].runningOffTrack ? nil : crossingTime)
                if entries[index].nextGate == 4 {
                    let previousCrossing = entries[index].lastCrossingTime
                    let lapTime = crossingTime - (previousCrossing ?? 0)
                    let clean = !entries[index].lapCompromised
                    if entries[index].lapHistory.count == Self.lapHistoryLimit {
                        entries[index].lapHistory.removeFirst()
                    }
                    entries[index].lapHistory.append(RaceLap(time:lapTime,clean:clean))
                    if previousCrossing != nil && clean {
                        entries[index].bestLap = min(entries[index].bestLap ?? lapTime,lapTime)
                        longestCleanLap = max(longestCleanLap ?? lapTime,lapTime)
                    }
                    entries[index].lastCrossingTime = crossingTime
                    entries[index].lapCompromised = entries[index].runningOffTrack
                    entries[index].nextGate = 1
                    entries[index].laps += 1
                    if checkeredTime == nil && entries[index].laps == lapCount {
                        winningCrossing = min(winningCrossing ?? crossingTime,crossingTime)
                    }
                } else { entries[index].nextGate += 1 }
            }
        }
        if checkeredTime == nil { checkeredTime = winningCrossing }
        guard let checkeredTime else { return }
        // Compare exact crossing times only after every entrant's gate has
        // been advanced. An earlier crossing in this tick stays racing.
        for index in entries.indices where entries[index].status == .racing {
            guard let crossing = entries[index].lastCrossingTime, crossing >= checkeredTime else { continue }
            entries[index].finishTime = crossing
            entries[index].status = .finished
            entries[index].runningOffTrack = false
        }
    }
}

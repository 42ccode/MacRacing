import Foundation
import simd

@main struct ComputerDrivingChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL")  \(message)")
        if !condition { failures += 1 }
    }

    static func checkPack(on kind: CircuitKind) {
        let circuit = Circuit(kind: kind), line = RacingLine(circuit: circuit)
        var player = Vehicle(); player.kind = .ferrari; player.reset(at: circuit.start)
        var traffic = ComputerTraffic()
        traffic.reset(count: 3, kind: player.kind, circuit: circuit, from: circuit.start.distance)
        var previous = ([player] + traffic.cars.map(\.vehicle)).map { circuit.nearest(to: $0.position).progress }
        var travelled = [Double](repeating: 0, count: 4)
        var peakOffset = 0.0, significantContacts = 0
        var command = DrivingInput()
        let dt = 1.0/240
        for frame in 0..<(240*180) {
            let location = circuit.nearest(to: player.position)
            if frame % 4 == 0 {
                command = ComputerDriver.input(for: player, at: location, circuit: circuit, line: line,
                                               pace: 0.82, traffic: traffic.cars.map(\.vehicle))
            }
            player.step(dt, input: command, assists: DrivingAssists(), roadDistance: location.distance,
                        roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress,
                        kerbsEnabled: circuit.hasKerb(at: location.progress))
            if let contact = traffic.step(dt, player: &player, circuit: circuit, line: line), contact.closingSpeed > 1.5 {
                significantContacts += 1
            }
            if frame % 24 == 0 {
                for (index, car) in ([player] + traffic.cars.map(\.vehicle)).enumerated() {
                    let sample = circuit.nearest(to: car.position)
                    peakOffset = max(peakOffset, sample.distance)
                    var step = sample.progress-previous[index]
                    if step < -circuit.length/2 { step += circuit.length }
                    if step > circuit.length/2 { step -= circuit.length }
                    travelled[index] += step
                    previous[index] = sample.progress
                }
                if travelled.allSatisfy({ $0 >= circuit.length }) { break }
            }
        }
        check(travelled.allSatisfy({ $0 >= circuit.length }), "Player auto drive and three rivals complete a physical lap on \(kind.label)")
        check(peakOffset < circuit.width/2-1, "Pack keeps vehicle-width clearance on \(kind.label)")
        check(significantContacts == 0, "Following control avoids hard contact in the reference pack on \(kind.label)")
    }

    static func checkOpponentInterpolation() {
        let circuit = Circuit(), line = RacingLine(circuit:circuit)
        var player = Vehicle()
        player.reset(at:circuit.start)
        var traffic = ComputerTraffic()
        traffic.reset(count:1,kind:.mazda,circuit:circuit,from:0)
        for _ in 0..<100 {
            _ = traffic.step(1/240,player:&player,circuit:circuit,line:line)
        }
        let previous = traffic.cars[0].vehicle.position
        _ = traffic.step(1/240,player:&player,circuit:circuit,line:line)
        _ = traffic.step(1/240,player:&player,circuit:circuit,line:line)
        let latest = traffic.cars[0].vehicle.position
        let displayStart = traffic.displayVehicles(remainder:0)[0].position
        let displayMiddle = traffic.displayVehicles(remainder:1/240)[0].position
        check(simd_distance(previous,latest)>0.0001 && displayStart == previous &&
              simd_distance(displayMiddle,(previous+latest)/2)<1e-8 &&
              traffic.cars[0].vehicle.position == latest,
              "Opponent visuals interpolate between solved poses without rewinding traffic physics")
    }

    static func checkRejoin() {
        let circuit = Circuit(), line = RacingLine(circuit:circuit)
        let start = circuit.sample(at:85)
        var car = Vehicle()
        car.kind = .mazda
        car.reset(at:start)
        car.position -= start.right*12
        car.heading -= 2.5
        car.velocity = car.forward*4
        for index in car.wheels.indices { car.wheels[index].angularVelocity = 4/car.wheelRadius }
        var returned = false
        var furthest = 0.0
        for _ in 0..<1440 {
            let location = circuit.nearest(to:car.position)
            furthest = max(furthest,location.distance)
            if location.distance < 5 && simd_dot(car.forward,location.tangent)>0.7 {
                returned = true
                break
            }
            let input = ComputerDriver.input(for:car,at:location,circuit:circuit,line:line,pace:0.82)
            car.step(1/240,input:input,assists:DrivingAssists(),roadDistance:location.distance,roadWidth:circuit.width,
                     roadContacts:circuit.wheelContacts(at:car.contactPoints))
        }
        check(returned && furthest < 15,"A car facing the wrong way on the grass returns without a teleport or barrier hit")

        car.position = start.point+start.right*8
        car.heading = atan2(start.tangent.x,start.tangent.y)
        car.velocity = start.tangent*5
        var approaching = Vehicle()
        let behind = circuit.sample(at:77)
        approaching.reset(at:behind)
        approaching.velocity = behind.tangent*25
        let location = circuit.nearest(to:car.position)
        let blocked = ComputerDriver.input(for:car,at:location,circuit:circuit,line:line,pace:0.82,traffic:[approaching])
        check(blocked.throttle == 0 && blocked.brake > 0.5,"An approaching rival takes priority over a rejoin")
    }

    static func checkSprintTiming() {
        let length = 1000.0
        func locations(_ progress: [Double], playerOffset: Double = 0) -> [TrackLocation] {
            progress.enumerated().map { i, progress in
                TrackLocation(point:SIMD2(progress,0),tangent:SIMD2(1,0),progress:progress,
                              lateral:0,distance:i == 0 ? playerOffset : 0,segment:0)
            }
        }
        var race = SprintRace(positions:[70,100],trackLength:length)
        race.step(0.1,locations:locations([88,110]),assisted:false,width:12)
        check(race.elapsed == 0 && race.order == [1,0] && race.countdownSeconds == 3,
              "Race countdown freezes timing and shows the grid order")
        for _ in 0..<720 { race.advanceCountdown(1/240) }
        check(race.countdown == 0 && race.showGo, "Green flag follows a three-second fixed-step countdown")
        let dt = 0.1
        for i in 1...190 {
            let player = (70 + Double(i)*10).truncatingRemainder(dividingBy:length)
            let rival = (100 + Double(i)*9.95).truncatingRemainder(dividingBy:length)
            race.step(dt,locations:locations([player,rival],playerOffset:i > 4 && i < 22 ? 9 : 0),
                      assisted:i == 3,width:12)
        }
        check(race.playerFinished == false && race.entries[1].laps == 1 &&
              race.entries[0].penalties == 1 && race.assisted,
              "Checkpoints, sustained off-track penalties and assisted state are independent of each other")
        for i in 191...200 {
            let player = (70 + Double(i)*10).truncatingRemainder(dividingBy:length)
            let rival = (100 + Double(i)*9.95).truncatingRemainder(dividingBy:length)
            race.step(dt,locations:locations([player,rival]),assisted:false,width:12)
        }
        check(race.finished && race.entries.allSatisfy { $0.laps == 2 } &&
              abs((race.entries[0].finishTime ?? 0)-19.3) < 1e-9 &&
              abs((race.entries[0].classifiedTime ?? 0)-21.3) < 1e-9 && race.order == [1,0],
              "Finish crossing interpolates within the tick and classifications include penalties")
        var jump = SprintRace(positions:[990],trackLength:length)
        jump.advanceCountdown(3)
        for progress in [5.0,245,255,745,755,990,5] {
            jump.step(0.1,locations:locations([progress]),assisted:false,width:12)
        }
        check(jump.entries[0].laps == 0, "Timing seam and projection jumps cannot skip the required gates")
        var verge = SprintRace(positions:[0],trackLength:length)
        verge.advanceCountdown(3)
        for frame in 0..<360 {
            verge.step(1/240,locations:locations([Double(frame)/240],playerOffset:7.2),
                       assisted:false,width:12,outside:[false])
        }
        check(verge.entries[0].penalties == 0 && !verge.entries[0].runningOffTrack,
              "A car still touching racing pavement does not get a centre-position penalty")
        for frame in 360..<720 {
            verge.step(1/240,locations:locations([Double(frame)/240],playerOffset:7.2),
                       assisted:false,width:12,outside:[true])
        }
        check(verge.entries[0].penalties == 1 && verge.entries[0].runningOffTrack,
              "Four wheels off track for exactly 1.5 seconds incur one penalty")
        var pit = SprintRace(positions:[0,10],trackLength:length)
        pit.advanceCountdown(3)
        for _ in 0..<72 {
            pit.observePitSpeed(1/240,index:0,inLane:true,limited:true,speed:22)
        }
        check(pit.entries[0].penalties == 0,"Brief pit overspeed clears within the grace period")
        pit.observePitSpeed(1/240,index:0,inLane:true,limited:true,speed:PitLane.speedLimit)
        for _ in 0..<220 {
            pit.observePitSpeed(1/240,index:0,inLane:true,limited:true,speed:22)
            pit.observePitSpeed(1/240,index:1,inLane:false,limited:false,speed:52)
        }
        check(pit.entries.map(\.penalties) == [1,0],"Only sustained overspeed in the limited pit lane earns one penalty")
        pit.observePitSpeed(1/240,index:0,inLane:false,limited:false,speed:22)
        for _ in 0..<84 { pit.observePitSpeed(1/240,index:0,inLane:true,limited:true,speed:22) }
        check(pit.entries[0].penalties == 2,"Leaving and returning to the pits starts a fresh speed check")
    }

    static func checkPassing() {
        let circuit = Circuit(kind:.ridge), line = RacingLine(circuit:circuit)
        let sample = circuit.sample(at:240)
        var car = Vehicle(); car.kind = .mazda; car.reset(at:sample)
        car.velocity = sample.tangent*25
        let location = circuit.nearest(to:car.position)
        let right = SIMD2(location.tangent.y,-location.tangent.x)
        var leader = car
        leader.position += sample.tangent*15
        leader.velocity = sample.tangent*12
        var clear = PassingPlan()
        for _ in 0..<40 {
            clear.update(1/120,car:car,location:location,circuit:circuit,line:line,baseLane:0,pace:0.84,traffic:[leader])
        }
        let side = clear.committedSide
        check(abs(side) == 1 && abs(clear.lane) > 1 && abs(clear.lane) < 3.6,
              "Rival commits to one clear side and builds its steering offset gradually")
        var left = car, rightCar = car
        left.position -= right*3.4 + sample.tangent*4
        rightCar.position += right*3.4 - sample.tangent*4
        var blocked = PassingPlan()
        for _ in 0..<40 {
            blocked.update(1/120,car:car,location:location,circuit:circuit,line:line,baseLane:0,pace:0.84,
                           traffic:[leader,left,rightCar])
        }
        check(blocked.committedSide == 0 && blocked.lane == 0,
              "Rival follows rather than changing lanes when both sides are occupied")
        for _ in 0..<200 {
            clear.update(1/120,car:car,location:location,circuit:circuit,line:line,baseLane:0,pace:0.84,traffic:[])
        }
        check(clear.committedSide == 0 && abs(clear.lane) < 0.5, "Rival returns gradually after the passing corridor clears")

        var traffic = ComputerTraffic()
        traffic.lineUp(count:1,kind:.mazda,circuit:circuit)
        var slow = Vehicle(); slow.kind = .mazda; slow.reset(at:circuit.sample(at:150))
        var peak = 0.0, contact = false, passed = false
        for _ in 0..<(240*17) {
            let loc = circuit.nearest(to:slow.position)
            let command = ComputerDriver.input(for:slow,at:loc,circuit:circuit,line:line,pace:0.28)
            slow.step(1/240,input:command,assists:DrivingAssists(),roadDistance:loc.distance,roadWidth:circuit.width,
                      roadContacts:circuit.wheelContacts(at:slow.contactPoints))
            if let hit = traffic.step(1/240,player:&slow,circuit:circuit,line:line), hit.closingSpeed > 0.2 { contact = true }
            let rival = circuit.nearest(to:traffic.cars[0].vehicle.position)
            peak = max(peak,rival.distance)
            passed = passed || rival.progress > loc.progress+12
            if passed { break }
        }
        check(passed && !contact && peak < circuit.width/2-0.8,
              "A faster AI car physically passes a slower car on the straight with room to spare")
    }

    static func checkPhysicalSprint(on kind: CircuitKind, condition: TrackCondition = .dry) {
        let circuit = Circuit(kind:kind,condition:condition), line = RacingLine(circuit:circuit)
        var player = Vehicle(); player.kind = .mazda; player.reset(at:circuit.gridSlot(3))
        if condition == .wet { player.service(setup:TyreSetup(compound:.wet)) }
        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:player.kind,circuit:circuit)
        func positions(_ player: Vehicle, _ traffic: ComputerTraffic) -> [TrackLocation] {
            ([player] + traffic.cars.map(\.vehicle)).map { circuit.nearest(to:$0.position) }
        }
        var race = SprintRace(positions:positions(player,traffic).map(\.progress),trackLength:circuit.length)
        race.advanceCountdown(3)
        var input = DrivingInput(), hardContacts = 0
        var location = circuit.nearest(to:player.position)
        let dt = 1.0/240
        for tick in 0..<(240*520) {
            if tick.isMultiple(of:2) {
                input = ComputerDriver.input(for:player,at:location,circuit:circuit,line:line,pace:0.82,traffic:traffic.cars.map(\.vehicle))
            }
            player.step(dt,input:input,assists:DrivingAssists(),roadDistance:location.distance,roadWidth:circuit.width,
                        roadContacts:circuit.wheelContacts(at:player.contactPoints))
            if let contact = traffic.step(dt,player:&player,circuit:circuit,line:line), contact.closingSpeed > 1.5 { hardContacts += 1 }
            let current = positions(player,traffic)
            location = current[0]
            let outside = [player.allWheelsOutside] + traffic.cars.map { $0.vehicle.allWheelsOutside }
            race.step(dt,locations:current,assisted:true,width:circuit.width,outside:outside)
            traffic.startCooldown(forRivalsFinishedIn:race)
            if race.finished { break }
        }
        check(race.finished && hardContacts == 0 && race.entries.allSatisfy { $0.penalties == 0 },
              "Four cars finish a physical two-lap race without hard player contact or off-track penalties: \(kind.label) \(condition.label)")
        check(traffic.cars.allSatisfy { ($0.cooldownSpeed ?? 0) >= 19.5 },
              "Finished rivals switch to a cooldown speed target: \(kind.label) \(condition.label)")
    }

    static func main() {
        checkOpponentInterpolation()
        checkRejoin()
        for kind in CircuitKind.allCases { checkPack(on: kind) }
        checkSprintTiming()
        checkPassing()
        for kind in CircuitKind.allCases { checkPhysicalSprint(on:kind) }
        checkPhysicalSprint(on:.north,condition:.wet)
        var player = Vehicle()
        player.heading = 2.14
        player.position = SIMD2(150,-78)
        func opponent(ahead: Double, right: Double) -> TrafficCar {
            var vehicle = player
            vehicle.position += player.forward*ahead - player.modelX*right
            return TrafficCar(vehicle:vehicle,pace:0.8,lane:0)
        }
        let nearLeft = opponent(ahead: -4, right: -2.5)
        let nearRight = opponent(ahead: 1, right: 2.5)
        let distant = [opponent(ahead: -9, right: 2.5), opponent(ahead: 8, right: -2.5),
                       opponent(ahead: -4, right: 0), opponent(ahead: -2, right: -5.5)]
        let left = SideTraffic(player: player, opponents: [nearLeft] + distant)
        let right = SideTraffic(player: player, opponents: [nearRight] + distant)
        let both = SideTraffic(player: player, opponents: [nearLeft, nearRight])
        let clear = SideTraffic(player: player, opponents: distant)
        check(left.left && !left.right, "Side warning follows the driver's left at a rotated heading")
        check(right.right && !right.left, "Side warning follows the driver's right at a rotated heading")
        check(both.left && both.right, "Side warnings can light independently on both sides")
        check(!clear.left && !clear.right, "Distant and directly trailing cars do not trigger side warnings")
        var closing = opponent(ahead:-11,right:2.5)
        closing.vehicle.velocity = player.forward*16
        let aboutToOverlap = SideTraffic(player:player,opponents:[closing])
        check(aboutToOverlap.right && !aboutToOverlap.left,
              "A fast approaching car in the adjacent lane warns before overlap")
        var hold = SideTrafficHold()
        _ = hold.update(aboutToOverlap,dt:1/120,active:true)
        let betweenSamples = hold.update(SideTraffic(),dt:0.08,active:true)
        let fullyClear = hold.update(SideTraffic(),dt:0.12,active:true)
        check(betweenSamples.right && !fullyClear.right,
              "Side warnings do not flicker across a brief boundary crossing")

        check(!ComputerDriver.wantsControl(DrivingInput(throttle: 0.03, brake: 0.02, steering: 0.06)), "Small controller drift keeps auto drive engaged")
        check(ComputerDriver.wantsControl(DrivingInput(throttle: 1)) &&
              ComputerDriver.wantsControl(DrivingInput(brake: 1)) &&
              ComputerDriver.wantsControl(DrivingInput(steering: -1)), "All three driver inputs can take back control")
        let circuit = Circuit(), line = RacingLine(circuit: circuit)
        var car = Vehicle(); car.reset(at: circuit.start); car.velocity = car.forward*20
        let location = circuit.nearest(to: car.position)
        var leader = car; leader.position += car.forward*7; leader.velocity = .zero
        let open = ComputerDriver.input(for: car, at: location, circuit: circuit, line: line, pace: 0.82)
        let blocked = ComputerDriver.input(for: car, at: location, circuit: circuit, line: line, pace: 0.82, traffic: [leader])
        check(blocked.brake > open.brake && blocked.throttle == 0, "A stationary car ahead triggers braking instead of acceleration")
        car.heading += .pi
        check(!ComputerDriver.canDrive(car, at: location, on: circuit), "Auto drive refuses a car facing backwards")
        car.reset(at: circuit.start); car.velocity = car.forward*18
        leader = car; leader.position += car.forward*4; leader.velocity = car.forward*5
        let before = simd_distance(car.position, leader.position)
        let hit = TrafficContact.resolve(&car, &leader)
        check(hit != nil && abs((hit?.closingSpeed ?? 0)-13) < 0.01 &&
              simd_distance(car.position,leader.position) > before && car.speed < leader.speed &&
              abs(car.yawRate) < 0.001 && abs(leader.yawRate) < 0.001,
              "Rear-end contact separates the cars and transfers momentum")
        func offsetImpact(_ offset: Double) -> (yaw: Double, momentumError: Double) {
            var first = Vehicle()
            var second = Vehicle()
            first.kind = .mazda
            second.kind = .centenario
            first.velocity = first.forward * 18
            second.velocity = second.forward * 5
            second.position = first.forward * 3.8 + first.modelX * offset
            let before = first.mass * first.velocity + second.mass * second.velocity
            _ = TrafficContact.resolve(&first, &second)
            let after = first.mass * first.velocity + second.mass * second.velocity
            return (first.yawRate, simd_distance(before,after))
        }
        let leftHit = offsetImpact(0.6)
        let rightHit = offsetImpact(-0.6)
        check(abs(leftHit.yaw) > 0.15 && abs(leftHit.yaw + rightHit.yaw) < 0.001 &&
              max(leftHit.momentumError,rightHit.momentumError) < 0.001,
              "Offset impacts create mirrored yaw while conserving linear momentum")
        leader.position = car.position + car.modelX*2.4
        check(TrafficContact.resolve(&car,&leader) == nil, "Adjacent lanes leave room for side-by-side driving")
        var session = RaceSession(); session.resetLap(at: 0)
        car.velocity = SIMD2(20,0)
        for frame in 1...1200 {
            let progress = Double(frame*2 % 1200)
            car.position = SIMD2(progress,0)
            let location = TrackLocation(point: car.position, tangent: SIMD2(1,0), progress: progress, lateral: 0, distance: 0, segment: 0)
            _ = session.step(0.1, vehicle: car, location: location, trackLength: 1200, trackWidth: 12, assisted: frame == 1)
            if frame == 600 { check(session.best == nil && !session.lastValid, "A brief auto drive segment keeps the whole lap out of personal records") }
        }
        check(session.best != nil && session.lastValid, "The next fully manual lap can set a personal record")
        if failures > 0 { exit(1) }
    }
}

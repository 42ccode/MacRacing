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
        var player = Vehicle(); player.kind = .centenario; player.reset(at: circuit.start)
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
        traffic.reset(count:1,kind:.porsche,circuit:circuit,from:0)
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
        car.kind = .porsche
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
        let driver = race.playerClassification
        check(driver?.position == 2 && driver?.status == .finished && driver?.penaltySeconds == 2 &&
              abs((driver?.bestLap ?? 0)-10) < 1e-9 && race.classifications.map(\.position) == [1,2],
              "Results retain both official finishing position and the quickest complete clean lap")
        check(abs((race.longestCleanLap ?? 0)-length/99.5) < 1e-9,
              "The closeout clock can use the slowest observed clean full lap")
        check(!race.retire(index:0) && !race.observePitSpeed(2,index:0,inLane:true,limited:true,speed:40) &&
              race.playerClassification == driver,
              "Settled cars cannot pick up penalties or be retired after the finish")
        var jump = SprintRace(positions:[990],trackLength:length)
        jump.advanceCountdown(3)
        for progress in [5.0,245,255,745,755,990,5] {
            jump.step(0.1,locations:locations([progress]),assisted:false,width:12)
        }
        check(jump.entries[0].laps == 0 && jump.playerLaps.isEmpty,
              "Timing seam and projection jumps cannot add a lap without the required gates")
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

        for lapCount in SprintRace.lapOptions {
            var custom = SprintRace(lapCount:lapCount,positions:[70],trackLength:length)
            custom.advanceCountdown(3)
            let finishFrame = lapCount*100-7
            for frame in 1..<finishFrame {
                let progress = (70+Double(frame)*10).truncatingRemainder(dividingBy:length)
                custom.step(dt,locations:locations([progress]),assisted:false,width:12)
            }
            check(!custom.finished && custom.entries[0].laps == lapCount-1,
                  "A \(lapCount)-lap sprint stays live up to the final crossing")
            custom.step(dt,locations:locations([0]),assisted:false,width:12)
            check(custom.finished && custom.playerDone && custom.playerClassification?.laps == lapCount &&
                  abs((custom.playerClassification?.classifiedTime ?? 0)-Double(finishFrame)*dt) < 1e-9,
                  "A \(lapCount)-lap sprint classifies the player at precisely the final crossing")
        }

        var firstLap = SprintRace(lapCount:2,positions:[70],trackLength:length)
        firstLap.advanceCountdown(3)
        for frame in 1...193 {
            let progress = (70+Double(frame)*10).truncatingRemainder(dividingBy:length)
            firstLap.step(dt,locations:locations([progress]),assisted:false,width:12,outside:[frame == 140])
        }
        check(firstLap.finished && firstLap.playerClassification?.bestLap == nil && firstLap.longestCleanLap == nil &&
              firstLap.playerClassification?.penaltySeconds == 0,
              "A standing-start partial lap and a briefly off-track lap do not register as fastest laps")

        var deadline = SprintRace(lapCount:1,positions:[100,110,90,80],trackLength:length)
        deadline.advanceCountdown(3)
        deadline.finalizeUnfinished()
        check(deadline.order == [1,0,2,3] && !deadline.finished && !deadline.retire(index:9) &&
              deadline.retire(index:3),
              "An early result request leaves racing cars active and retirement uses stable entrant indices")
        for frame in 1...93 {
            let progress = [100+Double(frame)*10,110+Double(frame)*10,90+Double(frame)*8,80+Double(frame)*10]
                .map { $0.truncatingRemainder(dividingBy:length) }
            deadline.step(dt,locations:locations(progress),assisted:frame > 90,width:12)
        }
        check(deadline.playerDone && deadline.playerFinished && !deadline.finished && !deadline.assisted,
              "The race can wait for rivals after a clean player finish")
        deadline.finalizeUnfinished()
        let results = deadline.classifications
        let elapsed = deadline.elapsed
        deadline.step(1,locations:locations([5,10,15,20]),assisted:true,width:12)
        check(deadline.finished && deadline.elapsed == elapsed && deadline.classifications == results &&
              results.map(\.index) == [1,0,2,3] &&
              results.map(\.status) == [.finished,.finished,.timedOut,.retired] &&
              results.suffix(2).allSatisfy { $0.finishTime == nil && $0.classifiedTime == nil },
              "An expired finish window freezes distinct timed-out and retired classifications")
        var retiredDriver = SprintRace(positions:[90,100],trackLength:length)
        retiredDriver.retire(index:0)
        retiredDriver.finalizeUnfinished()
        check(retiredDriver.finished && retiredDriver.playerDone && !retiredDriver.playerFinished &&
              retiredDriver.playerClassification?.status == .retired,
              "Retiring the player produces a complete DNF result")
    }

    static func checkCheckeredClassification() {
        let length = 100.0, dt = 0.2
        func step(_ race: inout SprintRace,_ values: [Double]) {
            let locations = values.map {
                TrackLocation(point:SIMD2($0,0),tangent:SIMD2(1,0),progress:$0,lateral:0,distance:0,segment:0)
            }
            race.step(dt,locations:locations,assisted:false,width:12)
        }

        var race = SprintRace(lapCount:2,positions:[0,0,0,0],trackLength:length)
        race.advanceCountdown(3)
        for distance in [20.0,40,60,80,0] { step(&race,[0,0,distance,distance]) }
        for distance in [20.0,40,60,80] { step(&race,[distance,distance,distance,distance]) }
        step(&race,[95,98,96,96])
        _ = race.observePitSpeed(0.35,index:3,inLane:true,limited:true,speed:30)
        let previousTime = race.elapsed
        step(&race,[3,10,3,4])
        check(abs((race.checkeredTime ?? 0)-(previousTime+dt*0.5)) < 1e-9 &&
              race.entries[0].status == .finished && race.entries[0].laps == 1 &&
              race.entries[1].status == .racing && race.entries[1].laps == 1,
              "Only legitimate crossings at or after the earliest within-step checkered time finish")
        check(race.playerLaps.count == 1 && race.playerLaps.first?.time == race.entries[0].finishTime &&
              race.playerLaps.first?.clean == true,
              "A legitimate laps-down finish is recorded in the timeline")
        check(race.order == [2,3,0,1] && race.entries[3].finishTime == race.checkeredTime &&
              (race.entries[0].classifiedTime ?? 0) < (race.entries[3].classifiedTime ?? 0),
              "Full distance ranks ahead of cars a lap down and penalties sort equal lap counts")
        for distance in [20.0,40,60,80,0] { step(&race,[3,distance,3,4]) }
        check(race.finished && race.entries[1].status == .finished && race.entries[1].laps == 2 &&
              race.order == [2,1,3,0] && race.entries[0].laps == 1,
              "A crossing that precedes the checkered flag finishes on the following legitimate lap")

        var tied = SprintRace(lapCount:1,positions:[0,0,0],trackLength:length)
        tied.advanceCountdown(3)
        for distance in [20.0,40,60,80,0] { step(&tied,[distance,distance,0]) }
        step(&tied,[0,0,98])
        step(&tied,[0,0,4])
        check(tied.entries[0].finishTime == tied.checkeredTime &&
              tied.entries[1].finishTime == tied.checkeredTime && tied.order == [0,1,2],
              "Exactly simultaneous finishes preserve stable entrant order")
        check(tied.entries[2].status == .racing && tied.entries[2].laps == 0,
              "A timing line jump without the required gates never takes the checkered flag")

        var closing = SprintRace(lapCount:1,positions:[0,0],trackLength:length)
        closing.advanceCountdown(3)
        closing.finalizeUnfinished()
        let wasRacing = !closing.playerDone
        for distance in [20.0,40,60,80,0] { step(&closing,[0,distance]) }
        closing.finalizeUnfinished()
        check(wasRacing && closing.finished && closing.playerClassification?.status == .timedOut &&
              closing.entries[1].status == .finished,
              "Closeout can time out a stalled player after checkered without changing a classified rival")
    }

    static func checkRaceLapHistory() {
        let length = 100.0
        func step(_ race: inout SprintRace,_ distance: Double,dt: Double = 0.2,outside: Bool = false) {
            let location = TrackLocation(point:SIMD2(distance,0),tangent:SIMD2(1,0),progress:distance,
                                         lateral:0,distance:0,segment:0)
            race.step(dt,locations:[location],assisted:false,width:12,outside:[outside])
        }

        var race = SprintRace(lapCount:3,positions:[8],trackLength:length)
        race.advanceCountdown(3)
        for progress in [20.0,40,60,80,5] { step(&race,progress) }
        check(race.playerLaps.count == 1 && abs((race.playerLaps.first?.time ?? 0)-0.96) < 1e-9 &&
              race.playerLaps.first?.clean == true && race.entries[0].bestLap == nil && race.longestCleanLap == nil,
              "The first race split is measured from green but cannot claim fastest full lap")

        for progress in [20.0,40,60,80,0] { step(&race,progress,outside:progress == 60) }
        for progress in [20.0,40,60,80,0] { step(&race,progress) }
        let history = race.playerLaps
        let expected = [0.96,1.04,1.0]
        check(history.map(\.clean) == [true,false,true] &&
              zip(history,expected).allSatisfy { abs($0.time-$1) < 1e-9 } &&
              abs((race.entries[0].bestLap ?? 0)-1) < 1e-9 &&
              abs(history.reduce(0) { $0+$1.time }-(race.entries[0].finishTime ?? 0)) < 1e-9,
              "Clean and dirty splits use exact crossing deltas and retain the clean fastest lap")
        step(&race,5)
        check(race.finished && race.playerLaps == history,
              "Crossings cannot alter the lap timeline after classification")
        let encoded = try? JSONEncoder().encode(history)
        let decoded = encoded.flatMap { try? JSONDecoder().decode([RaceLap].self,from:$0) }
        check(decoded == history,"Race split times and clean flags round-trip through persistence")

        let laps = SprintRace.lapHistoryLimit+4
        var cap = SprintRace(lapCount:laps,positions:[0],trackLength:length)
        cap.advanceCountdown(3)
        let steps = (0..<laps).map { 0.2+Double($0)*0.01 }
        for dt in steps {
            for progress in [20.0,40,60,80,0] { step(&cap,progress,dt:dt) }
        }
        let recent = steps.suffix(SprintRace.lapHistoryLimit)
        check(cap.finished && cap.entries[0].laps == laps && cap.playerLaps.count == SprintRace.lapHistoryLimit &&
              zip(cap.playerLaps,recent).allSatisfy { abs($0.time-5*$1) < 1e-9 },
              "Only the latest eight race splits are kept even when a race runs more laps")
    }

    static func checkStoppedRivalCloseout() {
        let circuit = Circuit(kind:.sprint)
        func rival(at progress: Double = 240,lateral: Double = 14,damage: Bool = true) -> TrafficCar {
            let sample = circuit.sample(at:progress)
            var car = Vehicle()
            car.reset(at:sample)
            car.position += sample.right*lateral
            if damage { car.impact(normalSpeed:20,outwardNormal:car.forward) }
            return TrafficCar(vehicle:car,pace:0.82,lane:0)
        }
        func observe(_ race: inout SprintRace,_ dt: Double,_ rivals: [TrafficCar],rollout: Bool = true) {
            let locations = [circuit.nearest(to:circuit.start.point)]+rivals.map {
                circuit.nearest(to:$0.vehicle.position)
            }
            race.closeOutStoppedRivals(dt,rivals:rivals,locations:locations,circuit:circuit,
                                       finishRolloutComplete:rollout)
        }
        func finishLap(_ race: inout SprintRace,entrants: [Int]) {
            let steps = Int(ceil(circuit.length/16))
            for frame in 1...steps {
                let progress = Double(frame % steps)*circuit.length/Double(steps)
                let locations = race.entries.indices.map { index in
                    let sample = circuit.sample(at:entrants.contains(index) ? progress : 0)
                    return TrackLocation(point:sample.point,tangent:sample.tangent,progress:sample.distance,
                                         lateral:0,distance:0,segment:0)
                }
                race.step(0.2,locations:locations,assisted:false,width:circuit.width)
            }
        }
        func newRace() -> SprintRace {
            var race = SprintRace(lapCount:1,positions:[0,0,0,0],trackLength:circuit.length)
            race.advanceCountdown(3)
            return race
        }

        let stopped = rival()
        let healthy = rival(damage:false)
        check(stopped.vehicle.wheels.filter(\.punctured).count == 2,
              "The stopped-rival test starts with two punctures after a hard nose impact")
        let clearField = [stopped,stopped,healthy]
        var race = newRace()
        observe(&race,3,clearField)
        check(race.checkeredTime == nil && race.entries.allSatisfy { $0.status == .racing },
              "An observed clear stop leaves a green race and its places unchanged")
        finishLap(&race,entrants:[3])
        observe(&race,3,clearField)
        check(race.checkeredTime != nil && !race.playerDone && race.entries[1].status == .racing,
              "A clear disabled rival cannot close a race while the player is still racing")
        finishLap(&race,entrants:[0])
        let classified = race.classifications.filter { $0.status == .finished }
        observe(&race,3,clearField,rollout:false)
        check(race.playerFinished && !race.finished && classified.count == 2,
              "Classified drivers retain their finish while the player completes the rollout")

        observe(&race,0.1,[stopped,healthy,healthy])
        check(!race.finished && race.entries[1].status == .racing,
              "The entire remaining field must qualify before the first retirement")
        let verge = rival(lateral:circuit.width/2+1)
        let box = rival(at:PitLane.boxProgress,lateral:circuit.pitLane.lateral(at:PitLane.boxProgress))
        observe(&race,2.4,clearField)
        observe(&race,0.1,[stopped,verge,healthy])
        observe(&race,2.4,clearField)
        observe(&race,0.1,[stopped,box,healthy])
        check(!race.finished && race.entries[2].status == .racing,
              "Moving into the verge or pit breaks the off-course stop interval")
        var creeping = stopped
        creeping.vehicle.velocity = creeping.vehicle.forward*0.30
        observe(&race,2.4,clearField)
        observe(&race,0.1,[stopped,creeping,healthy])
        for _ in 0..<599 { observe(&race,1.0/240,clearField) }
        check(!race.finished && race.entries[1].status == .racing,
              "Slow movement resets the continuous stop even after earlier long clear intervals")
        let retiredLaps = race.entries[1...2].map(\.laps)
        let penaltyAdded = race.observePitSpeed(0.35,index:2,inLane:true,limited:true,speed:30)
        observe(&race,1.0/240,clearField)
        check(penaltyAdded && race.finished && race.entries[2].penaltySeconds == 2 &&
              race.entries[1...2].allSatisfy { $0.status == .retired && $0.finishTime == nil } &&
              race.entries[1...2].map(\.laps) == retiredLaps &&
              race.classifications.filter { $0.status == .finished } == classified,
              "After 2.5 clear seconds retirement preserves finish results, laps and existing penalties")
        let results = race.classifications
        race.finalizeUnfinished()
        observe(&race,3,[healthy,healthy,healthy])
        check(race.classifications == results, "A later checkered deadline preserves completed retirements")

        var rematch = newRace()
        finishLap(&rematch,entrants:[0,3])
        var powerless = stopped
        powerless.vehicle = healthy.vehicle
        powerless.vehicle.damage.engine = 1
        let newField = [stopped,powerless,healthy]
        observe(&rematch,0.1,newField)
        check(!rematch.finished, "A rematch starts each stopped-rival observation interval from zero")
        observe(&rematch,2.4,newField)
        check(rematch.finished && rematch.entries[2].status == .retired,
              "A clear stop with very low power and severe engine damage can retire without punctures")
    }

    static func checkStartingGrid() {
        let circuit = Circuit(kind:.ridge,condition:.wet)
        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:.porsche,circuit:circuit)
        let defaultPaces = traffic.cars.map(\.pace)
        check(traffic.cars.enumerated().allSatisfy { i,rival in
            simd_distance(rival.vehicle.position,circuit.gridSlot(i).point) < 1e-9
        }, "The default race leaves the last starting position to the player")
        for playerSlot in 0...3 {
            traffic.lineUp(count:3,kind:.porsche,circuit:circuit,paceScale:1.07,playerGridSlot:playerSlot)
            let rivalSlots = (0...3).filter { $0 != playerSlot }
            check(traffic.cars.enumerated().allSatisfy { i,rival in
                simd_distance(rival.vehicle.position,circuit.gridSlot(rivalSlots[i]).point) < 1e-9 &&
                abs(rival.pace-defaultPaces[i]*1.07) < 1e-9
            }, "A player in grid slot \(playerSlot+1) has a unique place and correctly paced rivals")
        }
        traffic.lineUp(count:1,kind:.porsche,circuit:circuit,paceScale:.nan,playerGridSlot:-1)
        check(traffic.cars.count == 1 && traffic.cars[0].pace == defaultPaces[0] &&
              simd_distance(traffic.cars[0].vehicle.position,circuit.gridSlot(1).point) < 1e-9,
              "Single-rival lineups clamp an invalid grid slot and ignore non-finite pace")
        let target = ComputerDriver.playerCooldownTargetSpeed
        check(ComputerDriver.cooldownLimit(from:35,elapsed:2,target:target) == 32.1 &&
              ComputerDriver.cooldownLimit(from:19,elapsed:4,target:target) == target,
              "The post-finish target slows gradually to 64.8 km/h")
    }

    static func checkPassing() {
        let circuit = Circuit(kind:.ridge), line = RacingLine(circuit:circuit)
        let sample = circuit.sample(at:240)
        var car = Vehicle(); car.kind = .porsche; car.reset(at:sample)
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
        for _ in 0..<300 {
            clear.update(1/120,car:car,location:location,circuit:circuit,line:line,baseLane:0,pace:0.84,traffic:[])
        }
        check(clear.committedSide == 0 && abs(clear.lane) < 0.5, "Rival returns gradually after the passing corridor clears")

        var traffic = ComputerTraffic()
        traffic.lineUp(count:1,kind:.porsche,circuit:circuit)
        var slow = Vehicle(); slow.kind = .porsche; slow.reset(at:circuit.sample(at:150))
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

    static func checkWetObstaclePass() {
        let circuit = Circuit(kind:.grand,condition:.wet), line = RacingLine(circuit:circuit)
        let station = 190.0
        let sample = circuit.sample(at:station)
        let pose = TrackSample(point:line.sample(at:station).position,tangent:sample.tangent,distance:station)
        var stopped = Vehicle()
        stopped.kind = .porsche
        stopped.reset(at:pose)
        stopped.service(setup:TyreSetup(compound:.wet))

        let approach = circuit.sample(at:station-22)
        var follower = stopped
        follower.reset(at:TrackSample(point:line.sample(at:approach.distance).position,
                                     tangent:approach.tangent,distance:approach.distance))
        follower.velocity = approach.tangent*15
        let location = circuit.nearest(to:follower.position)
        func planningFrame(_ plan: inout PassingPlan, traffic: [Vehicle]) {
            plan.update(1.0/120,car:follower,location:location,circuit:circuit,line:line,
                        baseLane:0,pace:0.84,traffic:traffic)
        }
        var moving = stopped
        moving.velocity = sample.tangent*6
        var plan = PassingPlan()
        for _ in 0..<360 { planningFrame(&plan,traffic:[moving]) }
        check(plan.committedSide == 0 && plan.speedLimit == .infinity,
              "Wet traffic follows a slower moving car without initiating a race overtake")

        for _ in 0..<30 { planningFrame(&plan,traffic:[stopped]) }
        let briefStop = plan.committedSide
        for _ in 0..<120 { planningFrame(&plan,traffic:[moving]) }
        check(briefStop == 0 && plan.committedSide == 0,
              "A brief slow or stopped spell does not qualify for a wet obstacle pass")

        var left = moving, right = moving
        left.position += approach.right*3.8 - approach.tangent*6
        right.position -= approach.right*3.8 + approach.tangent*6
        for _ in 0..<180 { planningFrame(&plan,traffic:[stopped,left,right]) }
        check(plan.committedSide == 0,"A wet obstacle wait continues while both corridors are occupied")
        for _ in 0..<120 { planningFrame(&plan,traffic:[stopped]) }
        check(abs(plan.committedSide) == 1 && plan.speedLimit < 14,
              "A confirmed stationary obstacle permits a reduced-speed pass once there is room")

        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:.porsche,circuit:circuit)
        let dt = 1.0/240
        var hardContacts = 0
        var leftCourse = false
        var allPassed = false
        for _ in 0..<(240*24) {
            if let impact = traffic.step(dt,player:&stopped,circuit:circuit,line:line), impact.closingSpeed > 1.5 {
                hardContacts += 1
            }
            leftCourse = leftCourse || traffic.cars.contains { $0.vehicle.allWheelsOutside }
            if traffic.cars.allSatisfy({ circuit.nearest(to:$0.vehicle.position).progress > station+45 }) {
                allPassed = true
                break
            }
        }
        check(allPassed && hardContacts == 0 && !leftCourse,
              "Three wet Grand Circuit rivals all drive around a parked car without hard contact or leaving the course")
    }

    static func checkBlueFlagYield() {
        let circuit = Circuit(kind:.grand,condition:.wet), line = RacingLine(circuit:circuit)
        func car(at progress: Double,lateral: Double = 0,speed: Double = 16) -> Vehicle {
            let sample = circuit.sample(at:progress)
            let point = line.sample(at:progress).position+sample.right*lateral
            var vehicle = Vehicle()
            vehicle.reset(at:TrackSample(point:point,tangent:sample.tangent,distance:progress))
            vehicle.velocity = sample.tangent*speed
            return vehicle
        }
        var oneLapAhead = SprintRace(lapCount:5,positions:[0,0,0,0],trackLength:circuit.length)
        oneLapAhead.advanceCountdown(3)
        let sameLap = oneLapAhead
        for tick in 1...(Int(circuit.length/7)+1) {
            let progress = (Double(tick)*7).truncatingRemainder(dividingBy:circuit.length)
            let positions = [progress,0,0,0].map { p in circuit.nearest(to:circuit.sample(at:p).point) }
            oneLapAhead.step(0.1,locations:positions,assisted:false,width:circuit.width)
        }
        let owner = car(at:220)
        let chase = car(at:194,speed:23)
        let elsewhere = car(at:330)
        let ownerLocation = circuit.nearest(to:owner.position)
        var yield = BlueFlagYield()
        func update(_ race: SprintRace,_ field: [Vehicle],ticks: Int = 240) {
            for _ in 0..<ticks {
                yield.update(1.0/120,for:1,field:field,race:race,location:ownerLocation,
                             circuit:circuit,line:line,baseLane:0,passing:false)
            }
        }
        update(sameLap,[chase,owner,elsewhere,elsewhere])
        check(!yield.engaged,"A faster car behind on the same lap does not get an artificial lane opening")
        update(oneLapAhead,[chase,owner,car(at:225,lateral:-3.8),car(at:223,lateral:3.8)])
        check(!yield.engaged,"A lapped rival waits when both lanes are occupied")
        update(oneLapAhead,[chase,owner,elsewhere,elsewhere])
        check(yield.engaged && abs(yield.offset) > 2.8 && yield.speedLimit < owner.speed,
              "A clear straight lets a lapped rival ease aside and slow for the faster car")

        let clearAhead = car(at:243,speed:23)
        update(oneLapAhead,[clearAhead,owner,car(at:226),elsewhere])
        check(yield.engaged,"A lapped rival waits to merge back until the normal line is clear")
        update(oneLapAhead,[clearAhead,owner,elsewhere,elsewhere],ticks:480)
        check(!yield.engaged && yield.speedLimit == .infinity,
              "After providing clearance the lapped rival returns smoothly to its racing line")
    }

    static func checkDryingPace() {
        let circuit = Circuit(kind:.grand,condition:.wet), line = RacingLine(circuit:circuit)
        var car = Vehicle()
        car.kind = .centenario
        car.reset(at:circuit.sample(at:465))
        car.position = line.sample(at:465).position
        car.velocity = car.forward*28
        car.service(setup:TyreSetup(compound:.wet))
        car.distanceTravelled = 60
        let location = circuit.nearest(to:car.position)
        var onePath = TrackDrying(circuit:circuit)
        var bothPaths = TrackDrying(circuit:circuit)
        onePath.advance(TrackDrying.interval)
        bothPaths.advance(TrackDrying.interval)
        for index in 0..<68 {
            let station = location.progress+Double(index)*0.75
            let sample = circuit.sample(at:station)
            let lateral = simd_dot(line.sample(at:station).position-sample.point,sample.right)
            for _ in 0..<24 {
                let right = lateral+car.trackWidth/2, left = lateral-car.trackWidth/2
                onePath.displace(at:station,lateral:right,travelled:0.75,speed:28,load:3500,treadWidth:0.28)
                bothPaths.displace(at:station,lateral:right,travelled:0.75,speed:28,load:3500,treadWidth:0.28)
                bothPaths.displace(at:station,lateral:left,travelled:0.75,speed:28,load:3500,treadWidth:0.28)
            }
        }
        var pace = RivalDryingPace()
        func step(_ surface: TrackDrying?) -> Double {
            pace.update(1/120,car:car,location:location,circuit:circuit,line:line,lane:0,drying:surface)
        }
        for _ in 0..<11 { _ = step(bothPaths) }
        let held = pace.scale
        let first = step(bothPaths)
        for _ in 0..<12 { _ = step(bothPaths) }
        let both = pace.scale
        let disabled = step(nil)
        for _ in 0..<24 { _ = step(onePath) }
        let one = pace.scale
        check(held == 1 && (1.0039...1.0041).contains(first) && (1.005...1.03).contains(both),
              "Wet rival speed samples at 10 Hz and gradually uses a bounded share of measured grip")
        check(disabled == 1 && one < 1.0005,
              "A fixed wet session and a still-wet tyre path keep nearly the original rival speed")
    }

    static func checkRivalPitApproachFollowing() {
        let circuit = Circuit(kind:.sprint)
        let line = RacingLine(circuit:circuit)
        let pit = circuit.pitLane
        let approach = -196.0
        let lane = 0.64
        func routeOffset(_ progress: Double) -> Double {
            let sample = circuit.sample(at:progress)
            let racing = simd_dot(line.sample(at:progress).position-sample.point,sample.right)+lane
            let blend = clamp((progress-approach)/(PitLane.entry-approach),0,1)
            let shared = blend*blend*(3-2*blend)
            return racing+shared*(pit.lateral(at:progress)-racing)
        }
        func car(at progress: Double,offset: Double = 0,speed: Double) -> Vehicle {
            let sample = circuit.sample(at:progress)
            var car = Vehicle()
            car.reset(at:sample)
            car.position += sample.right*(routeOffset(progress)+offset)
            car.velocity = car.forward*speed
            return car
        }
        func request(_ source: Vehicle,near others: [Vehicle]) -> DrivingInput? {
            var subject = source
            subject.wheels[1].punctured = true
            var stop = RivalPitStop(approachStart:approach)
            return stop.input(1/120,car:&subject,at:circuit.nearest(to:subject.position),circuit:circuit,
                              line:line,lane:lane,pace:0.84,others:others,work:.tyres,speedLimit:.infinity)
        }
        let approaching = car(at:-182,speed:14)
        let closeLead = car(at:-165,speed:4)
        let offsetLead = car(at:-165,offset:3.1,speed:4)
        let behind = car(at:-190,speed:4)
        let open = request(approaching,near:[])
        let offset = request(approaching,near:[offsetLead,behind])
        let follow = request(approaching,near:[closeLead])
        check((open?.throttle ?? 0) > 0 && open?.brake == 0 &&
              offset?.throttle == open?.throttle && offset?.brake == open?.brake,
              "Pit approach keeps its normal command for cars behind or outside the shared route")
        check(follow?.throttle == 0 && (follow?.brake ?? 0) > 0.25 && follow?.steering == open?.steering,
              "A slow lead on the selected pit approach triggers braking before entry")
        let diverging = car(at:-96,speed:10.5)
        let crossing = car(at:-83,offset:1.70,speed:1.5)
        let crossingLocation = circuit.nearest(to:crossing.position)
        let clear = request(diverging,near:[])
        let yield = request(diverging,near:[crossing])
        check(!pit.contains(crossingLocation) && (clear?.throttle ?? 0) > 0 &&
              yield?.throttle == 0 && (yield?.brake ?? 0) > 0.25 && yield?.steering == clear?.steering,
              "The shared entrance remains protected until the pit lane diverges at the limiter line")
    }

    static func checkWetPuncturePitEntrance() {
        func command(_ model: VehicleKind,on condition: TrackCondition,tyre: Int,progress: Double,
                     speed: Double) -> DrivingInput {
            let circuit = Circuit(kind:.north,condition:condition)
            let sample = circuit.sample(at:progress)
            var car = Vehicle()
            car.kind = model
            car.reset(at:sample)
            car.position += sample.right*circuit.pitLane.lateral(at:progress)
            car.velocity = car.forward*speed
            car.wheels[tyre].punctured = true
            var stop = RivalPitStop(approachStart:-196)
            return stop.input(1/120,car:&car,at:circuit.nearest(to:car.position),circuit:circuit,
                              line:RacingLine(circuit:circuit),lane:0.64,pace:0.84,others:[],
                              work:.tyres,speedLimit:.infinity) ?? DrivingInput()
        }
        for model in VehicleKind.allCases {
            let front = [0,1].map { command(model,on:.wet,tyre:$0,progress:-125,speed:12) }
            let rear = [2,3].map { command(model,on:.wet,tyre:$0,progress:-125,speed:12) }
            let dry = command(model,on:.dry,tyre:0,progress:-125,speed:12)
            let settled = command(model,on:.wet,tyre:0,progress:-24,speed:10.5)
            check(front.allSatisfy { $0.brake > 0.20 && $0.throttle == 0 },
                  "Either front puncture starts braking before the wet pit branch: \(model.label)")
            check((rear+[dry,settled]).allSatisfy { $0.throttle > 0 && $0.brake == 0 },
                  "Rear punctures, dry approaches and the settled wet pit retain normal pace: \(model.label)")
        }
    }

    static func checkRivalPitInterruption() {
        let circuit = Circuit(kind:.sprint), line = RacingLine(circuit:circuit), lane = circuit.pitLane
        let box = lane.serviceSample(on:circuit)
        var player = Vehicle()
        player.reset(at:box)
        var damaged = Vehicle()
        damaged.reset(at:circuit.sample(at:-188))
        damaged.wheels[1].punctured = true
        let approach = circuit.nearest(to:damaged.position)
        check(RivalPitStop.work(for:damaged) == .tyres &&
              RivalPitStop.canEnter(car:damaged,location:approach,circuit:circuit,others:[]) &&
              !RivalPitStop.canEnter(car:damaged,location:approach,circuit:circuit,others:[player]),
              "A serviceable rival waits on track while the player's car occupies the pit box")
        damaged.wheels[0].punctured = true
        check(RivalPitStop.work(for:damaged) == nil,"A double puncture does not reserve the lap's only service position")

        for dislodged in [false,true] {
            var rival = Vehicle(), stop = RivalPitStop(approachStart:-195)
            rival.reset(at:box)
            rival.wheels[1].punctured = true
            for _ in 0..<32 {
                _ = stop.input(1/120,car:&rival,at:circuit.nearest(to:rival.position),circuit:circuit,
                               line:line,lane:0,pace:0.82,others:[],work:.tyres,speedLimit:.infinity)
            }
            guard case .servicing = stop.status else {
                check(false,"A stopped damaged rival starts its timed service in the box")
                continue
            }
            if dislodged {
                rival.position = circuit.sample(at:PitLane.boxProgress).point
            } else {
                rival.position += rival.forward*4.5
            }
            let start = rival.position
            let next = stop.input(1/120,car:&rival,at:circuit.nearest(to:start),circuit:circuit,
                                  line:line,lane:0,pace:0.82,others:[],work:.tyres,speedLimit:.infinity)
            check(rival.position == start && rival.gear == 1 && rival.wheels[1].punctured &&
                  (dislodged ? next == nil : next != nil && stop.status == .leaving),
                  dislodged ? "A rival pushed onto the raceway exits neutral and resumes normal control" :
                    "A rival pushed forward aborts the unfinished service and drives out with its fault intact")
        }
    }

    static func checkWetGridConvergence() {
        let circuit = Circuit(kind:.grand,condition:.wet), line = RacingLine(circuit:circuit)
        var player = Vehicle()
        player.kind = .porsche
        player.reset(at:circuit.gridSlot(3))
        player.service(setup:TyreSetup(compound:.wet))
        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:.porsche,circuit:circuit,paceScale:1.07)
        var location = circuit.nearest(to:player.position)
        var input = DrivingInput()
        var largestVelocityStep = 0.0
        let dt = 1.0/240
        for tick in 0..<(6*240) {
            let rivals = traffic.cars.map(\.vehicle)
            if tick.isMultiple(of:2) {
                input = ComputerDriver.input(for:player,at:location,circuit:circuit,line:line,
                                             pace:0.82,traffic:rivals)
            }
            player.step(dt,input:input,assists:DrivingAssists(),roadDistance:location.distance,roadWidth:circuit.width,
                        roadLateral:location.lateral,roadProgress:location.progress,
                        kerbsEnabled:circuit.hasKerb(at:location.progress),
                        roadContacts:circuit.wheelContacts(at:player.contactPoints),wake:AirWake.behind(player,leaders:rivals))
            _ = traffic.step(dt,player:&player,circuit:circuit,line:line)
            location = circuit.nearest(to:player.position)
            // A contact impulse is much larger than one 120 Hz tyre-force step.
            for (after,before) in zip(traffic.cars,rivals) {
                largestVelocityStep = max(largestVelocityStep,simd_distance(after.vehicle.velocity,before.velocity))
            }
        }
        check(largestVelocityStep < 0.2 && traffic.cars.allSatisfy { $0.vehicle.distanceTravelled > 20 },
              "Four Porsche 911s launch on wet Grand Circuit without a compression impact or a stalled rival")
    }

    static func checkPhysicalSprint(on kind: CircuitKind, condition: TrackCondition = .dry, vehicle: VehicleKind = .porsche,
                                    playerGridSlot: Int = 3, paceScale: Double = 1) {
        let circuit = Circuit(kind:kind,condition:condition), line = RacingLine(circuit:circuit)
        var player = Vehicle(); player.kind = vehicle; player.reset(at:circuit.gridSlot(playerGridSlot))
        if condition == .wet { player.service(setup:TyreSetup(compound:.wet)) }
        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:player.kind,circuit:circuit,paceScale:paceScale,playerGridSlot:playerGridSlot)
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
        let scenario = "\(vehicle.label) \(kind.label) \(condition.label) · grid \(playerGridSlot+1) · pace \(paceScale)"
        check(race.finished && hardContacts == 0 && race.entries.allSatisfy { $0.penalties == 0 },
              "Four cars finish a physical two-lap race without hard player contact or off-track penalties: \(scenario)")
        check(traffic.cars.allSatisfy { ($0.cooldownSpeed ?? 0) >= 19.5 },
              "Finished rivals switch to a cooldown speed target: \(scenario)")
    }

    static func checkVehicleContactBoundaries() {
        for firstKind in VehicleKind.allCases {
            let body = firstKind.bodyEnvelope
            let matches = VehicleKind.allCases.allSatisfy { secondKind in
                let other = secondKind.bodyEnvelope
                return [(SIMD2<Double>(1,0),0.0,body.x+other.x),
                        (SIMD2<Double>(0,1),0.0,body.y+other.z),
                        (SIMD2<Double>(0,1),Double.pi,body.y+other.y)].allSatisfy { axis,heading,boundary in
                    func touches(_ distance: Double) -> Bool {
                        var first = Vehicle(), second = Vehicle()
                        first.kind = firstKind
                        second.kind = secondKind
                        second.position = axis*distance
                        second.heading = heading
                        return TrafficContact.resolve(&first,&second) != nil
                    }
                    return touches(boundary-0.002) && !touches(boundary+0.002)
                }
            }
            check(matches,"Side, rear and oncoming traffic contacts follow the authored dimensions: \(firstKind.label)")
        }
    }

    static func main() {
        checkVehicleContactBoundaries()
        checkOpponentInterpolation()
        checkRejoin()
        for kind in CircuitKind.allCases { checkPack(on: kind) }
        checkSprintTiming()
        checkCheckeredClassification()
        checkRaceLapHistory()
        checkStoppedRivalCloseout()
        checkStartingGrid()
        checkPassing()
        checkWetObstaclePass()
        checkWetGridConvergence()
        checkDryingPace()
        checkRivalPitInterruption()
        checkRivalPitApproachFollowing()
        checkWetPuncturePitEntrance()
        checkBlueFlagYield()
        for vehicle in VehicleKind.allCases {
            for condition in TrackCondition.allCases {
                for kind in CircuitKind.allCases { checkPhysicalSprint(on:kind,condition:condition,vehicle:vehicle) }
            }
        }
        checkPhysicalSprint(on:.ridge,playerGridSlot:0,paceScale:1.07)
        checkPhysicalSprint(on:.grand,vehicle:.centenario,paceScale:1.07)
        checkPhysicalSprint(on:.valley,paceScale:0.89)
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
            first.kind = .porsche
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

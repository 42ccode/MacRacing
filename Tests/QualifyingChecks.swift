import Foundation
import simd

@main struct QualifyingChecks {
    static var failures = 0

    static func check(_ result: Bool,_ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func rollingTiming() {
        let circuit = Circuit(kind:.ridge,condition:.wet)
        let line = RacingLine(circuit:circuit)
        let setup = TyreSetup(compound:.wet)
        let rolling = QualifyingSession.rollingCar(kind:.porsche,circuit:circuit,line:line,tyres:setup)
        let start = circuit.nearest(to:rolling.position)
        let distance = circuit.length-start.progress
        check((55...90).contains(distance) && (9...14.001).contains(rolling.speed) &&
              simd_dot(rolling.velocity,start.tangent) > 8 && rolling.gear == 1 && rolling.rpm > 1000 &&
              rolling.wheels.allSatisfy {
                  $0.setup.compound == .wet && abs($0.angularVelocity*rolling.wheelRadius-rolling.speed) < 1e-6
              }, "Qualifying begins on a rolling wet approach with matched wheel speed and a real gear")

        func run(assisted: Bool = false,pit: Bool = false) -> QualifyingSession {
            var session = QualifyingSession(startingAt:start.progress)
            var car = rolling
            let dt = 0.2, speed = 25.0
            let ticks = Int((circuit.length+distance)/(speed*dt))+2
            for tick in 1...ticks {
                let sample = circuit.sample(at:start.progress+Double(tick)*speed*dt)
                car.position = sample.point
                if pit && !session.timing.waitingForStart && (33...65).contains(sample.distance) {
                    car.position += sample.right*circuit.pitLane.lateral(at:sample.distance)
                }
                car.heading = atan2(sample.tangent.x,sample.tangent.y)
                car.velocity = sample.tangent*speed
                let current = circuit.nearest(to:car.position)
                let automatic = assisted && !session.timing.waitingForStart && (3...12).contains(session.timing.elapsed)
                if session.step(dt,vehicle:car,location:current,circuit:circuit,assisted:automatic) { break }
            }
            return session
        }

        var clean = run()
        let expected = circuit.length/25
        check(clean.result?.outcome == .valid && clean.timing.completedLaps == 1 &&
              abs((clean.result?.time ?? 0)-expected) < 0.025 &&
              clean.result?.sectors.count == 3 && clean.elapsed > expected,
              "Only the ordered flying lap is timed and the three sector splits survive")
        let result = clean.result, elapsed = clean.elapsed
        clean.skip()
        let advanced = clean.step(1,vehicle:rolling,location:start,circuit:circuit)
        check(!advanced && clean.result == result && clean.elapsed == elapsed,
              "A settled lap cannot be overwritten by skipping or advancing the clock")
        check(run(assisted:true).result?.outcome == .assisted && run(pit:true).result?.outcome == .invalid,
              "Automatic steering and a mid-lap pit detour cannot earn a grid time")
        var timedOut = QualifyingSession(startingAt:start.progress)
        timedOut.step(QualifyingSession.timeLimit,vehicle:rolling,location:start,circuit:circuit)
        var skipped = QualifyingSession(startingAt:start.progress)
        skipped.skip()
        check(timedOut.result?.outcome == .timedOut && timedOut.result?.time == nil &&
              skipped.result?.outcome == .skipped && skipped.result?.time == nil,
              "A stalled attempt reaches a finite deadline and skipping settles without a time")
    }

    static func gridOrder() {
        let grid = QualifyingSession.grid(playerTime:77.3218,rivalTimes:[78,76,77.3214])
        check(grid.playerGridSlot == 2 && grid.rivalOrder == [1,2,0] &&
              grid.rows.map(\.entrantIndex) == [2,3,0,1] && grid.rows.map(\.position) == [1,2,3,4],
              "Sorted lap times determine every grid spot and displayed-millisecond ties are stable")
        let fallback = QualifyingSession.grid(playerTime:.infinity,rivalTimes:[91,nil,84])
        let pole = QualifyingSession.grid(playerTime:65,rivalTimes:[nil,nil])
        check(fallback.playerGridSlot == 3 && fallback.rivalOrder == [2,0,1] &&
              fallback.rows.last?.time == nil && pole.playerGridSlot == 0,
              "Valid times beat missing laps and a player without a time always starts last")

        let circuit = Circuit(kind:.ridge)
        var traffic = ComputerTraffic()
        traffic.lineUp(count:3,kind:.porsche,circuit:circuit,paceScale:1.07,
                       playerGridSlot:grid.playerGridSlot,rivalGridOrder:grid.rivalOrder)
        let expectedSlots = [3,0,1]
        check(traffic.cars.indices.allSatisfy { index in
            simd_distance(traffic.cars[index].vehicle.position,circuit.gridSlot(expectedSlots[index]).point) < 1e-9 &&
            traffic.cars[index].pace == ComputerTraffic.sprintPace(for:index,scale:1.07)
        }, "Each ranked AI is placed on its grid spot with its own qualifying pace and race identity")
        traffic.lineUp(count:3,kind:.porsche,circuit:circuit,playerGridSlot:2,rivalGridOrder:[0,0,3])
        check(traffic.cars.enumerated().allSatisfy { index, car in
            simd_distance(car.vehicle.position,circuit.gridSlot(index == 2 ? 3 : index).point) < 1e-9
        }, "Malformed rival orders fall back to the authored grid identities")
    }

    static func physicalReferences() {
        let dry = Circuit(kind:.grand)
        let dryLine = RacingLine(circuit:dry)
        let rivals = QualifyingSession.referenceTimes(kind:.centenario,circuit:dry,line:dryLine,rivals:3,paceScale:1.07)
        check(rivals.count == 3 && rivals.allSatisfy { ($0 ?? 0) > 30 } &&
              (rivals[0] ?? 0) < (rivals[2] ?? 0) && (rivals[2] ?? 0) < (rivals[1] ?? 0),
              "Three Pro Centenario rivals record ordered clean physical laps on Grand Circuit")
        let wet = Circuit(kind:.technical,condition:.wet)
        let wetLine = RacingLine(circuit:wet)
        let rookie = QualifyingSession.referenceTimes(kind:.porsche,circuit:wet,line:wetLine,rivals:1,paceScale:0.89)
        let harder = QualifyingSession.referenceTimes(kind:.porsche,circuit:wet,line:wetLine,rivals:1,paceScale:1.07)
        check((harder.first.flatMap { $0 } ?? 0) > 30 &&
              (harder.first.flatMap { $0 } ?? .infinity) < (rookie.first.flatMap { $0 } ?? 0),
              "Wet Technical Park references use rain tyres and reflect the real difficulty pace")
        let wetGrand = Circuit(kind:.grand,condition:.wet)
        let references = QualifyingSession.referenceTimes(kind:.centenario,circuit:wetGrand,line:RacingLine(circuit:wetGrand),
            rivals:3,paceScale:1.07)
        check(references.allSatisfy { ($0 ?? 0) > 30 },
              "All three Pro Centenarios hold the wet Grand braking combination and record clean reference times")
        let cancelled = QualifyingSession.referenceTimes(kind:.centenario,circuit:dry,line:dryLine,
            rivals:3,paceScale:1.07,shouldCancel:{ true })
        check(cancelled.count == 3 && cancelled.allSatisfy { $0 == nil },
              "Cancelling keeps entrant slots and leaves unfinished reference times empty")
    }

    static func main() {
        rollingTiming()
        gridOrder()
        physicalReferences()
        if failures > 0 { exit(1) }
    }
}

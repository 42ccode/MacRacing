import Foundation
import simd

@main struct RaceFlagChecks {
    static var failures = 0

    static func check(_ result: Bool,_ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func car(_ circuit: Circuit,at progress: Double,speed: Double = 0,
                    lateral: Double = 0,headingOffset: Double = 0) -> Vehicle {
        let sample = circuit.sample(at:progress)
        var car = Vehicle()
        car.reset(at:sample)
        car.position += sample.right*lateral
        car.heading += headingOffset
        car.velocity = car.forward*speed
        return car
    }

    static func step(_ flags: inout RaceFlags,_ circuit: Circuit,_ player: Vehicle,_ rivals: [Vehicle],
                     dt: Double = 0.05,line: RacingLine? = nil,race: SprintRace? = nil,active: Bool = true) -> RaceFlags.Caution? {
        flags.update(dt,player:player,rivals:rivals.map { TrafficCar(vehicle:$0,pace:1,lane:0) },
                     locations:([player]+rivals).map { circuit.nearest(to:$0.position) },
                     circuit:circuit,line:line,race:race,active:active)
    }

    static func roadHazards() {
        let circuit = Circuit(kind:.ridge)
        var flags = RaceFlags()
        let player = car(circuit,at:205,speed:30)
        let stopped = car(circuit,at:219,headingOffset:.pi/2)
        let further = car(circuit,at:255)
        let nearby = step(&flags,circuit,player,[further,stopped])
        check(nearby?.reason == .stopped && nearby?.entrantIndex == 2 &&
              abs((nearby?.distance ?? 0)-14) < 0.25,
              "The nearest sideways stopped car is an immediate real hazard on the racing surface")

        flags.reset()
        let slow = car(circuit,at:272,speed:6)
        let first = step(&flags,circuit,player,[slow])
        let confirmed = step(&flags,circuit,player,[slow])
        check(first == nil && confirmed?.reason == .slow,
              "A slower car at normal warning distance is confirmed on a second scan")

        let moving = car(circuit,at:272,speed:21)
        let held = step(&flags,circuit,player,[moving],dt:0.25)
        let cleared = step(&flags,circuit,player,[moving],dt:0.41)
        check(held?.reason == .slow && cleared == nil,
              "A brief acceleration preserves the warning while normal race traffic clears it")

        let approaching = car(circuit,at:219,speed:12,headingOffset:.pi)
        check(step(&flags,circuit,player,[approaching])?.reason == .oncoming,
              "An opponent travelling the opposite way is identified as oncoming")
        check(step(&flags,circuit,player,[approaching],active:false) == nil && flags.caution == nil,
              "Countdown, pause and cooldown can clear an active caution")
    }

    static func cornerPace() {
        let circuit = Circuit(kind:.technical,condition:.wet)
        let line = RacingLine(circuit:circuit)
        guard let apex = line.points.first(where: { (6...8).contains($0.targetSpeed) }) else {
            check(false,"Technical Park provides a low-speed wet corner for comparison")
            return
        }
        var flags = RaceFlags()
        let player = car(circuit,at:apex.progress-22,speed:22)
        let turning = car(circuit,at:apex.progress,speed:0.8*apex.targetSpeed)
        _ = step(&flags,circuit,player,[turning],line:line)
        check(step(&flags,circuit,player,[turning],line:line) == nil,
              "Normal slow traffic in an upcoming wet hairpin does not trigger a yellow flag")
        let crawling = car(circuit,at:apex.progress,speed:0.4*apex.targetSpeed)
        _ = step(&flags,circuit,player,[crawling],line:line)
        check(step(&flags,circuit,player,[crawling],line:line)?.reason == .slow,
              "A car crawling well below the corner's usual pace still triggers a yellow flag")
    }

    static func routeFiltering() {
        let circuit = Circuit(kind:.valley)
        var flags = RaceFlags()
        let player = car(circuit,at:circuit.length-12,speed:32)
        let stopped = car(circuit,at:7)
        let seam = step(&flags,circuit,player,[stopped])
        check(seam?.reason == .stopped && abs((seam?.distance ?? 0)-19) < 0.25,
              "Ahead distance follows the route across the timing seam")
        let after = step(&flags,circuit,car(circuit,at:14,speed:32),[stopped])
        check(after == nil,"A warning disappears after passing its car rather than hanging onto it behind")

        let pitPlayer = car(circuit,at:24,speed:20)
        let pitLocation = circuit.pitLane.serviceSample(on:circuit)
        var serviced = Vehicle()
        serviced.reset(at:pitLocation)
        let verge = car(circuit,at:40,lateral:8.3)
        check(step(&flags,circuit,pitPlayer,[serviced,verge]) == nil,
              "Cars in the service box or beyond the racing surface are ignored")
        check(step(&flags,circuit,serviced,[stopped]) == nil,
              "A driver using the pit lane receives no local course warning")

        let fast = car(circuit,at:225,speed:31)
        let edging = car(circuit,at:241,lateral:circuit.width/2+0.65)
        check(step(&flags,circuit,fast,[edging])?.reason == .stopped,
              "A stopped car still triggers caution when its body protrudes from outside the painted edge")
        let clear = car(circuit,at:241,lateral:circuit.width/2+1.80)
        check(step(&flags,circuit,fast,[clear]) == nil,
              "The warning clears when the entire car moves into the run-off")
        let skewed = car(circuit,at:241,lateral:circuit.width/2+1.80,headingOffset:.pi/2)
        check(step(&flags,circuit,fast,[skewed])?.reason == .stopped,
              "The same centre location is hazardous when the body is spun across the racing surface")
        flags.reset()

        let local = circuit.nearest(to:pitPlayer.position)
        var adjacent = pitPlayer
        adjacent.position += SIMD2(3,2)
        adjacent.velocity = .zero
        adjacent.heading += .pi/2
        let elsewhere = TrackLocation(point:adjacent.position,tangent:adjacent.forward,
            progress:local.progress+circuit.length/2,lateral:0,distance:0,segment:local.segment+40)
        let neighbor = TrafficCar(vehicle:adjacent,pace:1,lane:0)
        check(flags.update(0.05,player:pitPlayer,rivals:[neighbor],locations:[local,elsewhere],circuit:circuit,active:true) == nil,
              "A nearby perpendicular projection on a different sector is outside the forward-zone alert")
    }

    static func entrantPhases() {
        let length = 1000.0
        func positions(_ player: Double,_ rival: Double) -> [TrackLocation] {
            [player,rival,70,60].map {
                TrackLocation(point:SIMD2($0,0),tangent:SIMD2(1,0),progress:$0,lateral:0,distance:0,segment:0)
            }
        }
        var race = SprintRace(positions:[90,85,70,60],trackLength:length)
        check(RaceFlags.phase(for:0,in:race) == .countdown && RaceFlags.phase(for:4,in:race) == nil,
              "The flag phase only refers to an actual grid entrant")
        race.advanceCountdown(3)
        check(RaceFlags.phase(for:0,in:race) == .racing,"Green flag clears the countdown phase")
        for frame in 1...191 {
            let player = (90+Double(frame)*10).truncatingRemainder(dividingBy:length)
            let rival = (85+Double(frame)*7).truncatingRemainder(dividingBy:length)
            race.step(0.1,locations:positions(player,rival),assisted:false,width:12)
            if frame == 91 {
                check(RaceFlags.phase(for:0,in:race) == .finalLap && RaceFlags.phase(for:1,in:race) == .racing,
                      "Each entrant starts their final lap at their own timing line crossing")
            }
        }
        race.retire(index:2)
        check(RaceFlags.phase(for:0,in:race) == .finished && RaceFlags.phase(for:1,in:race) == .finalLap &&
              RaceFlags.phase(for:2,in:race) == .retired && RaceFlags.phase(for:3,in:race) == .finalLap,
              "The checkered flag marks the next valid crossing even for an entrant a lap down")
        race.finalizeUnfinished()
        check(RaceFlags.phase(for:1,in:race) == .timedOut && RaceFlags.phase(for:2,in:race) == .retired,
              "Timeout and retirement remain distinct after results settle")
    }

    static func blueFlag() {
        let circuit = Circuit(kind:.grand,condition:.wet)
        let player = car(circuit,at:220,speed:17)
        let faster = car(circuit,at:185,speed:29)
        var race = SprintRace(lapCount:3,positions:[90,85],trackLength:circuit.length)
        race.advanceCountdown(3)
        var flags = RaceFlags()
        _ = step(&flags,circuit,player,[faster],race:race)
        check(flags.blue == nil,"Same-lap racing traffic does not produce a blue flag")
        for sample in 1...Int(ceil(circuit.length/10)) {
            let progress = (85+Double(sample)*10).truncatingRemainder(dividingBy:circuit.length)
            let locations = [90,progress].map { point in
                let p = circuit.sample(at:point)
                return TrackLocation(point:p.point,tangent:p.tangent,progress:point,lateral:0,distance:0,segment:0)
            }
            race.step(0.1,locations:locations,assisted:false,width:circuit.width)
        }
        _ = step(&flags,circuit,player,[faster],race:race)
        check(flags.blue?.entrantIndex == 1 && abs((flags.blue?.distance ?? 0)-35) < 1,
              "A physically approaching car one lap ahead raises a blue flag")
        _ = step(&flags,circuit,player,[car(circuit,at:185,speed:12)],dt:0.2,race:race)
        check(flags.blue != nil,"A brief change in the approaching car's speed keeps the advisory readable")
        _ = step(&flags,circuit,player,[car(circuit,at:226,speed:28)],race:race)
        check(flags.blue == nil,"The blue flag clears as soon as its car has passed")
    }

    static func wrongWay() {
        let circuit = Circuit(kind:.ridge)
        let sample = circuit.sample(at:240)
        let dt = 1.0/240
        var monitor = WrongWayMonitor()
        var driver = car(circuit,at:240)
        let location = circuit.nearest(to:driver.position)

        func drive(_ steps: Int, speed: Double, side: Double = 0, active: Bool = true) -> Bool {
            driver.velocity = location.tangent*speed + sample.right*side
            for _ in 0..<steps {
                monitor.update(dt,vehicle:driver,location:location,circuit:circuit,active:active)
            }
            return monitor.isActive
        }

        check(!drive(155,speed:-5) && drive(1,speed:-5),
              "Backward travel turns on the warning after 650 ms at the simulation cadence")
        check(drive(480,speed:0) && drive(107,speed:5),
              "The wrong-way warning survives a stop and brief movement forwards")
        check(drive(1,speed:-5) && drive(107,speed:5) && !drive(1,speed:5),
              "Only 450 ms of continuous forward travel clears an active warning")

        driver.heading += .pi
        check(!drive(240,speed:9,side:4) && !drive(240,speed:-3,side:9),
              "Forward travel with backwards yaw and mostly sideways slides do not trigger a warning")
        check(!drive(90,speed:-5) && !drive(1,speed:0) && !drive(90,speed:-5),
              "Two short reverse corrections separated by a stop stay below the debounce")
        check(drive(156,speed:-5) && !drive(1,speed:-5,active:false) &&
              !drive(155,speed:-5) && drive(1,speed:-5),
              "Inactive sessions reset both the warning and its accumulated evidence")

        let pad = circuit.pitLane.serviceSample(on:circuit)
        var pitDriver = Vehicle()
        pitDriver.reset(at:pad)
        pitDriver.velocity = -pad.tangent*5
        let pit = circuit.nearest(to:pitDriver.position)
        check(circuit.pitLane.contains(pit) &&
              !monitor.update(1,vehicle:pitDriver,location:pit,circuit:circuit) && !monitor.isActive,
              "Entering the pit clears an existing warning and ignores pit-lane reversing")
    }

    static func main() {
        roadHazards()
        cornerPace()
        routeFiltering()
        entrantPhases()
        blueFlag()
        wrongWay()
        if failures > 0 { exit(1) }
    }
}

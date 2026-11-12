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

    static func main() {
        for kind in CircuitKind.allCases { checkPack(on: kind) }
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
              simd_distance(car.position,leader.position) > before && car.speed < leader.speed,
              "Rear-end contact separates the cars and transfers momentum")
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

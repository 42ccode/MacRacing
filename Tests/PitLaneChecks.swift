import Foundation

@main struct PitLaneChecks {
    static var failures = 0

    static func check(_ result: Bool, _ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func main() {
        for kind in CircuitKind.allCases {
            let circuit = Circuit(kind: kind)
            let lane = circuit.pitLane
            func location(_ progress: Double, offset: Double = 0) -> TrackLocation {
                let sample = circuit.sample(at: progress)
                return circuit.nearest(to: sample.point + sample.right * (lane.lateral(at: progress) + offset))
            }
            let route = stride(from: PitLane.entry+1, to: PitLane.exit, by: 2).allSatisfy { progress in
                [-1.85, 0, 1.85].allSatisfy { offset in
                    let point = location(progress, offset: offset)
                    return lane.hasAsphalt(at: point) && point.distance < 15 &&
                        abs(lane.localProgress(point.progress)-progress) < 4
                }
            }
            check(route, "\(kind.name) pit pavement follows the route inside the barrier")
            check([PitLane.entry+0.5, PitLane.exit-0.5].allSatisfy {
                location($0, offset: -0.85).distance < circuit.width/2
            }, "\(kind.name) entrance and exit overlap the racing surface")
            let bay = lane.serviceSample(on: circuit)
            var car = Vehicle()
            car.reset(at: bay)
            check(lane.inServiceBox(circuit.nearest(to: bay.point)) && car.contactPoints.allSatisfy {
                lane.hasAsphalt(at: circuit.nearest(to: $0))
            }, "\(kind.name) service pose fits the box and all four tyres are on asphalt")
            check(lane.isLimited(location(PitLane.limitEntry+3)) && lane.isLimited(location(-2)) &&
                lane.isLimited(location(2)) && lane.isLimited(location(PitLane.limitExit-3)) &&
                !lane.isLimited(location(PitLane.limitEntry-8)) && !lane.isLimited(location(PitLane.limitExit+8)) &&
                !lane.isLimited(circuit.nearest(to: circuit.start.point)),
                "\(kind.name) speed zone crosses the timing seam and excludes the main track")
        }

        let command = pitLimitedInput(DrivingInput(throttle: 1, brake: 0.8, steering: -0.3), speed: 19)
        check(command.throttle == 0 && command.brake == 0.8 && command.steering == -0.3,
              "Limiter keeps stronger driver braking and preserves steering")
        for kind in VehicleKind.allCases {
            var car = Vehicle()
            car.kind = kind
            car.gear = 2
            car.velocity = car.forward * 22
            for index in car.wheels.indices { car.wheels[index].angularVelocity = 22/car.wheelRadius }
            let input = DrivingInput(throttle: 1)
            var speedAfterSettling = 0.0
            for step in 0..<1440 {
                car.step(1/240, input: pitLimitedInput(input, speed: car.speed), assists: DrivingAssists(),
                         roadDistance: 0, roadWidth: 12)
                if step >= 480 { speedAfterSettling = max(speedAfterSettling, car.speed) }
            }
            check(speedAfterSettling < PitLane.speedLimit+0.28 && car.speed > PitLane.speedLimit-2,
                  "\(kind) limiter slows an overspeed car and holds it near 60 km/h at full pedal")
        }

        let circuit = Circuit()
        var car = Vehicle()
        car.velocity = circuit.start.tangent * 14
        var session = RaceSession()
        session.best = 90
        func cross(lateral: Double) {
            session.beginOutLap(at: circuit.length-2)
            let sample = circuit.sample(at: 1)
            let location = circuit.nearest(to: sample.point + sample.right*lateral)
            _ = session.step(0.2, vehicle: car, location: location, trackLength: circuit.length, trackWidth: circuit.width)
        }
        cross(lateral: -10.6)
        check(session.waitingForStart && session.elapsed == 0 && session.best == 90,
              "Crossing the timing seam off the racing surface preserves the out-lap and best lap")
        cross(lateral: 0)
        check(!session.waitingForStart && session.elapsed > 0 && session.elapsed < 0.2 &&
              session.completedLaps == 0 && session.best == 90,
              "A forward crossing on track starts a timed lap without scoring the out-lap")
        if failures > 0 { exit(1) }
    }
}

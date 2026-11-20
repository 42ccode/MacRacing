import Foundation

@main struct PitLaneChecks {
    static var failures = 0

    static func check(_ result: Bool, _ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func checkIndependentService() {
        let requested = TyreSetup(compound:.hard,coldPressure:1.95)
        let empty = PitServicePlan(work:.repairs,damage:VehicleDamage(),tyreSetup:requested)
        let small = VehicleDamage(front:0.38)
        let singleCorner = VehicleDamage(suspension:[0.55,0,0,0])
        let engine = VehicleDamage(engine:0.9)
        let excessive = VehicleDamage(front:2,rear:3,engine:4,suspension:[2,2,2,2])
        check(empty.duration == 0 && empty.tyreSetup == nil && empty.repairSeconds == 0,
              "Repairs are unavailable on an undamaged car")
        check(PitServicePlan.estimateRepairSeconds(for:small) == 11 &&
              PitServicePlan.estimateRepairSeconds(for:singleCorner) == 14 &&
              PitServicePlan.estimateRepairSeconds(for:engine) == 36 &&
              PitServicePlan.estimateRepairSeconds(for:excessive) == PitServicePlan.repairLimit,
              "Repair estimates increase with body, suspension and engine damage and cap at 60 seconds")
        let zeroAndInvalid = VehicleDamage(front:-1,rear:.nan,engine:.nan,suspension:[-2,0,0,0,1])
        check(PitServicePlan.estimateRepairSeconds(for:zeroAndInvalid) == 0,
              "The pit estimate ignores invalid negative severity and unmodelled suspension entries")
        let mildBoth = PitServicePlan(work:.both,damage:small,tyreSetup:requested)
        let heavyBoth = PitServicePlan(work:.both,damage:engine,tyreSetup:requested)
        check(mildBoth.tyreSeconds == 12 && mildBoth.repairSeconds == 11 && mildBoth.duration == 12 &&
              heavyBoth.duration == 36,
              "Parallel tyre and repair work keeps the longer service duration")

        var parked = Vehicle()
        parked.kind = .porsche
        parked.service(setup:TyreSetup(compound:.wet,coldPressure:1.7))
        parked.gear = 0
        parked.velocity = parked.forward*28
        for index in parked.wheels.indices { parked.wheels[index].angularVelocity = 28/parked.wheelRadius }
        for _ in 0..<2880 where parked.speed > 0.035 {
            parked.step(1.0/240,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        parked.damage = VehicleDamage(front:0.38,rear:0.18,engine:0.10,suspension:[0.2,0,0.15,0])
        parked.coolantTemperature = 119
        for index in parked.wheels.indices {
            parked.wheels[index].evolve(0.15,slipPower:0,speed:16,load:3300,locked:false,grass:true)
            parked.wheels[index].wear = 0.22+Double(index)*0.1
            parked.wheels[index].flatSpot = 0.18
            parked.wheels[index].temperature = 60+Double(index)
            parked.wheels[index].coreTemperature = 53
            parked.wheels[index].airRetention = 0.83
        }
        parked.wheels[1].punctured = true
        func damageState(_ car: Vehicle) -> [Double] {
            [car.damage.front,car.damage.rear,car.damage.engine]+car.damage.suspension
        }
        func tyreState(_ wheel: WheelState) -> [Double] {
            [wheel.wear,wheel.flatSpot,wheel.airRetention,wheel.surfaceContamination,wheel.coreTemperature,
             wheel.treadTemperatures.x,wheel.treadTemperatures.y,wheel.treadTemperatures.z,
             Double(wheel.setup.compound.rawValue),wheel.setup.coldPressure,wheel.punctured ? 1 : 0]
        }
        func brakeState(_ car: Vehicle) -> [[Double]] {
            car.wheels.map { [$0.brakeTemperature,$0.brakeSurfaceTemperature] }
        }
        let hot = brakeState(parked)
        for _ in 0..<2880 { parked.coolStationaryBrakes(1.0/240) }
        let cooled = brakeState(parked)
        check(parked.speed < 0.55 && hot != cooled && cooled.contains { $0[0] > 40 },
              "A parked stop follows normal rotor cooling and keeps residual brake heat")

        var tyresOnly = parked
        var chosen = requested
        let tyrePlan = PitServicePlan(work:.tyres,damage:tyresOnly.damage,tyreSetup:chosen)
        chosen.compound = .soft
        tyresOnly.completePitService(tyrePlan)
        check(tyrePlan.duration == 12 && tyrePlan.repairSeconds == 0 &&
              tyresOnly.wheels.allSatisfy { $0.setup == requested && $0.wear == 0 && $0.flatSpot == 0 &&
                  !$0.punctured && $0.airRetention == 1 && $0.surfaceContamination == 0 },
              "Tyres-only service fits the captured set and resets tyre wear, punctures and contamination")
        check(damageState(tyresOnly) == damageState(parked) &&
              tyresOnly.coolantTemperature == parked.coolantTemperature && brakeState(tyresOnly) == cooled,
              "Tyres-only service preserves vehicle damage, coolant and both rotor temperatures")

        var repairsOnly = parked
        let repairPlan = PitServicePlan(work:.repairs,damage:repairsOnly.damage,tyreSetup:requested)
        repairsOnly.completePitService(repairPlan)
        check(repairPlan.duration > 12 && repairPlan.tyreSeconds == 0 && repairPlan.tyreSetup == nil &&
              repairsOnly.damage.worst == 0 && repairsOnly.wheels.map(tyreState) == parked.wheels.map(tyreState),
              "Repairs remove all vehicle damage and preserve the installed tyres and their condition")
        check(repairsOnly.coolantTemperature == parked.coolantTemperature && brakeState(repairsOnly) == cooled,
              "Repairs-only service preserves coolant and both rotor temperatures")

        var both = parked
        both.completePitService(PitServicePlan(work:.both,damage:both.damage,tyreSetup:requested))
        check(both.damage.worst == 0 && both.wheels.map(tyreState) == tyresOnly.wheels.map(tyreState) &&
              both.coolantTemperature == parked.coolantTemperature && brakeState(both) == cooled,
              "A combined service repairs and fits its tyres while keeping all thermal carryover")

        var undamaged = repairsOnly
        undamaged.completePitService(empty)
        check(damageState(undamaged) == damageState(repairsOnly) &&
              undamaged.wheels.map(tyreState) == repairsOnly.wheels.map(tyreState) &&
              brakeState(undamaged) == cooled && undamaged.coolantTemperature == parked.coolantTemperature,
              "A zero-work repair plan cannot reset or replace any component")

        parked.service(setup:requested)
        check(parked.damage.worst == 0 && parked.coolantTemperature == 85 &&
              brakeState(parked).allSatisfy { $0 == [40,40] } &&
              parked.wheels.allSatisfy { $0.setup == requested && $0.wear == 0 },
              "Fresh-start service retains its full damage, coolant, brake and tyre reset")
    }

    static func main() {
        checkIndependentService()
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
            let approachSpeed = lane.targetSpeed(at:location(PitLane.limitEntry-10))
            check((approachSpeed ?? 0)>PitLane.speedLimit &&
                  lane.targetSpeed(at:location(PitLane.limitExit+6)) == nil &&
                  lane.targetSpeed(at:circuit.nearest(to:circuit.sample(at:0).point)) == nil,
                  "\(kind.name) pit approach backs off before the sign and leaves the racing lane clear")
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
        let lane = circuit.pitLane
        var approaching = Vehicle()
        approaching.kind = .porsche
        approaching.gear = 2
        approaching.velocity = approaching.forward*25
        for index in approaching.wheels.indices { approaching.wheels[index].angularVelocity = 25/approaching.wheelRadius }
        let begin = PitLane.limitEntry-27
        for _ in 0..<960 where approaching.distanceTravelled < PitLane.limitEntry-begin {
            let progress = begin+approaching.distanceTravelled
            let sample = circuit.sample(at:progress)
            let location = circuit.nearest(to:sample.point+sample.right*lane.lateral(at:progress))
            let target = lane.targetSpeed(at:location) ?? 25
            let applied = pitLimitedInput(DrivingInput(throttle:1),speed:approaching.speed,limit:target)
            approaching.step(1/240,input:applied,assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        print(String(format:"Pit approach crosses the sign at %.2f km/h from 90 km/h",approaching.speedKPH))
        check(approaching.distanceTravelled >= 27 && approaching.speed < PitLane.speedLimit+0.75 &&
              approaching.speed > PitLane.speedLimit-2,
              "With the limiter enabled, a 90 km/h approach is near the zone speed at the sign")
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

import Foundation
import simd

@main
struct PhysicsChecks {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS  \(message)") }
        else { print("FAIL  \(message)"); failures += 1 }
    }

    static func main() {
        let circuit = Circuit()
        let dt = 1.0 / 120
        var car = Vehicle()
        car.reset(at: circuit.start)
        let start = car.position
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(simd_distance(car.position, start) < 0.001, "Stationary car stays stationary")
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(throttle: 0, brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speed < 0.001, "Braking at rest never drives backwards")

        car.reset(at: circuit.start)
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speedKPH > 100 && car.speedKPH < 240, "Full throttle accelerates plausibly: \(Int(car.speedKPH)) km/h in 10 seconds")
        check(car.gear > 1, "Automatic gearbox shifts up")
        check(abs(simd_dot(car.position - start, car.modelX)) < 0.01, "Straight acceleration does not drift sideways")
        for _ in 0..<600 { car.step(dt, input: DrivingInput(brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speedKPH < 1, "Full braking stops the car")

        car.reset(at: circuit.start)
        for _ in 0..<600 { car.step(dt, input: DrivingInput(throttle: 0.5, steering: 0.5), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.position.x.isFinite && car.position.y.isFinite && car.speed < 100, "Turning integration stays finite and bounded")
        check(car.yawRate < 0, "Driver-right input turns clockwise when viewed from above")

        var road = Vehicle()
        var grass = Vehicle()
        for _ in 0..<600 {
            road.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
            grass.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 10, roadWidth: 12)
        }
        check(grass.speed < road.speed * 0.80, "Grass has reduced grip and increased resistance")

        var loaded = Vehicle()
        for _ in 0..<240 {
            loaded.step(dt, input: DrivingInput(), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let stationaryLoad = loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(abs(stationaryLoad - loaded.mass * 9.81) < 1, "Four spring loads balance gravity at rest")
        for _ in 0..<720 {
            loaded.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let frontStaticFraction = (loaded.wheelbase - 1.485) / loaded.wheelbase
        let acceleratingFraction = (loaded.wheels[0].normalLoad + loaded.wheels[1].normalLoad) / loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(acceleratingFraction < frontStaticFraction - 0.01, "Acceleration transfers normal load towards the rear wheels")
        for _ in 0..<60 {
            loaded.step(dt, input: DrivingInput(brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let brakingFraction = (loaded.wheels[0].normalLoad + loaded.wheels[1].normalLoad) / loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(brakingFraction > frontStaticFraction + 0.03, "Braking transfers normal load towards the front wheels")
        check(loaded.wheels.allSatisfy { $0.temperature.isFinite && $0.normalLoad >= 0 }, "Wheel temperatures and unilateral contact loads remain physical")

        var locked = road
        var noABS = DrivingAssists()
        noABS.abs = false
        for _ in 0..<80 {
            locked.step(dt, input: DrivingInput(brake: 1), assists: noABS, roadDistance: 0, roadWidth: 12)
        }
        check(locked.speed > 3 && locked.wheels.contains(where: { $0.slipRatio < -0.8 }), "Braking without ABS can lock a rotating wheel while the car is moving")

        var splitGrip = Vehicle()
        for _ in 0..<240 {
            splitGrip.step(dt, input: DrivingInput(throttle: 0.8), assists: DrivingAssists(), roadDistance: 6.7, roadWidth: 12, roadLateral: 6.7)
        }
        check(abs(splitGrip.wheels[2].longitudinalForce - splitGrip.wheels[3].longitudinalForce) > 50,
              "Contact patches respond independently when one side is on grass")

        // Condition model: controlled energy input isolates temperature, pressure and abrasion.
        var hotTyre = WheelState()
        let coldPressure = hotTyre.pressure
        for _ in 0..<1200 { hotTyre.evolve(0.1, slipPower: 12000, speed: 25, load: 3100, locked: false, grass: false) }
        check(hotTyre.temperature > 70 && hotTyre.coreTemperature > 38 && hotTyre.pressure > coldPressure,
              "Slip work heats the tread and carcass and raises tyre pressure")
        let hotTemperature = hotTyre.temperature
        for _ in 0..<1200 { hotTyre.evolve(0.1, slipPower: 0, speed: 0, load: 3100, locked: false, grass: false) }
        check(hotTyre.temperature < hotTemperature && hotTyre.temperature >= 26, "Parked tyres cool towards ambient")
        var soft = WheelState(), hard = WheelState()
        soft.setup.compound = .soft; hard.setup.compound = .hard
        for _ in 0..<1000 {
            soft.evolve(0.1, slipPower: 10000, speed: 20, load: 3100, locked: false, grass: false)
            hard.evolve(0.1, slipPower: 10000, speed: 20, load: 3100, locked: false, grass: false)
        }
        check(soft.wear > hard.wear * 2, "Soft compound wears faster under identical slip work")
        var worn = WheelState(); worn.temperature = 85; worn.coreTemperature = 65
        let freshGrip = worn.gripFactor
        worn.wear = 0.9
        check(worn.gripFactor < freshGrip * 0.75, "Worn tread reduces available grip")
        var lockedTyre = WheelState()
        for _ in 0..<500 { lockedTyre.evolve(0.1, slipPower: 50000, speed: 25, load: 3100, locked: true, grass: false) }
        check(lockedTyre.punctured && lockedTyre.flatSpot == 1 && lockedTyre.pressure < 0.1,
              "Prolonged wheel lock flat-spots the tyre, wears through and deflates it")
        var lightHit = Vehicle(); lightHit.impact(normalSpeed: 1, outwardNormal: SIMD2(1,0))
        check(lightHit.damage.worst == 0, "Parking-speed contact does not damage the car")
        var frontHit = Vehicle(); frontHit.impact(normalSpeed: 16, outwardNormal: SIMD2(0,1))
        var rearHit = Vehicle(); rearHit.impact(normalSpeed: 16, outwardNormal: SIMD2(0,-1))
        check(frontHit.damage.front > 0.5 && frontHit.damage.rear == 0 && frontHit.powerFactor < 1,
              "Front impact damages the nose and engine and reduces power")
        check(rearHit.damage.rear > 0.5 && rearHit.damage.front == 0,
              "Rear impact damages the rear independently")
        var sideHit = Vehicle(); sideHit.impact(normalSpeed: 20, outwardNormal: SIMD2(1,0))
        check(sideHit.damage.suspension[1] > sideHit.damage.suspension[0] && sideHit.wheels[1].punctured,
              "Driver-left side impact bends that suspension and can puncture its tyre")
        let damageBeforeRecovery = sideHit.damage.suspension[1]
        sideHit.reset(at: circuit.start, preservingCondition: true)
        check(sideHit.damage.suspension[1] == damageBeforeRecovery && sideHit.wheels[1].punctured && sideHit.speed == 0,
              "Track recovery preserves tyre and mechanical damage")
        for _ in 0..<600 { sideHit.step(dt,input:DrivingInput(throttle:0.6),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(sideHit.position.x.isFinite && sideHit.speed.isFinite && abs(sideHit.yawRate) < 10,
              "Bent suspension and a puncture remain numerically stable while driving")
        check(abs(sideHit.yawRate) > 0.001, "Asymmetric damage affects straight-line handling")
        let fitted = TyreSetup(compound: .hard, coldPressure: 1.8)
        sideHit.service(setup: fitted)
        check(sideHit.damage.worst == 0 && sideHit.wheels.allSatisfy { !$0.punctured && $0.wear == 0 && $0.flatSpot == 0 && $0.setup.compound == .hard && $0.setup.coldPressure == 1.8 },
              "Service repairs mechanical damage and fits the selected fresh tyre setup")
        var wornBrake = road, freshBrake = road
        for i in 0..<4 { wornBrake.wheels[i].wear = 0.95 }
        let freshStart = freshBrake.position, wornStart = wornBrake.position
        for _ in 0..<1200 {
            freshBrake.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            wornBrake.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(simd_distance(wornBrake.position,wornStart) > simd_distance(freshBrake.position,freshStart) * 1.10,
              "Worn tyres increase measured stopping distance in the full vehicle solver")

        var endurance = Vehicle()
        endurance.impact(normalSpeed:12,outwardNormal:SIMD2(1,0))
        for frame in 0..<36000 {
            endurance.step(1.0/60,input:DrivingInput(throttle:0.6,brake:frame % 1200 > 1000 ? 0.7 : 0,steering:0.15),
                assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(endurance.speed.isFinite && endurance.position.x.isFinite && endurance.coolantTemperature <= 160 &&
            endurance.wheels.allSatisfy { $0.temperature.isFinite && $0.pressure.isFinite && (0...1).contains($0.wear) && $0.normalLoad >= 0 },
              "Ten simulated minutes with damage keep thermal, wear and motion states bounded")

        var idleEngine = Vehicle()
        for _ in 0..<7200 { idleEngine.step(1.0/60,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check((80...95).contains(idleEngine.coolantTemperature), "Thermostat keeps an idling engine near operating temperature")

        var kerbCar = Vehicle()
        kerbCar.velocity = kerbCar.forward * 15
        for w in 0..<4 { kerbCar.wheels[w].angularVelocity = 15 / kerbCar.wheelRadius }
        let leftContacts = [WheelRoadContact(distance:4.5,progress:30,kerbsEnabled:true),
            WheelRoadContact(distance:6.4,progress:30,kerbsEnabled:true),
            WheelRoadContact(distance:4.5,progress:27.2,kerbsEnabled:true),
            WheelRoadContact(distance:6.4,progress:27.2,kerbsEnabled:true)]
        kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:leftContacts)
        check(kerbCar.wheels[1].surface == .kerb && kerbCar.wheels[3].surface == .kerb && kerbCar.wheels[0].surface == .asphalt && kerbCar.wheels[2].surface == .asphalt,
              "Per-wheel contact identifies driver-left kerb while car centre remains on asphalt")
        check(kerbCar.wheels[1].suspensionTravel > kerbCar.wheels[0].suspensionTravel && kerbCar.wheels[1].kerbFeedback > 0 && kerbCar.wheels[0].kerbFeedback == 0,
              "Raised kerb compresses the contacting suspension and excites only that side")
        var parkedKerb = Vehicle()
        parkedKerb.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:leftContacts)
        check(parkedKerb.kerbFeedback == 0, "A parked wheel on a kerb produces no continuous rumble")
        let noKerb = leftContacts.map { WheelRoadContact(distance:$0.distance,progress:$0.progress,kerbsEnabled:false) }
        kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:noKerb)
        check(kerbCar.wheels.allSatisfy { $0.surface != .kerb }, "Wheel sampling respects the end of a kerb segment")
        for _ in 0..<120 { kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(kerbCar.kerbFeedback < 0.0001, "Kerb feedback decays after rejoining asphalt")
        var accelerating = Vehicle()
        for _ in 0..<360 { accelerating.step(dt,input:DrivingInput(throttle:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(accelerating.driverG.y > 0 && accelerating.wheels[2].suspensionTravel > accelerating.wheels[0].suspensionTravel,
              "Acceleration G and rear suspension compression agree with weight transfer")
        for _ in 0..<30 { accelerating.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(accelerating.driverG.y < 0 && accelerating.wheels[0].suspensionTravel > accelerating.wheels[2].suspensionTravel,
              "Braking G and front suspension compression agree with weight transfer")
        var rightTurn = Vehicle()
        for _ in 0..<360 { rightTurn.step(dt,input:DrivingInput(throttle:0.6,steering:0.3),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(rightTurn.driverG.x > 0, "G-meter driver-right acceleration is positive")
        let points = rightTurn.contactPoints
        check(simd_dot(points[1]-points[0],rightTurn.modelX) > 1.9 && simd_dot(points[0]-points[2],rightTurn.forward) > 2.7,
              "Contact sample locations follow both wheel track and vehicle heading")

        check(circuit.length > 1000 && circuit.length < 2500, "Closed circuit length: \(Int(circuit.length)) metres")
        let onTrack = circuit.nearest(to: circuit.start.point)
        check(onTrack.distance < 0.05, "Track projection finds the start")
        let a = circuit.sample(at: 100)
        let b = circuit.sample(at: circuit.length + 100)
        check(simd_distance(a.point, b.point) < 0.001, "Track sampling wraps continuously")
        check(lapTime(65.123) == "1:05.123", "Lap formatter preserves milliseconds")

        var session = RaceSession()
        car.reset(at: circuit.start)
        session.resetLap(at: 8)
        // Drive the whole centreline to test ordered gates and a valid finish.
        for step in 0...16000 {
            let distance = 8 + Double(step) * 0.1
            let sample = circuit.sample(at: distance)
            car.position = sample.point
            car.velocity = sample.tangent * 12
            car.heading = atan2(sample.tangent.x, sample.tangent.y)
            _ = session.step(dt, vehicle: car, location: circuit.nearest(to: car.position), trackLength: circuit.length, trackWidth: 12)
            if session.completedLaps > 0 { break }
        }
        check(session.completedLaps == 1 && session.best != nil, "Ordered checkpoint traversal records a valid lap")
        check(!session.bestGhost.isEmpty, "A valid best lap retains a ghost recording")
        var recovery = RaceSession()
        recovery.resetLap(at: circuit.length * 0.7)
        check(recovery.checkpoint == 0 && recovery.elapsed == 0, "Recovery resets checkpoint and timing state")

        if failures > 0 { exit(1) }
        print("\nAll physics and timing checks passed.")
    }
}

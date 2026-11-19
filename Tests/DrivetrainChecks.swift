import Foundation
import simd

@main struct DrivetrainChecks {
    static var failures = 0
    static func check(_ result: Bool, _ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func drive(_ car: inout Vehicle, seconds: Double, input: DrivingInput,
                      assists: DrivingAssists = DrivingAssists(), distance: Double = 0) {
        for _ in 0..<Int(seconds * 240) {
            car.step(1/240, input: input, assists: assists, roadDistance: distance, roadWidth: 12)
        }
    }

    static func checkPowertrainSound() {
        let manual = DrivingAssists(tractionControl:false, automatic:false)
        let gas = DrivingInput(throttle:0.65)
        var grid = Vehicle()
        let gridSlot = TrackSample(point:.zero,tangent:SIMD2(0,1),distance:0)
        check(grid.powertrainSound.shaftRPM == 950 && grid.powertrainSound.driveLoad == 0,
              "A newly created combustion car reports idle before its first physics step")
        drive(&grid,seconds:0.2,input:gas,assists:manual)
        grid.kind = .honda
        let rollingMotorRPM = abs(grid.wheels[2].angularVelocity + grid.wheels[3].angularVelocity)/2 * grid.kind.finalDrive * 60/(2 * .pi)
        check(abs(grid.powertrainSound.shaftRPM - rollingMotorRPM) < 0.001 && grid.powertrainSound.driveLoad == 0,
              "Selecting the electric car reads wheel-linked motor speed and clears the previous driving torque")
        grid.reset(at:gridSlot)
        check(grid.powertrainSound.shaftRPM == 0 && grid.powertrainSound.overrun == 0,
              "A reset Honda e has a stationary rotor during the countdown")
        grid.kind = .centenario
        grid.reset(at:gridSlot)
        check(grid.powertrainSound.shaftRPM == 950 && grid.powertrainSound.overrun == 0,
              "Resetting the combustion car restores idle during the countdown")
        for kind in VehicleKind.allCases where kind != .honda {
            var free = Vehicle()
            free.kind = kind
            free.gear = 0
            for _ in 0..<480 where free.rpm < 4700 {
                drive(&free,seconds:1/240,input:gas,assists:manual)
            }
            var loaded = free
            loaded.gear = 3
            let wheelOmega = free.rpm * 2 * .pi / (60 * kind.gearRatios[2] * kind.finalDrive)
            loaded.velocity = loaded.forward * (wheelOmega * loaded.wheelRadius)
            for i in loaded.wheels.indices { loaded.wheels[i].angularVelocity = wheelOmega }
            loaded.step(1/720,input:gas,assists:manual,roadDistance:0,roadWidth:12)
            let underPower = loaded.powertrainSound
            check(abs(free.powertrainSound.shaftRPM - underPower.shaftRPM) < 0.1 &&
                  free.powertrainSound.driveLoad == 0 && free.powertrainSound.overrun == 0 &&
                  abs(underPower.driveLoad-gas.throttle) < 0.001 && underPower.overrun == 0,
                  "Same RPM and throttle resolve unloaded neutral and driving torque: \(kind.label)")

            var shifted = loaded
            _ = shifted.requestShift(1,pedals:gas,automatic:false)
            drive(&shifted,seconds:0.02,input:gas,assists:manual)
            let cut = shifted.powertrainSound.driveLoad
            drive(&shifted,seconds:0.3,input:gas,assists:manual)
            check(abs(cut - underPower.driveLoad * 0.35) < 0.001 &&
                  abs(shifted.powertrainSound.driveLoad - underPower.driveLoad) < 0.001,
                  "Upshift drops and restores sound load with the transmitted torque: \(kind.label)")

            drive(&loaded,seconds:0.3,input:DrivingInput(),assists:manual)
            let overrun = loaded.powertrainSound
            loaded.gear = 0
            loaded.step(1/720,input:DrivingInput(),assists:manual,roadDistance:0,roadWidth:12)
            check(overrun.driveLoad == 0 && overrun.overrun > 0.55 &&
                  loaded.powertrainSound.overrun == 0 && loaded.powertrainSound.driveLoad == 0,
                  "Lifting backdrives the engine until neutral disconnects it: \(kind.label)")
            if kind == .mazda {
                print(String(format:"MX-5 at %.0f rpm: neutral %.3f, loaded %.3f, cut %.3f, closed-throttle backdrive %.3f",
                             underPower.shaftRPM,free.powertrainSound.driveLoad,underPower.driveLoad,cut,overrun.overrun))
            }
        }

        var coast = Vehicle()
        coast.kind = .mazda
        coast.gear = 0
        coast.rpm = 3000
        drive(&coast,seconds:0.22,input:DrivingInput(),assists:manual)
        let afterLift = coast.rpm
        drive(&coast,seconds:3.0,input:DrivingInput(),assists:manual)
        check((2400...2900).contains(afterLift) && abs(coast.rpm - 950) < 1,
              "An unloaded MX-5 crank loses speed over time and settles at governed idle")
        var cutSamples = 0
        var maxRPM = 0.0
        for _ in 0..<720 {
            drive(&coast,seconds:1/240,input:DrivingInput(throttle:1),assists:manual)
            if coast.ignitionFraction == 0 { cutSamples += 1 }
            maxRPM = max(maxRPM,coast.rpm)
        }
        check(cutSamples > 0 && (coast.kind.redline...coast.kind.redline+40).contains(maxRPM) &&
              coast.speed == 0 && coast.powertrainSound.driveLoad == 0,
              "Neutral can reach the governor and cut firing without transmitting wheel torque")

        var onGrass = Vehicle()
        onGrass.kind = .ferrari
        var reducedOnGrass = false
        for _ in 0..<120 {
            drive(&onGrass,seconds:1/240,input:DrivingInput(throttle:1),distance:10)
            if onGrass.tcActive && onGrass.powertrainSound.driveLoad + 0.15 < onGrass.engineThrottle {
                reducedOnGrass = true
            }
        }
        check(reducedOnGrass, "Traction control limiting wheel torque reduces sound load at the same throttle")

        var reverse = Vehicle()
        reverse.kind = .mazda
        reverse.gear = -1
        reverse.velocity = reverse.forward * -4
        for i in reverse.wheels.indices { reverse.wheels[i].angularVelocity = -4/reverse.wheelRadius }
        drive(&reverse,seconds:0.15,input:gas,assists:manual)
        let reverseLoad = reverse.powertrainSound.driveLoad
        drive(&reverse,seconds:0.2,input:DrivingInput(),assists:manual)
        check(reverseLoad > 0.5 && reverse.powertrainSound.overrun > 0.1,
              "Reverse distinguishes propulsive and overrun sound torque in the direction of travel")

        var electric = Vehicle()
        electric.kind = .honda
        electric.gear = 0
        drive(&electric,seconds:0.4,input:gas,assists:manual)
        check(electric.powertrainSound.shaftRPM == 0 && electric.powertrainSound.driveLoad == 0,
              "A stationary Honda e in neutral has no spinning traction motor with the accelerator down")
        electric.velocity = electric.forward * 22
        for i in electric.wheels.indices { electric.wheels[i].angularVelocity = 22/electric.wheelRadius }
        drive(&electric,seconds:0.15,input:DrivingInput(),assists:manual)
        let axleOmega = (electric.wheels[2].angularVelocity + electric.wheels[3].angularVelocity)/2
        check(electric.powertrainSound.shaftRPM > 3800 &&
              abs(electric.powertrainSound.shaftRPM - axleOmega * electric.kind.finalDrive * 60/(2 * .pi)) < 0.001 &&
              electric.powertrainSound.driveLoad == 0 && electric.powertrainSound.overrun == 0,
              "Honda e coasting in neutral still turns its fixed reduction without driving or regeneration")
        electric.gear = 1
        drive(&electric,seconds:0.15,input:gas,assists:manual)
        let evLoad = electric.powertrainSound.driveLoad
        drive(&electric,seconds:0.25,input:DrivingInput(),assists:manual)
        check(evLoad > 0.6 && electric.powertrainSound.driveLoad == 0 && electric.powertrainSound.overrun == 0,
              "Honda e delivers torque under power and reports no unmodelled regeneration on lift")
    }

    static func main() {
        checkPowertrainSound()
        let brake = DrivingInput(brake: 1)
        var car = Vehicle()
        check(car.requestShift(-1, pedals: DrivingInput(), automatic: true) == .stopAndBrake,
              "Automatic mode keeps drive engaged until the car is braked")
        check(car.requestShift(-1, pedals: brake, automatic: true) == .shifted && car.gearLabel == "N",
              "A braked car can select neutral in automatic mode")
        drive(&car, seconds: 0.5, input: DrivingInput(throttle: 0.8))
        check(car.gear == 0 && car.rpm > 5000 && car.speed < 0.001,
              "Neutral lets the engine rev with no propulsion or automatic gear selection")
        car.velocity = car.forward*8
        check(car.requestShift(-1, pedals: brake, automatic: true) == .stopAndBrake && car.gear == 0,
              "Reverse is blocked when rolling forward despite brake input")
        car.velocity = .zero
        check(car.requestShift(-1, pedals: DrivingInput(throttle: 0.5, brake: 1), automatic: true) == .stopAndBrake,
              "Reverse is blocked with simultaneous throttle and brake")
        check(car.requestShift(-1, pedals: brake, automatic: true) == .shifted && car.gearLabel == "R",
              "Reverse engages with the brake held at rest")
        drive(&car, seconds: 5, input: DrivingInput(throttle: 1))
        check(car.gear == -1 && car.forwardSpeed < -4 && car.forwardSpeed > -8.1 && car.position.y < -12,
              "Reverse torque moves the car backwards with a low-speed governor")
        check(car.requestShift(1, pedals: brake, automatic: true) == .stopAndBrake,
              "Leaving reverse requires slowing the car before direction change")
        drive(&car, seconds: 4, input: brake)
        check(car.speed < 0.05 && abs(car.yawRate) < 0.02, "Braking stops reverse motion without oscillation")
        check(car.requestShift(1, pedals: brake, automatic: true) == .shifted && car.gear == 0,
              "A stopped car exits reverse through neutral")
        drive(&car, seconds: 0.25, input: brake)
        check(car.requestShift(1, pedals: brake, automatic: true) == .shifted && car.gear == 1,
              "Drive can be reselected after neutral")
        drive(&car, seconds: 1.5, input: DrivingInput(throttle: 0.7))
        check(car.forwardSpeed > 3, "Drive accelerates forward after a reverse manoeuvre")

        var coasting = Vehicle(); coasting.gear = 0; coasting.velocity = coasting.forward*18
        for index in 0..<4 { coasting.wheels[index].angularVelocity = 18/coasting.wheelRadius }
        var revving = coasting
        drive(&coasting, seconds: 1, input: DrivingInput())
        drive(&revving, seconds: 1, input: DrivingInput(throttle: 0.8))
        check(abs(coasting.speed-revving.speed) < 0.001 && revving.rpm > 5000,
              "Neutral coasting is independent of accelerator position")
        for kind in [VehicleKind.ferrari, .porsche, .centenario] {
            var sample = Vehicle(); sample.kind = kind
            drive(&sample, seconds: 0.3, input: DrivingInput(throttle: 0.5), assists: DrivingAssists(tractionControl: false))
            let frontForce = sample.wheels.prefix(2).map(\.longitudinalForce).reduce(0,+)
            check(kind.frontDriveShare > 0 ? frontForce > 100 : frontForce < 0,
                  "Front contact patches transmit propulsion only on AWD: \(kind.label)")
        }
        var manual = Vehicle()
        check(manual.requestShift(1, pedals: DrivingInput(), automatic: true) == .unavailable &&
              manual.requestShift(1, pedals: DrivingInput(), automatic: false) == .shifted && manual.gear == 2,
              "Forward shifts are controlled by the chosen transmission mode")
        check(manual.requestShift(1, pedals: DrivingInput(), automatic: false) == .busy && manual.gear == 2,
              "Repeated shift requests respect the shift delay")
        var shift = Vehicle()
        shift.kind = .mazda
        shift.velocity = shift.forward*15
        for i in shift.wheels.indices { shift.wheels[i].angularVelocity = 15/shift.wheelRadius }
        let shifted = shift.requestShift(1,pedals:DrivingInput(throttle:0.5),automatic:false)
        var previousIgnition = shift.ignitionFraction
        var largestRestoration = 0.0
        for _ in 0..<60 {
            drive(&shift,seconds:1/240,input:DrivingInput(throttle:0.5),assists:DrivingAssists(automatic:false))
            largestRestoration = max(largestRestoration,shift.ignitionFraction-previousIgnition)
            previousIgnition = shift.ignitionFraction
        }
        check(shifted == .shifted && (0.02...0.08).contains(largestRestoration) && shift.ignitionFraction == 1,
              "Torque returns over several physics steps after an upshift")
        var downshift = Vehicle()
        downshift.kind = .mazda
        downshift.gear = 4
        downshift.velocity = downshift.forward*44
        check(downshift.requestShift(-1,pedals:brake,automatic:false) == .overRev && downshift.gear == 4,
              "An unsafe manual downshift keeps the current gear")
        downshift.velocity = downshift.forward*22
        for i in downshift.wheels.indices { downshift.wheels[i].angularVelocity = 22/downshift.wheelRadius }
        let manualAssists = DrivingAssists(automatic:false)
        drive(&downshift,seconds:0.4,input:DrivingInput(),assists:manualAssists)
        let fourthGearRPM = downshift.rpm
        let accepted = downshift.requestShift(-1,pedals:brake,automatic:false)
        drive(&downshift,seconds:0.12,input:DrivingInput(brake:0.3),assists:manualAssists)
        check(accepted == .shifted && downshift.gear == 3 && downshift.rpm > fourthGearRPM*1.18 &&
              downshift.rpm < downshift.kind.redline && downshift.brakeLinePressure > 0.05,
              "A safe braked downshift matches the lower ratio while line pressure keeps building")
        let mazda = VehicleKind.mazda
        let peakTorque = mazda.fullThrottleTorque(at: 5000)
        let redlinePowerHP = mazda.fullThrottleTorque(at: mazda.redline) * mazda.redline * (2 * .pi / 60) / 745.7
        check(abs(peakTorque / 1.35581795 - 125) < 0.05 && abs(redlinePowerHP - 142) < 0.05,
              "Mazda engine model meets both published full throttle anchors")
        var mx5 = Vehicle(); mx5.kind = .mazda
        var shifts: [Double] = [], previousGear = mx5.gear
        var launchTime = 0.0
        for tick in 1...2400 {
            drive(&mx5, seconds: 1/240, input: DrivingInput(throttle: 1))
            if mx5.gear != previousGear {
                previousGear = mx5.gear
                shifts.append(mx5.speedKPH)
            }
            if mx5.speedKPH >= 100 { launchTime = Double(tick) / 240; break }
        }
        let theoreticalShiftSpeeds = mazda.gearRatios.prefix(2).map {
            mazda.upshiftRPM * 2 * .pi / 60 * mx5.wheelRadius / ($0 * mazda.finalDrive) * 3.6
        }
        check(shifts.count == 2 && zip(shifts, theoreticalShiftSpeeds).allSatisfy { abs($0 - $1) < 4 }
              && (6.5...8.5).contains(launchTime),
              "Mazda reaches 100 km/h in third with its two shifts close to gearing estimates")
        check(BrakeCurve.allCases.allSatisfy { curve in
            (1...99).allSatisfy { i in
                let travel = Double(i)/100
                let pressure = Vehicle.brakeDemand(travel,curve:curve)
                return pressure > Vehicle.brakeDemand(travel-0.01,curve:curve) &&
                    abs(Vehicle.brakeTravel(for:pressure,curve:curve)-travel) < 0.001
            }
        }, "All brake curves rise monotonically and can be inverted by automatic systems")
        check(BrakeCurve.allCases.allSatisfy { curve in
            var car = Vehicle()
            var assists = DrivingAssists()
            assists.brakeCurve = curve
            let target = 0.008
            drive(&car,seconds:0.8,input:DrivingInput(brake:Vehicle.brakeTravel(for:target,curve:curve)),assists:assists)
            return abs(target-car.brakeLinePressure) < 0.0001
        }, "Low pressure requests and calibration curves agree with the settled hydraulic model")
        func brakeCurveSample(_ curve: BrakeCurve, travel: Double) -> Vehicle {
            var car = Vehicle(); car.kind = .mazda; car.gear = 0; car.velocity = car.forward*30
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 30/car.wheelRadius }
            var assists = DrivingAssists(); assists.brakeCurve = curve
            drive(&car,seconds:0.40,input:DrivingInput(brake:travel),assists:assists)
            return car
        }
        let soft = brakeCurveSample(.deep,travel:0.35), sharp = brakeCurveSample(.direct,travel:0.35)
        let full = BrakeCurve.allCases.map { brakeCurveSample($0,travel:1) }
        check(soft.brakeLinePressure < 0.08 && sharp.brakeLinePressure > 0.16 &&
              soft.longitudinalG > sharp.longitudinalG + 0.18 &&
              full.allSatisfy { abs($0.brakeLinePressure-1) < 0.001 && abs($0.speed-full[0].speed) < 0.001 },
              "A lighter brake curve preserves more travel at partial pedal without reducing full braking")
        func rollingMazda() -> Vehicle {
            var car = Vehicle()
            car.kind = .mazda
            car.gear = 0
            car.velocity = car.forward*30
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 30/car.wheelRadius }
            return car
        }
        var lightTap = rollingMazda()
        var emergency = lightTap
        drive(&lightTap,seconds:0.025,input:DrivingInput(brake:0.25))
        drive(&emergency,seconds:0.025,input:DrivingInput(brake:1))
        let lightFraction = lightTap.brakeLinePressure / BrakeCurve.progressive.pressure(for:0.25)
        check((0.14...0.34).contains(lightFraction) && (0.46...0.62).contains(emergency.brakeLinePressure),
              "Initial travel softens a light tap while emergency pressure still builds promptly")
        check(lightTap.brakeLightsActive && lightTap.brakeLinePressure < 0.025,
              "A light brake tap reaches the brake lights before the line builds full pressure")
        var trail = rollingMazda()
        drive(&trail,seconds:0.25,input:DrivingInput(brake:0.85))
        let firm = trail.brakeLinePressure
        drive(&trail,seconds:0.05,input:DrivingInput(brake:0.32,steering:0.4))
        let target = BrakeCurve.progressive.pressure(for:0.32)
        check(trail.brakeLinePressure > target && trail.brakeLinePressure < firm*0.28 && abs(trail.steeringAngle) > 0.008,
              "Trail braking meters pressure down as steering starts, without dropping the brakes")
        drive(&trail,seconds:0.085,input:DrivingInput(steering:0.45))
        check(trail.brakeLinePressure < 0.002 && !trail.absActive,
              "Coming fully off the pedal vents residual pressure and clears ABS")
        let overspeed = 19.0
        let limitPressure = BrakeCurve.allCases.map { curve in
            let command = pitLimitedInput(DrivingInput(throttle:1),speed:overspeed,curve:curve)
            return curve.pressure(for:command.brake)
        }
        check((limitPressure.max() ?? 0)-(limitPressure.min() ?? 0) < 0.001,
              "Pit limiter applies the same pressure even when player pedal response changes")
        check(DrivingAssists.validatedBrakeBias(.nan) == DrivingAssists.defaultBrakeBias &&
              DrivingAssists.validatedBrakeBias(4) == 0.72 && DrivingAssists.validatedBrakeBias(-1) == 0.52,
              "Brake bias rejects invalid data and clamps the supported range")

        func brakeSample(_ bias: Double) -> (frontShare: Double, force: Double) {
            var sample = Vehicle(); sample.gear = 0; sample.velocity = sample.forward*30
            for index in 0..<4 { sample.wheels[index].angularVelocity = 30/sample.wheelRadius }
            var assists = DrivingAssists(abs: false); assists.frontBrakeBias = bias
            drive(&sample, seconds: 0.35, input: DrivingInput(brake: 0.28), assists: assists)
            let total = -sample.wheels.map(\.longitudinalForce).reduce(0,+)
            let front = -(sample.wheels[0].longitudinalForce + sample.wheels[1].longitudinalForce)
            return (front/total,total)
        }
        let rearward = brakeSample(0.52), forward = brakeSample(0.72)
        print(String(format:"Measured front force share %.1f%% → %.1f%% at 28%% pedal",rearward.frontShare*100,forward.frontShare*100))
        check(forward.frontShare-rearward.frontShare > 0.15,
              "Changing bias changes actual front/rear tyre braking forces")
        check(abs(forward.force-rearward.force)/rearward.force < 0.05,
              "At partial braking below grip limits, changing the split preserves total force")

        func frontAxleOnRollers(_ kind: VehicleKind, brake: Double) -> (normal: Double, braking: Double) {
            var sample = Vehicle()
            sample.kind = kind
            sample.gear = 0
            let rollerSpeed = 22.0
            for wheel in sample.wheels.indices { sample.wheels[wheel].angularVelocity = rollerSpeed/sample.wheelRadius }
            for _ in 0..<600 {
                sample.velocity = sample.forward * rollerSpeed
                sample.step(1/240, input: DrivingInput(brake:brake), assists: DrivingAssists(automatic:false),
                            roadDistance:0, roadWidth:12)
            }
            return (sample.wheels[0].normalLoad + sample.wheels[1].normalLoad,
                    -sample.wheels.reduce(0) { $0 + $1.longitudinalForce })
        }
        let coastingHonda = frontAxleOnRollers(.honda,brake:0)
        let brakingHonda = frontAxleOnRollers(.honda,brake:0.5)
        let inferredHeight = VehicleKind.honda.wheelbase * (brakingHonda.normal - coastingHonda.normal)
            / (brakingHonda.braking - coastingHonda.braking)
        print(String(format:"Honda e effective CG height from brake load transfer %.3f m",inferredHeight))
        check(abs(inferredHeight - 0.50) < 0.015,
              "Measured Honda front axle load change under braking recovers its published approximate CG height")

        func roadStepInertia(_ kind: VehicleKind) -> (roll: Double, pitch: Double) {
            var sample = Vehicle()
            sample.kind = kind
            var contacts = Array(repeating:WheelRoadContact(distance:0,progress:0,kerbsEnabled:false),count:4)
            contacts[0].elevation = 0.008
            let interval = 1.0/720
            sample.step(interval, input:DrivingInput(), assists:DrivingAssists(), roadDistance:0, roadWidth:12, roadContacts:contacts)
            let loads = sample.wheels.map(\.normalLoad)
            let rollMoment = (loads[1] + loads[3] - loads[0] - loads[2]) * kind.track/2
            let frontArm = kind.distanceFromCGToFrontAxle
            let pitchMoment = (loads[0] + loads[1]) * frontArm - (loads[2] + loads[3]) * (kind.wheelbase-frontArm)
            return (rollMoment * interval * interval / sample.roll, pitchMoment * interval * interval / sample.pitch)
        }
        let eliseInertia = roadStepInertia(.lotus), hondaInertia = roadStepInertia(.honda)
        check(eliseInertia.roll > 0 && eliseInertia.pitch > 0 &&
              hondaInertia.roll > eliseInertia.roll * 1.5 && hondaInertia.pitch > eliseInertia.pitch * 1.7,
              "Wheel loads on a unilateral road step produce distinct roll and pitch responses for the Elise and Honda e")

        for (kind, expectedFrontShare) in [(VehicleKind.ferrari,0.42),(.porsche,0.38),(.honda,0.50)] {
            var sample = Vehicle()
            sample.kind = kind
            drive(&sample,seconds:1,input:DrivingInput())
            let totalLoad = sample.wheels.reduce(0) { $0 + $1.normalLoad }
            let frontShare = (sample.wheels[0].normalLoad + sample.wheels[1].normalLoad) / totalLoad
            check(abs(frontShare - expectedFrontShare) < 0.001 && abs(totalLoad-sample.mass*9.81) < 1 && abs(sample.pitch) < 0.0001,
                  "Stationary wheel loads reproduce the reference axle split without pitching: \(kind.label)")
        }

        var spinning = Vehicle()
        spinning.kind = .ferrari
        spinning.heading = 0.7
        spinning.position = SIMD2(10,-12)
        spinning.heave = 0.15
        spinning.yawRate = 3
        spinning.gear = 0
        let originalCG = spinning.centreOfGravityPosition
        let originalOrigin = spinning.position
        spinning.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        let frontMidpoint = (spinning.contactPoints[0] + spinning.contactPoints[1])/2
        check(spinning.wheels.allSatisfy { $0.normalLoad == 0 } &&
              simd_distance(spinning.position,originalOrigin) > 0.0001 &&
              simd_distance(spinning.centreOfGravityPosition,originalCG) < 0.0000001 &&
              simd_distance(frontMidpoint,spinning.position + spinning.forward * spinning.kind.frontAxle) < 0.0000001,
              "An airborne rear-biased car pivots about its stationary CG while the wheels follow the authored model")
        for direction in [-1.0,1.0] {
            var sample = Vehicle(); sample.gear = 0; sample.velocity = sample.forward*7.8*direction
            for index in 0..<4 { sample.wheels[index].angularVelocity = sample.forwardSpeed/sample.wheelRadius }
            var release = 0.0
            for _ in 0..<120 {
                sample.step(1/240,input:brake,assists:DrivingAssists(),roadDistance:9,roadWidth:12)
                release = max(release,sample.absRelease)
            }
            check(release > 0.1,"ABS detects locking under braking in direction \(direction)")
        }
        if failures > 0 { exit(1) }
    }
}

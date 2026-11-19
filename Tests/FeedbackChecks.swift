import Foundation
import simd
@main struct FeedbackChecks {
    static var failures=0
    static func check(_ valid:Bool,_ message:String) {
        print("\(valid ? "PASS" : "FAIL")  \(message)");if !valid { failures += 1 }
    }
    static func main() {
        var car=Vehicle();car.velocity=car.forward*20
        for i in 0..<4 { car.wheels[i].normalLoad=3100 }
        var feedback=HapticFeedback()
        let idle=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(idle.peak==0,"Smooth straight running does not produce permanent rumble")
        func cornerTrace(front: Double,rear: Double,load: Double = 3100,lateralForce: Double = 3000) -> [HapticOutput] {
            var sample = car
            var mapping = HapticFeedback()
            for index in sample.wheels.indices {
                sample.wheels[index].normalLoad = load
                sample.wheels[index].relaxedSlipAngle = 0.15
                sample.wheels[index].slidingFraction = index < 2 ? front : rear
                sample.wheels[index].lateralForce = lateralForce
                sample.wheels[index].longitudinalForce = 3000-abs(lateralForce)
            }
            return (0..<60).map { _ in
                mapping.update(vehicle:sample,input:DrivingInput(),impact:.zero,dt:1/60,active:true)
            }
        }
        let frontTrace = cornerTrace(front:0.95,rear:0.18).suffix(30)
        let rearTrace = cornerTrace(front:0.18,rear:0.95).suffix(30)
        let frontStrengths = frontTrace.map(\.combinedGrip), rearStrengths = rearTrace.map(\.combinedGrip)
        let rearLevels = rearStrengths.reduce(into:[Int]()) { values,strength in
            values.append(HapticOutput.compatibilityLevel(for:strength*0.75,previous:values.last ?? 0))
        }
        check(frontStrengths.min()! > 0.15 && frontStrengths.max()!-frontStrengths.min()! < 0.01 &&
              rearStrengths.max()!-rearStrengths.min()! > 0.10 &&
              Set(rearLevels).count >= 3 &&
              frontTrace.last!.sharpness > rearTrace.last!.sharpness+0.20,
              "Front push gives steady scrub while rear breakaway pulses even on a combined handle")
        check(cornerTrace(front:1,rear:1,load:0).allSatisfy { $0.peak == 0 } &&
              cornerTrace(front:1,rear:1,lateralForce:0).allSatisfy { $0.peak == 0 },
              "Airborne and purely longitudinal sliding do not generate cornering cues")
        let balanced = cornerTrace(front:0.95,rear:0.95).suffix(30).map(\.combinedGrip)
        check(balanced.min()! > 0.15 && balanced.max()!-balanced.min()! < 0.01,
              "A balanced four-wheel slide does not falsely signal rear breakaway")
        var fishtail = Vehicle()
        fishtail.kind = .mazda
        fishtail.gear = 0
        fishtail.yawRate = 1.6
        fishtail.velocity = fishtail.forward*22 - fishtail.modelX*(fishtail.yawRate*fishtail.kind.frontAxle)
        for index in fishtail.wheels.indices { fishtail.wheels[index].angularVelocity = 22/fishtail.wheelRadius }
        var recovery = HapticFeedback()
        var initialCue = 0.0, finalCue = 0.0
        for frame in 0..<240 {
            for _ in 0..<4 {
                fishtail.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            }
            finalCue = recovery.update(vehicle:fishtail,input:DrivingInput(),impact:.zero,dt:1/60,active:true).combinedGrip
            if frame < 6 { initialCue = max(initialCue,finalCue) }
        }
        check(initialCue > 0.08 && finalCue < 0.01,
              "A simulated rear-axle disturbance reaches the handles within 100 ms and clears as the car settles")
        car.wheels[1].kerbFeedback=1;car.wheels[3].kerbFeedback=1
        let left=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(left.left>0.3 && left.right==0,"Driver-left kerbs excite the left handle only")
        feedback.reset();car.wheels[1].kerbFeedback=0;car.wheels[3].kerbFeedback=0;car.wheels[0].kerbFeedback=1
        let right=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(right.right>0.3 && right.left==0,"Driver-right kerbs excite the right handle only")
        let paused=feedback.update(vehicle:car,input:DrivingInput(),impact:SIMD2(1,1),dt:0.001,active:false)
        check(paused.peak==0,"Pause immediately clears road and collision vibration")
        car.velocity = .zero
        check(feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true).peak==0,"Stationary kerb contact does not rumble")
        let hit=feedback.update(vehicle:car,input:DrivingInput(),impact:SIMD2(1,0.25),dt:0.05,active:true)
        check(hit.left>hit.right && hit.left>0,"A stopped car can still receive the directional impact impulse")
        feedback.reset();car.velocity=car.forward*20;car.absActive=true;car.absRelease=0.8
        let absFeedback=feedback.update(vehicle:car,input:DrivingInput(brake:1),impact:.zero,dt:0.01,active:true)
        check(absFeedback.brake>0 && absFeedback.throttle==0,"ABS pulses are routed to the brake trigger")
        var pulse = HapticFeedback()
        let absTrace = (0..<60).map { _ in
            pulse.update(vehicle:car,input:DrivingInput(brake:0.9),impact:.zero,dt:1/120,active:true).brake
        }
        let steadyPulse = absTrace.dropFirst(12)
        check(steadyPulse.max()! > 0.55 && steadyPulse.min()! < 0.15 &&
              Set(steadyPulse.map { Int($0*100) }).count > 12,
              "ABS produces a distinguishable pulse with intermediate amplitudes")
        car.absActive = false
        var released = HapticOutput.zero
        for _ in 0..<12 {
            released = pulse.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:1/120,active:true)
        }
        check(released.brake < 0.01,"ABS feedback fades promptly when the brake unloads")
        feedback.reset();car.absActive=false;car.wheels[2].slipRatio=0.9
        let spin=feedback.update(vehicle:car,input:DrivingInput(throttle:1),impact:.zero,dt:0.05,active:true)
        check(spin.throttle>0 && spin.brake==0,"Driven wheel spin is routed to the throttle trigger")
        check(spin.scaled(0).peak==0 && spin.scaled(.nan).peak==0,"Off and invalid gain safely silence all actuators")
        check(HapticOutput(left:9,right:9,brake:9,throttle:9).scaled(1).peak<=0.8,"Feedback saturates at the configured safe output ceiling")
        check(HapticOutput.test(at:0.1).left>0 && HapticOutput.test(at:0.8).right>0 && HapticOutput.test(at:1.3).brake>0 &&
              HapticOutput.test(at:1.9).throttle>0 && HapticOutput.test(at:HapticOutput.testDuration).peak==0,
              "Finite calibration sequence covers both handles and triggers")
        check(absFeedback.combinedGrip >= absFeedback.brake*0.8 && HapticOutput.test(at:1.9).combinedGrip > 0.4,
              "Combined grip mode retains ABS and trigger effects")
        let kerbAndABS = HapticOutput(left:0.27,right:0.04,brake:0.24)
        check(kerbAndABS.combinedGrip > 0.30 && kerbAndABS.combinedGrip < 0.36,
              "The combined Xbox channel preserves weaker brake texture over a kerb")
        check(HapticOutput.compatibilityLevel(for:0.227,previous:4) == 4 &&
              HapticOutput.compatibilityLevel(for:0.235,previous:4) == 5 &&
              HapticOutput.compatibilityLevel(for:0.224,previous:5) == 5,
              "Compatibility output holds its level through a small fluctuation near a boundary")
        var locking = Vehicle()
        locking.velocity = locking.forward*20
        locking.wheels[0].slipRatio = -0.75
        locking.wheels[0].normalLoad = 3100
        var roadFeedback = HapticFeedback()
        let rollingLock = roadFeedback.update(vehicle:locking,input:DrivingInput(brake:0.7),impact:.zero,dt:1/120,active:true)
        locking.wheels[0].normalLoad = 0
        let unloadedLock = roadFeedback.update(vehicle:locking,input:DrivingInput(brake:0.7),impact:.zero,dt:1/120,active:true)
        check(rollingLock.brake > 0.2 && unloadedLock.brake == 0,
              "A loaded locking tyre warns through the brake trigger without false feedback from an unloaded wheel")
        var controlled = Vehicle()
        controlled.velocity = controlled.forward*20
        controlled.tcActive = true
        controlled.tcReduction = 0.5
        var tcFeedback = HapticFeedback()
        let tcCue = tcFeedback.update(vehicle:controlled,input:DrivingInput(throttle:0.6),impact:.zero,dt:0.05,active:true)
        check(tcCue.throttle > 0.08 && tcCue.throttle < 0.14 && tcCue.brake == 0,
              "A traction cut leaves a subtle throttle warning even after spin is suppressed")
        let circuit=Circuit()
        check(kerbElevation(progress:1,distanceFromEdge:0)==0 && kerbElevation(progress:1,distanceFromEdge:0.85)==0,"Kerb entry and exit meet the asphalt without a height step")
        check((0..<100).allSatisfy { (0...0.043).contains(kerbElevation(progress:Double($0)/10,distanceFromEdge:0.4)) },"Shared kerb profile remains within its 42 mm design height")
        var coupled=Vehicle()
        let contacts=[WheelRoadContact(distance:0,progress:30,kerbsEnabled:true),WheelRoadContact(distance:6.4,progress:30,kerbsEnabled:true),WheelRoadContact(distance:0,progress:27,kerbsEnabled:true),WheelRoadContact(distance:0,progress:27,kerbsEnabled:true)]
        coupled.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12,roadContacts:contacts)
        check(coupled.wheels[1].antiRollForce>0 && abs(coupled.wheels[0].antiRollForce+coupled.wheels[1].antiRollForce)<0.001,"Anti-roll coupling transfers load within the axle without adding net support")
        coupled.heave = -0.12
        coupled.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        check(coupled.wheels.allSatisfy { $0.bumpStopForce>0 && $0.normalLoad>=0 },"Deep suspension compression engages progressive bump stops")
        func stop(_ initialTemperature:Double) -> (Double,Double) {
            var v=Vehicle();v.velocity=v.forward*35
            for i in 0..<4 { v.wheels[i].angularVelocity=35/v.wheelRadius;v.wheels[i].brakeTemperature=initialTemperature }
            for _ in 0..<2400 { v.step(1/240,input:DrivingInput(brake:0.35),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
            return (v.distanceTravelled,v.wheels[0].brakeTemperature)
        }
        let fresh=stop(40),hot=stop(1000)
        print(String(format:"Brake comparison at 35%% pedal: fresh %.2f m, hot %.2f m",fresh.0,hot.0))
        check(fresh.1>40,"Braking work raises rotor temperature")
        check(hot.0>fresh.0*1.08,"Overheated brakes increase stopping distance at equal 35% pedal demand")
        var repair=Vehicle();repair.wheels[0].brakeTemperature=850
        repair.reset(at:circuit.start,preservingCondition:true)
        check(repair.wheels[0].brakeTemperature==850,"Recovery preserves overheated brake condition")
        repair.service(setup:TyreSetup())
        check(repair.wheels.allSatisfy { $0.brakeTemperature==40 && $0.brakeFadeFactor==1 },"Service restores brake temperature and available torque")
        check(CircuitKind.allCases.allSatisfy { !Circuit(kind:$0).cornerDistances.isEmpty },"All six maps derive braking markers from their own bends")
        if failures>0 {exit(1)}
    }
}

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
        feedback.reset();car.absActive=false;car.wheels[2].slipRatio=0.9
        let spin=feedback.update(vehicle:car,input:DrivingInput(throttle:1),impact:.zero,dt:0.05,active:true)
        check(spin.throttle>0 && spin.brake==0,"Driven wheel spin is routed to the throttle trigger")
        check(spin.scaled(0).peak==0 && spin.scaled(.nan).peak==0,"Off and invalid gain safely silence all actuators")
        check(HapticOutput(left:9,right:9,brake:9,throttle:9).scaled(1).peak<=0.8,"Feedback saturates at the configured safe output ceiling")
        check(HapticOutput.test(at:0.1).left>0 && HapticOutput.test(at:0.45).right>0 && HapticOutput.test(at:0.8).brake>0 && HapticOutput.test(at:1.1).throttle>0 && HapticOutput.test(at:1.4).peak==0,"Finite calibration sequence covers both handles and triggers")
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
        check(CircuitKind.allCases.allSatisfy { !Circuit(kind:$0).cornerDistances.isEmpty },"All four maps derive braking markers from their own bends")
        if failures>0 {exit(1)}
    }
}

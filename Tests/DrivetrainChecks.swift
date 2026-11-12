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

    static func main() {
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
        var manual = Vehicle()
        check(manual.requestShift(1, pedals: DrivingInput(), automatic: true) == .unavailable &&
              manual.requestShift(1, pedals: DrivingInput(), automatic: false) == .shifted && manual.gear == 2,
              "Forward shifts are controlled by the chosen transmission mode")
        check(manual.requestShift(1, pedals: DrivingInput(), automatic: false) == .busy && manual.gear == 2,
              "Repeated shift requests respect the shift delay")
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

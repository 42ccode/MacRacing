import Foundation

@main struct KeyboardSteeringChecks {
    static func main() {
        for hz in [60,120,240] {
            var left = KeyboardSteering()
            for _ in 0..<(hz/4) { left.update(left:true,right:false,dt:1/Double(hz)) }
            precondition(left.value == -1)
            for _ in 0..<(hz/12) { left.update(left:false,right:true,dt:1/Double(hz)) }
            precondition(abs(left.value) < 1e-9)
            for _ in 0..<(hz/4) { left.update(left:false,right:true,dt:1/Double(hz)) }
            precondition(left.value == 1)
            for _ in 0..<(hz/6) { left.update(left:true,right:true,dt:1/Double(hz)) }
            precondition(left.value == 0)
            print("PASS  Keyboard holds, countersteering and opposed keys agree at \(hz) Hz")
        }
        for kind in VehicleKind.allCases {
            func tap(gradual: Bool, movingRight: Bool) -> (Double,Double) {
                var car = Vehicle(), steering = KeyboardSteering()
                car.kind = kind
                car.reset(at:Circuit(kind:.north).start)
                car.velocity = car.forward*(100/3.6)
                for i in car.wheels.indices { car.wheels[i].angularVelocity = car.speed/car.wheelRadius }
                var peakAngle = 0.0, peakYaw = 0.0
                for tick in 0..<120 {
                    let active = tick < 12
                    steering.update(left:active && !movingRight,right:active && movingRight,dt:1/240)
                    let command = gradual ? steering.value : (active ? (movingRight ? 1.0 : -1.0) : 0)
                    car.step(1/240,input:DrivingInput(steering:command),assists:DrivingAssists(),roadDistance:0,roadWidth:20)
                    peakAngle = max(peakAngle,abs(car.steeringAngle)*180 / .pi)
                    peakYaw = max(peakYaw,abs(car.yawRate)*180 / .pi)
                }
                return (peakAngle,peakYaw)
            }
            for right in [false,true] {
                let old = tap(gradual:false,movingRight:right), new = tap(gradual:true,movingRight:right)
                precondition(new.0 > 0.1 && new.0 < 0.6*old.0 && new.1 > 0.1 && new.1 < 0.75*old.1)
                print(String(format:"PASS  %@ 50 ms key tap at 100 km/h, wheel %.2f → %.2f°, yaw %.2f → %.2f°/s",kind.label,old.0,new.0,old.1,new.1))
            }
        }
    }
}

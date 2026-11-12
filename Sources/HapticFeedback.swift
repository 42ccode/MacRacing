import Foundation
import simd

struct HapticOutput: Equatable {
    var left = 0.0
    var right = 0.0
    var brake = 0.0
    var throttle = 0.0
    var sharpness = 0.3
    static let zero = HapticOutput()
    var peak: Double { max(left,right,brake,throttle) }
    func scaled(_ amount: Double) -> HapticOutput {
        let gain = amount.isFinite ? clamp(amount,0,1) : 0
        return HapticOutput(left:clamp(left*gain,0,0.8),right:clamp(right*gain,0,0.8),
            brake:clamp(brake*gain,0,0.65),throttle:clamp(throttle*gain,0,0.65),sharpness:sharpness)
    }
    static func test(at time: Double) -> HapticOutput {
        switch time {
        case 0..<0.25: return HapticOutput(left:0.45)
        case 0.35..<0.60: return HapticOutput(right:0.45)
        case 0.70..<0.95: return HapticOutput(brake:0.40)
        case 1.05..<1.30: return HapticOutput(throttle:0.40)
        default: return .zero
        }
    }
}

/// Hardware-independent signal mapping. Wheel order: FR, FL, RR, RL.
struct HapticFeedback {
    private var phase = 0.0
    private var output = HapticOutput.zero
    mutating func reset() { phase = 0; output = .zero }
    mutating func update(vehicle: Vehicle, input: DrivingInput, impact: SIMD2<Double>, dt: Double, active: Bool) -> HapticOutput {
        guard active else { reset(); return .zero }
        let step = clamp(dt,0,0.1)
        phase = (phase+step).truncatingRemainder(dividingBy:1)
        let rolling = clamp((vehicle.speed-0.5)/8,0,1)
        func side(_ indices: [Int]) -> Double {
            indices.map { i in
                let wheel = vehicle.wheels[i]
                guard wheel.normalLoad > 100 else { return 0.0 }
                let slip = clamp((abs(wheel.slipAngle)-0.04)*2 + max(0,abs(wheel.slipRatio)-0.10)*0.25,0,1)
                let rough = wheel.surface == .grass ? 0.10*(0.5+0.5*sin(phase * .pi*38)) : 0
                return rolling*(wheel.kerbFeedback*0.6+slip*0.22+rough)
            }.max() ?? 0
        }
        let absPulse = vehicle.absActive && input.brake>0.1 ? vehicle.absRelease*(0.4+0.6*max(0,sin(phase * .pi*26))) : 0
        let driveDirection = vehicle.gear < 0 ? -1.0 : 1.0
        let spin = input.throttle>0.1 && vehicle.gear != 0 ? clamp((max(vehicle.wheels[2].slipRatio*driveDirection,vehicle.wheels[3].slipRatio*driveDirection)-0.12)*0.7,0,0.5)*rolling : 0
        let target = HapticOutput(left:side([1,3])+impact.x*0.7+absPulse*0.12,
            right:side([0,2])+impact.y*0.7+spin*0.18,brake:absPulse*0.6,throttle:spin,
            sharpness:vehicle.kerbFeedback>0.1 ? 0.65 : 0.3)
        let gain = 1-exp(-step*24)
        output.left += (target.left-output.left)*gain
        output.right += (target.right-output.right)*gain
        output.brake = target.brake; output.throttle = target.throttle; output.sharpness = target.sharpness
        return output.scaled(1)
    }
}

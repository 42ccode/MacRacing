import Foundation
import simd

struct HapticOutput: Equatable {
    var left = 0.0
    var right = 0.0
    var brake = 0.0
    var throttle = 0.0
    var sharpness = 0.3
    static let zero = HapticOutput()
    static let testDuration = 2.25
    var peak: Double { max(left,right,brake,throttle) }
    var combinedGrip: Double {
        let road = max(left,right)
        let controls = max(brake*0.80,throttle*0.70)
        let main = clamp(max(road,controls),0,0.8)
        return main + 0.38*min(road,controls)*(1-main/0.8)
    }
    static func compatibilityLevel(for value: Double,previous: Int) -> Int {
        guard value.isFinite else { return 1 }
        let level = clamp(Int((clamp(value,0,0.8)/0.05).rounded()),1,16)
        // Keep adjacent levels from repeatedly restarting the motor if the
        // signal vibrates near a boundary.
        if previous > 0, abs(level-previous) == 1, abs(value-Double(previous)*0.05) < 0.033 {
            return previous
        }
        return level
    }
    func scaled(_ amount: Double) -> HapticOutput {
        let gain = amount.isFinite ? clamp(amount,0,1) : 0
        return HapticOutput(left:clamp(left*gain,0,0.8),right:clamp(right*gain,0,0.8),
            brake:clamp(brake*gain,0,0.65),throttle:clamp(throttle*gain,0,0.65),sharpness:sharpness)
    }
    static func test(at time: Double) -> HapticOutput {
        switch time {
        case 0..<0.44: return HapticOutput(left:0.80)
        case 0.56..<1.0: return HapticOutput(right:0.80)
        case 1.12..<1.56: return HapticOutput(brake:0.65)
        case 1.68..<2.12: return HapticOutput(throttle:0.65)
        default: return .zero
        }
    }
}

/// Hardware-independent signal mapping. Wheel order: FR, FL, RR, RL.
struct HapticFeedback {
    private var roadPhase = 0.0
    private var rearSlipPhase = 0.0
    private var absPhase = 0.0
    private var absEnvelope = 0.0
    private var output = HapticOutput.zero

    mutating func reset() { self = HapticFeedback() }

    mutating func update(vehicle: Vehicle, input: DrivingInput, impact: SIMD2<Double>, dt: Double, active: Bool) -> HapticOutput {
        guard active else { reset(); return .zero }
        let step = clamp(dt,0,0.1)
        let speed = vehicle.speed
        let rolling = clamp((speed-0.6)/8,0,1)
        roadPhase = (roadPhase + step * min(17,4 + speed*0.34)).truncatingRemainder(dividingBy:1)
        func follow(_ value: Double,_ target: Double,attack: Double,release: Double) -> Double {
            let rate = target > value ? attack : release
            return value + (target-value)*(1-exp(-step*rate))
        }
        func cornerSlip(_ wheel: WheelState) -> Double {
            let totalForce = hypot(wheel.longitudinalForce,wheel.lateralForce)
            guard totalForce > 1, wheel.normalLoad > 100 else { return 0 }
            let lateralShare = abs(wheel.lateralForce)/totalForce
            let slide = clamp((wheel.slidingFraction-0.12)/0.88,0,1)
            let treadSpeed = speed*abs(sin(wheel.relaxedSlipAngle))
            let load = clamp(wheel.normalLoad/(vehicle.mass*9.81/4),0,1)
            return slide*lateralShare*load*clamp(treadSpeed/1.6,0,1)
        }
        let corner = SIMD4(cornerSlip(vehicle.wheels[0]),cornerSlip(vehicle.wheels[1]),
                           cornerSlip(vehicle.wheels[2]),cornerSlip(vehicle.wheels[3]))
        let frontSlip = max(corner[0],corner[1])
        let rearSlip = max(corner[2],corner[3])
        let rearExcess = max(0,rearSlip-frontSlip)
        rearSlipPhase = (rearSlipPhase+step*5).truncatingRemainder(dividingBy:1)
        let rearPulse = 0.5+0.5*cos(2 * .pi * rearSlipPhase)
        func road(_ index: Int) -> Double {
            let wheel = vehicle.wheels[index]
            let contact = clamp((wheel.normalLoad-100)/1100,0,1)
            let scrub = index < 2 ? 0.23*corner[index] :
                0.16*corner[index]+min(corner[index],rearExcess)*(0.22*rearPulse-0.09)
            let texture = 0.60 + 0.40 * sin(2 * .pi * (roadPhase + Double(index)*0.17))
            let grass = wheel.surface == .grass ? 0.105*texture : 0
            let wheelPulse = 0.5+0.5*cos(wheel.rotation)
            // At very high speed the wheel pulses approach the playback
            // rate. Blend towards their average rather than aliasing.
            let vibrationShare = clamp((abs(wheel.angularVelocity)-120)/65,0,1)
            let flatTexture = wheelPulse*wheelPulse*(1-vibrationShare)+0.375*vibrationShare
            let flatSpot = wheel.flatSpot * (0.015+0.13*flatTexture) * clamp(speed/20,0,1)
            return rolling*(scrub + contact*(0.53*wheel.kerbFeedback + grass + flatSpot))
        }
        func grip(_ front: Int,_ rear: Int) -> Double {
            let a = road(front), b = road(rear)
            return max(a,b) + 0.22*min(a,b)
        }
        let absTarget = vehicle.absActive && input.brake > 0.05 ? clamp(vehicle.absRelease,0,1)*rolling : 0
        if absEnvelope < 0.002 && absTarget > 0 { absPhase = 0 }
        absEnvelope = follow(absEnvelope,absTarget,attack:100,release:44)
        if absEnvelope > 0.001 { absPhase = (absPhase+step*11).truncatingRemainder(dividingBy:1) }
        let pulse = absEnvelope*(0.59+0.41*cos(2 * .pi * absPhase))
        let heavyBrake = clamp((vehicle.brakeLinePressure-0.38)/0.62,0,1)*rolling
        let driveDirection = vehicle.gear < 0 ? -1.0 : 1.0
        let rollingDirection = vehicle.forwardSpeed < 0 ? -1.0 : 1.0
        let locking = vehicle.wheels.reduce(0.0) { highest,wheel in
            let slip = clamp((-wheel.slipRatio*rollingDirection-0.13)/0.58,0,1)
            let loaded = clamp((wheel.normalLoad-250)/1100,0,1)
            return max(highest,slip*loaded)
        }
        let driveSlip = vehicle.wheels.indices.reduce(0.0) { highest,index in
            let axleShare = index < 2 ? vehicle.kind.frontDriveShare : 1-vehicle.kind.frontDriveShare
            let wheel = vehicle.wheels[index]
            guard axleShare > 0, wheel.normalLoad > 100 else { return highest }
            return max(highest,wheel.slipRatio*driveDirection)
        }
        let spin = input.throttle > 0.1 && vehicle.gear != 0
            ? clamp((driveSlip-0.12)*0.63,0,0.50)*rolling : 0
        let tractionControl = vehicle.tcActive && input.throttle > 0.15 ? 0.23*vehicle.tcReduction*rolling : 0
        let left = grip(1,3), right = grip(0,2)
        output.left = follow(output.left,left+0.70*impact.x,attack:63,release:25)
        output.right = follow(output.right,right+0.70*impact.y,attack:63,release:25)
        let lockCue = input.brake > 0.12 && !vehicle.absActive ? locking*rolling*0.30 : 0
        output.brake = max(0.77*pulse,heavyBrake*0.24,lockCue)
        output.throttle = follow(output.throttle,max(spin,tractionControl),attack:38,release:31)
        let roadSharpness = 0.38*clamp(vehicle.kerbFeedback+max(impact.x,impact.y),0,1)
        let frontSharpness = 0.37*max(0,frontSlip-rearSlip)*rolling
        let sharp = 0.23 + max(roadSharpness,frontSharpness) + 0.12*pulse
        output.sharpness = follow(output.sharpness,sharp,attack:55,release:23)
        return output.scaled(1)
    }
}

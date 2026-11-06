import Foundation
import simd

struct DrivingInput {
    var throttle = 0.0
    var brake = 0.0
    var steering = 0.0
}

struct DrivingAssists {
    var abs = true
    var tractionControl = true
    var automatic = true
    var steeringDeadzone = 0.08
}

struct WheelState {
    var angularVelocity = 0.0
    var rotation = 0.0
    var slipRatio = 0.0
    var slipAngle = 0.0
    var normalLoad = 0.0
    var longitudinalForce = 0.0
    var lateralForce = 0.0
    var temperature = 38.0
    var brakePressure = 1.0
    var surfaceHeight = 0.0
}

/// Four contact patches, rotating wheels and sprung heave/roll/pitch states.
/// Brush-style combined-slip tyres use explicit prototype parameters, not iRacing data.
struct Vehicle {
    var position = SIMD2<Double>.zero
    var velocity = SIMD2<Double>.zero
    var heading = 0.0
    var yawRate = 0.0
    var steeringAngle = 0.0
    var rpm = 950.0
    var gear = 1
    var lateralG = 0.0
    var longitudinalG = 0.0
    var tyreSlip = 0.0
    var tcActive = false
    var absActive = false
    var distanceTravelled = 0.0
    var wheels = [WheelState](repeating: WheelState(), count: 4)
    var heave = 0.0
    var roll = 0.0
    var pitch = 0.0
    private var heaveRate = 0.0
    private var rollRate = 0.0
    private var pitchRate = 0.0
    private var shiftCooldown = 0.0

    let mass = 1260.0
    let wheelbase = 2.80
    let wheelRadius = 0.384
    let trackWidth = 1.96
    let gearRatios = [3.20, 2.10, 1.52, 1.18, 0.95, 0.79]
    var forward: SIMD2<Double> { SIMD2(sin(heading), cos(heading)) }
    var modelX: SIMD2<Double> { SIMD2(cos(heading), -sin(heading)) }
    var speed: Double { simd_length(velocity) }
    var speedKPH: Double { speed * 3.6 }
    // Angular coordinates are positive about +Y (toward model-local +X).
    // With a +Z-facing car, that is left from the driver's seat.
    var ignitionFraction: Double {
        let shiftCut = shiftCooldown > 0.12 ? 0.35 : 1.0
        return rpm > 7100 ? shiftCut * 0.10 : shiftCut
    }
    var forwardSpeed: Double { simd_dot(velocity, forward) }

    mutating func reset(at sample: TrackSample) {
        self = Vehicle()
        position = sample.point
        heading = atan2(sample.tangent.x, sample.tangent.y)
    }

    mutating func shift(_ direction: Int) {
        guard shiftCooldown <= 0 else { return }
        gear = clamp(gear + direction, 1, 6)
        shiftCooldown = 0.22
    }

    mutating func step(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                       roadDistance: Double, roadWidth: Double, roadLateral: Double? = nil, roadProgress: Double = 0, kerbsEnabled: Bool = true) {
        guard dt > 0 && dt <= 0.1 else { return }
        let steps = max(1, Int(ceil(dt * 720)))
        tcActive = false
        absActive = false
        for _ in 0..<steps {
            integrate(dt / Double(steps), input: input, assists: assists,
                      lateral: roadLateral ?? roadDistance, roadWidth: roadWidth, progress: roadProgress, kerbsEnabled: kerbsEnabled)
        }
    }

    private mutating func integrate(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                                    lateral: Double, roadWidth: Double, progress: Double, kerbsEnabled: Bool) {
        let throttle = clamp(input.throttle, 0, 1)
        let brake = clamp(input.brake, 0, 1)
        let vf = simd_dot(velocity, forward)
        let vl = simd_dot(velocity, modelX)
        let lf = 1.485
        let lr = wheelbase - lf
        let halfTrack = trackWidth / 2
        let xs = [-halfTrack, halfTrack, -halfTrack, halfTrack]
        let zs = [lf, lf, -lr, -lr]
        let weight = mass * 9.81
        let ratio = gearRatios[gear - 1] * 3.9
        let drivenOmega = (wheels[2].angularVelocity + wheels[3].angularVelocity) / 2
        let coupledRPM = abs(drivenOmega) * ratio * 60 / (2 * .pi)
        let targetRPM = clamp(coupledRPM, 950 + throttle * 450, 7400)
        rpm += (targetRPM - rpm) * (1 - exp(-dt * 20))
        shiftCooldown = max(0, shiftCooldown - dt)
        if assists.automatic && shiftCooldown <= 0 {
            if rpm > 6500 && gear < 6 { shift(1) }
            else if rpm < 2450 && gear > 1 { shift(-1) }
        }
        let engineTorque = (235 + 65 * sin(clamp((rpm - 1000) / 6500, 0, 1) * .pi)) * throttle
        let engineDrag = throttle < 0.05 && abs(vf) > 0.8 ? 26.0 : 0.0
        let axleTorque = (engineTorque * ignitionFraction - engineDrag) * gearRatios[gear - 1] * 3.9 * 0.91
        let diffTransfer = clamp((wheels[3].angularVelocity - wheels[2].angularVelocity) * 15, -350, 350)
        let driveTorques = [0, 0, axleTorque / 2 + diffTransfer, axleTorque / 2 - diffTransfer]
        var totalFx = 0.0
        var totalFy = 0.0
        var yawTorque = 0.0
        var verticalForce = 0.0
        var rollTorque = 0.0
        var pitchTorque = 0.0
        var maximumSlip = 0.0

        let raw = clamp(input.steering, -1, 1)
        let steeringLimit = 0.52 / (1 + abs(vf) / 20)
        // Both the pad and keyboard supply positive for driver-right. Convert
        // once to model yaw here, keeping wheel forces and animation in sync.
        let target = -raw * (0.45 + 0.55 * raw * raw) * steeringLimit
        let returning = abs(target) < abs(steeringAngle) || target * steeringAngle < 0
        let steeringRate = returning ? 2.8 : 1.9 / (1 + abs(vf) * 0.012)
        steeringAngle += clamp(target - steeringAngle, -steeringRate * dt, steeringRate * dt)

        for i in 0..<4 {
            var wheel = wheels[i]
            let x = xs[i]
            let z = zs[i]
            let onGrass = abs(lateral + x) > roadWidth / 2 + (kerbsEnabled ? 0.85 : 0.35)
            let onKerb = kerbsEnabled && abs(lateral + x) > roadWidth / 2 && !onGrass
            let surfaceHeight = onKerb ? 0.030 + 0.012 * sin((progress + z) * 7) : 0.0
            let roadVerticalSpeed = clamp((surfaceHeight - wheel.surfaceHeight) / dt, -0.7, 0.7)
            wheel.surfaceHeight = surfaceHeight
            let staticLoad = weight * (i < 2 ? lr : lf) / wheelbase / 2
            let springRate = i < 2 ? 46000.0 : 49000.0
            let damper = i < 2 ? 2900.0 : 3100.0
            let deflection = heave + pitch * z + roll * x - surfaceHeight
            let deflectionRate = heaveRate + pitchRate * z + rollRate * x - roadVerticalSpeed
            let load = clamp(staticLoad - springRate * deflection - damper * deflectionRate, 0, staticLoad * 4)
            wheel.normalLoad = load
            verticalForce += load
            rollTorque += x * load
            pitchTorque += z * load
            let steer = i < 2 ? steeringAngle : 0.0
            let c = cos(steer)
            let s = sin(steer)
            let cornerForward = vf - yawRate * x
            let cornerLateral = vl + yawRate * z
            let u = cornerForward * c + cornerLateral * s
            let v = cornerLateral * c - cornerForward * s
            let temperatureFactor = 1 - 0.13 * min(abs(wheel.temperature - 75) / 50, 1)
            let loadSensitivity = pow(3100 / max(load, 100), 0.09)
            let peakMu = (onGrass ? 0.48 : 1.24) * temperatureFactor * loadSensitivity
            let capacity = max(1, load * peakMu)
            let slipAngle = atan2(v, max(abs(u), 1.5))

            func forces(_ omega: Double) -> (fx: Double, fy: Double, ratio: Double) {
                let longitudinalSlip = omega * wheelRadius - u
                let slipRatio = longitudinalSlip / max(abs(u), 2)
                let stiffnessScale = pow(max(load, 1) / 3100, 0.82)
                let linearX = 65000 * stiffnessScale * slipRatio
                let linearY = -48000 * stiffnessScale * tan(clamp(slipAngle, -1.2, 1.2))
                let demand = hypot(linearX, linearY)
                let sliding = hypot(longitudinalSlip, v)
                let available = capacity * (0.82 + 0.18 * exp(-sliding / 5))
                let magnitude = available * (1 - exp(-demand / max(available, 1)))
                let scale = demand > 0.00001 ? magnitude / demand : 1
                return (linearX * scale, linearY * scale, slipRatio)
            }

            var driveTorque = driveTorques[i]
            if assists.tractionControl && driveTorque > 0 {
                let gripTorque = capacity * wheelRadius * 0.93
                let slipCut = clamp(1 - max(0, wheel.slipRatio - 0.08) * 4, 0.12, 1)
                let limited = min(driveTorque, gripTorque) * slipCut
                if limited < driveTorque * 0.98 { tcActive = true }
                driveTorque = limited
            }
            let locking = wheel.slipRatio < -0.13 && abs(u) > 3
            let pressureTarget = assists.abs && locking ? 0.18 : 1.0
            wheel.brakePressure += (pressureTarget - wheel.brakePressure) * min(1, dt * 55)
            if assists.abs && locking && brake > 0.1 { absActive = true }
            let brakeTorque = brake * (i < 2 ? 2500 : 1550) * (assists.abs ? wheel.brakePressure : 1)
            let inertia = 1.7
            let previousOmega = wheel.angularVelocity
            func balance(_ omega: Double) -> Double {
                inertia * (omega - previousOmega) / dt - driveTorque + forces(omega).fx * wheelRadius
            }
            let atRest = balance(0)
            let omega: Double
            if abs(atRest) <= brakeTorque {
                omega = 0
            } else {
                let sign = atRest < 0 ? 1.0 : -1.0
                let centre = previousOmega + driveTorque * dt / inertia
                let span = (capacity * wheelRadius + brakeTorque) * dt / inertia + 1
                var lo = centre - span
                var hi = centre + span
                // Implicit angular integration avoids low-speed numerical wheel chatter.
                for _ in 0..<17 {
                    let mid = (lo + hi) / 2
                    if balance(mid) + sign * brakeTorque > 0 { hi = mid } else { lo = mid }
                }
                omega = (lo + hi) / 2
            }
            let contact = forces(omega)
            wheel.angularVelocity = omega
            wheel.rotation += omega * dt
            wheel.slipRatio = contact.ratio
            wheel.slipAngle = slipAngle
            wheel.longitudinalForce = contact.fx
            wheel.lateralForce = contact.fy
            let heat = abs(contact.fx * (omega * wheelRadius - u)) + abs(contact.fy * v)
            wheel.temperature += (heat / 8500 - (wheel.temperature - 26) * (0.004 + abs(u) * 0.00025)) * dt
            wheel.temperature = clamp(wheel.temperature, 26, 180)
            let fx = contact.fx * c - contact.fy * s
            let fy = contact.fx * s + contact.fy * c
            totalFx += fx
            totalFy += fy
            yawTorque += z * fy - x * fx
            maximumSlip = max(maximumSlip, min(1, abs(contact.ratio) * 1.4 + abs(slipAngle) * 2))
            wheels[i] = wheel
        }

        let drag = 0.43 * vf * abs(vf)
        let offroadFraction = Double(wheels.enumerated().filter { abs(lateral + xs[$0.offset]) > roadWidth / 2 + 0.95 }.count) / 4
        let rollingDemand = weight * (0.013 + offroadFraction * 0.055)
        let rolling = (vf >= 0 ? 1.0 : -1.0) * min(rollingDemand, abs(vf) * mass / dt)
        totalFx -= drag + rolling
        let ax = totalFx / mass
        let ay = totalFy / mass
        let acceleration = forward * ax + modelX * ay
        velocity += acceleration * dt
        yawRate += yawTorque / 2150 * dt
        if speed < 0.08 && throttle < 0.01 {
            velocity *= exp(-12 * dt)
            yawRate *= exp(-12 * dt)
            if speed < 0.002 && brake > 0.1 { velocity = .zero }
        }
        heading += yawRate * dt
        heading = atan2(sin(heading), cos(heading))
        position += velocity * dt
        distanceTravelled += speed * dt
        lateralG += (ay / 9.81 - lateralG) * min(1, dt * 12)
        longitudinalG += (ax / 9.81 - longitudinalG) * min(1, dt * 12)
        tyreSlip = maximumSlip
        let downforce = speed * speed * 0.80
        heaveRate += ((verticalForce - weight - downforce) / mass) * dt
        rollRate += (rollTorque + mass * ay * 0.44) / 520 * dt
        pitchRate += (pitchTorque + mass * ax * 0.44) / 1900 * dt
        heave += heaveRate * dt
        roll += rollRate * dt
        pitch += pitchRate * dt
        if abs(heave) > 0.15 { heave = clamp(heave, -0.15, 0.15); heaveRate = 0 }
        if abs(roll) > 0.18 { roll = clamp(roll, -0.18, 0.18); rollRate = 0 }
        if abs(pitch) > 0.15 { pitch = clamp(pitch, -0.15, 0.15); pitchRate = 0 }
    }
}

func lapTime(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—:——.———" }
    let millis = Int(seconds * 1000)
    return String(format: "%d:%02d.%03d", millis / 60000, (millis / 1000) % 60, millis % 1000)
}

struct GhostFrame: Codable {
    let time: Double
    let x: Double
    let z: Double
    let heading: Double
}

struct RaceSession {
    var elapsed = 0.0
    var lap = 1
    var best: Double?
    var last: Double?
    var completedLaps = 0
    var checkpoint = 0
    var validLap = true
    var currentGhost: [GhostFrame] = []
    var bestGhost: [GhostFrame] = []
    var newBest = false
    private var previousProgress: Double?
    private var recordingClock = 0.0
    private var started = false
    private var waitingForStart = false

    var nextCheckpointFraction: Double { checkpoint < 3 ? Double(checkpoint + 1) / 4 : 1 }

    mutating func resetLap(at progress: Double) {
        elapsed = 0
        checkpoint = 0
        validLap = true
        previousProgress = progress
        currentGhost = []
        recordingClock = 0
        started = false
        // A recovery on the back half must return to the start before timing.
        waitingForStart = progress > 20
    }

    mutating func step(_ dt: Double, vehicle: Vehicle, location: TrackLocation, trackLength: Double, trackWidth: Double) -> Bool {
        newBest = false
        if !started && vehicle.speed > 0.8 && !waitingForStart { started = true }
        if started { elapsed += dt }
        if location.distance > trackWidth * 0.5 + 2.5 && started { validLap = false }
        if started {
            recordingClock += dt
            if recordingClock >= 0.05 {
                recordingClock = 0
                currentGhost.append(GhostFrame(time: elapsed, x: vehicle.position.x, z: vehicle.position.y, heading: vehicle.heading))
            }
        }
        let fraction = location.progress / trackLength
        let movingForward = simd_dot(vehicle.velocity, location.tangent) > 0.5
        if let previousProgress {
            let crossedFinish = previousProgress > trackLength * 0.90 && location.progress < trackLength * 0.10 && movingForward
            if waitingForStart && crossedFinish {
                waitingForStart = false
                started = true
                elapsed = 0
                checkpoint = 0
                validLap = true
                currentGhost = []
            } else if checkpoint == 3 && crossedFinish && elapsed > 15 {
                let finished = elapsed
                last = finished
                completedLaps += 1
                if validLap && (best == nil || finished < best!) {
                    best = finished
                    bestGhost = currentGhost
                    newBest = true
                }
                lap += 1
                elapsed = 0
                checkpoint = 0
                validLap = true
                currentGhost = []
                self.previousProgress = location.progress
                return true
            }
            let previousFraction = previousProgress / trackLength
            if checkpoint < 3 {
                let target = Double(checkpoint + 1) / 4
                if previousFraction < target && fraction >= target && fraction - previousFraction < 0.03 && movingForward {
                    checkpoint += 1
                }
            }
        }
        previousProgress = location.progress
        return false
    }

    func ghost(at time: Double) -> GhostFrame? {
        guard bestGhost.count > 1, time >= bestGhost[0].time, time <= bestGhost.last!.time else { return nil }
        var low = 0
        var high = bestGhost.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if bestGhost[mid].time <= time { low = mid } else { high = mid }
        }
        let a = bestGhost[low]
        let b = bestGhost[high]
        let t = (time - a.time) / max(b.time - a.time, 0.001)
        let angleDelta = atan2(sin(b.heading - a.heading), cos(b.heading - a.heading))
        return GhostFrame(time: time, x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t, heading: a.heading + angleDelta * t)
    }
}

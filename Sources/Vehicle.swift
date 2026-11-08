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

enum TyreCompound: Int, CaseIterable {
    case soft, medium, hard
    var label: String { ["软胎", "中性胎", "硬胎"][rawValue] }
    var grip: Double { [1.05, 1.0, 0.96][rawValue] }
    var wearRate: Double { [1.6, 1.0, 0.65][rawValue] }
    var optimum: Double { [75, 85, 95][rawValue] }
}

struct TyreSetup {
    var compound = TyreCompound.medium
    var coldPressure = 1.65 // gauge bar at 26 C, prototype dry tyre
}

struct VehicleDamage {
    var front = 0.0
    var rear = 0.0
    var engine = 0.0
    var suspension = [Double](repeating: 0, count: 4)
    var worst: Double { ([front, rear, engine] + suspension).max() ?? 0 }
}

enum WheelSurface { case asphalt, kerb, grass }

struct WheelRoadContact {
    var distance: Double
    var progress: Double
    var kerbsEnabled: Bool
}

struct WheelState {
    var angularVelocity = 0.0
    var rotation = 0.0
    var slipRatio = 0.0
    var slipAngle = 0.0
    var normalLoad = 0.0
    var longitudinalForce = 0.0
    var lateralForce = 0.0
    var temperature = 38.0 // tread surface C
    var coreTemperature = 38.0
    var wear = 0.0 // 0 new, 1 worn through
    var flatSpot = 0.0
    var punctured = false
    var airRetention = 1.0
    var setup = TyreSetup()
    var pressure: Double {
        max(0, ((setup.coldPressure + 1.013) * (coreTemperature + 273.15) / 299.15 - 1.013) * airRetention)
    }
    var gripFactor: Double {
        let thermal = clamp(1 - abs(temperature - setup.compound.optimum) * 0.003, 0.62, 1)
        let pressureLoss = min(0.30, abs(pressure - 2.05) * 0.22)
        return setup.compound.grip * thermal * (1 - pressureLoss) * (1 - 0.40 * wear * wear)
            * (1 - flatSpot * 0.12) * (punctured ? 0.28 : 1)
    }
    var radiusScale: Double { punctured ? 0.84 : 1 - flatSpot * 0.006 }

    mutating func evolve(_ dt: Double, slipPower: Double, speed: Double, load: Double, locked: Bool, grass: Bool) {
        let heat = min(max(slipPower, 0), 150000)
        let conduction = (temperature - coreTemperature) * 0.045
        temperature += (heat / 4800 + load * abs(speed) * 0.000006 - conduction
            - (temperature - 26) * (0.012 + abs(speed) * 0.0006)) * dt
        coreTemperature += (conduction * 0.28 - (coreTemperature - 26) * 0.002) * dt
        temperature = clamp(temperature, 26, 220)
        coreTemperature = clamp(coreTemperature, 26, 150)
        let abrasion = heat / 16000000 + abs(speed) / 3500000 * min(load / 3100, 2)
        wear = clamp(wear + abrasion * setup.compound.wearRate * (grass ? 1.3 : 1)
            * (temperature > 120 ? 1 + (temperature - 120) / 40 : 1) * dt, 0, 1)
        if locked && speed > 5 && load > 100 {
            flatSpot = min(1, flatSpot + heat / 1800000 * dt)
        }
        if wear >= 1 || flatSpot >= 1 { punctured = true }
        if punctured { airRetention = max(0, airRetention - dt * 0.6) }
    }
    var brakePressure = 1.0
    var surfaceHeight = 0.0
    var suspensionTravel = 0.0 // metres from static ride height; positive = compression
    var suspensionVelocity = 0.0 // m/s, positive = compressing
    var surface = WheelSurface.asphalt
    var kerbFeedback = 0.0 // bounded, smoothed road excitation, zero when parked

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
    var damage = VehicleDamage()
    var coolantTemperature = 85.0
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
    var driverG: SIMD2<Double> { SIMD2(-lateralG, longitudinalG) }
    var kerbFeedback: Double { wheels.map(\.kerbFeedback).max() ?? 0 }
    var contactPoints: [SIMD2<Double>] {
        let xs = [-trackWidth/2, trackWidth/2, -trackWidth/2, trackWidth/2]
        let zs = [1.485, 1.485, -(wheelbase-1.485), -(wheelbase-1.485)]
        return (0..<4).map { position + modelX * xs[$0] + forward * zs[$0] }
    }
    var forwardSpeed: Double { simd_dot(velocity, forward) }

    var powerFactor: Double { max(0.08, 1 - damage.engine * 0.85 - max(0, coolantTemperature - 115) * 0.012) }

    func wheelSteer(_ index: Int) -> Double {
        (index < 2 ? steeringAngle : 0) + damage.suspension[index] * (index % 2 == 0 ? -0.10 : 0.10)
    }

    mutating func impact(normalSpeed: Double, outwardNormal: SIMD2<Double>) {
        guard normalSpeed.isFinite, normalSpeed > 1.5 else { return }
        let severity = clamp(pow((normalSpeed - 1.5) / 18, 2), 0, 1)
        let nose = simd_dot(outwardNormal, forward)
        let side = simd_dot(outwardNormal, modelX)
        if nose >= 0 { damage.front = min(1, damage.front + severity * (0.35 + 0.65 * abs(nose))) }
        else { damage.rear = min(1, damage.rear + severity * (0.35 + 0.65 * abs(nose))) }
        damage.engine = min(1, damage.engine + severity * max(0, nose) * 0.50)
        let axle = nose >= 0 ? 0 : 2
        let sideIndex = side >= 0 ? 1 : 0
        for index in 0..<4 {
            let axleWeight = index / 2 == axle / 2 ? 1.0 : 0.2
            let sideWeight = abs(side) < 0.25 ? 0.65 : (index % 2 == sideIndex ? 1.0 : 0.10)
            let hit = severity * axleWeight * sideWeight
            damage.suspension[index] = min(1, damage.suspension[index] + hit)
            if hit > 0.48 { wheels[index].punctured = true }
        }
    }

    mutating func service(setup: TyreSetup) {
        damage = VehicleDamage()
        coolantTemperature = 85
        wheels = (0..<4).map { _ in var w = WheelState(); w.setup = setup; return w }
    }

    mutating func reset(at sample: TrackSample, preservingCondition: Bool = false) {
        let oldWheels = wheels, oldDamage = damage, oldCoolant = coolantTemperature
        self = Vehicle()
        if preservingCondition {
            damage = oldDamage; coolantTemperature = oldCoolant
            for i in 0..<4 {
                wheels[i].setup = oldWheels[i].setup
                wheels[i].temperature = oldWheels[i].temperature
                wheels[i].coreTemperature = oldWheels[i].coreTemperature
                wheels[i].wear = oldWheels[i].wear
                wheels[i].flatSpot = oldWheels[i].flatSpot
                wheels[i].punctured = oldWheels[i].punctured
                wheels[i].airRetention = oldWheels[i].airRetention
            }
        }
        position = sample.point
        heading = atan2(sample.tangent.x, sample.tangent.y)
    }

    mutating func shift(_ direction: Int) {
        guard shiftCooldown <= 0 else { return }
        gear = clamp(gear + direction, 1, 6)
        shiftCooldown = 0.22
    }

    mutating func step(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                       roadDistance: Double, roadWidth: Double, roadLateral: Double? = nil, roadProgress: Double = 0, kerbsEnabled: Bool = true, roadContacts: [WheelRoadContact]? = nil) {
        guard dt > 0 && dt <= 0.1 else { return }
        let steps = max(1, Int(ceil(dt * 720)))
        tcActive = false
        absActive = false
        for _ in 0..<steps {
            integrate(dt / Double(steps), input: input, assists: assists,
                      lateral: roadLateral ?? roadDistance, roadWidth: roadWidth, progress: roadProgress, kerbsEnabled: kerbsEnabled, roadContacts: roadContacts)
        }
    }

    private mutating func integrate(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                                    lateral: Double, roadWidth: Double, progress: Double, kerbsEnabled: Bool, roadContacts: [WheelRoadContact]?) {
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
        let engineTorque = powerFactor * (235 + 65 * sin(clamp((rpm - 1000) / 6500, 0, 1) * .pi)) * throttle
        // Thermostat restricts cooling below operating temperature; nose damage
        // reduces radiator capacity rather than cooling an idling engine to ambient.
        coolantTemperature += ((0.35 + throttle * 1.8 + damage.front * 0.6) -
            max(0, coolantTemperature - 80) * (0.085 + abs(vf) * 0.0025) * (1 - damage.front * 0.88)) * dt
        coolantTemperature = clamp(coolantTemperature, 26, 160)
        damage.engine = min(1, damage.engine + max(0, coolantTemperature - 125) * dt * 0.00015)
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
            let road = roadContacts?.count == 4 ? roadContacts![i] : WheelRoadContact(
                distance: abs(lateral + x), progress: progress + z, kerbsEnabled: kerbsEnabled)
            let onGrass = road.distance > roadWidth / 2 + (road.kerbsEnabled ? 0.85 : 0.35)
            let onKerb = road.kerbsEnabled && road.distance > roadWidth / 2 && !onGrass
            wheel.surface = onGrass ? .grass : (onKerb ? .kerb : .asphalt)
            let vibration = wheel.flatSpot * 0.003 * cos(wheel.rotation) * min(abs(vf) / 5, 1)
            let surfaceHeight = (onKerb ? 0.030 + 0.012 * sin(road.progress * 7) : 0.0)
                - wheelRadius * (1 - wheel.radiusScale) + vibration
            let roadVerticalSpeed = clamp((surfaceHeight - wheel.surfaceHeight) / dt, -0.7, 0.7)
            wheel.surfaceHeight = surfaceHeight
            let staticLoad = weight * (i < 2 ? lr : lf) / wheelbase / 2
            let springRate = (i < 2 ? 46000.0 : 49000.0) * (1 - damage.suspension[i] * 0.45)
            let damper = (i < 2 ? 2900.0 : 3100.0) * (1 - damage.suspension[i] * 0.60)
            let deflection = heave + pitch * z + roll * x - surfaceHeight
            let deflectionRate = heaveRate + pitchRate * z + rollRate * x - roadVerticalSpeed
            let load = clamp(staticLoad - springRate * deflection - damper * deflectionRate, 0, staticLoad * 4)
            wheel.normalLoad = load
            wheel.suspensionTravel = -deflection
            wheel.suspensionVelocity = -deflectionRate
            let excitation = onKerb && speed > 1 && load > 100
                ? clamp(abs(roadVerticalSpeed) / 0.7 * 0.7 + 0.3 * abs(sin(road.progress * 7)), 0, 1)
                    * min(speed / 8, 1) * min(load / staticLoad, 1.2) : 0
            wheel.kerbFeedback += (clamp(excitation, 0, 1) - wheel.kerbFeedback) * (1 - exp(-dt * 28))
            verticalForce += load
            rollTorque += x * load
            pitchTorque += z * load
            let steer = wheelSteer(i)
            let radius = wheelRadius * wheel.radiusScale
            let c = cos(steer)
            let s = sin(steer)
            let cornerForward = vf - yawRate * x
            let cornerLateral = vl + yawRate * z
            let u = cornerForward * c + cornerLateral * s
            let v = cornerLateral * c - cornerForward * s
            let loadSensitivity = pow(3100 / max(load, 100), 0.09)
            let peakMu = (onGrass ? 0.48 : 1.24) * wheel.gripFactor * loadSensitivity
            let capacity = max(1, load * peakMu)
            let slipAngle = atan2(v, max(abs(u), 1.5))

            func forces(_ omega: Double) -> (fx: Double, fy: Double, ratio: Double) {
                let longitudinalSlip = omega * radius - u
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
                let gripTorque = capacity * radius * 0.93
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
                inertia * (omega - previousOmega) / dt - driveTorque + forces(omega).fx * radius
            }
            let atRest = balance(0)
            let omega: Double
            if abs(atRest) <= brakeTorque {
                omega = 0
            } else {
                let sign = atRest < 0 ? 1.0 : -1.0
                let centre = previousOmega + driveTorque * dt / inertia
                let span = (capacity * radius + brakeTorque) * dt / inertia + 1
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
            let heat = abs(contact.fx * (omega * radius - u)) + abs(contact.fy * v)
            wheel.evolve(dt, slipPower: heat, speed: abs(u), load: load,
                         locked: contact.ratio < -0.8, grass: onGrass)
            let fx = contact.fx * c - contact.fy * s
            let fy = contact.fx * s + contact.fy * c
            totalFx += fx
            totalFy += fy
            yawTorque += z * fy - x * fx
            maximumSlip = max(maximumSlip, min(1, abs(contact.ratio) * 1.4 + abs(slipAngle) * 2))
            wheels[i] = wheel
        }

        let drag = (0.43 + damage.front * 0.22 + damage.rear * 0.13) * vf * abs(vf)
        let offroadFraction = Double(wheels.filter { $0.surface == .grass }.count) / 4
        let flatCount = Double(wheels.filter { $0.punctured }.count)
        let rollingDemand = weight * (0.013 + offroadFraction * 0.055 + flatCount * 0.018)
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
        let downforce = speed * speed * 0.80 * (1 - damage.rear * 0.65)
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

import Foundation
import simd

struct DrivingInput {
    var throttle = 0.0
    var brake = 0.0
    var steering = 0.0
}

struct DrivingAssists {
    var absLevel = 3
    var tcLevel = 3
    var abs: Bool { get { absLevel > 0 } set { absLevel = newValue ? max(1,absLevel) : 0 } }
    var tractionControl: Bool { get { tcLevel > 0 } set { tcLevel = newValue ? max(1,tcLevel) : 0 } }
    var automatic = true
    var steeringDeadzone = 0.08
    static let defaultBrakeBias = 2500.0 / 4050.0
    static let brakeBiasRange = 0.52...0.72
    var frontBrakeBias = Self.defaultBrakeBias

    static func validatedBrakeBias(_ value: Double) -> Double {
        value.isFinite ? clamp(value, brakeBiasRange.lowerBound, brakeBiasRange.upperBound) : defaultBrakeBias
    }
    init(abs: Bool = true, tractionControl: Bool = true, automatic: Bool = true,
         steeringDeadzone: Double = 0.08, absLevel: Int = 3, tcLevel: Int = 3) {
        self.absLevel = abs ? clamp(absLevel,0,5) : 0
        self.tcLevel = tractionControl ? clamp(tcLevel,0,5) : 0
        self.automatic = automatic; self.steeringDeadzone = steeringDeadzone
    }
    var absSlipThreshold: Double { 0.22 - Double(clamp(absLevel,1,5))*0.03 }
    var tcSlipThreshold: Double { 0.17 - Double(clamp(tcLevel,1,5))*0.03 }
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
    var relaxedSlipAngle = 0.0 // contact-patch lateral response, radians
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
    var brakeTemperature = 40.0
    var brakeFadeFactor: Double { clamp(1-max(0,brakeTemperature-650)/700,0.55,1) }
    var antiRollForce = 0.0
    var bumpStopForce = 0.0
    var brakePressure = 1.0
    var surfaceHeight = 0.0
    var suspensionTravel = 0.0 // metres from static ride height; positive = compression
    var suspensionVelocity = 0.0 // m/s, positive = compressing
    var surface = WheelSurface.asphalt
    var kerbFeedback = 0.0 // bounded, smoothed road excitation, zero when parked

}

/// Four contact patches, rotating wheels and sprung heave/roll/pitch states.
/// Brush-style combined-slip tyres use explicit prototype parameters, not iRacing data.
enum VehicleKind: Int, CaseIterable, Codable {
    case concept, ferrari, porsche, bmw, mazda
    var label: String { ["Concept GT", "Ferrari 458", "Porsche 911 4S", "BMW M3 E30", "Mazda MX-5"][rawValue] }
    var assetName: String { ["CarConcept", "Ferrari458", "Porsche911", "BMWM3E30", "MazdaMX5"][rawValue] }
    var hasSimpleCabin: Bool { self == .porsche || self == .bmw }
    // Experimental driving presets, not manufacturer-calibrated specifications.
    var mass: Double { [1260, 1485, 1420, 1210, 1025][rawValue] }
    var wheelbase: Double { [2.80, 2.65, 2.44, 2.5911, 2.2597][rawValue] }
    var frontAxle: Double { [1.485, 1.325, 1.22, 1.2956, 1.1299][rawValue] }
    var track: Double { [1.96, 1.66, 1.50, 1.4067, 1.4066][rawValue] }
    var radius: Double { [0.384, 0.359, 0.328, 0.3116, 0.3007][rawValue] }
    var torqueScale: Double { [1, 1.55, 1.28, 0.86, 0.64][rawValue] }
    var credit: String { ["Eric Chadwick / DGG · CC BY 4.0", "vicent091036 · CC BY 4.0", "Lionsharp Studios · CC BY-SA 4.0", "Martin Trafas · CC BY 4.0", "Black Snow · CC BY 4.0"][rawValue] }
}

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
    var tcReduction = 0.0
    var absRelease = 0.0
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

    var kind = VehicleKind.concept
    var mass: Double { kind.mass }
    var wheelbase: Double { kind.wheelbase }
    var wheelRadius: Double { kind.radius }
    var trackWidth: Double { kind.track }
    let gearRatios = [3.20, 2.10, 1.52, 1.18, 0.95, 0.79]
    var gearLabel: String { gear == -1 ? "R" : (gear == 0 ? "N" : String(gear)) }
    private var transmissionRatio: Double {
        if gear == -1 { return 2.80 }
        return (1...gearRatios.count).contains(gear) ? gearRatios[gear-1] : 0
    }
    enum ShiftResult { case shifted, busy, unavailable, stopAndBrake }
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
        let lf = kind.frontAxle
        let zs = [lf, lf, -(wheelbase-lf), -(wheelbase-lf)]
        return (0..<4).map { position + modelX * xs[$0] + forward * zs[$0] }
    }
    var forwardSpeed: Double { simd_dot(velocity, forward) }
    // Geometry-scaled prototype yaw inertia; not a manufacturer measurement.
    var yawInertia: Double { mass * (wheelbase * wheelbase + trackWidth * trackWidth) * 0.18 }

    var powerFactor: Double { max(0.08, 1 - damage.engine * 0.85 - max(0, coolantTemperature - 115) * 0.012) }

    func wheelSteer(_ index: Int) -> Double {
        let x = (index % 2 == 0 ? -1.0 : 1.0) * trackWidth / 2
        // +X is driver-left. Inner and outer wheels share a turn centre at the
        // rear axle, instead of being parallel and scrubbing at low speed.
        let tangent = tan(steeringAngle)
        let angle = index < 2 ? atan(wheelbase * tangent / (wheelbase - x * tangent)) : 0
        return angle + damage.suspension[index] * (index % 2 == 0 ? -0.10 : 0.10)
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
        let oldKind = kind
        self = Vehicle()
        kind = oldKind
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
                wheels[i].brakeTemperature = oldWheels[i].brakeTemperature
            }
        }
        position = sample.point
        heading = atan2(sample.tangent.x, sample.tangent.y)
    }

    private mutating func engageGear(_ next: Int) {
        gear = next
        shiftCooldown = next == 0 ? 0.12 : 0.22
    }

    mutating func requestShift(_ direction: Int, pedals: DrivingInput, automatic: Bool) -> ShiftResult {
        guard direction == -1 || direction == 1 else { return .unavailable }
        let next = gear + direction
        guard (-1...gearRatios.count).contains(next), !automatic || (gear <= 1 && next <= 1) else { return .unavailable }
        guard shiftCooldown <= 0 else { return .busy }
        let changesDirection = next == -1 || gear == -1 || (next == 1 && forwardSpeed < -0.75)
        if changesDirection || (automatic && next == 0) {
            guard speed < 0.75, pedals.brake >= 0.25, pedals.throttle < 0.08 else { return .stopAndBrake }
        }
        engageGear(next)
        return .shifted
    }

    mutating func step(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                       roadDistance: Double, roadWidth: Double, roadLateral: Double? = nil, roadProgress: Double = 0, kerbsEnabled: Bool = true, roadContacts: [WheelRoadContact]? = nil) {
        guard dt > 0 && dt <= 0.1 else { return }
        let steps = max(1, Int(ceil(dt * 720)))
        tcActive = false
        absActive = false
        tcReduction = 0; absRelease = 0
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
        let lf = kind.frontAxle
        let lr = wheelbase - lf
        let halfTrack = trackWidth / 2
        let xs = [-halfTrack, halfTrack, -halfTrack, halfTrack]
        let zs = [lf, lf, -lr, -lr]
        let weight = mass * 9.81
        let ratio = transmissionRatio * 3.9
        let drivenOmega = (wheels[2].angularVelocity + wheels[3].angularVelocity) / 2
        let coupledRPM = abs(drivenOmega) * ratio * 60 / (2 * .pi)
        let targetRPM = gear == 0 ? 950 + throttle * 6350 : clamp(coupledRPM, 950 + throttle * 450, 7400)
        rpm += (targetRPM - rpm) * (1 - exp(-dt * 20))
        shiftCooldown = max(0, shiftCooldown - dt)
        if assists.automatic && gear > 0 && shiftCooldown <= 0 {
            if rpm > 6500 && gear < gearRatios.count { engageGear(gear+1) }
            else if rpm < 2450 && gear > 1 { engageGear(gear-1) }
        }
        let engineTorque = kind.torqueScale * powerFactor * (235 + 65 * sin(clamp((rpm - 1000) / 6500, 0, 1) * .pi)) * throttle
        // Thermostat restricts cooling below operating temperature; nose damage
        // reduces radiator capacity rather than cooling an idling engine to ambient.
        coolantTemperature += ((0.35 + throttle * 1.8 + damage.front * 0.6) -
            max(0, coolantTemperature - 80) * (0.085 + abs(vf) * 0.0025) * (1 - damage.front * 0.88)) * dt
        coolantTemperature = clamp(coolantTemperature, 26, 160)
        damage.engine = min(1, damage.engine + max(0, coolantTemperature - 125) * dt * 0.00015)
        let engineDrag = throttle < 0.05 && abs(vf) > 0.8 ? 26.0 : 0.0
        let driveDirection = gear < 0 ? -1.0 : 1.0
        let reverseLimit = gear < 0 ? clamp((8 + vf)/2, 0, 1) : 1
        let axleTorque = (driveDirection * engineTorque * ignitionFraction * reverseLimit - copysign(engineDrag, vf))
            * transmissionRatio * 3.9 * 0.91
        let diffTransfer = gear == 0 ? 0 : clamp((wheels[3].angularVelocity - wheels[2].angularVelocity) * 15, -350, 350)
        let frontBrakeBias = DrivingAssists.validatedBrakeBias(assists.frontBrakeBias)
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

        // Sample all four heights before solving loads, so the anti-roll coupling
        // is symmetric and cannot depend on left/right iteration order.
        let contactRoads = (0..<4).map { i in
            roadContacts?.count == 4 ? roadContacts![i] : WheelRoadContact(distance:abs(lateral+xs[i]),progress:progress+zs[i],kerbsEnabled:kerbsEnabled)
        }
        let surfaceHeights = (0..<4).map { i -> Double in
            let road=contactRoads[i], wheel=wheels[i]
            let kerb = road.kerbsEnabled ? kerbElevation(progress:road.progress,distanceFromEdge:road.distance-roadWidth/2) : 0
            return kerb-wheelRadius*(1-wheel.radiusScale)+wheel.flatSpot*0.003*cos(wheel.rotation)*min(abs(vf)/5,1)
        }
        for i in 0..<4 {
            var wheel = wheels[i]
            let x = xs[i]
            let z = zs[i]
            let road = contactRoads[i]
            let onGrass = road.distance > roadWidth / 2 + (road.kerbsEnabled ? 0.85 : 0.35)
            let onKerb = road.kerbsEnabled && road.distance > roadWidth / 2 && !onGrass
            wheel.surface = onGrass ? .grass : (onKerb ? .kerb : .asphalt)
            let surfaceHeight = surfaceHeights[i]
            let roadVerticalSpeed = clamp((surfaceHeight - wheel.surfaceHeight) / dt, -0.7, 0.7)
            wheel.surfaceHeight = surfaceHeight
            let staticLoad = weight * (i < 2 ? lr : lf) / wheelbase / 2
            let springRate = (i < 2 ? 46000.0 : 49000.0) * (1 - damage.suspension[i] * 0.45)
            let damper = (i < 2 ? 2900.0 : 3100.0) * (1 - damage.suspension[i] * 0.60)
            let deflection = heave + pitch * z + roll * x - surfaceHeight
            let deflectionRate = heaveRate + pitchRate * z + rollRate * x - roadVerticalSpeed
            let other = i ^ 1
            let otherDeflection = heave+pitch*zs[other]+roll*xs[other]-surfaceHeights[other]
            wheel.antiRollForce = -(i < 2 ? 9000.0 : 6500.0)*(deflection-otherDeflection)
            let bump = max(0,-deflection-0.075)
            wheel.bumpStopForce = min(18000,180000*bump*bump/0.04)
            let droop = max(0,deflection-0.09)*90000
            let load = clamp(staticLoad-springRate*deflection-damper*deflectionRate+wheel.antiRollForce+wheel.bumpStopForce-droop,0,staticLoad*4)
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
            // Lateral relaxation length: tyre force builds over travelled
            // distance. Blend out the lag near rest to avoid parking chatter.
            let relaxationLength = 0.35
            wheel.relaxedSlipAngle += (slipAngle - wheel.relaxedSlipAngle)
                * (1 - exp(-dt * max(abs(u), 3) / relaxationLength))
            let transientBlend = clamp(abs(u) / 3, 0, 1)
            let forceSlipAngle = slipAngle * (1 - transientBlend) + wheel.relaxedSlipAngle * transientBlend

            func forces(_ omega: Double) -> (fx: Double, fy: Double, ratio: Double) {
                let longitudinalSlip = omega * radius - u
                let slipRatio = longitudinalSlip / max(abs(u), 2)
                let stiffnessScale = pow(max(load, 1) / 3100, 0.82)
                let linearX = 65000 * stiffnessScale * slipRatio
                let linearY = -48000 * stiffnessScale * tan(clamp(forceSlipAngle, -1.2, 1.2))
                let demand = hypot(linearX, linearY)
                let sliding = hypot(longitudinalSlip, v)
                let available = capacity * (0.82 + 0.18 * exp(-sliding / 5))
                let magnitude = available * (1 - exp(-demand / max(available, 1)))
                let scale = demand > 0.00001 ? magnitude / demand : 1
                return (linearX * scale, linearY * scale, slipRatio)
            }

            var driveTorque = driveTorques[i]
            // Do not treat tiny coasting differential torques as accelerator
            // intervention (or amplify them into a false percentage at rest).
            let requestedDrive = driveTorque * driveDirection
            if assists.tractionControl && throttle > 0.01 && requestedDrive > 1 {
                let level = Double(clamp(assists.tcLevel,1,5))
                let gripTorque = capacity * radius * (1.08-level*0.05)
                let slipCut = clamp(1 - max(0, wheel.slipRatio * driveDirection - assists.tcSlipThreshold) * (1 + level), 0.12, 1)
                let limited = min(requestedDrive, gripTorque) * slipCut
                if limited < requestedDrive * 0.98 { tcActive = true }
                tcReduction = max(tcReduction,1-limited/requestedDrive)
                driveTorque = limited * driveDirection
            }
            let rollingDirection = u < 0 ? -1.0 : 1.0
            let locking = wheel.slipRatio * rollingDirection < -assists.absSlipThreshold && abs(u) > 3
            let pressureTarget = assists.abs && locking ? (0.30-Double(clamp(assists.absLevel,1,5))*0.04) : 1.0
            wheel.brakePressure += (pressureTarget - wheel.brakePressure) * min(1, dt * 55)
            if assists.abs && brake > 0.1 {
                absRelease = max(absRelease,1-wheel.brakePressure)
                if locking { absActive = true }
            }
            let brakeTorque = brake * 4050 * (i < 2 ? frontBrakeBias : 1-frontBrakeBias) * wheel.brakeFadeFactor * (assists.abs ? wheel.brakePressure : 1)
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
            let brakeWork = brakeTorque * abs((previousOmega+omega)/2)
            wheel.brakeTemperature += (brakeWork/14500-(wheel.brakeTemperature-26)*(0.004+abs(u)*0.00025))*dt
            wheel.brakeTemperature = clamp(wheel.brakeTemperature,26,1100)
            wheel.angularVelocity = omega
            wheel.rotation = (wheel.rotation + omega * dt).truncatingRemainder(dividingBy: 2 * .pi)
            wheel.slipRatio = contact.ratio
            wheel.slipAngle = slipAngle
            wheel.longitudinalForce = contact.fx
            wheel.lateralForce = contact.fy
            let heat = abs(contact.fx * (omega * radius - u)) + abs(contact.fy * v)
            wheel.evolve(dt, slipPower: heat, speed: abs(u), load: load,
                         locked: contact.ratio * rollingDirection < -0.8, grass: onGrass)
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
        yawRate += yawTorque / yawInertia * dt
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

struct LapProgress: Codable {
    let fraction: Double
    let time: Double
}

struct LapRecord: Codable {
    let time: Double
    let sectors: [Double]
    let trace: [LapProgress]
    let ghost: [GhostFrame]

    static func key(vehicle: VehicleKind, circuit: CircuitKind) -> String { "timing9-\(vehicle.rawValue)-\(circuit.rawValue)" }
    var isValid: Bool {
        guard time.isFinite, time>15, time<=3600, sectors.count==3,
              sectors.allSatisfy({$0.isFinite && $0>0}), abs(sectors.reduce(0,+)-time)<0.02,
              trace.count>=2, trace.count<=20000, ghost.count>=2, ghost.count<=20000,
              trace.first?.time==0, (trace.first?.fraction ?? 1)<=0.02, ghost.first?.time==0,
              trace.last?.fraction==1, abs((trace.last?.time ?? 0)-time)<0.001 else {return false}
        for (i,s) in trace.enumerated() {
            guard s.fraction.isFinite, (0...1).contains(s.fraction), s.time.isFinite, (0...time).contains(s.time) else {return false}
            if i>0 && (s.fraction<=trace[i-1].fraction || s.time<=trace[i-1].time) {return false}
        }
        for (i,g) in ghost.enumerated() {
            guard g.time.isFinite, (0...time).contains(g.time), g.x.isFinite, g.z.isFinite, g.heading.isFinite,
                  abs(g.x)<100000, abs(g.z)<100000 else {return false}
            if i>0 && g.time<=ghost[i-1].time {return false}
        }
        return true
    }
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
    var bestTrace: [LapProgress] = []
    var bestSectors: [Double] = []
    private(set) var sectors: [Double] = []
    private(set) var lastSectors: [Double] = []
    private(set) var lastValid = false
    private(set) var invalidReason = ""
    private(set) var waitingForStart = false
    private(set) var delta: Double?
    private var currentTrace: [LapProgress] = []
    private var sectorSplits: [Double] = []
    private var previousProgress: Double?
    private var recordingClock = 0.0
    private var wrongWayTime = 0.0
    private var started = false

    var nextCheckpointFraction: Double { checkpoint < 3 ? Double(checkpoint + 1) / 4 : 1 }
    var status: String {
        waitingForStart ? "出场圈 · 通过起点后计时" : (!validLap ? "本圈无效 · "+invalidReason : (started ? "有效圈" : "准备起步"))
    }
    var record: LapRecord? {
        guard let best else {return nil}
        let result=LapRecord(time:best,sectors:bestSectors,trace:bestTrace,ghost:bestGhost)
        return result.isValid ? result : nil
    }
    mutating func restore(_ record: LapRecord?) {
        guard let record, record.isValid else {return}
        best=record.time;bestSectors=record.sectors;bestTrace=record.trace;bestGhost=record.ghost
    }
    mutating func invalidate(_ reason:String) {
        if validLap {invalidReason=reason};validLap=false;delta=nil
    }
    mutating func resetLap(at progress: Double) {
        elapsed=0;checkpoint=0;validLap=true;invalidReason="";delta=nil
        previousProgress=progress;currentGhost=[];currentTrace=[];sectors=[];sectorSplits=[]
        recordingClock=0;wrongWayTime=0;started=false;waitingForStart=progress>20
    }
    private mutating func beginFlyingLap(progress:Double,remainder:Double,vehicle:Vehicle) {
        resetLap(at:0);waitingForStart=false;started=true;elapsed=remainder;previousProgress=progress
        currentTrace=[LapProgress(fraction:0,time:0)]
        currentGhost=[GhostFrame(time:0,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading)]
    }
    func referenceTime(at fraction:Double) -> Double? {
        guard bestTrace.count>=2, fraction>=bestTrace[0].fraction, fraction<=1 else {return nil}
        var lo=0, hi=bestTrace.count-1
        while lo+1<hi {let mid=(lo+hi)/2;if bestTrace[mid].fraction<=fraction {lo=mid}else{hi=mid}}
        let a=bestTrace[lo],b=bestTrace[hi]
        return a.time+(b.time-a.time)*(fraction-a.fraction)/(b.fraction-a.fraction)
    }
    mutating func step(_ dt: Double, vehicle: Vehicle, location: TrackLocation, trackLength: Double, trackWidth: Double, assisted: Bool = false) -> Bool {
        newBest=false
        let fraction=clamp(location.progress/trackLength,0,1)
        let forwardSpeed=simd_dot(vehicle.velocity,location.tangent), movingForward=forwardSpeed>0.5
        if !started && vehicle.speed>0.8 && !waitingForStart {
            started=true
            currentTrace=[LapProgress(fraction:clamp((previousProgress ?? location.progress)/trackLength,0,1),time:0)]
            currentGhost=[GhostFrame(time:0,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading)]
        }
        let before=elapsed
        if started {
            elapsed += dt
            if assisted { invalidate("自动驾驶") }
            if location.distance>trackWidth*0.5+2.5 {invalidate("驶出赛道边界")}
            wrongWayTime=forwardSpeed < -1 ? wrongWayTime+dt : 0
            if wrongWayTime>0.6 {invalidate("逆向行驶")}
            if elapsed>3600 {invalidate("超过单圈记录时限")}
        }
        if let previous=previousProgress {
            let crossed=previous>trackLength*0.90 && location.progress<trackLength*0.10 && movingForward
            let distance=crossed ? trackLength-previous+location.progress : location.progress-previous
            if started && abs(distance)>trackLength*0.03 {invalidate("跳过赛道检查点")}
            if crossed && waitingForStart {
                let share=(trackLength-previous)/max(distance,0.001)
                beginFlyingLap(progress:location.progress,remainder:dt*(1-share),vehicle:vehicle)
                return false
            }
            if crossed && started {
                let share=clamp((trackLength-previous)/max(distance,0.001),0,1)
                let finished=before+dt*share
                if checkpoint != 3 {invalidate("缺少赛道检查点")}
                if sectorSplits.count != 2 {invalidate("缺少分段检查点")}
                let completeSectors=sectors+[max(0,finished-(sectorSplits.last ?? 0))]
                let finishedValid=validLap && finished>15
                if currentTrace.last!.fraction<1 && (currentTrace.last?.time ?? 0)<finished {currentTrace.append(LapProgress(fraction:1,time:finished))}
                if (currentGhost.last?.time ?? 0)<finished {currentGhost.append(GhostFrame(time:finished,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading))}
                let candidate=LapRecord(time:finished,sectors:completeSectors,trace:currentTrace,ghost:currentGhost)
                let recorded=finished>15
                if recorded {
                    last=finished;lastSectors=completeSectors.count==3 ? completeSectors : [];lastValid=finishedValid;completedLaps += 1;lap += 1
                    if finishedValid && candidate.isValid && (best == nil || finished<best!) {
                        best=finished;bestGhost=currentGhost;bestTrace=currentTrace;bestSectors=completeSectors;newBest=true
                    }
                }
                beginFlyingLap(progress:location.progress,remainder:dt*(1-share),vehicle:vehicle)
                return recorded
            }
            if started && movingForward && distance>0 && distance<trackLength*0.03 {
                if checkpoint<3 {
                    let target=Double(checkpoint+1)*trackLength/4
                    if previous<target && location.progress>=target {checkpoint += 1}
                }
                if sectorSplits.count<2 {
                    let target=Double(sectorSplits.count+1)*trackLength/3
                    if previous<target && location.progress>=target {
                        let split=before+dt*(target-previous)/distance
                        sectors.append(split-(sectorSplits.last ?? 0));sectorSplits.append(split)
                    }
                }
            }
        }
        if started {
            recordingClock += dt
            if recordingClock>=0.05 {
                recordingClock.formTruncatingRemainder(dividingBy:0.05)
                if currentGhost.count<19998 {
                    currentGhost.append(GhostFrame(time:elapsed,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading))
                    if fraction>(currentTrace.last?.fraction ?? -1) {currentTrace.append(LapProgress(fraction:fraction,time:elapsed))}
                } else {invalidate("超过单圈记录容量")}
            }
        }
        delta = started && validLap && movingForward ? referenceTime(at:fraction).map {elapsed-$0} : nil
        previousProgress=location.progress
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

import Foundation
import simd

struct DrivingInput {
    var throttle = 0.0
    var brake = 0.0
    var steering = 0.0
}

struct AirWake {
    var intensity = 0.0

    static func behind(_ car: Vehicle, leaders: [Vehicle]) -> AirWake {
        guard car.forwardSpeed > 12 else { return AirWake() }
        var strongest = 0.0
        for other in leaders where other.forwardSpeed > 12 {
            guard simd_dot(car.forward,other.forward) > 0.91 else { continue }
            let offset = other.position-car.position
            let gap = simd_dot(offset,other.forward)
            guard gap > 3, gap < 55 else { continue }
            let across = abs(simd_dot(offset,other.modelX))
            let width = 1.65+gap*0.033
            let side = clamp(1-across/width,0,1)
            let following = clamp((55-gap)/48,0,1) * clamp((gap-3)/3,0,1)
            let speed = clamp((other.forwardSpeed-12)/15,0,1)
            strongest = max(strongest,side*side*following*speed)
        }
        return AirWake(intensity:strongest)
    }
}

struct DrivingAssists {
    var absLevel = 3
    var tcLevel = 3
    var abs: Bool { get { absLevel > 0 } set { absLevel = newValue ? max(1,absLevel) : 0 } }
    var tractionControl: Bool { get { tcLevel > 0 } set { tcLevel = newValue ? max(1,tcLevel) : 0 } }
    var automatic = true
    var steeringDeadzone = 0.08
    var brakeCurve = BrakeCurve.progressive
    var steeringCurve = SteeringCurve.standard
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
    var absSlipThreshold: Double { 0.17 - Double(clamp(absLevel,1,5))*0.022 }
    var tcSlipThreshold: Double { 0.17 - Double(clamp(tcLevel,1,5))*0.03 }
}

enum BrakeCurve: Int, CaseIterable, Codable {
    case progressive, deep, direct

    var label: String {
        switch self {
        case .progressive: return "渐进"
        case .deep: return "长行程"
        case .direct: return "短行程"
        }
    }

    func pressure(for travel: Double) -> Double {
        let request = requestedPressure(for:travel)
        return request * Self.takeUpTarget(for:request)
    }

    fileprivate func requestedPressure(for travel: Double) -> Double {
        let p = clamp(travel,0,1)
        switch self {
        case .progressive: return p*(0.12+p*(0.42+0.46*p))
        case .deep: return p*(0.045+p*(0.260+0.695*p))
        case .direct: return p*(0.29+p*(0.40+0.31*p))
        }
    }

    fileprivate static func takeUpTarget(for requestedPressure: Double) -> Double {
        let ratio = clamp(requestedPressure / 0.024,0,1)
        // The take-up slope meets the main curve without a kink.
        return ratio + ratio*ratio*(1-ratio)
    }
}

enum SteeringCurve: Int, CaseIterable, Codable {
    case standard, precision, direct

    var label: String {
        switch self {
        case .standard: return "标准"
        case .precision: return "细腻"
        case .direct: return "灵敏"
        }
    }

    func response(_ input: Double) -> Double {
        let value = clamp(input,-1,1)
        let center: Double
        let exponent: Double
        switch self {
        case .standard: (center,exponent) = (0.255,1.32)
        case .precision: (center,exponent) = (0.13,1.40)
        case .direct: (center,exponent) = (0.43,1.25)
        }
        return value * (center + (1-center) * pow(abs(value),exponent))
    }
}

enum TyreCompound: Int, CaseIterable {
    case soft, medium, hard, wet
    var label: String { ["软胎", "中性胎", "硬胎", "雨胎"][rawValue] }
    var grip: Double { [1.05, 1.0, 0.96, 0.90][rawValue] }
    var wearRate: Double { [1.6, 1.0, 0.65, 1.35][rawValue] }
    var optimum: Double { [75, 85, 95, 57][rawValue] }

    func wetGrip(waterDepth: Double, speed: Double, pressure: Double = 1.80) -> Double {
        let coverage = clamp(waterDepth / 0.55, 0, 1)
        let speedFactor = clamp((speed - 13) / 32, 0, 1)
        let waterLoss = self == .wet ? 0.12 + 0.16 * speedFactor : 0.32 + 0.30 * speedFactor
        let standingWater = clamp((waterDepth-0.55)/0.75,0,1)
        let extraLoss = standingWater * speedFactor * (self == .wet ? 0.10 : 0.18)
        guard extraLoss > 0 else { return 1 - coverage * waterLoss }
        // Standing water supports a larger fraction of the footprint at
        // lower inflation. Bound the correction to partial contact loss.
        let pressureEffect = clamp(0.36*(1.80/max(pressure,0.85)-1),-0.08,0.08)
        return 1 - coverage * waterLoss - extraLoss*(1+pressureEffect)
    }
}

struct TyreSetup: Equatable {
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

enum PitServiceWork: String, CaseIterable {
    case tyres, repairs, both

    var changesTyres: Bool { self != .repairs }
    var repairsDamage: Bool { self != .tyres }
}

struct PitServicePlan {
    static let tyreDuration = 12.0
    static let repairLimit = 60.0

    let work: PitServiceWork
    let tyreSetup: TyreSetup?
    let tyreSeconds: Double
    let repairSeconds: Double

    /// Tyre fitting and mechanical work can run in parallel.
    var duration: Double { max(tyreSeconds,repairSeconds) }

    init(work: PitServiceWork, damage: VehicleDamage, tyreSetup: TyreSetup) {
        self.work = work
        self.tyreSetup = work.changesTyres ? tyreSetup : nil
        tyreSeconds = work.changesTyres ? Self.tyreDuration : 0
        repairSeconds = work.repairsDamage ? Self.estimateRepairSeconds(for:damage) : 0
    }

    static func estimateRepairSeconds(for damage: VehicleDamage) -> Double {
        func severity(_ value: Double) -> Double { value.isNaN ? 0 : clamp(value,0,1) }
        let bodywork = 18*(severity(damage.front)+severity(damage.rear))
        let suspension = 18*damage.suspension.prefix(4).reduce(0) { $0+severity($1) }
        let powertrain = 35*severity(damage.engine)
        let work = bodywork+suspension+powertrain
        // Original game durations. Four seconds of setup for any actual repair.
        return work > 0 ? min(repairLimit,ceil(4+work)) : 0
    }
}

enum WheelSurface { case asphalt, kerb, grass }

private struct BrakeThermalSpec {
    let frontCapacity: Double, rearCapacity: Double // J/K per disc
    let fadeStart: Double

    func capacity(front: Bool) -> Double { front ? frontCapacity : rearCapacity }
}

struct VehicleRenderSample {
    let kind: VehicleKind
    let position: SIMD2<Double>
    let velocity: SIMD2<Double>
    let heading: Double
    let attitude: SIMD3<Double>
    let steering: Double
    let rearSteering: Double
    let roadElevation: Double
    let wheelRotations: SIMD4<Double>
    let wheelHeights: SIMD4<Double>
}

struct WheelState {
    var angularVelocity = 0.0
    var rotation = 0.0
    fileprivate(set) var accumulatedRotation = 0.0
    var slipRatio = 0.0
    var slipAngle = 0.0
    var relaxedSlipAngle = 0.0 // contact-patch lateral response, radians
    var relaxedSlipRatio = 0.0 // longitudinal contact-patch response
    var normalLoad = 0.0
    var longitudinalForce = 0.0
    var lateralForce = 0.0
    var gripUsage = 0.0
    var slidingFraction = 0.0
    fileprivate(set) var slidingPower = 0.0 // friction work rate in the sliding portion of the footprint, W
    fileprivate(set) var contactSlipSpeed = 0.0 // resultant tread-to-ground velocity, m/s
    fileprivate(set) var rollingContactSpeed = 0.0 // longitudinal speed shared by road and tread, m/s
    fileprivate(set) var pavedContactFraction = 1.0
    var aligningMoment = 0.0 // Pneumatic contribution about the contact centre, N·m, positive toward model-local +X.
    fileprivate(set) var spray = 0.0
    fileprivate(set) var waterFilm = 0.0
    fileprivate(set) var surfaceContamination = 0.0
    private(set) var treadTemperatures = SIMD3<Double>(repeating:38) // inner, middle, outer
    var temperature: Double {
        get { (treadTemperatures.x+treadTemperatures.y+treadTemperatures.z)/3 }
        set { treadTemperatures = SIMD3(repeating:newValue) }
    }
    var coreTemperature = 38.0
    var wear = 0.0 // 0 new, 1 worn through
    var flatSpot = 0.0
    var punctured = false
    var airRetention = 1.0
    var setup = TyreSetup()
    var pressure: Double {
        max(0, ((setup.coldPressure + 1.013) * (coreTemperature + 273.15) / 299.15 - 1.013) * airRetention)
    }
    var carcassFlex: Double { clamp(1.76/max(pressure,0.8),0.74,1.7) }
    var gripFactor: Double {
        let optimum = setup.compound.optimum
        func thermalFactor(_ value: Double) -> Double { clamp(1 - abs(value-optimum)*0.003,0.62,1) }
        let thermal = (thermalFactor(treadTemperatures.x)+thermalFactor(treadTemperatures.y)+thermalFactor(treadTemperatures.z))/3
        let pressureLoss = min(0.30, abs(pressure - 2.05) * 0.22)
        return setup.compound.grip * thermal * (1 - pressureLoss) * (1 - 0.40 * wear * wear)
            * (1 - 0.20 * surfaceContamination)
            * (1 - flatSpot * 0.12) * (punctured ? 0.28 : 1)
    }
    var radiusScale: Double { punctured ? 0.84 : 1 - flatSpot * 0.006 }

    mutating func evolve(_ dt: Double, slipPower: Double, speed: Double, load: Double, locked: Bool, grass: Bool,
                         surfaceTemperature: Double = 26, grassCoverage: Double? = nil,
                         lateralWork: Double = 0, waterDepth: Double = 0) {
        let contact = grassCoverage ?? (grass ? 1 : 0)
        let rate = (contact / 7 + (1 - contact) / 42) * abs(speed) * clamp(load / 1200, 0, 1)
        surfaceContamination += (contact - surfaceContamination) * (1 - exp(-rate * dt))
        let heat = min(max(slipPower, 0), 150000)
        let mean = temperature
        let conduction = (mean - coreTemperature) * 0.045
        let shoulderWork = clamp(lateralWork,-1,1)*0.54
        let crownWork = clamp((pressure-2.05)*0.52,-0.34,0.27)
        let work = SIMD3(1-shoulderWork-crownWork,1+2*crownWork,1+shoulderWork-crownWork)
        let temperatures = treadTemperatures
        let ambientCooling = 0.012 + abs(speed) * 0.0006
        let roadCoupling = clamp(load/3100,0,2) * (0.009 + clamp(waterDepth,0,1.3)*0.027)
        let flexHeat = load*abs(speed)*0.000006*carcassFlex
        for section in 0..<3 {
            let local = temperatures[section]
            let equalizing = (mean-local)*0.09
            treadTemperatures[section] = clamp(local + (heat/4800*work[section] + flexHeat
                - (local-coreTemperature)*0.045 - (local-26)*ambientCooling
                + (surfaceTemperature-local)*roadCoupling + equalizing)*dt,26,220)
        }
        coreTemperature += (conduction * 0.28 - (coreTemperature - 26) * 0.002) * dt
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

    mutating func preserveTread(from previous: WheelState) { treadTemperatures = previous.treadTemperatures }
    var brakeTemperature = 40.0
    fileprivate(set) var brakeSurfaceTemperature = 40.0

    fileprivate func brakeFade(at threshold: Double) -> Double {
        let interface = max(brakeTemperature,0.76*brakeSurfaceTemperature+0.24*brakeTemperature)
        let excess = clamp((interface-threshold)/435,0,1)
        return 1-0.45*excess*(2-excess)
    }

    fileprivate mutating func heatBrake(_ dt: Double, workRate: Double, capacity: Double,
                                        speed: Double, waterDepth: Double) {
        // Friction first heats the swept face, which conducts into the rotor.
        let conduction = (brakeSurfaceTemperature-brakeTemperature)*capacity*0.039
        let convection = capacity*(0.0026+0.00027*speed)*(1+0.18*clamp(waterDepth,0,1))
        let surfaceLoss = (brakeSurfaceTemperature-26)*convection*0.36
        let bulkLoss = (brakeTemperature-26)*convection*0.64
        brakeSurfaceTemperature = clamp(brakeSurfaceTemperature +
            (0.90*workRate-conduction-surfaceLoss)*dt/(capacity*0.22),26,1250)
        brakeTemperature = clamp(brakeTemperature + (conduction-bulkLoss)*dt/(capacity*0.78),26,1100)
    }
    var antiRollForce = 0.0
    var bumpStopForce = 0.0
    var brakePressure = 1.0
    fileprivate var absPressureTarget = 1.0
    fileprivate var tractionTorqueScale = 1.0
    var surfaceHeight = 0.0
    fileprivate var localSurfaceHeight = 0.0 // kerb and tyre only
    var suspensionTravel = 0.0 // metres from static ride height; positive = compression
    var suspensionVelocity = 0.0 // m/s, positive = compressing
    var surface = WheelSurface.asphalt
    var kerbFeedback = 0.0 // bounded, smoothed road excitation, zero when parked

}

/// Four contact patches, rotating wheels and sprung heave/roll/pitch states.
/// Brush-style combined-slip tyres use explicit prototype parameters, not iRacing data.
enum VehicleKind: Int, CaseIterable, Codable {
    // Persisted IDs are shared with earlier saves and telemetry.
    case porsche = 2, centenario = 5

    var alternate: Self { self == .porsche ? .centenario : .porsche }
    var label: String { self == .porsche ? "Porsche 911 Carrera 4S" : "Lamborghini Centenario" }
    var assetName: String { self == .porsche ? "Porsche911" : "Centenario" }
    // The US 2020 Carrera 4S PDK specifies a 3,487-lb curb weight.
    var mass: Double { self == .porsche ? 3_487 * 0.45359237 : 1520 }
    // Experimental geometry and chassis parameters in SI units.
    var wheelbase: Double { self == .porsche ? 2.44 : 2.69175 }
    var frontAxle: Double { wheelbase / 2 }
    var distanceFromCGToFrontAxle: Double { self == .porsche ? wheelbase * 0.62 : frontAxle }
    var centreOfGravityOffset: Double { frontAxle - distanceFromCGToFrontAxle }
    var track: Double { self == .porsche ? 1.50 : 1.697 }
    var radius: Double { self == .porsche ? 0.328 : 0.37 }
    var treadWidth: SIMD2<Double> { (self == .porsche ? SIMD2(0.245,0.305) : SIMD2(0.255,0.355)) * 0.88 }
    var bodyEnvelope: SIMD3<Double> { self == .porsche ? SIMD3(0.93,2.20,2.08) : SIMD3(1.03,2.60,2.37) }
    fileprivate var wheelInertias: SIMD2<Double> { self == .porsche ? SIMD2(1.42,1.83) : SIMD2(1.64,2.17) }
    var steeringRatio: Double { self == .porsche ? 15 : 13.6 }
    var centreOfGravityHeight: Double { self == .porsche ? 0.48 : 0.42 }
    fileprivate typealias BodyInertia = (roll: Double, pitch: Double, yaw: Double)
    private static func inertia(for kind: Self) -> BodyInertia {
        let lateralSpread = 0.30 * kind.track
        let verticalSpread = 0.58 * kind.centreOfGravityHeight
        let longitudinalSpread = 0.46 * kind.wheelbase
        let lateral = kind.mass * lateralSpread * lateralSpread
        let vertical = kind.mass * verticalSpread * verticalSpread
        let longitudinal = kind.mass * longitudinalSpread * longitudinalSpread
        return (lateral + vertical, longitudinal + vertical, longitudinal + lateral)
    }
    private static let porscheInertia = inertia(for:.porsche)
    private static let centenarioInertia = inertia(for:.centenario)
    fileprivate var bodyInertia: BodyInertia { self == .porsche ? Self.porscheInertia : Self.centenarioInertia }
    private var torqueScale: Double { self == .porsche ? 1.28 : 1.82 }
    // Prototype effective crank and flywheel inertia (kg·m²) for unloaded ICE operation.
    var freeCrankInertia: Double { 0.06 + 0.12 * torqueScale }
    var frontDriveShare: Double { self == .porsche ? 0.30 : 0.35 }
    private struct Gearbox {
        var ratios: [Double]
        var reverse: Double
        var finalDrive: Double
        var redline: Double
        var upshift: Double
        var shiftDuration = 0.22
        var shiftTorqueFloor = 0.35
    }
    // Factory ratios and speed limits are cited in Preview 28's validation notes.
    // Shift durations and torque overlap are simulation parameters.
    private static let porscheGearbox = Gearbox(ratios:[4.89,3.17,2.15,1.56,1.18,0.94,0.76,0.61],
        reverse:3.96, finalDrive:3.39*0.92, redline:7500, upshift:7275, shiftDuration:0.13, shiftTorqueFloor:0.64)
    private static let centenarioGearbox = Gearbox(ratios:[3.909,2.438,1.810,1.458,1.185,0.967,0.844],
        reverse:2.929, finalDrive:2.867, redline:8600, upshift:8425, shiftDuration:0.17, shiftTorqueFloor:0.30)
    private var gearbox: Gearbox { self == .porsche ? Self.porscheGearbox : Self.centenarioGearbox }
    var gearRatios: [Double] { gearbox.ratios }
    var reverseRatio: Double { gearbox.reverse }
    var finalDrive: Double { gearbox.finalDrive }
    var redline: Double { gearbox.redline }
    var upshiftRPM: Double { gearbox.upshift }
    var shiftDuration: Double { gearbox.shiftDuration }
    var shiftTorqueFloor: Double { gearbox.shiftTorqueFloor }
    // Effective rotor masses and pad temperature limits are simulation estimates.
    private static let porscheBrakes = BrakeThermalSpec(frontCapacity:5500,rearCapacity:4550,fadeStart:550)
    private static let centenarioBrakes = BrakeThermalSpec(frontCapacity:6200,rearCapacity:5100,fadeStart:710)
    fileprivate var braking: BrakeThermalSpec { self == .porsche ? Self.porscheBrakes : Self.centenarioBrakes }
    fileprivate var launchRPM: Double { self == .porsche ? 2450 : 3200 }
    fileprivate var maximumEngineBrake: Double { self == .porsche ? 43 : 72 }
    fileprivate func coastTorque(at rpm: Double) -> Double {
        return maximumEngineBrake * (0.42 + 0.58 * clamp(rpm/redline,0,1))
    }

    private struct TorqueCurve {
        var peakWatts: Double
        var points: [(rpm: Double, nm: Double)]
    }
    private static func torque(watts: Double, at rpm: Double) -> Double { watts * 60/(rpm * 2 * .pi) }
    // The published peak power and torque constrain the curve. The samples in between are estimates.
    private static let porscheTorque = TorqueCurve(peakWatts:331_000, points:[(950,182),(1500,320),(2000,470),
        (2300,530),(5000,530),(5800,515),(6500,torque(watts:331_000,at:6500)),(7500,400)])
    private static let centenarioTorque = TorqueCurve(peakWatts:566_000, points:[(950,310),(2000,460),
        (3500,582),(4800,664),(5500,690),(6500,680),(7400,666),(8500,torque(watts:566_000,at:8500)),(8600,622)])
    func fullThrottleTorque(at rpm: Double) -> Double {
        let curve = self == .porsche ? Self.porscheTorque : Self.centenarioTorque
        let points = curve.points
        if rpm <= points[0].rpm { return points[0].nm }
        let powerLimit = Self.torque(watts:curve.peakWatts,at:rpm)
        for i in 1..<points.count where rpm <= points[i].rpm {
            let low = points[i-1], high = points[i]
            let fraction = (rpm - low.rpm) / (high.rpm - low.rpm)
            return min(powerLimit, low.nm + (high.nm - low.nm) * fraction)
        }
        return min(powerLimit, points[points.count-1].nm)
    }
    var springScale: Double { self == .porsche ? 1.02 : 1.24 }
    var antiRollScale: Double { self == .porsche ? 1.05 : 1.25 }
    // Effective force coefficients in N/(m/s)², including air density.
    var dragCoefficient: Double { self == .porsche ? 0.41 : 0.52 }
    var downforceCoefficient: Double { self == .porsche ? 0.18 : 0.88 }
    var frontAeroBalance: Double { self == .porsche ? 0.39 : 0.42 }
    var credit: String { self == .porsche ? "JK3Dstudios · CC BY 4.0" : "SDC PERFORMANCE · CC BY 4.0" }
}

/// Source measurements from the drivetrain's last completed physics substep.
struct PowertrainSound {
    var driveLoad = 0.0 // Delivered driving torque / full-throttle torque at this RPM.
    var overrun = 0.0 // Power driving the closed-throttle engine / its drag power at redline.
    var shaftRPM = 0.0 // Absolute crankshaft or traction motor speed, rev/min.
    var inGear = false
    var shiftEngagement = 1.0 // Existing combustion gearbox torque recovery ramp.
    var regeneration = 0.0 // Recovered motor shaft power / simulated regeneration limit.
}

struct Vehicle {
    var position = SIMD2<Double>.zero
    var velocity = SIMD2<Double>.zero
    var heading = 0.0
    var yawRate = 0.0
    var steeringAngle = 0.0
    private(set) var rearSteeringAngle = 0.0
    var rpm = 950.0
    var gear = 1
    var lateralG = 0.0
    var longitudinalG = 0.0
    var tyreSlip = 0.0
    private(set) var aeroLoad = SIMD2<Double>.zero // front, rear, N
    private(set) var wakeStrength = 0.0
    var tcActive = false
    var absActive = false
    var tcReduction = 0.0
    var absRelease = 0.0
    private var absSampleClock = 0.0
    private(set) var absValveActivity = 0.0
    var distanceTravelled = 0.0
    var damage = VehicleDamage()
    var coolantTemperature = 85.0
    var wheels = [WheelState](repeating: WheelState(), count: 4)
    var heave = 0.0
    private(set) var roadElevation = 0.0
    private var roadElevationReady = false
    var hasRoadElevationSample: Bool { roadElevationReady }
    var roll = 0.0
    var pitch = 0.0
    private var heaveRate = 0.0
    private var rollRate = 0.0
    private var pitchRate = 0.0
    private var shiftCooldown = 0.0
    private var queuedForwardShift: (direction: Int, remaining: Double)?
    private var shiftingDown = false
    private var freeRevCut = false
    private(set) var engineThrottle = 0.0
    private var shaftLoad = (drive: 0.0, overrun: 0.0)
    private var brakeTakeUp = 0.0
    private(set) var brakeLinePressure = 0.0
    private(set) var brakePedalTravel = 0.0

    var kind = VehicleKind.porsche {
        didSet {
            if kind != oldValue {
                shaftLoad = (0, 0)
                rearSteeringAngle = 0
                cancelQueuedShift()
            }
        }
    }
    var mass: Double { kind.mass }
    var wheelbase: Double { kind.wheelbase }
    var wheelRadius: Double { kind.radius }
    var trackWidth: Double { kind.track }
    var gearRatios: [Double] { kind.gearRatios }
    var gearLabel: String { gear == -1 ? "R" : (gear == 0 ? "N" : String(gear)) }
    private var transmissionRatio: Double {
        if gear == -1 { return kind.reverseRatio }
        return (1...gearRatios.count).contains(gear) ? gearRatios[gear-1] : 0
    }
    private var drivenWheelOmega: Double {
        let front = wheels[0].angularVelocity + wheels[1].angularVelocity
        let rear = wheels[2].angularVelocity + wheels[3].angularVelocity
        return (front * kind.frontDriveShare + rear * (1 - kind.frontDriveShare)) / 2
    }
    var powertrainSound: PowertrainSound {
        return PowertrainSound(driveLoad:shaftLoad.drive, overrun:shaftLoad.overrun, shaftRPM:rpm,
                               inGear:gear != 0, shiftEngagement:gear == 0 ? 1 : shiftEngagement)
    }
    enum ShiftResult { case shifted, busy, unavailable, stopAndBrake, overRev }
    var forward: SIMD2<Double> { SIMD2(sin(heading), cos(heading)) }
    var modelX: SIMD2<Double> { SIMD2(cos(heading), -sin(heading)) }
    var centreOfGravityPosition: SIMD2<Double> { position + forward * kind.centreOfGravityOffset }
    var modelHeave: Double { heave - pitch * kind.centreOfGravityOffset }
    var speed: Double { simd_length(velocity) }
    var speedKPH: Double { speed * 3.6 }
    // Angular coordinates are positive about +Y (toward model-local +X).
    // With a +Z-facing car, that is left from the driver's seat.
    private var shiftEngagement: Double {
        let equivalentCooldown = shiftCooldown * (0.22/kind.shiftDuration)
        let release = clamp((0.155-equivalentCooldown)/0.070,0,1)
        return release*release*(3-2*release)
    }
    var ignitionFraction: Double {
        if gear == 0 && freeRevCut { return 0 }
        let shiftCut = kind.shiftTorqueFloor+(1-kind.shiftTorqueFloor)*shiftEngagement
        return rpm > kind.redline ? shiftCut * 0.10 : shiftCut
    }
    var driverG: SIMD2<Double> { SIMD2(-lateralG, longitudinalG) }
    var brakeLightsActive: Bool { brakePedalTravel > 0.075 || brakeLinePressure > 0.018 }
    var brakeCapacityShare: Double { wheels.map { $0.brakeFade(at:kind.braking.fadeStart) }.min() ?? 1 }
    var kerbFeedback: Double { wheels.map(\.kerbFeedback).max() ?? 0 }
    var allWheelsOutside: Bool { wheels.allSatisfy { $0.surface == .grass } }
    var contactPoints: [SIMD2<Double>] {
        let xs = [-trackWidth/2, trackWidth/2, -trackWidth/2, trackWidth/2]
        let lf = kind.frontAxle
        let zs = [lf, lf, -(wheelbase-lf), -(wheelbase-lf)]
        return (0..<4).map { position + modelX * xs[$0] + forward * zs[$0] }
    }
    var forwardSpeed: Double { simd_dot(velocity, forward) }
    /// Interpolate display coordinates only. Input, telemetry, collisions and
    /// lap timing always read the latest completed fixed step.
    var renderSample: VehicleRenderSample {
        VehicleRenderSample(kind:kind,position:position,velocity:velocity,heading:heading,
                            attitude:SIMD3(heave,roll,pitch),steering:steeringAngle,rearSteering:rearSteeringAngle,
                            roadElevation:roadElevation,
                            wheelRotations:SIMD4(wheels[0].rotation,wheels[1].rotation,wheels[2].rotation,wheels[3].rotation),
                            wheelHeights:SIMD4(wheels[0].surfaceHeight,wheels[1].surfaceHeight,wheels[2].surfaceHeight,wheels[3].surfaceHeight))
    }

    func displayPose(previous: VehicleRenderSample, fraction: Double) -> Vehicle {
        let t = clamp(fraction,0,1)
        guard kind == previous.kind else { return self }
        var result = self
        func blend(_ a: Double, _ b: Double) -> Double { a+(b-a)*t }
        func angle(_ a: Double, _ b: Double) -> Double {
            let difference = b-a
            return a+atan2(sin(difference),cos(difference))*t
        }
        result.position = previous.position + (position-previous.position)*t
        result.heading = angle(previous.heading,heading)
        result.velocity = previous.velocity + (velocity-previous.velocity)*t
        result.heave = blend(previous.attitude.x,heave)
        result.roll = blend(previous.attitude.y,roll)
        result.pitch = blend(previous.attitude.z,pitch)
        result.steeringAngle = blend(previous.steering,steeringAngle)
        result.rearSteeringAngle = blend(previous.rearSteering,rearSteeringAngle)
        result.roadElevation = blend(previous.roadElevation,roadElevation)
        for i in wheels.indices {
            result.wheels[i].rotation = angle(previous.wheelRotations[i],wheels[i].rotation)
            result.wheels[i].surfaceHeight = blend(previous.wheelHeights[i],wheels[i].surfaceHeight)
        }
        return result
    }

    /// Apply a recorded pose to a display-only vehicle.
    mutating func applyReplayPose(_ sample: VehicleRenderSample, hasElevation: Bool, braking: Bool,
                                  spray: SIMD4<Double>) {
        kind = sample.kind
        position = sample.position
        velocity = sample.velocity
        heading = sample.heading
        heave = sample.attitude.x
        roll = sample.attitude.y
        pitch = sample.attitude.z
        steeringAngle = sample.steering
        rearSteeringAngle = sample.rearSteering
        roadElevation = sample.roadElevation
        roadElevationReady = hasElevation
        brakePedalTravel = braking ? 1 : 0
        brakeLinePressure = 0
        for index in wheels.indices {
            wheels[index].rotation = sample.wheelRotations[index]
            wheels[index].surfaceHeight = sample.wheelHeights[index]
            wheels[index].spray = spray[index]
        }
    }

    var steeringLimit: Double {
        let speed = abs(forwardSpeed) / 16.5
        return 0.52 / sqrt(1 + speed * speed * speed)
    }

    var handwheelAngle: Double {
        let lockFraction = clamp(abs(steeringAngle)/0.52,0,1)
        let ratio = kind == .porsche ? kind.steeringRatio-1.7*lockFraction*lockFraction : kind.steeringRatio
        return steeringAngle*ratio
    }

    static func steeringResponse(_ input: Double, curve: SteeringCurve = .standard) -> Double {
        curve.response(input)
    }

    static func brakeDemand(_ travel: Double, curve: BrakeCurve = .progressive) -> Double {
        curve.pressure(for:travel)
    }

    static func brakeTravel(for demand: Double, curve: BrakeCurve = .progressive) -> Double {
        if demand <= 0 { return 0 }
        if demand >= 1 { return 1 }
        var lower = 0.0, upper = 1.0
        for _ in 0..<12 {
            let middle = (lower + upper) / 2
            if brakeDemand(middle,curve:curve) < demand { lower = middle } else { upper = middle }
        }
        return (lower + upper) / 2
    }
    var yawInertia: Double { kind.bodyInertia.yaw }

    var powerFactor: Double { max(0.08, 1 - damage.engine * 0.85 - max(0, coolantTemperature - 115) * 0.012) }

    func wheelSteer(_ index: Int) -> Double {
        let x = (index % 2 == 0 ? -1.0 : 1.0) * trackWidth / 2
        let front = tan(steeringAngle)
        let rear = tan(rearSteeringAngle)
        // +X is driver-left. When both axles steer, their common centre of
        // rotation follows the difference of the two axle directions.
        let tangent = index < 2 ? front : rear
        let angle = atan(wheelbase*tangent/(wheelbase-x*(front-rear)))
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

    private func barrierPoint(outward normal: SIMD2<Double>) -> SIMD2<Double> {
        let forwardDot = simd_dot(forward,normal)
        let sideDot = simd_dot(modelX,normal)
        let envelope = kind.bodyEnvelope
        let corner = 0.20
        let axleReach = (forwardDot < 0 ? envelope.z : envelope.y) - corner
        let longitudinal = axleReach*clamp(forwardDot*6,-1,1)
        let lateral = (envelope.x-corner)*clamp(sideDot*6,-1,1)
        return forward*longitudinal+modelX*lateral+normal*corner
    }

    func projectedBodyReach(toward direction: SIMD2<Double>) -> Double {
        simd_dot(barrierPoint(outward:direction),direction)
    }

    mutating func constrainToGuardRail(at location: TrackLocation) -> (normal: SIMD2<Double>, closingSpeed: Double, point: SIMD2<Double>)? {
        guard location.distance > Circuit.guardRailInnerEdge-3 else { return nil }
        let normal = (position-location.point)/location.distance
        let point = barrierPoint(outward:normal)
        let depth = location.distance + simd_dot(point,normal) - Circuit.guardRailInnerEdge
        guard depth > 0 else { return nil }
        position -= normal*(depth+0.001)
        return (normal,hitBarrier(outward:normal,point:point),position+point)
    }

    /// Resolve the velocity at the striking part of the vehicle envelope.
    mutating func hitBarrier(outward normal: SIMD2<Double>) -> Double {
        hitBarrier(outward:normal,point:barrierPoint(outward:normal))
    }

    private mutating func hitBarrier(outward normal: SIMD2<Double>, point: SIMD2<Double>) -> Double {
        let arm = point-forward*kind.centreOfGravityOffset
        let lever = arm.y*normal.x-arm.x*normal.y
        let closing = simd_dot(velocity,normal)+yawRate*lever
        guard closing > 0 else { return 0 }
        let invMass = 1/mass + lever*lever/yawInertia
        let normalImpulse = 1.15*closing/invMass
        velocity -= normal*(normalImpulse/mass)
        yawRate -= normalImpulse*lever/yawInertia
        let tangent = SIMD2(-normal.y,normal.x)
        let tangentLever = arm.y*tangent.x-arm.x*tangent.y
        let slide = simd_dot(velocity,tangent)+yawRate*tangentLever
        let frictionImpulse = min(abs(slide)/(1/mass+tangentLever*tangentLever/yawInertia),normalImpulse*0.28)
        velocity -= tangent*(copysign(frictionImpulse,slide)/mass)
        yawRate -= copysign(frictionImpulse,slide)*tangentLever/yawInertia
        return closing
    }

    mutating func service(setup: TyreSetup,preservingBrakeHeat: Bool = false) {
        cancelQueuedShift()
        damage = VehicleDamage()
        coolantTemperature = 85
        fitTyres(setup,preservingBrakeHeat:preservingBrakeHeat)
        resetABSModulation()
    }

    /// Apply the selected work at the end of a stopped pit service.
    mutating func completePitService(_ plan: PitServicePlan) {
        guard plan.duration > 0 else { return }
        if let setup = plan.tyreSetup { fitTyres(setup,preservingBrakeHeat:true) }
        if plan.repairSeconds > 0 { damage = VehicleDamage() }
        resetABSModulation()
    }

    private mutating func resetABSModulation() {
        absSampleClock = 0
        absActive = false
        absRelease = 0
        absValveActivity = 0
        for index in wheels.indices {
            wheels[index].brakePressure = 1
            wheels[index].absPressureTarget = 1
        }
    }

    private mutating func fitTyres(_ setup: TyreSetup,preservingBrakeHeat: Bool) {
        wheels = wheels.map { previous in
            var fresh = WheelState()
            fresh.setup = setup
            if preservingBrakeHeat {
                fresh.brakeTemperature = previous.brakeTemperature
                fresh.brakeSurfaceTemperature = previous.brakeSurfaceTemperature
            }
            return fresh
        }
    }

    mutating func coolStationaryBrakes(_ dt: Double) {
        let brakes = kind.braking
        for index in wheels.indices {
            let capacity = brakes.capacity(front:index < 2)
            wheels[index].heatBrake(dt,workRate:0,capacity:capacity,speed:0,waterDepth:0)
        }
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
                wheels[i].preserveTread(from:oldWheels[i])
                wheels[i].coreTemperature = oldWheels[i].coreTemperature
                wheels[i].wear = oldWheels[i].wear
                wheels[i].flatSpot = oldWheels[i].flatSpot
                wheels[i].punctured = oldWheels[i].punctured
                wheels[i].airRetention = oldWheels[i].airRetention
                wheels[i].brakeTemperature = oldWheels[i].brakeTemperature
                wheels[i].brakeSurfaceTemperature = oldWheels[i].brakeSurfaceTemperature
                wheels[i].surfaceContamination = oldWheels[i].surfaceContamination
            }
        }
        position = sample.point
        heading = atan2(sample.tangent.x, sample.tangent.y)
    }

    private mutating func engageGear(_ next: Int) {
        shiftingDown = next > 0 && next < gear
        gear = next
        shiftCooldown = next == 0 ? 0.12 : kind.shiftDuration
    }

    private mutating func integrateFreeCrank(_ dt: Double) {
        let idleRPM = 950.0
        let rpmPerRadSecond = 60 / (2 * Double.pi)
        let inertia = kind.freeCrankInertia
        if rpm >= kind.redline { freeRevCut = true }
        else if rpm <= kind.redline - 120 { freeRevCut = false }

        let losses = kind.maximumEngineBrake * (0.5 + 1.5 * rpm / kind.redline)
        // The published curve is brake torque. Add back internal losses to
        // infer the firing torque, then apply friction even if ignition is cut.
        let fullFiringTorque = kind.fullThrottleTorque(at:rpm) * powerFactor + losses
        let idleGovernor = clamp(losses + inertia * (idleRPM-rpm) / (rpmPerRadSecond * 0.12), 0, fullFiringTorque)
        let firingTorque = max(idleGovernor, fullFiringTorque * engineThrottle) * ignitionFraction
        rpm = clamp(rpm + (firingTorque-losses) / inertia * dt * rpmPerRadSecond, 0, kind.redline+300)
    }

    mutating func cancelQueuedShift() { queuedForwardShift = nil }

    mutating func requestShift(_ direction: Int, pedals: DrivingInput, automatic: Bool,
                               queueIfBusy: Bool = false) -> ShiftResult {
        if queueIfBusy { cancelQueuedShift() }
        guard direction == -1 || direction == 1 else { return .unavailable }
        let next = gear + direction
        guard (-1...gearRatios.count).contains(next), !automatic || (gear <= 1 && next <= 1) else { return .unavailable }
        guard shiftCooldown <= 0 else {
            if queueIfBusy && !automatic && gear > 0 && next > 0 { queuedForwardShift = (direction,0.16) }
            return .busy
        }
        let changesDirection = next == -1 || gear == -1 || (next == 1 && forwardSpeed < -0.75)
        if changesDirection || (automatic && next == 0) {
            guard speed < 0.75, pedals.brake >= 0.25, pedals.throttle < 0.08 else { return .stopAndBrake }
        }
        if next > 0 && next < gear {
            let roadOmega = abs(forwardSpeed)/wheelRadius
            let proposedRPM = max(roadOmega,abs(drivenWheelOmega))*gearRatios[next-1]*kind.finalDrive*60/(2 * .pi)
            guard proposedRPM < kind.redline*1.035 else { return .overRev }
        }
        engageGear(next)
        return .shifted
    }

    mutating func step(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                       roadDistance: Double, roadWidth: Double, roadLateral: Double? = nil, roadProgress: Double = 0,
                       kerbsEnabled: Bool = true, roadContacts: [WheelRoadContact]? = nil, wake: AirWake = AirWake()) {
        guard dt > 0 && dt <= 0.1 else { return }
        brakePedalTravel = input.brake.isFinite ? clamp(input.brake,0,1) : 0
        wakeStrength += (clamp(wake.intensity,0,1)-wakeStrength) * (1-exp(-dt*6))
        let steps = max(1, Int(ceil(dt * 720)))
        tcActive = false
        absActive = false
        tcReduction = 0; absRelease = 0
        absValveActivity = 0
        let lf = kind.distanceFromCGToFrontAxle, lr = wheelbase-lf
        let halfTrack = trackWidth/2
        let x = SIMD4(-halfTrack,halfTrack,-halfTrack,halfTrack)
        let z = SIMD4(lf,lf,-lr,-lr)
        let road = StepRoad(contacts:roadContacts, lateral:roadLateral ?? roadDistance,
                            width:roadWidth, progress:roadProgress, kerbsEnabled:kerbsEnabled,
                            x:x, z:z, cgOffset:kind.centreOfGravityOffset, treadWidth:kind.treadWidth)
        for _ in 0..<steps {
            integrate(dt / Double(steps), input:input, assists:assists, road:road, xs:x, zs:z)
        }
    }

    // Road samples stay fixed through the three tyre solves. Keep the car's
    // changing flat spots, rolling radius and suspension state in the substep.
    private struct StepRoad {
        let contacts: [WheelRoadContact]
        let elevation: Double
        var heights = SIMD4<Double>.zero
        var grass = SIMD4<Double>.zero
        var surfaceMu = SIMD4<Double>(repeating:1.24)
        var dry = SIMD4<Double>.zero
        var surfaces = [WheelSurface](repeating:.asphalt,count:4)

        init(contacts provided: [WheelRoadContact]?, lateral: Double, width: Double, progress: Double,
             kerbsEnabled: Bool, x: SIMD4<Double>, z: SIMD4<Double>, cgOffset: Double,
             treadWidth: SIMD2<Double>) {
            if let provided, provided.count == 4 { contacts = provided }
            else {
                contacts = (0..<4).map { i in
                    WheelRoadContact(distance:abs(lateral+x[i]),progress:progress+z[i]+cgOffset,kerbsEnabled:kerbsEnabled)
                }
            }
            elevation = contacts.reduce(0) { $0 + $1.elevation } / 4
            let halfWidth = width/2
            for i in contacts.indices {
                let road = contacts[i]
                let kerb = road.kerb
                let grassEdge = halfWidth + kerb.width
                let onGrass = road.distance > grassEdge
                let onKerb = kerb.scale > 0 && road.distance > halfWidth && !onGrass
                surfaces[i] = onGrass ? .grass : (onKerb ? .kerb : .asphalt)
                let tread = treadWidth[i / 2]
                func overlap(beyond edge: Double) -> Double {
                    let t = clamp((road.distance-edge+0.5*tread)/tread,0,1)
                    return t*t*(3-2*t)
                }
                let grassShare = overlap(beyond:grassEdge)
                let paintShare = (overlap(beyond:halfWidth)-grassShare)*min(1,kerb.scale*3)
                let paintLoss = (0.055+0.17*clamp(road.waterDepth/0.65,0,1))*paintShare
                grass[i] = grassShare
                surfaceMu[i] = 1.24-0.76*grassShare-paintLoss
                dry[i] = (1-grassShare) * (1-clamp(road.waterDepth/0.75,0,1)) * (1-0.12*paintShare)
                heights[i] = road.elevation - elevation + kerb.elevation(progress:road.progress,distanceFromEdge:road.distance-halfWidth)
            }
        }
    }

    private mutating func integrate(_ dt: Double, input: DrivingInput, assists: DrivingAssists,
                                    road: StepRoad, xs: SIMD4<Double>, zs: SIMD4<Double>) {
        let throttle = clamp(input.throttle, 0, 1)
        let throttleRate = throttle >= engineThrottle ? 22+9*throttle : 42
        engineThrottle += (throttle-engineThrottle)*(1-exp(-dt*throttleRate))
        let demand = assists.brakeCurve.requestedPressure(for:brakePedalTravel)
        // Light pedal closes the initial travel gently. A firm hit takes up
        // that travel much faster, and a small modulation keeps it taken up.
        let takeUpTarget = BrakeCurve.takeUpTarget(for:demand)
        let takeUpRate = takeUpTarget > brakeTakeUp ? 35 + 155 * demand : 13
        brakeTakeUp += (takeUpTarget - brakeTakeUp) * (1 - exp(-dt * takeUpRate))
        let pressureTarget = demand * brakeTakeUp
        let delta = pressureTarget - brakeLinePressure
        // A seated pad can take up a small increase through the filled line.
        // A fresh stroke or a larger pressure change still builds at the slower rate.
        let flowRate = (2 / 0.011) / (1 + sqrt(1 + abs(delta) / 0.16))
        let initialRate = 29 + 11 * pressureTarget
        let seated = clamp(1-delta/0.024,0,1)*BrakeCurve.takeUpTarget(for:brakeLinePressure)
        let pressureRate = delta > 0 ? initialRate+(flowRate-initialRate)*seated*seated*(3-2*seated) : flowRate
        brakeLinePressure += delta * (1 - exp(-dt * pressureRate))
        if demand == 0 && brakeLinePressure < 0.0001 { brakeLinePressure = 0 }
        let brake = brakeLinePressure
        let absEnabled = assists.abs && brake > 0.025
        absSampleClock = absEnabled ? absSampleClock-dt : 0
        let sampleABS = absEnabled && absSampleClock <= 1e-9
        if sampleABS { absSampleClock += 1.0/120 }
        let vf = simd_dot(velocity, forward)
        let vl = simd_dot(velocity, modelX)
        let lf = zs[0], lr = -zs[2]
        let weight = mass * 9.81
        let airSpeed = max(0, vf)
        let aeroForce = airSpeed * airSpeed * kind.downforceCoefficient
        let aeroBalance = kind.frontAeroBalance
        aeroLoad = SIMD2(aeroForce * aeroBalance * (1 - damage.front * 0.60) * (1-wakeStrength*0.23),
                        aeroForce * (1 - aeroBalance) * (1 - damage.rear * 0.65) * (1-wakeStrength*0.13))
        let ratio = transmissionRatio * kind.finalDrive
        let frontShare = kind.frontDriveShare
        let rearShare = 1 - frontShare
        let coupledRPM = abs(drivenWheelOmega) * ratio * 60 / (2 * .pi)
        let roadRPM = max(0,vf) / wheelRadius * ratio * 60 / (2 * .pi)
        let launchRPM = kind.launchRPM
        // Open the starting clutch at rest. It takes up as the crank rises,
        // and blends into ordinary shaft coupling over the first few metres.
        let launchTravel = gear == 1 && launchRPM > 0 ? clamp((roadRPM-1100)/(launchRPM-850),0,1) : 1
        let clutchSlip = 1 - launchTravel*launchTravel*(3-2*launchTravel)
        if gear == 0 {
            integrateFreeCrank(dt)
        } else {
            freeRevCut = false
            let idleTarget = 950 + throttle * 450
            let slipTarget = idleTarget + max(0,launchRPM-idleTarget) * engineThrottle * clutchSlip
            let targetRPM = clamp(coupledRPM, slipTarget, kind.redline + 300)
            let normalMatching = shiftingDown ? 32.0 : 20.0
            let speedMatching = shiftCooldown > 0 ? normalMatching * (0.22/kind.shiftDuration) : 20
            rpm += (targetRPM-rpm)*(1-exp(-dt*speedMatching))
        }
        shiftCooldown = max(0, shiftCooldown - dt)
        if let queued = queuedForwardShift {
            if assists.automatic || queued.remaining <= dt {
                cancelQueuedShift()
            } else if shiftCooldown == 0 {
                cancelQueuedShift()
                // Reevaluate direction and over-rev interlocks against current speed.
                _ = requestShift(queued.direction,pedals:input,automatic:false)
            } else {
                queuedForwardShift?.remaining -= dt
            }
        }
        if assists.automatic && gear > 0 && shiftCooldown <= 0 {
            // A stored gear may exceed the ratios in a newly selected car.
            // Wheelspin alone cannot trigger a higher gear at low road speed.
            if gear > gearRatios.count {
                engageGear(gearRatios.count)
            } else if rpm > kind.upshiftRPM && gear < gearRatios.count && roadRPM > kind.upshiftRPM*0.83 && brake < 0.22 {
                engageGear(gear+1)
            } else if gear > 1 {
                let lowerRatio = gearRatios[gear-2]/gearRatios[gear-1]
                let lowerRoadRPM = roadRPM*lowerRatio
                // Prepare the exit gear under straight-line brake load.
                // Once the chassis is loaded sideways, revert to the low
                // road-speed threshold to avoid interrupting the corner.
                let brakeLoad = clamp((brake-0.19)/0.42,0,1)
                let cornerMargin = clamp((0.62-abs(lateralG))/0.36,0,1)
                let preparation = gear > 2 ? brakeLoad*cornerMargin : 0
                let brakingRPM = kind.redline*0.68/lowerRatio
                let threshold = 2450 + max(0,brakingRPM-2450)*preparation
                if rpm < threshold && lowerRoadRPM < kind.redline*0.88 { engageGear(gear-1) }
            }
        }
        let ratedTorque = kind.fullThrottleTorque(at:rpm)
        let initialBite = clamp((rpm-950)/max(190,760*engineThrottle),0,1) * (1-clamp(brake/0.30,0,1))
        let driveCoupling = 1-clutchSlip*(1-initialBite)
        let engineTorque = ratedTorque*powerFactor*engineThrottle*driveCoupling
        // Thermostat restricts cooling below operating temperature; nose damage
        // reduces radiator capacity rather than cooling an idling engine to ambient.
        coolantTemperature += ((0.35 + throttle * 1.8 + damage.front * 0.6) -
            max(0, coolantTemperature - 80) * (0.085 + abs(vf) * 0.0025) * (1 - damage.front * 0.88)) * dt
        coolantTemperature = clamp(coolantTemperature, 26, 160)
        damage.engine = min(1, damage.engine + max(0, coolantTemperature - 125) * dt * 0.00015)
        let shiftClutch = shiftingDown ? 0.18+0.82*shiftEngagement : 1
        let backdriveClutch = shiftClutch * (1-clutchSlip)
        let engineDrag = kind.coastTorque(at:rpm)*backdriveClutch*clamp(1-engineThrottle/0.16,0,1)*clamp(abs(vf)/3,0,1)
        let driveDirection = gear < 0 ? -1.0 : 1.0
        let reverseLimit = gear < 0 ? clamp((8 + vf)/2, 0, 1) : 1
        let transmissionEfficiency = 0.91
        let availableDrive = engineTorque * ignitionFraction * reverseLimit
        var drivingTorque = availableDrive
        var freeCrankRise = 0.0
        if gear == 1 && clutchSlip > 0 && availableDrive > 0 && drivenWheelOmega > 0 {
            // Match the two clutch faces without propelling a shaft already spinning faster
            // than the crank. The previous contact forces predict tyre resistance this substep.
            let wheelInertia = kind.wheelInertias
            let inverseCrank = 1/kind.freeCrankInertia
            let inverseShaft = 0.5*ratio*ratio*transmissionEfficiency*(frontShare*frontShare/wheelInertia.x + rearShare*rearShare/wheelInertia.y)
            let tyreReaction = 0.5*wheelRadius*ratio*(
                frontShare*(wheels[0].longitudinalForce+wheels[1].longitudinalForce)/wheelInertia.x +
                rearShare*(wheels[2].longitudinalForce+wheels[3].longitudinalForce)/wheelInertia.y)
            let difference = rpm * (2 * .pi/60) - drivenWheelOmega*ratio
            let synchronizingTorque = (difference/dt + availableDrive*inverseCrank + tyreReaction)/(inverseCrank+inverseShaft)
            drivingTorque = clamp(synchronizingTorque,0,availableDrive)
            freeCrankRise = (availableDrive-drivingTorque)*inverseCrank*dt*(60/(2 * .pi))
        }
        let axleTorque = (driveDirection * drivingTorque - copysign(engineDrag, vf))
            * transmissionRatio * kind.finalDrive * transmissionEfficiency
        let diffStrength = gear == 0 ? 0 : 6 + throttle * 9
        let frontTransfer = clamp((wheels[1].angularVelocity - wheels[0].angularVelocity) * diffStrength, -350, 350) * frontShare
        let rearTransfer = clamp((wheels[3].angularVelocity - wheels[2].angularVelocity) * diffStrength, -350, 350) * rearShare
        let frontBrakeBias = DrivingAssists.validatedBrakeBias(assists.frontBrakeBias)
        let brakeCapacity = 4050 * sqrt(mass / 1260.0)
        let braking = kind.braking
        let frontTorque = axleTorque * frontShare / 2, rearTorque = axleTorque * rearShare / 2
        let driveTorques = SIMD4(frontTorque+frontTransfer,frontTorque-frontTransfer,rearTorque+rearTransfer,rearTorque-rearTransfer)
        var totalFx = 0.0
        var deliveredAxleTorque = 0.0
        var totalFy = 0.0
        var slopeReaction = SIMD2<Double>.zero
        var yawTorque = 0.0
        var verticalForce = 0.0
        var rollTorque = 0.0
        var pitchTorque = 0.0
        var maximumSlip = 0.0
        var rollingDemand = 0.0

        // Both the pad and keyboard supply positive for driver-right. Convert
        // once to model yaw here, keeping wheel forces and animation in sync.
        let command = Self.steeringResponse(input.steering,curve:assists.steeringCurve)
        let target = -command * steeringLimit
        let error = target - steeringAngle
        let centering = clamp(-error * steeringAngle / 0.0025,0,1)
        let highway = clamp((abs(vf) - 9) / 25,0,1)
        let deliberate = clamp(max(abs(command),abs(steeringAngle) / steeringLimit) / 0.30,0,1)
        let bandwidth = 23 - 8 * highway * (1 - deliberate) + 9 * centering
        let speedLimit = 2.9 / (1 + abs(vf) * 0.008) + 1.2 * centering
        // A smooth rate limit keeps corrections and reversals on the same rack.
        steeringAngle += speedLimit * tanh(error * bandwidth / speedLimit) * dt
        if kind == .centenario {
            let blend = clamp((abs(vf)*3.6-32)/58,0,1)
            let ratio = -0.19+0.30*blend*blend*(3-2*blend)
            let targetRear = clamp(steeringAngle*ratio,-0.05236,0.05236)
            rearSteeringAngle += (targetRear-rearSteeringAngle)*(1-exp(-dt*18))
        }

        // Sample all four heights before solving loads, so the anti-roll coupling
        // is symmetric and cannot depend on left/right iteration order.
        let elevation = road.elevation
        if roadElevationReady {
            // Keep the sprung body's world height continuous as the contact
            // reference changes. Spring compression remains in metres.
            heave += roadElevation - elevation
        }
        roadElevation = elevation
        roadElevationReady = true
        let flatSpotSpeed = min(abs(vf)/5,1)
        var surfaceHeights = road.heights
        for i in 0..<4 {
            let wheel = wheels[i]
            surfaceHeights[i] = surfaceHeights[i]-wheelRadius*(1-wheel.radiusScale)
                + wheel.flatSpot*0.003*cos(wheel.rotation)*flatSpotSpeed
        }
        let springScale = kind.springScale
        let damperScale = sqrt(springScale * mass / 1260.0)
        let antiRollScale = kind.antiRollScale
        let previousBrakePressure = SIMD4(wheels[0].brakePressure,wheels[1].brakePressure,wheels[2].brakePressure,wheels[3].brakePressure)
        for i in 0..<4 {
            var wheel = wheels[i]
            let x = xs[i]
            let z = zs[i]
            let state = road.contacts[i]
            wheel.surface = road.surfaces[i]
            let onGrass = wheel.surface == .grass, onKerb = wheel.surface == .kerb
            let surfaceHeight = surfaceHeights[i]
            let cornerVelocity = velocity + yawRate * (modelX * z - forward * x)
            // Smooth base-slope velocity comes from the analytic profile.
            // The finite difference handles kerbs and tyre radius changes.
            let relativeSurfaceHeight = surfaceHeight - (state.elevation - elevation)
            let localSurfaceSpeed = clamp((relativeSurfaceHeight-wheel.localSurfaceHeight)/dt,-0.7,0.7)
            let roadVerticalSpeed = simd_dot(cornerVelocity,state.gradient) + localSurfaceSpeed
            wheel.localSurfaceHeight = relativeSurfaceHeight
            wheel.surfaceHeight = surfaceHeight
            let staticLoad = weight * (i < 2 ? lr : lf) / wheelbase / 2
            let springRate = (i < 2 ? 46000.0 : 49000.0) * springScale * (1 - damage.suspension[i] * 0.45)
            let damper = (i < 2 ? 2900.0 : 3100.0) * damperScale * (1 - damage.suspension[i] * 0.60)
            let deflection = heave + pitch * z + roll * x - surfaceHeight
            let deflectionRate = heaveRate + pitchRate * z + rollRate * x - roadVerticalSpeed
            let other = i ^ 1
            let otherDeflection = heave+pitch*zs[other]+roll*xs[other]-surfaceHeights[other]
            wheel.antiRollForce = -(i < 2 ? 9000.0 : 6500.0) * antiRollScale * (deflection-otherDeflection)
            let bump = max(0,-deflection-0.075)
            wheel.bumpStopForce = min(18000,180000*bump*bump/0.04)
            let droop = max(0,deflection-0.09)*90000
            let load = clamp(staticLoad-springRate*deflection-damper*deflectionRate+wheel.antiRollForce+wheel.bumpStopForce-droop,0,staticLoad*4)
            wheel.normalLoad = load
            wheel.suspensionTravel = -deflection
            wheel.suspensionVelocity = -deflectionRate
            // Smooth grade contributes to suspension motion, while the texture cue follows local relief.
            let excitation = onKerb && speed > 1 && load > 100
                ? clamp(abs(localSurfaceSpeed) + 0.3 * abs(sin(state.progress * 7)), 0, 1)
                    * min(speed / 8, 1) * min(load / staticLoad, 1.2) * state.kerb.scale : 0
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
            // Blend over roughly one tread width while the contact patch straddles the edge.
            let grassShare = road.grass[i]
            let waterDepth = state.waterDepth * (1 - grassShare)
            // Mix the surfaces under each contact and use the actual tyre
            // load. A softer carcass or puncture adds rolling resistance.
            let pressureFlex = wheel.carcassFlex
            let tyreDrag = 0.013+0.006*(pressureFlex-1)
            let waterDrag = clamp(waterDepth/0.9,0,1)*clamp(abs(u)/25,0,1)*0.0028
            rollingDemand += load * (tyreDrag+grassShare*0.055+waterDrag+(wheel.punctured ? 0.072 : 0))
            wheel.waterFilm = waterDepth
            wheel.spray = clamp(waterDepth / 0.7,0,1) * clamp((abs(u) - 3) / 32,0,1) * clamp(load / 1800,0,1)
            let wetGrip = wheel.setup.compound.wetGrip(waterDepth:waterDepth,speed:abs(u),pressure:wheel.pressure)
            let peakMu = road.surfaceMu[i] * wheel.gripFactor * loadSensitivity * wetGrip
            let capacity = load * peakMu
            let slipAngle = atan2(v, max(abs(u), 1.5))
            // A softer casing or higher load takes more travelled distance
            // to build lateral force. Blend out the lag near rest.
            let loadRatio = clamp(load/3100,0.2,2.1)
            let casing = pressureFlex.squareRoot()
            let relaxationLength = 0.35*casing*(0.88+0.12*loadRatio)
            wheel.relaxedSlipAngle += (slipAngle - wheel.relaxedSlipAngle)
                * (1 - exp(-dt * max(abs(u), 3) / relaxationLength))
            let transientBlend = clamp(abs(u) / 3, 0, 1)
            let forceSlipAngle = slipAngle * (1 - transientBlend) + wheel.relaxedSlipAngle * transientBlend
            let slipDenominator = max(abs(u), 2)
            // The sliding part of the previously solved footprint retains
            // less longitudinal shear. Keep finite carcass response even in
            // full sliding and leave the steady friction envelope intact.
            let longitudinalMemory = 1-0.28*wheel.slidingFraction
            let longitudinalLength = 0.12*(0.80+0.20*casing)*(0.95+0.05*loadRatio)*longitudinalMemory
            let longitudinalResponse = 1-transientBlend*exp(-dt*max(abs(u),3)/longitudinalLength)
            let relaxedRatio = wheel.relaxedSlipRatio
            let stiffnessScale = pow(max(load, 1) / 3100, 0.82)
            let lateralDeflection = -tan(forceSlipAngle)
            let linearY = 48000 * stiffnessScale * lateralDeflection
            let lateralSlipSpeed = lateralDeflection * max(abs(u), 1.5)
            let slidingSpeed = hypot(relaxedRatio * slipDenominator, lateralSlipSpeed)
            let slidingGrip = capacity * (0.82 + 0.18 * exp(-slidingSpeed / 5))
            let longitudinalStiffness = 65000 * stiffnessScale

            func forces(_ omega: Double) -> (fx: Double, fy: Double, ratio: Double, slidingFraction: Double, momentPerLength: Double) {
                let slipRatio = (omega * radius - u) / slipDenominator
                guard capacity > 0 else { return (0, 0, slipRatio, 0, 0) }
                let forceRatio = relaxedRatio + (slipRatio - relaxedRatio) * longitudinalResponse
                let linearX = longitudinalStiffness * forceRatio
                let demand = hypot(linearX, linearY)
                let slidingLength = min(1, demand / (3 * capacity))
                let stickingLength = 1 - slidingLength
                let adhesionScale = stickingLength * stickingLength
                let slidingFraction = slidingLength * slidingLength * (3 - 2 * slidingLength)
                let longitudinalSlipSpeed = omega * radius - u
                let slipSpeed = hypot(longitudinalSlipSpeed, v)
                let frictionPerSpeed = slidingGrip / max(slipSpeed, 0.05)
                let slidingScale = frictionPerSpeed * slidingFraction
                // First moment about the footprint midpoint, with distance measured
                // from the leading edge. Sticking shear grows linearly; sliding
                // shear follows the same parabolic pressure profile as its force.
                let adhesiveMoment = linearY * adhesionScale * (0.5 - 2 * stickingLength / 3)
                let slidingMoment = v * frictionPerSpeed * 1.5 * adhesionScale * slidingLength * slidingLength
                return (linearX * adhesionScale + longitudinalSlipSpeed * slidingScale,
                        linearY * adhesionScale - v * slidingScale, slipRatio, slidingFraction,
                        adhesiveMoment + slidingMoment)
            }

            var driveTorque = driveTorques[i]
            // Do not treat tiny coasting differential torques as accelerator
            // intervention (or amplify them into a false percentage at rest).
            let requestedDrive = driveTorque * driveDirection
            if assists.tractionControl && throttle > 0.01 && requestedDrive > 1 {
                let level = Double(clamp(assists.tcLevel,1,5))
                let lateralShare = clamp(abs(wheel.lateralForce)/max(capacity,1),0,1)
                let combinedGripShare = sqrt(1-0.62*lateralShare*lateralShare)
                let gripTorque = capacity*radius*(1.08-level*0.05)*combinedGripShare
                let excessSpin = max(0,wheel.slipRatio*driveDirection-assists.tcSlipThreshold)
                let targetScale = clamp(1-excessSpin*(1+level),0.12,1)
                let controlRate = targetScale < wheel.tractionTorqueScale ? 95.0 : 23-2*level
                wheel.tractionTorqueScale += (targetScale-wheel.tractionTorqueScale)*(1-exp(-dt*controlRate))
                let limited = min(requestedDrive,gripTorque)*wheel.tractionTorqueScale
                if limited < requestedDrive * 0.98 { tcActive = true }
                tcReduction = max(tcReduction,1-limited/requestedDrive)
                driveTorque = limited * driveDirection
            } else {
                wheel.tractionTorqueScale = 1
            }
            deliveredAxleTorque += driveTorque
            let rollingDirection = u < 0 ? -1.0 : 1.0
            if assists.abs {
                if !absEnabled {
                    // End slip commands at low line pressure and retain the valve's refill time.
                    wheel.absPressureTarget = 1
                } else if sampleABS {
                    let dryContact = road.dry[i]
                    let oppositeDry = road.dry[i ^ 1]
                    // Use a higher slip target on a dry axle and leave more
                    // lateral grip for steering when the front tyres are loaded sideways.
                    let lateralUse = clamp(abs(linearY) / max(capacity,1),0,1)
                    let slipThreshold = assists.absSlipThreshold
                        + min(dryContact,oppositeDry)*(0.012+Double(assists.absLevel)*0.006)
                        - 0.020*lateralUse
                    let excessSlip = max(0,-wheel.slipRatio*rollingDirection-slipThreshold)
                    let authority = clamp((abs(u)-2.5)/2.5,0,1)
                    let release = min(0.90,excessSlip*(9+2*Double(assists.absLevel)))*authority
                    let imbalance = max(0,dryContact-oppositeDry)*(1-previousBrakePressure[i ^ 1])
                    let stabilityRelief = imbalance*clamp((brake-0.22)/0.38,0,1)*Double(assists.absLevel)*0.028
                    wheel.absPressureTarget = 1-max(release,stabilityRelief*authority)
                }
                let delta = wheel.absPressureTarget-wheel.brakePressure
                let rate = delta < 0 ? 85.0 : 22.0
                let movement = delta*min(1,dt*rate)
                wheel.brakePressure += movement
                if absEnabled {
                    let flow = (movement < 0 ? -movement*0.045 : movement*0.030)/dt
                    absValveActivity = max(absValveActivity,clamp(flow*min(1,brake*2.1),0,1))
                    absRelease = max(absRelease,1-wheel.brakePressure)
                    absActive = absActive || wheel.brakePressure < 0.965
                }
            } else {
                wheel.brakePressure = 1
                wheel.absPressureTarget = 1
            }
            let hydraulic = brake * brakeCapacity * (i < 2 ? frontBrakeBias : 1-frontBrakeBias)
                * wheel.brakeFade(at:braking.fadeStart) * wheel.brakePressure
            let brakeTorque = hydraulic
            let inertia = kind.wheelInertias[i / 2]
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
                let resistance = sign * brakeTorque
                var fLo = balance(lo) + resistance
                var fHi = balance(hi) + resistance
                var root: Double?
                for i in 0..<14 {
                    let mid = (lo + hi) / 2
                    let secant = lo - fLo*(hi-lo)/(fHi-fLo)
                    let candidate = i < 10 ? clamp(secant,lo+(hi-lo)*0.03,hi-(hi-lo)*0.03) : mid
                    let value = balance(candidate) + resistance
                    if abs(value) < 0.004 { root = candidate; break }
                    if value > 0 { hi = candidate; fHi = value } else { lo = candidate; fLo = value }
                }
                if let root {
                    omega = root
                } else {
                    for _ in 0..<14 where hi-lo > 0.000_025 {
                        let mid = (lo+hi)/2
                        if balance(mid)+resistance > 0 { hi=mid } else { lo=mid }
                    }
                    omega = (lo+hi)/2
                }
            }
            let contact = forces(omega)
            wheel.slidingFraction = contact.slidingFraction
            let treadSpeed = omega * radius
            let slipSpeed = hypot(treadSpeed - u, v)
            wheel.contactSlipSpeed = slipSpeed
            // Use only the sliding traction in forces(). The sticking portion
            // also generates cornering force but largely stores elastic energy.
            wheel.slidingPower = slidingGrip * contact.slidingFraction * slipSpeed * min(1, slipSpeed / 0.05)
            wheel.rollingContactSpeed = treadSpeed * u > 0 ? min(abs(treadSpeed), abs(u)) : 0
            wheel.pavedContactFraction = 1 - grassShare
            // Estimate footprint area from load and gauge pressure, with a
            // nominal length/width ratio of 0.55. Blend the rolling direction at rest.
            let patchLength = sqrt(0.55 * load / (max(wheel.pressure, 0.8) * 100_000))
            wheel.aligningMoment = patchLength * contact.momentPerLength * clamp(u / 1.5, -1, 1)
            let available = capacity + (slidingGrip - capacity) * contact.slidingFraction
            wheel.gripUsage = available > 1 ? clamp(hypot(contact.fx, contact.fy) / available, 0, 1) : 0
            let averageOmega = (previousOmega+omega)/2
            let brakeWork = hydraulic * abs(averageOmega)
            wheel.heatBrake(dt,workRate:brakeWork,capacity:braking.capacity(front:i < 2),speed:abs(u),waterDepth:waterDepth)
            wheel.angularVelocity = omega
            let rotationStep = omega * dt
            wheel.rotation = (wheel.rotation + rotationStep).truncatingRemainder(dividingBy: 2 * .pi)
            wheel.accumulatedRotation += rotationStep
            wheel.slipRatio = contact.ratio
            wheel.relaxedSlipRatio += (contact.ratio - relaxedRatio) * longitudinalResponse
            wheel.slipAngle = slipAngle
            wheel.longitudinalForce = contact.fx
            wheel.lateralForce = contact.fy
            let treadWork = abs(contact.fx * (omega * radius - u)) + abs(contact.fy * v)
            // Sliding dissipates heat. Most of the work in the adhering part
            // is stored in elastic deflection, with a smaller hysteresis loss.
            let heat = wheel.slidingPower + 0.20*max(0,treadWork-wheel.slidingPower)
            let workBias = clamp((contact.fy * (i.isMultiple(of:2) ? -1 : 1))/max(load,100),-1,1)
            wheel.evolve(dt, slipPower: heat, speed: abs(u), load: load,
                         locked: contact.ratio * rollingDirection < -0.8, grass: onGrass,
                         surfaceTemperature: state.surfaceTemperature - 6 * grassShare, grassCoverage: grassShare,
                         lateralWork:workBias,waterDepth:waterDepth)
            let fx = contact.fx * c - contact.fy * s
            let fy = contact.fx * s + contact.fy * c
            let normalReaction = -state.gradient * load
            slopeReaction += normalReaction
            let worldFx = fx + simd_dot(normalReaction,forward)
            let worldFy = fy + simd_dot(normalReaction,modelX)
            totalFx += worldFx
            totalFy += worldFy
            yawTorque += z * worldFy - x * worldFx + wheel.aligningMoment
            maximumSlip = max(maximumSlip, min(1, abs(contact.ratio) * 1.4 + abs(slipAngle) * 2))
            wheels[i] = wheel
        }

        let wheelOmega = drivenWheelOmega
        let reduction = transmissionRatio * kind.finalDrive
        let netShaftTorque = reduction > 0 ? deliveredAxleTorque * driveDirection / (reduction * transmissionEfficiency) : 0
        let backdriveRPM = max(0, wheelOmega * driveDirection) * reduction * 60 / (2 * .pi)
        shaftLoad.drive = clamp(min(drivingTorque, netShaftTorque) / ratedTorque, 0, 1)
        shaftLoad.overrun = clamp(min(-netShaftTorque, engineDrag) * backdriveRPM / (kind.maximumEngineBrake * kind.redline), 0, 1)
        rpm = min(kind.redline+300,rpm+freeCrankRise)
        let drag = (kind.dragCoefficient*(1-wakeStrength*0.20) + damage.front*0.22 + damage.rear*0.13) * vf * abs(vf)
        let rolling = (vf >= 0 ? 1.0 : -1.0) * min(rollingDemand, abs(vf) * mass / dt)
        let groundLongitudinalForce = totalFx - simd_dot(slopeReaction,forward) - rolling
        let groundLateralForce = totalFy - simd_dot(slopeReaction,modelX)
        totalFx -= drag + rolling
        let ax = totalFx / mass
        let ay = totalFy / mass
        let feltAx = (groundLongitudinalForce - drag) / mass
        let feltAy = groundLateralForce / mass
        let acceleration = forward * ax + modelX * ay
        velocity += acceleration * dt
        yawRate += yawTorque / yawInertia * dt
        if speed < 0.08 && throttle < 0.01 {
            velocity *= exp(-12 * dt)
            yawRate *= exp(-12 * dt)
            if speed < 0.002 && brake > 0.1 { velocity = .zero }
        }
        let previousForward = forward
        heading += yawRate * dt
        heading = atan2(sin(heading), cos(heading))
        position += velocity * dt + (previousForward - forward) * kind.centreOfGravityOffset
        distanceTravelled += speed * dt
        lateralG += (feltAy / 9.81 - lateralG) * min(1, dt * 12)
        longitudinalG += (feltAx / 9.81 - longitudinalG) * min(1, dt * 12)
        tyreSlip = maximumSlip
        heaveRate += ((verticalForce - weight - aeroLoad.x - aeroLoad.y) / mass) * dt
        let height = kind.centreOfGravityHeight
        let inertia = kind.bodyInertia
        rollRate += (rollTorque + groundLateralForce * height) / inertia.roll * dt
        pitchRate += (pitchTorque + groundLongitudinalForce * height - aeroLoad.x * lf + aeroLoad.y * lr) / inertia.pitch * dt
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

    func interpolated(to next: GhostFrame,share: Double,time: Double) -> GhostFrame {
        let angle = atan2(sin(next.heading-heading),cos(next.heading-heading))
        return GhostFrame(time:time,x:x+(next.x-x)*share,z:z+(next.z-z)*share,heading:heading+angle*share)
    }
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

    static func key(vehicle: VehicleKind, circuit: CircuitKind, condition: TrackCondition = .dry,
                    legacyLayout: Bool = false, legacyPorscheMass: Bool = false) -> String {
        let generation = vehicle == .porsche && !legacyPorscheMass ? "timing10" : "timing9"
        let key = "\(generation)-\(vehicle.rawValue)-\(circuit.rawValue)"
        let surface = condition == .wet ? key + "-wet" : key
        return circuit.hasElevation && !legacyLayout ? surface + "-graded" : surface
    }
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

struct LapInputs: Codable {
    static let intervals = 800
    static let legacyIntervals = 200
    let throttle: Double
    let brake: Double
    let steering: Double
    let speedKPH: Double
    let linePressure: Double?
    let handwheelDegrees: Double? // positive to the driver’s right

    init(_ input: DrivingInput, speedKPH: Double, linePressure: Double? = nil,handwheelDegrees: Double? = nil) {
        throttle = input.throttle; brake = input.brake; steering = input.steering
        self.speedKPH = speedKPH
        self.linePressure = linePressure
        self.handwheelDegrees = handwheelDegrees
    }

    var isValid: Bool {
        (0...1).contains(throttle) && (0...1).contains(brake)
            && (-1...1).contains(steering) && (0...1000).contains(speedKPH)
            && (linePressure.map { (0...1).contains($0) } ?? true)
            && (handwheelDegrees.map { (-720...720).contains($0) } ?? true)
    }

    func interpolated(to next: Self, share: Double) -> Self {
        let share = clamp(share, 0, 1)
        let pressure = linePressure.flatMap { a in next.linePressure.map { a+($0-a)*share } }
        let wheel = handwheelDegrees.flatMap { a in next.handwheelDegrees.map { a+($0-a)*share } }
        return Self(DrivingInput(throttle: throttle + (next.throttle - throttle) * share,
            brake: brake + (next.brake - brake) * share,
            steering: steering + (next.steering - steering) * share),
            speedKPH: speedKPH + (next.speedKPH - speedKPH) * share,linePressure:pressure,handwheelDegrees:wheel)
    }
}

struct LapSummary: Codable {
    let time: Double
    let sectors: [Double]

    var isValid: Bool {
        (15...3600).contains(time) && sectors.count == 3
            && sectors.allSatisfy { $0.isFinite && $0 > 0 }
            && abs(sectors.reduce(0, +) - time) < 0.02
    }
}

struct AnalysedLap: Codable {
    let summary: LapSummary
    let inputs: [LapInputs]

    var isValid: Bool {
        summary.isValid && (inputs.count == LapInputs.intervals+1 || inputs.count == LapInputs.legacyIntervals+1)
            && inputs.allSatisfy(\.isValid)
    }

    /// The two recordings may have different spacing. Compare observations at the same distance.
    func input(at fraction: Double) -> LapInputs {
        let position = clamp(fraction,0,1)*Double(inputs.count-1)
        let first = Int(position)
        if position == Double(first) || first == inputs.count-1 { return inputs[first] }
        return inputs[first].interpolated(to:inputs[first+1],share:position-Double(first))
    }

}

struct PracticeAnalysis: Codable {
    static let historyLimit = 20
    private(set) var history: [LapSummary] = []
    private(set) var latest: AnalysedLap?
    private(set) var fastest: AnalysedLap?

    mutating func append(_ lap: AnalysedLap) {
        guard lap.isValid else { return }
        history.append(lap.summary)
        if history.count > Self.historyLimit { history.removeFirst() }
        latest = lap
        if fastest.map({ lap.summary.time < $0.summary.time }) ?? true { fastest = lap }
    }

    mutating func validate() {
        history = Array(history.filter(\.isValid).suffix(Self.historyLimit))
        if latest?.isValid == false { latest = nil }
        if fastest?.isValid == false { fastest = nil }
        if let latest, fastest.map({ latest.summary.time < $0.summary.time }) ?? true { fastest = latest }
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
    private(set) var analysedLap: AnalysedLap?
    private var lapInputs: [LapInputs] = []
    private var previousInputs: LapInputs?
    private var previousPose: GhostFrame?
    private var currentTrace: [LapProgress] = []
    private var sectorSplits: [Double] = []
    private var previousProgress: Double?
    private var recordingClock = 0.0
    private var wrongWayTime = 0.0
    private var started = false

    var nextCheckpointFraction: Double { checkpoint < 3 ? Double(checkpoint + 1) / 4 : 1 }
    var liveGhost: GhostFrame? { started && !waitingForStart ? ghost(at:elapsed) : nil }
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
        lapInputs.removeAll(keepingCapacity: true)
        previousInputs = nil
        previousPose = nil
        recordingClock=0;wrongWayTime=0;started=false;waitingForStart=progress>20
    }
    mutating func beginOutLap(at progress: Double) {
        resetLap(at: progress)
        waitingForStart = true
    }

    private mutating func beginFlyingLap(progress:Double,remainder:Double,startPose:GhostFrame,inputs:LapInputs) {
        resetLap(at:0);waitingForStart=false;started=true;elapsed=remainder;previousProgress=progress
        currentTrace=[LapProgress(fraction:0,time:0)]
        currentGhost=[startPose]
        lapInputs = [inputs]
        previousInputs = inputs
    }

    private mutating func sampleInputs(from previous: Double, to progress: Double, input: LapInputs) {
        guard validLap, progress > previous, let previousInputs else { return }
        while lapInputs.count <= LapInputs.intervals {
            let target = Double(lapInputs.count) / Double(LapInputs.intervals)
            guard target <= progress else { break }
            lapInputs.append(previousInputs.interpolated(to: input, share: (target - previous) / (progress - previous)))
        }
    }
    func referenceTime(at fraction:Double) -> Double? {
        guard bestTrace.count>=2, fraction>=bestTrace[0].fraction, fraction<=1 else {return nil}
        var lo=0, hi=bestTrace.count-1
        while lo+1<hi {let mid=(lo+hi)/2;if bestTrace[mid].fraction<=fraction {lo=mid}else{hi=mid}}
        let a=bestTrace[lo],b=bestTrace[hi]
        return a.time+(b.time-a.time)*(fraction-a.fraction)/(b.fraction-a.fraction)
    }
    mutating func step(_ dt: Double, vehicle: Vehicle, location: TrackLocation, trackLength: Double, trackWidth: Double,
                       assisted: Bool = false, input: DrivingInput = DrivingInput()) -> Bool {
        newBest=false
        analysedLap = nil
        let fraction=clamp(location.progress/trackLength,0,1)
        let controls = LapInputs(input,speedKPH:vehicle.speedKPH,linePressure:vehicle.brakeLinePressure,
                                 handwheelDegrees:-vehicle.handwheelAngle*180 / .pi)
        let pose = GhostFrame(time:0,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading)
        let lastPose = previousPose ?? pose
        defer { previousPose = pose }
        let forwardSpeed=simd_dot(vehicle.velocity,location.tangent), movingForward=forwardSpeed>0.5
        if !started && vehicle.speed>0.8 && !waitingForStart {
            started=true
            currentTrace=[LapProgress(fraction:clamp((previousProgress ?? location.progress)/trackLength,0,1),time:0)]
            currentGhost=[lastPose]
            lapInputs = [controls]
            previousInputs = controls
        }
        let before=elapsed
        if started {
            elapsed += dt
            if assisted { invalidate("自动驾驶") }
            if vehicle.allWheelsOutside || location.distance>trackWidth*0.5+2.5 {
                invalidate("驶出赛道边界")
            }
            wrongWayTime=forwardSpeed < -1 ? wrongWayTime+dt : 0
            if wrongWayTime>0.6 {invalidate("逆向行驶")}
            if elapsed>3600 {invalidate("超过单圈记录时限")}
        }
        if let previous=previousProgress {
            let crossed=previous>trackLength*0.90 && location.progress<trackLength*0.10 && movingForward
            let distance=crossed ? trackLength-previous+location.progress : location.progress-previous
            if started && abs(distance)>trackLength*0.03 {invalidate("跳过赛道检查点")}
            if crossed && waitingForStart && location.distance <= trackWidth/2 {
                let share=clamp((trackLength-previous)/max(distance,0.001),0,1)
                let startInputs = previousInputs?.interpolated(to: controls, share: share) ?? controls
                let startPose = lastPose.interpolated(to:pose,share:share,time:0)
                beginFlyingLap(progress:location.progress,remainder:dt*(1-share),startPose:startPose,inputs:startInputs)
                if assisted && share < 1 { invalidate("自动驾驶") }
                sampleInputs(from: 0, to: fraction, input: controls)
                previousInputs = controls
                return false
            }
            if crossed && started {
                let share=clamp((trackLength-previous)/max(distance,0.001),0,1)
                let finished=before+dt*share
                if checkpoint != 3 {invalidate("缺少赛道检查点")}
                if sectorSplits.count != 2 {invalidate("缺少分段检查点")}
                let completeSectors=sectors+[max(0,finished-(sectorSplits.last ?? 0))]
                let finishedValid=validLap && finished>15
                let finishInputs = previousInputs?.interpolated(to: controls, share: share) ?? controls
                let finishPose = lastPose.interpolated(to:pose,share:share,time:finished)
                sampleInputs(from: previous / trackLength, to: 1, input: finishInputs)
                if currentTrace.last!.fraction<1 && (currentTrace.last?.time ?? 0)<finished {currentTrace.append(LapProgress(fraction:1,time:finished))}
                if (currentGhost.last?.time ?? 0)<finished { currentGhost.append(finishPose) }
                let candidate=LapRecord(time:finished,sectors:completeSectors,trace:currentTrace,ghost:currentGhost)
                let recorded=finished>15
                if recorded {
                    last=finished;lastSectors=completeSectors.count==3 ? completeSectors : [];lastValid=finishedValid;completedLaps += 1;lap += 1
                    if finishedValid && candidate.isValid && (best == nil || finished<best!) {
                        best=finished;bestGhost=currentGhost;bestTrace=currentTrace;bestSectors=completeSectors;newBest=true
                    }
                    if finishedValid && candidate.isValid {
                        let analysis = AnalysedLap(summary: LapSummary(time: finished, sectors: completeSectors), inputs: lapInputs)
                        if analysis.isValid { analysedLap = analysis }
                    }
                }
                let startPose = GhostFrame(time:0,x:finishPose.x,z:finishPose.z,heading:finishPose.heading)
                beginFlyingLap(progress:location.progress,remainder:dt*(1-share),startPose:startPose,inputs:finishInputs)
                if assisted && share < 1 { invalidate("自动驾驶") }
                sampleInputs(from: 0, to: fraction, input: controls)
                previousInputs = controls
                return recorded
            }
            if started && movingForward && distance>0 && distance<trackLength*0.03 {
                sampleInputs(from: previous / trackLength, to: fraction, input: controls)
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
        previousInputs = controls
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
        return a.interpolated(to:b,share:t,time:time)
    }
}

/// Smooth intervention over the last few km/h. Existing braking demand wins.
func pitLimitedInput(_ input: DrivingInput,speed: Double,curve: BrakeCurve = .progressive,
                     limit: Double = PitLane.speedLimit) -> DrivingInput {
    var result = input
    result.throttle = min(input.throttle,clamp((limit-speed)/1.8,0,1))
    if speed > limit {
        let demand = clamp((speed-limit)*0.23,0,1)
        result.brake = max(input.brake, Vehicle.brakeTravel(for: demand,curve:curve))
    }
    return result
}

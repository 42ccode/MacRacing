import AppKit
import SceneKit
import Metal
import simd

enum SettingsPage: String, CaseIterable {
    case driving, controller, display, aids, audio
    var title: String {
        switch self {
        case .driving: return "驾驶"
        case .controller: return "手柄"
        case .display: return "画面"
        case .aids: return "显示辅助"
        case .audio: return "声音"
        }
    }
}

enum SessionPrompt {
    case restart, leave, pit, retire
}

extension PitServiceWork {
    var title: String {
        switch self {
        case .tyres: return "换胎"
        case .repairs: return "维修"
        case .both: return "换胎和维修"
        }
    }
}

enum GarageSelection {
    case vehicles, circuits
}

enum SettingsReset {
    case controller, display, audio
}

enum SettingsChoice: String {
    case camera, steering, braking, antialiasing, tyres

    var page: SettingsPage {
        switch self {
        case .steering, .braking: return .controller
        case .camera, .antialiasing: return .display
        case .tyres: return .driving
        }
    }

    var title: String {
        switch self {
        case .camera: return "驾驶视角"
        case .steering: return "转向响应"
        case .braking: return "制动响应"
        case .antialiasing: return "画质档位"
        case .tyres: return "下次安装的轮胎"
        }
    }

    var detail: String {
        switch self {
        case .camera: return "选择进入赛道时的镜头。驾驶中仍可用 Tab / Y 切换。"
        case .steering: return "调整摇杆经过死区后的响应。三档的最大转向输入相同。"
        case .braking: return "调整扳机行程与目标压力的关系。实际制动还受压力建立和 ABS 影响。"
        case .antialiasing: return "选择抗锯齿、阴影与接触处光影的细节级别。"
        case .tyres: return "本次选择在重新开始或进站换胎时生效。"
        }
    }

    var options: [(title: String, detail: String)] {
        switch self {
        case .camera:
            let descriptions = ["从驾驶员眼位看座舱","贴近仪表台","从引擎盖上方观察","最低的车外视角","在车尾近处观察","保留更大的周边视野"]
            return DrivingView.allCases.map { ($0.label,descriptions[$0.rawValue]) }
        case .steering:
            let descriptions = ["转向量随摇杆平稳上升","减小中心附近的转向量","小幅推杆也能更快转向"]
            return SteeringCurve.allCases.map { ($0.label,descriptions[$0.rawValue]) }
        case .braking:
            let descriptions = ["兼顾轻刹和重刹","拉长轻刹区间","较早建立目标压力"]
            return BrakeCurve.allCases.map { ($0.label,descriptions[$0.rawValue]) }
        case .antialiasing:
            let descriptions = ["关闭抗锯齿，保留基本阴影","2× 抗锯齿，中等阴影与光影","4× 抗锯齿，完整阴影与光影"]
            return GraphicsQuality.allCases.map { ($0.title,descriptions[$0.rawValue]) }
        case .tyres:
            let descriptions = ["干地抓地更高，磨耗较快","平衡干地抓地和磨耗","干地更耐磨，峰值抓地较低","降低湿地和积水中的抓地损失"]
            return TyreCompound.allCases.map { ($0.label,descriptions[$0.rawValue]) }
        }
    }

    var showsResponseGraph: Bool { self == .steering || self == .braking }
    func response(at input: Double,index: Int) -> Double {
        switch self {
        case .braking: return BrakeCurve(rawValue:index)?.pressure(for:input) ?? 0
        case .steering: return SteeringCurve(rawValue:index)?.response(input) ?? 0
        default: return 0
        }
    }
}

enum RenderingRate: Int, CaseIterable {
    case hz60 = 60, hz120 = 120
    var title: String { "\(rawValue) FPS" }
    var next: Self { self == .hz60 ? .hz120 : .hz60 }
}

enum ReplayViewpoint: Int, CaseIterable {
    case chase, chaseFar, bonnet, trackside, cockpit

    var label: String { self == .trackside ? "赛道镜头" : drivingView.label }
    var drivingView: DrivingView {
        switch self {
        case .chase, .trackside: return .chase
        case .chaseFar: return .chaseFar
        case .bonnet: return .bonnet
        case .cockpit: return .cockpit
        }
    }
    var next: Self { Self(rawValue:(rawValue+1)%Self.allCases.count) ?? .chase }
}

struct VehicleSettings: Codable {
    var compound: Int
    var coldPressure: Double
    var absLevel: Int
    var tcLevel: Int
    var automatic: Bool
    var frontBrakeBias: Double
    var brakeCurve: Int? = nil
    var steeringCurve: Int? = nil

    init(tyres: TyreSetup, assists: DrivingAssists) {
        compound = tyres.compound.rawValue
        coldPressure = tyres.coldPressure
        absLevel = assists.absLevel
        tcLevel = assists.tcLevel
        automatic = assists.automatic
        frontBrakeBias = assists.frontBrakeBias
        brakeCurve = assists.brakeCurve.rawValue
        steeringCurve = assists.steeringCurve.rawValue
    }

    func apply(to tyres: inout TyreSetup, assists: inout DrivingAssists) {
        tyres.compound = TyreCompound(rawValue: compound) ?? .medium
        tyres.coldPressure = coldPressure.isFinite ? clamp(coldPressure, 1.3, 2.1) : 1.65
        assists.absLevel = clamp(absLevel, 0, 5)
        assists.tcLevel = clamp(tcLevel, 0, 5)
        assists.automatic = automatic
        assists.frontBrakeBias = DrivingAssists.validatedBrakeBias(frontBrakeBias)
        assists.brakeCurve = brakeCurve.flatMap(BrakeCurve.init(rawValue:)) ?? .progressive
        assists.steeringCurve = steeringCurve.flatMap(SteeringCurve.init(rawValue:)) ?? .standard
    }
}

struct SavedPractice: Codable {
    let version: Int
    let best: Double?
    let ghost: [GhostFrame]
    let abs: Bool
    let tractionControl: Bool
    let automatic: Bool
    let deadzone: Double
    let muted: Bool
    let cockpit: Bool?
    let verticalFOV: Double?
    let eyeHeight: Double?
    let compound: Int?
    let coldPressure: Double?
    var drivingView: Int? = nil
    var vehicleKind: Int? = nil
    var circuitKind: Int? = nil
    var absLevel: Int? = nil
    var tcLevel: Int? = nil
    var hapticLevel: Int? = nil
    var hapticRoute: Int? = nil
    var records: [String:LapRecord]? = nil
    var racingLineEnabled: Bool? = nil
    var opponentCount: Int? = nil
    var hudPositions: [String:HUDPosition]? = nil
    var brakeBiasByVehicle: [String:Double]? = nil
    var pitLimiterEnabled: Bool? = nil
    var mirrorEnabled: Bool? = nil
    var compactHUD: Bool? = nil
    var vehicleSettings: [String: VehicleSettings]? = nil
    var analysis: [String: PracticeAnalysis]? = nil
    var trackCondition: Int? = nil
    var graphicsQuality: Int? = nil
    var ghostEnabled: Bool? = nil
    var showHUD: Bool? = nil
    var masterVolume: Double? = nil
    var motorVolume: Double? = nil
    var effectsVolume: Double? = nil
    var renderingRate: Int? = nil
    var raceConfiguration: RaceConfiguration? = nil
    var raceRecords: [RaceRecord]? = nil
    var cups: [String:CupProgress]? = nil
    var lessonRecords: [String:DrivingLessonRecord]? = nil
}

struct DrivingTick {
    let timestamp: Double
    let processingTime: Double
    let physicsSteps: Int
    let sceneUpdated: Bool
}

private struct PracticeSelection {
    let vehicle: VehicleKind
    let circuit: CircuitKind
    let condition: TrackCondition
}

private final class QualifyingReferenceJob {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private struct PracticeLoad {
    var settings: SavedPractice?
    var data: Data?
    var usedRecovery = false
    var unreadablePrimary: Data?
}

/// Access is serialized by RacingGame's existing persistence queue.
private final class PracticeRecovery {
    static let filename = "practice-recovery.json"
    private var knownGood: Data?
    private var unreadable: Data?
    private var wroteRecovery = false

    init(_ load: PracticeLoad) {
        knownGood = load.data
        unreadable = load.unreadablePrimary
        wroteRecovery = load.usedRecovery
    }

    func preserveBeforeWriting(in directory: URL) throws {
        if let unreadable {
            try unreadable.write(to:directory.appendingPathComponent("practice-unreadable.json"),options:.atomic)
            self.unreadable = nil
        }
        if !wroteRecovery, let data = knownGood {
            do {
                try data.write(to:directory.appendingPathComponent(Self.filename),options:.atomic)
                wroteRecovery = true
            } catch {
                // Updating the optional backup does not block a healthy save.
            }
        }
    }

    func didWrite(_ data: Data) {
        if !wroteRecovery { knownGood = data }
        else { knownGood = nil }
    }
}

private struct TelemetrySample {
    let lapTime: Double
    let telemetryElapsed: Double
    let progress: Double
    let lateral: Double
    let raceLap: Int
    let validLap: Bool
    let vehicle: Vehicle
    let controls: DrivingInput
    let command: DrivingInput
    let drivingAssists: DrivingAssists
    let circuit: CircuitKind
    let condition: TrackCondition
    let grade: Double
    let crossfall: Double

    func encode() -> String {
        let base = String(format: "%.3f,%.3f,%.3f,%.2f,%d,%.0f,%.3f,%.3f,%.3f,%.3f,%.3f,%d",
            lapTime,vehicle.position.x,vehicle.position.y,vehicle.speedKPH,vehicle.gear,
            vehicle.rpm, controls.throttle, controls.brake, controls.steering,
            vehicle.lateralG,vehicle.longitudinalG,validLap ? 1 : 0)
        let wheels = vehicle.wheels
        var data = wheels.map(\.temperature)
        data += wheels.map(\.pressure)
        data += wheels.map(\.wear)
        data += [vehicle.damage.front, vehicle.damage.rear, vehicle.damage.engine, vehicle.coolantTemperature]
        data += wheels.map { $0.suspensionTravel * 1000 }
        data += wheels.map(\.normalLoad)
        data += wheels.map(\.kerbFeedback)
        data += [Double(vehicle.kind.rawValue),Double(circuit.rawValue),Double(drivingAssists.absLevel),
                 Double(drivingAssists.tcLevel),vehicle.absRelease,vehicle.tcReduction,drivingAssists.frontBrakeBias]
        data += [vehicle.brakeLinePressure,vehicle.yawRate,vehicle.aeroLoad.x,vehicle.aeroLoad.y]
        data += wheels.map(\.gripUsage)
        data += wheels.map(\.surfaceContamination)
        data += [Double(condition.rawValue),Double(wheels[0].setup.compound.rawValue)]
        data += wheels.map(\.waterFilm)
        data += [vehicle.roadElevation,grade*100,crossfall*100]
        data += wheels.flatMap { [$0.treadTemperatures.x,$0.treadTemperatures.y,$0.treadTemperatures.z] }
        data += [telemetryElapsed,progress,lateral,vehicle.steeringAngle,Double(raceLap)]
        data += wheels.map { vehicle.brakeLinePressure * $0.brakePressure }
        data += wheels.map(\.slipRatio)
        data += wheels.map(\.longitudinalForce)
        let pressureTarget = drivingAssists.brakeCurve.pressure(for:command.brake)
        data += [vehicle.wakeStrength,command.throttle,command.brake,pressureTarget,vehicle.engineThrottle]
        data += wheels.map(\.slidingFraction)
        data += wheels.map(\.lateralForce)
        data += wheels.map(\.aligningMoment)
        let decimals = String(repeating:",%.4f",count:data.count)
        let fields = String(format:decimals,arguments:data)
        return base+fields
    }
}

private final class TelemetryRecording {
    // Sample conversion, rows and writes are confined to the same serial queue.
    private static let header = "time_s,x_m,z_m,speed_kph,gear,rpm,throttle,brake,steering,lateral_g,longitudinal_g,valid_lap,fr_surface_c,fl_surface_c,rr_surface_c,rl_surface_c,fr_bar,fl_bar,rr_bar,rl_bar,fr_wear,fl_wear,rr_wear,rl_wear,front_damage,rear_damage,engine_damage,coolant_c,fr_travel_mm,fl_travel_mm,rr_travel_mm,rl_travel_mm,fr_load_n,fl_load_n,rr_load_n,rl_load_n,fr_kerb,fl_kerb,rr_kerb,rl_kerb,car_id,track_id,abs_level,tc_level,abs_release,tc_reduction,front_brake_bias,brake_line_pressure,yaw_rate_rad_s,aero_front_n,aero_rear_n,fr_grip_use,fl_grip_use,rr_grip_use,rl_grip_use,fr_contamination,fl_contamination,rr_contamination,rl_contamination,track_condition,tyre_compound,fr_water_mm,fl_water_mm,rr_water_mm,rl_water_mm,road_elevation_m,road_grade_pct,road_crossfall_pct,fr_tread_inner_c,fr_tread_middle_c,fr_tread_outer_c,fl_tread_inner_c,fl_tread_middle_c,fl_tread_outer_c,rr_tread_inner_c,rr_tread_middle_c,rr_tread_outer_c,rl_tread_inner_c,rl_tread_middle_c,rl_tread_outer_c,session_time_s,track_progress_m,track_lateral_m,rack_angle_rad,lap_index,fr_brake_pressure,fl_brake_pressure,rr_brake_pressure,rl_brake_pressure,fr_longitudinal_slip,fl_longitudinal_slip,rr_longitudinal_slip,rl_longitudinal_slip,fr_longitudinal_force_n,fl_longitudinal_force_n,rr_longitudinal_force_n,rl_longitudinal_force_n,wake_strength,applied_throttle,applied_brake,brake_steady_target,engine_throttle,fr_sliding_fraction,fl_sliding_fraction,rr_sliding_fraction,rl_sliding_fraction,fr_lateral_force_n,fl_lateral_force_n,rr_lateral_force_n,rl_lateral_force_n,fr_aligning_moment_nm,fl_aligning_moment_nm,rr_aligning_moment_nm,rl_aligning_moment_nm"
    private var rows = [TelemetryRecording.header]

    func append(_ sample: TelemetrySample) {
        rows.append(sample.encode())
    }

    func write(to file: URL) throws {
        try (rows.joined(separator:"\n")+"\n").write(to:file,atomically:true,encoding:.utf8)
    }
}

final class RacingGame {
    private(set) var circuit: Circuit
    let input: InputManager
    let sound = EngineSound()
    private(set) var world: RacingWorld
    let hud = HUDView()
    let sceneView: DrivingViewport
    var vehicle = Vehicle()
    private var previousVehicle: VehicleRenderSample?
    var assists = DrivingAssists()
    private var vehicleSettings: [String: VehicleSettings] = [:]
    private var vehicleSettingsKey: String { String(vehicle.kind.rawValue) }
    private var analysis: [String: PracticeAnalysis] = [:]
    var practiceAnalysis: PracticeAnalysis { analysis[recordKey] ?? PracticeAnalysis() }
    private(set) var showingAnalysis = false
    private(set) var showingControllerReview = false
    private(set) var settingsPage: SettingsPage?
    private(set) var showcase: VehicleShowcase?
    private(set) var showcaseError: String?
    private(set) var showingSeatPreview = false
    private(set) var settingsChoice: SettingsChoice?
    private(set) var returningSettingsControl: String?
    private(set) var sessionPrompt: SessionPrompt?
    private(set) var garageSelection: GarageSelection?
    private(set) var settingsReset: SettingsReset?
    private var calibrationReturnPage: SettingsPage?
    private(set) var settingsStatus: String?
    private(set) var practiceReadNotice: String?
    private(set) var graphicsQuality = GraphicsQuality.quality
    private(set) var renderingRate = RenderingRate.hz120
    private(set) var analysisPage = 0
    var drivingInput = DrivingInput()
    var session = RaceSession()
    private(set) var sprint: SprintRace?
    private(set) var raceConfiguration = RaceConfiguration()
    private(set) var activeRaceConfiguration: RaceConfiguration?
    private(set) var activeRaceGrid: QualifyingSession.Grid?
    private(set) var plannedRaceTyres: TyreSetup?
    private(set) var plannedRaceWork = PitServiceWork.both
    private(set) var activeRaceService: PitServicePlan?
    private(set) var trackDrying: TrackDrying?
    private var dryingClock = 0.0
    private var dryingHistory: [TrackDrying] = []
    private var displayedDryingTime: Double?
    private(set) var racePitStops = 0
    private(set) var showingRaceSetup = false
    private(set) var showingRaceHistory = false
    private(set) var raceHistoryPage = 0
    private(set) var reviewedRaceLaps: RaceRecord?
    private(set) var showingPracticeBests = false
    private(set) var bestsShowsLegacyPorsche = false
    private(set) var bestsVehicle = VehicleKind.porsche
    private(set) var bestsCondition = TrackCondition.dry
    private(set) var raceRecords: [RaceRecord] = []
    private(set) var showingCupMenu = false
    private(set) var selectedCup = CupSeries.club
    private(set) var activeCup: CupEntry?
    private(set) var cupRoundRecorded = false
    private var cups: [CupSeries:CupProgress] = [:]
    private var activityReturnSelection: PracticeSelection?
    private var activeRaceID: UUID?
    private var cooldownSpeed: Double?
    private var finishRolloutRemaining = 0.0
    private var classifiedRolloutTime = 0.0
    private var checkeredDeadline: Double?
    private var raceReplay = RaceReplay()
    private var raceFlags = RaceFlags()
    var raceCaution: RaceFlags.Caution? { raceFlags.caution }
    var raceBlueFlag: RaceFlags.Blue? { raceFlags.blue }
    private var wrongWay = WrongWayMonitor()
    var isWrongWay: Bool { wrongWay.isActive }
    private(set) var replay: RacePlayback?
    private(set) var replayView = ReplayViewpoint.chase
    private(set) var replayFrame: RaceReplay.Frame?
    private var replayFrameClock = 0.0
    private var replayNeedsFrame = false
    private var replayNeedsCameraReset = false
    private var replaySoundActive = false
    private var replayContactTime: Double?
    private var replayLookRemaining = 0.0
    var raceResultReady: Bool { sprint?.finished == true && activeRaceID == nil }
    var canReplay: Bool { raceReplay.hasFootage && raceResultReady }
    private(set) var showingSchool = false
    private(set) var selectedLesson = DrivingLessonKind.braking
    private(set) var lesson: DrivingLessonRun?
    private(set) var rollingCountdown = 0.0
    private var rollingGo = 0.0
    var showRollingGo: Bool { rollingGo > 0 }
    private(set) var lessonPersonalBest = false
    private(set) var lessonRecords: [DrivingLessonKind:DrivingLessonRecord] = [:]
    private(set) var qualifying: QualifyingSession?
    private var qualifyingSetup: RaceConfiguration?
    private var qualifyingReferenceJob: QualifyingReferenceJob?
    private var qualifyingReferenceTimes: [Double?]?
    var qualifyingGrid: QualifyingSession.Grid? {
        guard let result = qualifying?.result, let times = qualifyingReferenceTimes else { return nil }
        return QualifyingSession.grid(playerTime:result.time,rivalTimes:times)
    }
    private var records: [String:LapRecord] = [:]
    var hasLegacyPorscheBests: Bool {
        bestsVehicle == .porsche && CircuitKind.allCases.contains {
            records[LapRecord.key(vehicle:.porsche,circuit:$0,condition:bestsCondition,legacyPorscheMass:true)] != nil
        }
    }
    func bestPracticeLap(at track: CircuitKind) -> LapRecord? {
        records[LapRecord.key(vehicle:bestsVehicle,circuit:track,condition:bestsCondition,
                              legacyPorscheMass:bestsShowsLegacyPorsche)]
    }
    private var legacyPractice: (data: Data, version: Int)?
    private var recordKey: String { LapRecord.key(vehicle:vehicle.kind,circuit:circuit.kind,condition:circuit.condition) }
    var location: TrackLocation
    var hasStarted = false { didSet { updateTickTimer() } }
    var isPaused = true {
        didSet {
            if isPaused { vehicle.cancelQueuedShift() }
            updateTickTimer()
        }
    }
    var showHelp = false
    var isNavigatingMenu: Bool { isPaused || !hasStarted }
    var drivingView = DrivingView.chase
    var cockpit: Bool { drivingView.isInterior }
    var ghostEnabled = true
    var showHUD = true
    private(set) var compactHUD = true
    private(set) var mirrorEnabled = true
    private(set) var mirrorImage: NSImage?
    private var mirrorRenderer: SCNRenderer?
    private var mirrorQueue: MTLCommandQueue?
    private var mirrorPasses: [VehicleMirror:MTLRenderPassDescriptor] = [:]
    private var mirrorInFlight = false
    private var nextMirrorFrame = 0.0
    private var mirrorSequenceIndex = 0
    private var focusedMirror: VehicleMirror?
    private var mirrorCost = 0.0
    private var mirrorRevision = 0
    private var replayMirrorsPending: Set<VehicleMirror> = []
    private var mirrorSession: Bool {
        guard mirrorEnabled else { return false }
        if replay != nil { return replayView == .cockpit }
        return hasStarted && !isPaused && serviceRemaining == 0 && cockpit
    }
    var showMirror: Bool { replay == nil && mirrorSession && showHUD }
    private(set) var sideTraffic = SideTraffic()
    private var sideTrafficHold = SideTrafficHold()
    var hudPositions: [String:HUDPosition] = [:]
    private(set) var editingHUD = false
    private var resumeAfterHUDEdit = false
    private var hudLayoutBeforeEdit: [String:HUDPosition] = [:]
    private var hudEditReturnPage: SettingsPage?
    var racingLineEnabled = true
    private(set) var opponentCount = 3
    private(set) var traffic = ComputerTraffic()
    private(set) var autoDriveEnabled = false
    var tyreSetup = TyreSetup()
    var canPlanTyres: Bool { sprint == nil && lesson == nil && qualifying == nil && serviceRemaining == 0 }
    var canPitService: Bool {
        hasStarted && lesson == nil && qualifying == nil && (sprint.map { $0.countdown == 0 && !$0.playerDone } ?? true)
    }
    var plannedRaceStop: PitServicePlan? {
        guard sprint != nil, let plannedRaceTyres else { return nil }
        return PitServicePlan(work:plannedRaceWork,damage:vehicle.damage,tyreSetup:plannedRaceTyres)
    }
    func cupProgress(_ series: CupSeries) -> CupProgress { cups[series] ?? CupProgress() }
    var hasPendingTyres: Bool { vehicle.wheels.first?.setup != tyreSetup }
    var serviceRemaining = 0.0
    private(set) var inPitLane = false
    var pitLimiterEnabled = true
    var inPitSpeedZone: Bool { circuit.pitLane.isLimited(location) }
    var pitOverspeed: Bool { inPitSpeedZone && vehicle.speed > PitLane.speedLimit + 0.28 }
    var pitApproachLabel: String? {
        guard let metres = circuit.pitLane.metresToSpeedLimit(at:location) else { return nil }
        return "距限速区 \(max(1,Int(ceil(metres)))) m · 60 km/h"
    }
    var gTrace: [SIMD2<Double>] = []
    var inputHistory = InputHistory()
    var notice = ""
    var noticeRemaining = 0.0
    private var timer: Timer?
    private var tickRate = 0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var controlClock = DrivingStepClock()
    private var renderClock = 0.0
    private var sceneCadence = UpdateCadence()
    private var peripheralCadence = UpdateCadence()
    private var lastPeripheralUpdate: Double?
    private var lastSceneUpdate: Double?
    var inspectDrivingTick: ((DrivingTick) -> Void)?
    private var hudNoticeVisible = false
    private var hudControllerName: String?
    private var hudHapticStatus = ""
    private var sceneDirty = true
    private var collisionCooldown = 0.0
    private var pendingContact: ContactSound?
    private var impactFeedback = SIMD2<Double>.zero
    private var feedback = HapticFeedback()
    private static let persistenceQueue = DispatchQueue(label:"studio.apexlab.practice-persistence",qos:.utility)
    private var practiceSaveRevision = 0
    private var telemetrySaveRevision = 0
    private var telemetryClock = 0.0
    private var telemetryElapsed = 0.0
    private var telemetry = TelemetryRecording()
    private var telemetrySampleCount = 0
    private static let peripheralRate = 120

    private static func defaultDataDirectory() -> URL {
        let fm = FileManager.default
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let portable = parent.appendingPathComponent("APEX Lab Data", isDirectory: true)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APEX Lab", isDirectory: true)
        let portableExists = fm.fileExists(atPath: portable.path)
        func hasPractice(in folder: URL) -> Bool {
            fm.fileExists(atPath:folder.appendingPathComponent("practice.json").path) ||
                fm.fileExists(atPath:folder.appendingPathComponent(PracticeRecovery.filename).path)
        }
        if (portableExists ? fm.isWritableFile(atPath:portable.path) : fm.isWritableFile(atPath:parent.path)) &&
            (hasPractice(in:portable) || !hasPractice(in:support)) {
            return portable
        }
        return support
    }
    private let dataDirectory: URL
    private let practiceRecovery: PracticeRecovery

    init(frame: NSRect, dataDirectory: URL? = nil, monitorControllers: Bool = true) {
        input = InputManager(monitorControllers: monitorControllers)
        let folder = dataDirectory ?? Self.defaultDataDirectory()
        self.dataDirectory = folder
        let practice = Self.readPractice(in:folder)
        practiceRecovery = PracticeRecovery(practice)
        let saved = practice.settings
        let kind = saved?.vehicleKind.flatMap(VehicleKind.init(rawValue:)) ?? .porsche
        let track = saved?.circuitKind.flatMap(CircuitKind.init(rawValue:)) ?? .north
        let condition = saved?.trackCondition.flatMap(TrackCondition.init(rawValue:)) ?? .dry
        let circuit = Circuit(kind:track,condition:condition)
        self.circuit = circuit
        world = RacingWorld(circuit:circuit,vehicleKind:kind)
        location = circuit.nearest(to: circuit.start.point)
        sceneView = DrivingViewport(frame:frame)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.scene = world.scene
        sceneView.pointOfView = world.camera
        sceneView.preferredFramesPerSecond = renderingRate.rawValue
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        hud.frame = frame
        hud.autoresizingMask = [.width, .height]
        hud.game = self
        input.onAction = { [weak self] action in self?.action(action) }
        vehicle.kind = kind
        if let saved, let data = practice.data { applyPractice(saved,data:data) }
        if practice.usedRecovery { practiceReadNotice = "已从上一份存档恢复。" }
        else if practice.unreadablePrimary != nil { practiceReadNotice = "当前存档无法读取，保存时会保留原始文件。" }
        applyGraphicsQuality()
        vehicle.reset(at: self.circuit.start)
        vehicle.service(setup: tyreSetup)
        location = self.circuit.nearest(to: vehicle.position)
        session.resetLap(at: location.progress)
        world.update(vehicle: vehicle, input: drivingInput, dt: 0, cockpit: false, ghost: nil, view: .chase)
        updateMenuCamera()
        updateTickTimer()
    }

    private func updateTickTimer() {
        let rate = hasStarted && !isPaused ? DrivingStepClock.drivingRate : Self.peripheralRate
        guard rate != tickRate else { return }
        timer?.invalidate()
        tickRate = rate
        let nextTimer = Timer(timeInterval:1/Double(rate),repeats:true) { [weak self] _ in self?.tick() }
        timer = nextTimer
        RunLoop.main.add(nextTimer,forMode:.common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { sceneView.presentPendingFrame(at:now) }
        let dt = clamp(now - lastTime, 0, 1.0 / 15)
        var physicsSteps = 0
        var drivingElapsed = 0.0
        lastTime = now
        let wasPaused = isPaused
        drivingInput = input.read(dt: dt, deadzone: assists.steeringDeadzone,
                                  acceptDriving: hasStarted && !isPaused && sprint?.playerDone != true && serviceRemaining == 0,
                                  diagnose: showingControllerReview, navigateMenu: isNavigatingMenu, now: now)
        if let showcase {
            let animated = showcase.update(dt)
            let cameraMoved = showcase.moveCamera(input.showcaseCamera,dt:dt)
            if animated || cameraMoved { sceneView.requestFrame() }
            return
        }
        if replay != nil {
            updateReplay(dt)
            updateMirror(at:now)
            return
        }
        // Button handlers can change pause state during polling.
        if isPaused || wasPaused { drivingInput = DrivingInput() }
        if !isPaused && hasStarted && serviceRemaining > 0 {
            drivingInput = DrivingInput()
            let steps = controlClock.advance(at:now,to:drivingInput).count
            for _ in 0..<steps {
                if isPaused || serviceRemaining == 0 { break }
                simulatePitService(controlClock.step)
                physicsSteps += 1
            }
        } else if !isPaused && hasStarted {
            if let speed = cooldownSpeed {
                let limit = ComputerDriver.cooldownLimit(from:speed,elapsed:dt,target:ComputerDriver.playerCooldownTargetSpeed)
                cooldownSpeed = limit
                drivingInput = ComputerDriver.input(for:vehicle,at:location,circuit:circuit,line:world.racingLine,
                    pace:0.72,traffic:traffic.cars.map(\.vehicle),brakeCurve:assists.brakeCurve,
                    steeringCurve:assists.steeringCurve,maximumSpeed:limit)
            } else if autoDriveEnabled && (ComputerDriver.wantsControl(drivingInput) || input.keyboard.hasPendingPress) {
                autoDriveEnabled = false
                announce("已接管车辆", duration: 2)
            }
            let automation = autoDriveEnabled || cooldownSpeed != nil
            if autoDriveEnabled && cooldownSpeed == nil {
                if ComputerDriver.canDrive(vehicle, at: location, on: circuit) {
                    drivingInput = ComputerDriver.input(for: vehicle, at: location, circuit: circuit,
                        line:world.racingLine,pace:0.82,traffic:traffic.cars.map(\.vehicle),brakeCurve:assists.brakeCurve,
                        steeringCurve:assists.steeringCurve)
                } else {
                    autoDriveEnabled = false
                    drivingInput = DrivingInput(brake: 1)
                    announce("自动驾驶已退出 · 请对准赛道方向", duration: 3)
                }
            }
            let batch = controlClock.advance(at:now,to:drivingInput)
            drivingElapsed = batch.elapsed
            let manual = !automation && !wasPaused && sprint?.playerDone != true
            if manual && batch.elapsed == 0 { input.keyboard.rebase(at:now,holding:input.keys) }
            for index in 0..<batch.count {
                if isPaused { break }
                let analog = batch[index]
                drivingInput = manual
                    ? input.keyboard.sample(over:analog,ending:batch.stepEnd(index,at:now),step:controlClock.step)
                    : analog
                simulate(controlClock.step,input:drivingInput)
                physicsSteps += 1
            }
            if manual && batch.count == 0 { drivingInput = input.keyboard.current(over:drivingInput) }
        } else { controlClock.reset() }
        if noticeRemaining > 0 { noticeRemaining -= dt }
        let driving = hasStarted && !isPaused && serviceRemaining == 0 && (sprint?.countdown ?? 0) == 0
        let playerDriving = driving && sprint?.playerDone != true && rollingCountdown == 0
        inputHistory.update(input:drivingInput,absActive:vehicle.absActive,dt:drivingElapsed,active:playerDriving,
                            linePressure:vehicle.brakeLinePressure)
        let refreshPeripherals = peripheralCadence.take(at:now,interval:1/Double(Self.peripheralRate))
        if refreshPeripherals {
            let peripheralDT = clamp(now-(lastPeripheralUpdate ?? now-dt),0,1.0/15)
            lastPeripheralUpdate = now
            let adjacent = driving ? SideTraffic(player:vehicle,opponents:traffic.cars) : SideTraffic()
            sideTraffic = sideTrafficHold.update(adjacent,dt:peripheralDT,active:driving)
            impactFeedback *= exp(-peripheralDT*12)
            let signal = feedback.update(vehicle:vehicle,input:drivingInput,impact:impactFeedback,dt:peripheralDT,
                                         active:playerDriving && input.hapticsAvailable)
            input.updateHaptics(signal,dt:peripheralDT,driving:playerDriving)
        }
        let running = hasStarted && !isPaused
        let continuous = running && renderingRate == .hz120
        if sceneView.isPlaying != running {
            sceneView.isPlaying = running
            sceneDirty = true
        }
        if sceneView.rendersContinuously != continuous {
            sceneView.rendersContinuously = continuous
            sceneDirty = true
        }
        let present = (sceneDirty || running) && sceneCadence.take(at:now,interval:1/Double(renderingRate.rawValue),forced:sceneDirty)
        let opponents = hasStarted && (present || refreshPeripherals) ? traffic.cars.map(\.vehicle) : []
        if present {
            recordTrackDrying()
            let presentationDT = clamp(now-(lastSceneUpdate ?? now-dt),0,1.0/15)
            world.advanceTrackDryingDisplay(presentationDT)
            lastSceneUpdate = now
            let ghost = ghostEnabled && hasStarted && sprint == nil && lesson == nil && qualifying == nil ? session.liveGhost : nil
            let displayCar = running && serviceRemaining == 0 && (sprint?.countdown ?? 0) == 0 && rollingCountdown == 0
                ? previousVehicle.map { vehicle.displayPose(previous:$0,fraction:controlClock.displayRemainder/controlClock.step) } ?? vehicle : vehicle
            let displayTraffic = driving ? traffic.displayVehicles(remainder:controlClock.displayRemainder) : opponents
            world.updateTraffic(displayTraffic)
            world.updateSpray(player:displayCar,opponents:displayTraffic,cockpit:cockpit,active:driving)
            world.setStartLights(countdown:sprint?.countdownSeconds)
            if driving { world.updateTyreMarks(vehicle:displayCar,dt:presentationDT) }
            world.sideLook = showingSeatPreview ? 0 : input.sideLook
            let renderView: DrivingView = showingSeatPreview ? .cockpit : (hasStarted ? drivingView : .chase)
            world.update(vehicle:displayCar,input:drivingInput,dt:presentationDT,cockpit:renderView.isInterior,
                         ghost:showingSeatPreview ? nil : ghost,view:renderView)
            if !showingSeatPreview { updateMenuCamera() }
            if !continuous { sceneView.requestFrame() }
            sceneDirty = false
        }
        if refreshPeripherals {
            let audible = hasStarted && !isPaused && serviceRemaining == 0
            let rollingSignal = rollingCountdown > 0 ? Int(ceil(rollingCountdown)) : (rollingGo > 0 ? 4 : 0)
            let raceSignal = sprint.map { $0.showGo ? 4 : $0.countdownSeconds } ?? rollingSignal
            publishDrivingSound(vehicle:vehicle,rivals:opponents,camera:world.camera,inCabin:cockpit,active:audible,signal:raceSignal)
            if let contact = pendingContact, audible { playContact(contact,camera:world.camera,cockpit:cockpit) }
            pendingContact = nil
            updateMirror(at:now)
        }
        renderClock += dt
        if renderClock >= 1.0 / 30 {
            renderClock.formTruncatingRemainder(dividingBy: 1.0 / 30)
            if hasStarted && !isPaused && serviceRemaining == 0 {
                gTrace.append(vehicle.driverG)
                if gTrace.count > 45 { gTrace.removeFirst(gTrace.count - 45) }
            }
            let controllerChanged = hudControllerName != input.controllerName || hudHapticStatus != input.hapticStatus
            let noticeVisible = noticeRemaining > 0
            if running || (showingControllerReview && input.controller != nil) || controllerChanged || hudNoticeVisible != noticeVisible {
                hud.needsDisplay = true
            }
            hudControllerName = input.controllerName
            hudHapticStatus = input.hapticStatus
            hudNoticeVisible = noticeVisible
        }
        if let observer = inspectDrivingTick {
            observer(DrivingTick(timestamp:now,processingTime:ProcessInfo.processInfo.systemUptime-now,
                                 physicsSteps:physicsSteps,sceneUpdated:present))
        }
    }

    func viewportChanged() {
        sceneDirty = true
        hud.needsDisplay = true
    }

    private func publishDrivingSound(vehicle: Vehicle,rivals: [Vehicle],camera: SCNNode,inCabin: Bool,
                                     active: Bool,signal: Int = 0,recorded: RaceReplay.Frame? = nil) {
        let right = camera.simdWorldRight
        let ear = camera.simdWorldPosition
        let earRight = SIMD2(Double(right.x),Double(right.z))
        let earPosition = SIMD2(Double(ear.x),Double(ear.z))
        let fixedCamera = recorded != nil && replayView == .trackside
        let earVelocity: SIMD2<Double> = fixedCamera ? .zero : vehicle.velocity
        let ray = vehicle.position-earPosition
        let doppler = fixedCamera ? OpponentMotor.doppler(along:ray/max(1,simd_length(ray)),
                                                         source:vehicle.velocity,listener:earVelocity) : 1
        let localEar = world.car.simdConvertPosition(ear,from:nil)
        let localRight = world.car.simdConvertVector(right,from:nil)
        let perspective = VehicleSoundPerspective(kind:vehicle.kind,localEar:SIMD3<Double>(localEar),
                                                   localRight:SIMD3<Double>(localRight),cockpit:inCabin,doppler:doppler)
        let voices: [OpponentMotor] = active ? rivals.enumerated().map { index,opponent in
            var source = OpponentMotor.relative(to:vehicle,opponent:opponent,listenerRight:earRight,
                                                listenerPosition:earPosition,listenerVelocity:earVelocity,
                                                recordedTyres:recorded?.rivalAudio[index].tyres)
            if let audio = recorded?.rivalAudio[index] {
                source.powertrain = audio.powertrain
                source.throttle = audio.throttle
                source.ignition = audio.ignition
            }
            return source
        } : []
        var road = recorded?.playerRoad ?? RoadSound(vehicle:vehicle)
        road.placeSources(for:vehicle,at:earPosition,right:earRight)
        let audio = recorded?.playerAudio
        sound.update(rpm:vehicle.rpm,throttle:audio?.throttle ?? vehicle.engineThrottle,
                     ignition:audio?.ignition ?? vehicle.ignitionFraction,powertrain:audio?.powertrain ?? vehicle.powertrainSound,
                     perspective:perspective,cockpit:inCabin,kerb:road.kerbIntensity,roadSpeed:vehicle.speed,
                     roadSound:road,spray:vehicle.wheels.map(\.spray).max() ?? 0,
                     kind:vehicle.kind,opponents:voices,raceSignal:signal,paused:!active)
    }

    private func playContact(_ contact: ContactSound,camera: SCNNode,cockpit: Bool) {
        let ear = camera.simdWorldPosition, right = camera.simdWorldRight
        sound.playContact(contact,listenerPosition:SIMD2(Double(ear.x),Double(ear.z)),
                          listenerRight:SIMD2(Double(right.x),Double(right.z)),cockpit:cockpit)
    }

    private func registerImpact(_ speed: Double,normal: SIMD2<Double>,point: SIMD2<Double>,dt: Double) {
        vehicle.impact(normalSpeed:speed,outwardNormal:normal)
        let strength = clamp(speed/12,0,1), side = simd_dot(normal,vehicle.modelX)
        impactFeedback = SIMD2(strength*(side < -0.2 ? 0.25 : 1),strength*(side > 0.2 ? 0.25 : 1))
        let contact = ContactSound(closingSpeed:speed,position:point)
        pendingContact = contact
        if let race = sprint, activeRaceID != nil {
            raceReplay.recordContact(contact,at:race.elapsed+classifiedRolloutTime+dt)
        }
    }

    private func updateMenuCamera() {
        if !hasStarted {
            world.frameMenuCar(vehicle,aspect:sceneView.bounds.width/max(1,sceneView.bounds.height))
        }
    }

    private func updateMirror(at now: Double) {
        guard mirrorSession else {
            if nextMirrorFrame != 0 {
                for mirror in VehicleMirror.allCases { world.setMirrorImage(nil,for:mirror) }
            }
            mirrorImage = nil
            nextMirrorFrame = 0
            mirrorSequenceIndex = 0
            focusedMirror = nil
            mirrorCost = 0
            return
        }
        let glance = input.sideLook
        let looking: VehicleMirror = glance < 0 ? .left : .right
        let threshold = focusedMirror == looking ? 0.16 : 0.25
        let focus = abs(glance) > threshold && world.hasMirror(looking) ? looking : nil
        if focus != focusedMirror {
            focusedMirror = focus
            mirrorSequenceIndex = 0
            nextMirrorFrame = now
        }
        guard now >= nextMirrorFrame, !mirrorInFlight else { return }
        let sequence = VehicleMirror.refreshOrder(focused:focus)
        let views = sequence.filter { mirror in
            if replay?.isPlaying == false && !replayMirrorsPending.contains(mirror) { return false }
            return world.hasMirror(mirror) || (mirror == .centre && showMirror)
        }
        guard !views.isEmpty else { return }
        let mirror = views[mirrorSequenceIndex % views.count]
        mirrorSequenceIndex = (mirrorSequenceIndex+1) % views.count
        if mirrorRenderer == nil {
            guard let device = sceneView.device ?? MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else { return }
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = world.scene
            mirrorQueue = queue
            mirrorRenderer = renderer
        }
        if mirrorPasses[mirror] == nil, let device = mirrorQueue?.device {
            mirrorPasses[mirror] = Self.makeMirrorPass(device:device,size:mirror.size)
        }
        guard let renderer = mirrorRenderer, let pass = mirrorPasses[mirror],
              let texture = pass.colorAttachments[0].texture,
              let command = mirrorQueue?.makeCommandBuffer() else { return }
        mirrorInFlight = true
        renderer.pointOfView = world.camera(for:mirror)
        let width = texture.width, height = texture.height
        let sourceWorld = world
        let sourceKind = vehicle.kind
        let revision = mirrorRevision
        let encodeStart = ProcessInfo.processInfo.systemUptime
        renderer.render(atTime:now,viewport:CGRect(x:0,y:0,width:width,height:height),commandBuffer:command,passDescriptor:pass)
        let encodeTime = ProcessInfo.processInfo.systemUptime-encodeStart
        mirrorCost += (encodeTime-mirrorCost)*0.20
        let rate = focus == nil ? 30.0 : 36.0
        nextMirrorFrame = now + clamp(mirrorCost*7,1/rate,1.0/14)
        command.addCompletedHandler { [weak self, weak renderer] completed in
            let image: CGImage? = completed.status == .completed ? sceneTextureImage(texture) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.mirrorInFlight = false
                guard let image, let renderer, self.mirrorSession, self.mirrorRenderer === renderer,
                      self.world === sourceWorld, self.vehicle.kind == sourceKind,
                      self.mirrorRevision == revision else { return }
                self.replayMirrorsPending.remove(mirror)
                self.world.setMirrorImage(image,for:mirror)
                if mirror == .centre {
                    self.mirrorImage = NSImage(cgImage:image,size:NSSize(width:width,height:height))
                }
                if self.replay != nil { self.sceneView.requestFrame() }
            }
        }
        command.commit()
    }

    private static func makeMirrorPass(device: MTLDevice,size: (width: Int,height: Int)) -> MTLRenderPassDescriptor? {
        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:size.width,height:size.height,mipmapped:false)
        color.usage = .renderTarget
        color.storageMode = .shared
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:size.width,height:size.height,mipmapped:false)
        depth.usage = .renderTarget
        depth.storageMode = .private
        guard let texture = device.makeTexture(descriptor:color), let depthTexture = device.makeTexture(descriptor:depth) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        return pass
    }

    private func simulate(_ dt: Double,input controls: DrivingInput) {
        if rollingCountdown > 0 {
            rollingCountdown = max(0,rollingCountdown-dt)
            if rollingCountdown < 1e-6 { rollingCountdown = 0; rollingGo = 0.75 }
            return
        }
        rollingGo = max(0,rollingGo-dt)
        if let race = sprint, race.countdown > 0 {
            sprint?.advanceCountdown(dt)
            return
        }
        previousVehicle = vehicle.renderSample
        location = circuit.nearest(to: vehicle.position)
        let contacts = circuit.wheelContacts(at:vehicle.contactPoints,drying:trackDrying)
        var activeAssists = assists
        if let lesson {
            activeAssists = lesson.kind.assists
            activeAssists.brakeCurve = assists.brakeCurve
            activeAssists.steeringCurve = assists.steeringCurve
        }
        if autoDriveEnabled || cooldownSpeed != nil {activeAssists.automatic = true}
        let pitTarget = pitLimiterEnabled ? circuit.pitLane.targetSpeed(at:location) : nil
        let command = pitTarget.map {
            pitLimitedInput(controls,speed:vehicle.speed,curve:assists.brakeCurve,limit:$0)
        } ?? controls
        vehicle.step(dt,input:command,assists:activeAssists,roadDistance:location.distance,roadWidth:circuit.width,
                     roadLateral:location.lateral,roadProgress:location.progress,kerbsEnabled:circuit.hasKerb(at:location.progress),
                     roadContacts:contacts,wake:AirWake.behind(vehicle,leaders:traffic.cars.map(\.vehicle)))
        collisionCooldown = max(0, collisionCooldown - dt)
        if let contact = traffic.step(dt,player:&vehicle,circuit:circuit,line:world.racingLine,drying:trackDrying,race:sprint),
           contact.closingSpeed > 1.5, collisionCooldown <= 0 {
            registerImpact(contact.closingSpeed,normal:contact.normal,point:contact.point,dt:dt)
            collisionCooldown = 0.4
            announce("与电脑车辆接触", duration: 2)
        }
        location = circuit.nearest(to: vehicle.position)
        if let contact = vehicle.constrainToGuardRail(at:location) {
            location = circuit.nearest(to:vehicle.position)
            let normal = contact.normal, impact = contact.closingSpeed
            if impact > 1.5 {
                if collisionCooldown <= 0 {
                    registerImpact(impact,normal:normal,point:contact.point,dt:dt)
                }
                collisionCooldown = 0.4
                announce(sprint == nil ? "碰撞损伤 · R 复位保留车损 · Shift+P 拖车" : "碰撞损伤 · 可从暂停菜单重新发车",duration:3)
            }
        }
        let onLane = circuit.pitLane.contains(location)
        if onLane != inPitLane {
            inPitLane = onLane
            if sprint == nil && lesson == nil && qualifying == nil { session.beginOutLap(at:location.progress) }
            if onLane { autoDriveEnabled = false }
            if sprint == nil && lesson == nil && qualifying == nil {
                announce(onLane ? "维修道 · 限速 60 km/h · 黄框停车后按 P" : "驶出维修道 · 出场圈",duration:3)
            } else if onLane && sprint != nil {
                announce("维修道 · 限速 60 km/h · 黄框停稳后按 P",duration:3)
            }
        }
        let timedDriving = sprint?.playerDone == false || (qualifying != nil && qualifying?.result == nil)
        wrongWay.update(dt,vehicle:vehicle,location:location,circuit:circuit,active:timedDriving)
        if lesson != nil {
            lesson?.step(dt,vehicle:vehicle,input:command,location:location,circuit:circuit)
            if let completed = lesson, let outcome = completed.result { completeLesson(completed,outcome:outcome) }
        } else if qualifying != nil {
            if qualifying?.step(dt,vehicle:vehicle,location:location,circuit:circuit,
                                assisted:autoDriveEnabled,input:command) == true {
                completeQualifying()
            }
        } else if sprint != nil {
            advanceTrackDrying(dt,includePlayer:true)
            updateRaceTiming(dt)
        } else if !inPitLane && session.step(dt, vehicle: vehicle, location: location, trackLength: circuit.length,
            trackWidth: circuit.width, assisted: autoDriveEnabled, input: controls) {
            if let lap = session.analysedLap { analysis[recordKey, default: PracticeAnalysis()].append(lap) }
            if session.newBest {
                announce("个人最佳  \(lapTime(session.best))  ·  幽灵车已更新", duration: 6)
            } else { announce((session.lastValid ? "完成有效圈  " : "本圈无效 · 不计入最佳  ")+lapTime(session.last), duration:5) }
            if session.newBest || session.analysedLap != nil { savePractice(background:true) }
        }
        recordTelemetry(dt,input:controls,command:command,drivingAssists:activeAssists)
    }

    private func simulatePitService(_ dt: Double) {
        var parked = vehicle
        _ = traffic.step(dt,player:&parked,circuit:circuit,line:world.racingLine,drying:trackDrying,race:sprint)
        vehicle.coolStationaryBrakes(dt)
        serviceRemaining = max(0,serviceRemaining-dt)
        if serviceRemaining < 1e-6 {
            serviceRemaining = 0
            let title: String
            if let plan = activeRaceService {
                vehicle.completePitService(plan)
                racePitStops += 1
                title = plan.work.title
            } else {
                vehicle.service(setup:tyreSetup,preservingBrakeHeat:true)
                title = PitServiceWork.both.title
            }
            activeRaceService = nil
            let inGear = sprint != nil && assists.automatic
            if inGear { vehicle.gear = 1 }
            world.resetCamera()
            input.clear()
            let departure = inGear ? "轻踩油门驶出维修道" : "挂入 1 挡驶出维修道"
            announce(title+"完成 · "+departure,duration:5)
        }
        if sprint != nil {
            advanceTrackDrying(dt,includePlayer:false)
            updateRaceTiming(dt)
            recordTelemetry(dt,input:DrivingInput(),command:DrivingInput(),drivingAssists:assists)
        }
    }

    private func advanceTrackDrying(_ dt: Double,includePlayer: Bool) {
        guard trackDrying != nil else { return }
        dryingClock += dt
        let interval = TrackDrying.interval
        guard dryingClock+1e-9 >= interval else { return }
        dryingClock = max(0,dryingClock-interval)
        trackDrying?.advance(interval)
        func clearUnderTyres(_ car: Vehicle) {
            guard car.speed > 3 else { return }
            for (index,point) in car.contactPoints.enumerated() {
                let wheel = car.wheels[index]
                guard wheel.surface == .asphalt && wheel.normalLoad > 100 else { continue }
                let contact = circuit.nearest(to:point)
                if circuit.pitLane.hasAsphalt(at:contact) { continue }
                trackDrying?.displace(at:contact.progress,lateral:contact.lateral,travelled:car.speed*interval,
                                      speed:car.speed,load:wheel.normalLoad,treadWidth:car.kind.treadWidth[index/2])
            }
        }
        if includePlayer { clearUnderTyres(vehicle) }
        for rival in traffic.cars { clearUnderTyres(rival.vehicle) }
    }

    private func recordTrackDrying(final: Bool = false) {
        guard let trackDrying else { return }
        if let previous = dryingHistory.last?.elapsed {
            if trackDrying.elapsed <= previous {
                if final { displayTrackDrying(trackDrying,force:true) }
                return
            }
            if !final && trackDrying.elapsed-previous < 4 { return }
        }
        dryingHistory.append(trackDrying)
        while dryingHistory.count > 1 && dryingHistory[1].elapsed < trackDrying.elapsed-RaceReplay.durationLimit {
            dryingHistory.removeFirst()
        }
        displayTrackDrying(trackDrying,transitioning:!final)
    }

    private func displayTrackDrying(_ surface: TrackDrying?,transitioning: Bool = false,force: Bool = false) {
        guard force || surface?.elapsed != displayedDryingTime else { return }
        world.displayTrackDrying(surface,transitioning:transitioning)
        displayedDryingTime = surface?.elapsed
    }

    private func updateRaceTiming(_ dt: Double) {
        guard let race = sprint, activeRaceID != nil else { return }
        if race.playerFinished { finishRolloutRemaining = max(0,finishRolloutRemaining-dt) }
        if race.finished {
            classifiedRolloutTime += dt
            raceReplay.record(time:race.elapsed+classifiedRolloutTime,player:vehicle,rivals:traffic.cars.map(\.vehicle))
            if finishRolloutRemaining == 0 { completeRace() }
            return
        }
        let wasFinished = race.playerFinished
        let positions = [location] + traffic.cars.map { circuit.nearest(to: $0.vehicle.position) }
        let outside = [vehicle.allWheelsOutside] + traffic.cars.map { $0.vehicle.allWheelsOutside }
        let pitLane = circuit.pitLane
        for index in positions.indices {
            let pitLocation = positions[index]
            let speed = index == 0 ? vehicle.speed : traffic.cars[index-1].vehicle.speed
            let penalized = sprint?.observePitSpeed(dt,index:index,inLane:pitLane.contains(pitLocation),
                                                   limited:pitLane.isLimited(pitLocation),speed:speed) == true
            if index == 0 && penalized { announce("维修道限速违规 · 加罚 2 秒",duration:4) }
        }
        sprint?.step(dt,locations:positions,assisted:autoDriveEnabled,width:circuit.width,outside:outside)
        if let active = sprint {
            raceFlags.update(dt,player:vehicle,rivals:traffic.cars,locations:positions,circuit:circuit,
                             line:world.racingLine,race:active,
                             active:active.countdown == 0 && !active.showGo && !active.playerDone)
            if RaceFlags.phase(for:0,in:active) == .finalLap && RaceFlags.phase(for:0,in:race) != .finalLap {
                sound.playCue(.finalLap)
            }
        }
        if let elapsed = sprint?.elapsed {
            raceReplay.record(time:elapsed,player:vehicle,rivals:traffic.cars.map(\.vehicle))
        }
        if let updatedRace = sprint { traffic.startCooldown(forRivalsFinishedIn:updatedRace) }
        if !wasFinished && sprint?.playerFinished == true {
            finishRolloutRemaining = 1.65
            cooldownSpeed = max(ComputerDriver.playerCooldownTargetSpeed,vehicle.speed)
            autoDriveEnabled = false
            input.clear()
            sound.playCue(.checkered)
        }
        sprint?.closeOutStoppedRivals(dt,rivals:traffic.cars,locations:positions,circuit:circuit,
                                      finishRolloutComplete:finishRolloutRemaining == 0)
        if let updated = sprint, let checkered = updated.checkeredTime {
            if checkeredDeadline == nil {
                let lap = updated.longestCleanLap ?? circuit.length/15
                checkeredDeadline = checkered+clamp(lap*1.25,45,240)
            }
            if let checkeredDeadline, updated.elapsed >= checkeredDeadline { sprint?.finalizeUnfinished() }
        }
        if sprint?.finished == true && finishRolloutRemaining == 0 { completeRace() }
    }

    private func recordTelemetry(_ dt: Double,input controls: DrivingInput,command: DrivingInput,
                                 drivingAssists: DrivingAssists) {
        telemetryElapsed += dt
        telemetryClock += dt
        if telemetryClock + 1e-9 >= 0.1 && sprint?.finished != true {
            telemetryClock = max(0,telemetryClock-0.1)
            if telemetrySampleCount < 36000 {
                let profile = circuit.roadProfile(at:location.progress,lateral:location.lateral)
                let sample = TelemetrySample(lapTime:sprint?.elapsed ?? qualifying?.timing.elapsed ?? session.elapsed,
                    telemetryElapsed:telemetryElapsed,progress:location.progress,lateral:location.lateral,
                    raceLap:sprint.map { min($0.lapCount,($0.entries.first?.laps ?? 0)+1) } ?? session.lap,
                    validLap:sprint == nil && lesson == nil && qualifying == nil && session.validLap,
                    vehicle:vehicle,controls:controls,command:command,drivingAssists:drivingAssists,
                    circuit:circuit.kind,condition:circuit.condition,grade:profile.grade,crossfall:profile.crossfall)
                telemetrySampleCount += 1
                let recording = telemetry
                Self.persistenceQueue.async { autoreleasepool { recording.append(sample) } }
            }
        }
    }

    func captureFrame() {
        do {
            try FileManager.default.createDirectory(at:dataDirectory,withIntermediateDirectories:true)
            let image = sceneView.snapshot()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data:tiff),
                  let png = bitmap.representation(using:.png,properties:[:]) else { return }
            let url = dataDirectory.appendingPathComponent("driving-view.png")
            try png.write(to:url)
            announce("驾驶画面已保存 · driving-view.png",duration:3)
        } catch { announce("截图保存失败：\(error.localizedDescription)",duration:5) }
    }

    func action(_ action: String) {
        if isNavigatingMenu && ["menuUp","menuDown","menuLeft","menuRight","menuAccept","menuNext","menuPrevious"].contains(action) {
            if action == "menuAccept", !hud.activateMenuFocus() {
                if showcase == nil && settingsPage == nil && sessionPrompt == nil && garageSelection == nil && !showHelp && !showingAnalysis && !showingControllerReview { self.action("confirm") }
            } else if action != "menuAccept" { hud.moveMenuFocus(action) }
            return
        }
        if let showcase {
            if ["closeShowcase","menuBack","pause","showcaseUse"].contains(action) {
                self.showcase = nil
                showcaseError = nil
                sceneView.scene = world.scene
                sceneView.pointOfView = world.camera
                world.resetCamera()
                sceneDirty = true
                if action == "showcaseUse" {
                    garageSelection = nil
                    selectVehicle(showcase.kind)
                }
            } else if action == "showcasePrevious" || action == "showcaseNext" {
                let kind = showcase.kind.alternate
                do { try showcase.select(kind); showcaseError = nil }
                catch { showcaseError = "无法载入 "+kind.label+" 的展示模型" }
            } else if action == "showcaseCabinLight" {
                showcase.toggleCabinLight()
            } else if action == "showcaseAllPanels" {
                showcase.toggleAllPanels()
            } else if action == "camera" {
                showcase.nextView()
            } else if let value = action.components(separatedBy:":").last {
                if action.hasPrefix("showcasePanel:"), let panel = ShowcasePanel(rawValue:value) { showcase.toggle(panel) }
                if action.hasPrefix("showcaseLight:"), let lamp = VehicleShowcase.Lamp(rawValue:value) { showcase.toggle(lamp) }
                if action.hasPrefix("showcaseView:"), let view = VehicleShowcase.Viewpoint(rawValue:value) { showcase.setView(view) }
            }
            sceneView.requestFrame()
            hud.needsDisplay = true
            return
        }
        if replay != nil {
            switch action {
            case "closeReplay","pause","menuBack": closeReplay()
            case "replayPlay":
                let previous = replay?.time
                replay?.togglePlay()
                if replay?.time != previous { resetReplayCamera() }
                else if replayView == .cockpit && replay?.isPlaying == false {
                    replayMirrorsPending = Set(VehicleMirror.allCases)
                }
            case "replayEarlier","replayLater":
                replay?.skip(action == "replayEarlier" ? -5 : 5)
                resetReplayCamera()
            case "replayRate":
                if let current = replay?.rate { replay?.rate = current.next }
            case "replayCamera","camera":
                replayView = replayView.next
                resetReplayCamera()
            case "controllerDisconnected": replay?.isPlaying = false
            default: return
            }
            hud.needsDisplay = true
            return
        }
        if action == "openShowcase" {
            guard !hasStarted, settingsPage == nil, !showHelp, !showingAnalysis, !showingControllerReview else { return }
            guard let assets = Bundle.main.resourceURL?.appendingPathComponent("Assets") else { return }
            do {
                let gallery = try VehicleShowcase(kind:vehicle.kind,assetRoot:assets)
                showcase = gallery
                showcaseError = nil
                sceneView.isPlaying = false
                sceneView.rendersContinuously = false
                sceneView.scene = gallery.scene
                sceneView.pointOfView = gallery.camera
                sceneView.requestFrame()
            } catch { showcaseError = "无法载入车辆展示，请检查游戏素材。" }
            hud.needsDisplay = true
            return
        }
        if editingHUD && !["hudLayout","hudLayoutReset","cancelHUDLayout","pause","menuBack","controllerDisconnected"].contains(action) { return }
        if let choice = settingsChoice {
            if ["closeChoice","pause","menuBack","settings"].contains(action) {
                closeSettingsChoice(choice)
                return
            }
            if action.hasPrefix("setChoice:"), let index = Int(action.dropFirst("setChoice:".count)),
               choice.options.indices.contains(index) {
                applySettingsChoice(choice,index:index)
                closeSettingsChoice(choice)
                return
            }
            if action != "controllerDisconnected" { return }
        }
        if showingSeatPreview {
            switch action {
            case "seatPreview","pause","menuBack","settings":
                showingSeatPreview = false
                returningSettingsControl = "seatPreview"
                world.resetCamera()
                sceneDirty = true
                hud.needsDisplay = true
                return
            case "fovDown","fovUp","seatDown","seatUp","controllerDisconnected": break
            default: return
            }
        }
        if showingControllerReview {
            switch action {
            case "controllerReview", "pause", "confirm", "menuBack":
                showingControllerReview = false
                input.stopHaptics()
                settingsPage = calibrationReturnPage
                returningSettingsControl = settingsPage == .controller ? "controllerReview" : nil
                calibrationReturnPage = nil
            case "hapticTest", "hapticLevel", "hapticRoute", "deadzoneDown", "deadzoneUp",
                 "brakeCurve", "steeringCurve", "controllerDisconnected":
                break
            default: return
            }
            if !showingControllerReview { hud.needsDisplay = true; return }
        }
        if showingAnalysis {
            switch action {
            case "analysis", "pause", "confirm", "menuBack": showingAnalysis = false
            case "analysisZoom": hud.toggleAnalysisZoom()
            case "analysisPage": analysisPage = (analysisPage + 1) % 2
            case "controllerDisconnected": autoDriveEnabled = false
            default: return
            }
            hud.needsDisplay = true
            return
        }
        if showHelp {
            switch action {
            case "help", "pause", "confirm", "menuBack":
                showHelp = false
                hud.needsDisplay = true
                return
            case "controllerDisconnected": break
            default: return
            }
        }
        if let prompt = sessionPrompt {
            if prompt == .pit, action.hasPrefix("pitWork:") {
                guard serviceRemaining == 0, plannedRaceTyres != nil,
                      let work = PitServiceWork(rawValue:String(action.dropFirst("pitWork:".count))) else { return }
                plannedRaceWork = work
                hud.needsDisplay = true
                return
            }
            if prompt == .pit, action.hasPrefix("pitTyres:") {
                guard serviceRemaining == 0, plannedRaceWork.changesTyres, var plan = plannedRaceTyres else { return }
                let change = String(action.dropFirst("pitTyres:".count))
                if change == "down" || change == "up" {
                    let increment = change == "up" ? 0.05 : -0.05
                    plan.coldPressure = clamp(plan.coldPressure+increment,1.3,2.1)
                } else if let value = Int(change), let compound = TyreCompound(rawValue:value) {
                    plan.compound = compound
                } else { return }
                plannedRaceTyres = plan
                hud.needsDisplay = true
                return
            }
            switch action {
            case "pause", "menuBack", "cancelPrompt":
                sessionPrompt = nil; hud.needsDisplay = true; return
            case "confirmPrompt":
                guard prompt != .pit else { return }
                sessionPrompt = nil
                switch prompt {
                case .restart: self.action("restart")
                case .leave:
                    if let series = activeCup?.series {
                        self.action("leaveSprint")
                        selectedCup = series
                        self.action("cups")
                    } else {
                        self.action(sprint == nil ? "leavePractice" : "leaveSprint")
                    }
                case .retire: self.action("retireSprint")
                case .pit: break
                }
                return
            case "service", "tow":
                guard prompt == .pit else { return }
                sessionPrompt = nil
            case "controllerDisconnected": break
            default: return
            }
        }
        if let selection = garageSelection {
            if ["menuBack","pause","closeGarage"].contains(action) {
                garageSelection = nil; hud.needsDisplay = true; return
            }
            if selection == .vehicles, action.hasPrefix("car:"),
               let raw = Int(action.dropFirst(4)), let kind = VehicleKind(rawValue:raw) {
                garageSelection = nil
                selectVehicle(kind)
                hud.needsDisplay = true; return
            }
            if selection == .circuits, action.hasPrefix("circuit:"),
               let raw = Int(action.dropFirst(8)), let kind = CircuitKind(rawValue:raw) {
                garageSelection = nil
                selectCircuit(kind,condition:circuit.condition)
                hud.needsDisplay = true; return
            }
            if action != "controllerDisconnected" { return }
        }
        if reviewedRaceLaps != nil {
            if ["closeRaceLaps","pause","menuBack"].contains(action) {
                reviewedRaceLaps = nil
                hud.needsDisplay = true
                return
            }
            if action != "controllerDisconnected" { return }
        }
        if showingRaceHistory {
            if ["closeRaceHistory","pause","menuBack"].contains(action) {
                showingRaceHistory = false
                hud.needsDisplay = true
                return
            }
            if action == "raceHistoryPrevious" || action == "raceHistoryNext" {
                guard !showingPracticeBests else { return }
                let lastPage = max(0,(raceRecords.count-1)/RaceRecord.pageSize)
                raceHistoryPage = clamp(raceHistoryPage+(action == "raceHistoryNext" ? 1 : -1),0,lastPage)
                hud.needsDisplay = true
                return
            }
            if action == "historyRaces" || action == "historyBests" {
                showingPracticeBests = action == "historyBests"
                hud.needsDisplay = true
                return
            }
            if !showingPracticeBests, action.hasPrefix("viewRaceLaps:"),
               let id = UUID(uuidString:String(action.dropFirst("viewRaceLaps:".count))),
               let record = raceRecords.first(where:{ $0.id == id && $0.lapHistory?.isEmpty == false }) {
                reviewedRaceLaps = record
                hud.needsDisplay = true
                return
            }
            if showingPracticeBests {
                switch action {
                case "bestsPreviousCar", "bestsNextCar":
                    let cars = VehicleKind.allCases
                    let index = cars.firstIndex(of:bestsVehicle) ?? 0
                    let offset = action == "bestsNextCar" ? 1 : -1
                    bestsVehicle = cars[(index+offset+cars.count)%cars.count]
                    bestsShowsLegacyPorsche = false
                    hud.needsDisplay = true
                    return
                case "bestsDry", "bestsWet":
                    bestsCondition = action == "bestsDry" ? .dry : .wet
                    bestsShowsLegacyPorsche = false
                    hud.needsDisplay = true
                    return
                case "bestsPorscheSpecification":
                    if hasLegacyPorscheBests { bestsShowsLegacyPorsche.toggle() }
                    hud.needsDisplay = true
                    return
                default: break
                }
            }
            if action != "controllerDisconnected" { return }
        }
        if showingRaceSetup {
            if ["closeRaceSetup","pause","menuBack"].contains(action) {
                showingRaceSetup = false
                hud.needsDisplay = true
                return
            }
            if action.hasPrefix("raceOption:") {
                applyRaceOption(String(action.dropFirst("raceOption:".count)))
                hud.needsDisplay = true
                return
            }
            guard ["startSprint","selectVehicle","selectCircuit","trackCondition","controllerDisconnected"].contains(action) else { return }
        }
        if showingCupMenu {
            if ["closeCupMenu","pause","menuBack"].contains(action) {
                showingCupMenu = false
                hud.needsDisplay = true
                return
            }
            if action.hasPrefix("cup:"),
               let series = CupSeries(rawValue:String(action.dropFirst("cup:".count))) {
                selectedCup = series
                hud.needsDisplay = true
                return
            }
            guard ["startCupRound","startNewCup","controllerDisconnected"].contains(action) else { return }
        }
        if showingSchool {
            if ["closeSchool","pause","menuBack"].contains(action) {
                showingSchool = false
                hud.needsDisplay = true
                return
            }
            if action.hasPrefix("lesson:"),
               let kind = DrivingLessonKind(rawValue:String(action.dropFirst("lesson:".count))) {
                selectedLesson = kind
                hud.needsDisplay = true
                return
            }
            guard ["startLesson","controllerDisconnected"].contains(action) else { return }
        }
        if let reset = settingsReset {
            switch action {
            case "cancelSettingsReset","pause","menuBack","settings":
                settingsReset = nil; returningSettingsControl = settingsResetAction(reset); hud.needsDisplay = true; return
            case "confirmSettingsReset":
                settingsReset = nil
                returningSettingsControl = settingsResetAction(reset)
                resetSettings(reset)
                hud.needsDisplay = true
                return
            case "controllerDisconnected": break
            default: return
            }
        }
        if settingsPage != nil {
            if ["settings","pause","confirm","menuBack"].contains(action) {
                settingsPage = nil; returningSettingsControl = nil; settingsStatus = nil
                input.stopHaptics(); hud.needsDisplay = true; return
            }
            if action.hasPrefix("choice:"),
               let choice = SettingsChoice(rawValue:String(action.dropFirst("choice:".count))) {
                guard settingsPage == choice.page, choice != .tyres || canPlanTyres else { return }
                returningSettingsControl = nil
                settingsChoice = choice; hud.needsDisplay = true; return
            }
            if action.hasPrefix("settings:"),
               let page = SettingsPage(rawValue:String(action.dropFirst("settings:".count))) {
                settingsPage = page; hud.needsDisplay = true; return
            }
            let allowed = ["automatic","abs","tc","brakeBiasDown","brakeBiasUp","brakeCurve","steeringCurve","compound",
                           "pressureDown","pressureUp","deadzoneDown","deadzoneUp","hapticLevel","hapticTest","controllerReview",
                           "graphicsQuality","mirror","racingLine","compactHUD","hud","camera","cameraPrevious","fovDown",
                           "fovUp","seatUp","seatDown","hudLayout","mute","ghost","pitLimiter","autoDrive","controllerDisconnected",
                           "masterDown","masterUp","motorDown","motorUp","effectsDown","effectsUp","renderingRate",
                           "resetAudioSettings","resetControllerSettings","resetDisplaySettings","seatPreview"]
            guard allowed.contains(action) else { return }
        }
        sceneDirty = true
        switch action {
        case "selectVehicle", "selectCircuit":
            guard !hasStarted && isPaused else { return }
            garageSelection = action == "selectVehicle" ? .vehicles : .circuits
        case "askRestart", "askLeavePractice", "pitMenu", "askRetireRace":
            guard isPaused && hasStarted && (action != "pitMenu" || canPitService) else { return }
            if action == "askRetireRace" {
                guard sprint?.playerDone == false else { return }
                sessionPrompt = .retire
            } else {
                sessionPrompt = action == "pitMenu" ? .pit : (action == "askRestart" ? .restart : .leave)
            }
        case "raceSetup":
            guard !hasStarted && isPaused else { return }
            showingRaceSetup = true
        case "raceHistory":
            guard !hasStarted || raceResultReady else { return }
            raceHistoryPage = 0
            showingPracticeBests = false
            bestsShowsLegacyPorsche = false
            bestsVehicle = vehicle.kind
            bestsCondition = circuit.condition
            showingRaceHistory = true
        case "raceLaps":
            guard raceResultReady, let record = raceRecords.first, record.lapHistory?.isEmpty == false else { return }
            reviewedRaceLaps = record
        case "cups":
            guard !hasStarted && isPaused else { return }
            showingCupMenu = true
        case "startCupRound":
            guard showingCupMenu && !hasStarted else { return }
            startCupRound(selectedCup)
        case "startNewCup":
            guard showingCupMenu && !hasStarted &&
                  cupProgress(selectedCup).records.count == selectedCup.rounds.count else { return }
            cups[selectedCup]?.startNewRun()
            savePractice()
        case "cupContinue":
            guard let entry = activeCup, isPaused, raceResultReady else { return }
            self.action("leaveSprint")
            selectedCup = entry.series
            self.action("cups")
        case "school":
            guard !hasStarted && isPaused else { return }
            showingSchool = true
        case "startLesson":
            guard showingSchool && !hasStarted else { return }
            startLesson(selectedLesson)
        case "lessonRetry":
            guard isPaused, let lesson else { return }
            startLesson(lesson.kind)
        case "lessonNext":
            guard let lesson, isPaused, case .some(.passed) = lesson.result,
                  let index = DrivingLessonKind.allCases.firstIndex(of:lesson.kind) else { return }
            let next = index+1
            if DrivingLessonKind.allCases.indices.contains(next) { startLesson(DrivingLessonKind.allCases[next]) }
            else { leaveLesson() }
        case "leaveLesson":
            guard isPaused && lesson != nil else { return }
            leaveLesson()
        case "settings":
            if hasStarted && !isPaused { saveTelemetry() }
            isPaused = true
            input.clear()
            settingsStatus = nil
            settingsPage = .driving
        case "seatPreview":
            guard settingsPage == .display else { return }
            showingSeatPreview = true
            world.resetCamera()
        case "resetAudioSettings","resetControllerSettings","resetDisplaySettings":
            guard settingsPage != nil else { return }
            settingsReset = action == "resetAudioSettings" ? .audio : (action == "resetControllerSettings" ? .controller : .display)
        case "graphicsQuality":
            guard isPaused else { return }
            graphicsQuality = GraphicsQuality(rawValue:(graphicsQuality.rawValue+1)%GraphicsQuality.allCases.count) ?? .quality
            applyGraphicsQuality()
            savePractice()
        case "renderingRate":
            guard isPaused else { return }
            renderingRate = renderingRate.next
            applyGraphicsQuality()
            savePractice()
        case "controllerReview":
            guard isPaused else { return }
            calibrationReturnPage = settingsPage
            settingsPage = nil
            input.resetDiagnostics()
            showingControllerReview = true
        case "analysis":
            guard !editingHUD, sprint == nil, lesson == nil, qualifying == nil else { return }
            isPaused = true
            showingAnalysis = true
            analysisPage = 0
            input.clear()
            saveTelemetry()
        case "service", "tow":
            guard canPitService && serviceRemaining == 0 && (action != "tow" || sprint == nil) else { return }
            let lane = circuit.pitLane
            let contact = circuit.nearest(to:vehicle.position)
            if action == "service" {
                guard lane.inServiceBox(contact) && vehicle.speed < 0.55 else {
                    announce(sprint == nil ? "请在维修黄框内停稳 · Shift+P 拖车" : "请在维修黄框内停稳",duration:3)
                    return
                }
            }
            let plan = plannedRaceStop
            if sprint != nil {
                guard let plan, plan.duration > 0 else {
                    announce("当前车辆无需维修",duration:3)
                    return
                }
            }
            saveTelemetry()
            let sample = action == "tow" ? lane.serviceSample(on:circuit) :
                TrackSample(point:vehicle.position,tangent:vehicle.forward,distance:contact.progress)
            vehicle.reset(at:sample,preservingCondition:true)
            activeRaceService = plan
            world.breakTyreMarkStreaks()
            previousVehicle = nil
            vehicle.gear = 0
            location = circuit.nearest(to:vehicle.position)
            inPitLane = true
            if sprint == nil { session.beginOutLap(at:location.progress) }
            gTrace.removeAll(keepingCapacity:true)
            inputHistory.reset()
            autoDriveEnabled = false
            serviceRemaining = plan?.duration ?? PitServicePlan.tyreDuration
            noticeRemaining = 0
            collisionCooldown = 0
            controlClock.reset()
            isPaused = false
            showHelp = false
            input.clear()
            world.resetCamera()
        case "mirror":
            mirrorEnabled.toggle()
            savePractice()
        case "pitLimiter":
            pitLimiterEnabled.toggle()
            savePractice()
            announce(pitLimiterEnabled ? "维修道限速开启 · 60 km/h" : "维修道限速关闭",duration:2)
        case "vehicleNext", "vehiclePrevious":
            guard isPaused && serviceRemaining == 0 && sprint == nil && lesson == nil && qualifying == nil else { return }
            selectVehicle(vehicle.kind.alternate)
        case "trackNext", "trackPrevious":
            guard isPaused && serviceRemaining == 0 && sprint == nil && lesson == nil && qualifying == nil else { return }
            let count = CircuitKind.allCases.count
            let shift = action == "trackNext" ? 1 : -1
            selectCircuit(CircuitKind(rawValue:(circuit.kind.rawValue+count+shift)%count)!,condition:circuit.condition)
        case "trackCondition":
            guard isPaused && serviceRemaining == 0 && sprint == nil && lesson == nil && qualifying == nil else { return }
            let next: TrackCondition = circuit.condition == .dry ? .wet : .dry
            selectCircuit(circuit.kind,condition:next)
        case "compound":
            guard canPlanTyres && isPaused else { return }
            tyreSetup.compound = TyreCompound(rawValue: (tyreSetup.compound.rawValue + 1) % TyreCompound.allCases.count)!
            savePractice()
        case "pressureDown", "pressureUp":
            guard canPlanTyres && isPaused else { return }
            tyreSetup.coldPressure = clamp(tyreSetup.coldPressure + (action == "pressureUp" ? 0.05 : -0.05), 1.3, 2.1)
            savePractice()
        case "hudLayout","cancelHUDLayout":
            guard hasStarted && (editingHUD || (sprint?.playerDone != true && lesson?.result == nil && qualifying?.result == nil)) else { return }
            if editingHUD {
                if action == "cancelHUDLayout" { hudPositions = hudLayoutBeforeEdit }
                editingHUD = false
                isPaused = action == "cancelHUDLayout" || !resumeAfterHUDEdit
                settingsPage = hudEditReturnPage
                returningSettingsControl = hudEditReturnPage == nil ? nil : "hudLayout"
                hudEditReturnPage = nil
                hudLayoutBeforeEdit.removeAll()
                if action == "hudLayout" { savePractice() }
            } else {
                guard action == "hudLayout" else { return }
                hudLayoutBeforeEdit = hudPositions
                hudEditReturnPage = settingsPage
                settingsPage = nil
                resumeAfterHUDEdit = !isPaused
                if !isPaused { saveTelemetry() }
                isPaused = true
                editingHUD = true
            }
            input.clear()
            hud.layoutModeChanged()
        case "hudLayoutReset":
            guard editingHUD else { return }
            for key in hud.editablePanelKeys { hudPositions.removeValue(forKey:key) }
        case "opponents":
            guard isPaused && sprint == nil && lesson == nil && qualifying == nil else { return }
            opponentCount = (opponentCount + 1) % 4
            traffic.reset(count: opponentCount, kind: vehicle.kind, circuit: circuit, from: location.progress)
            savePractice()
        case "autoDrive":
            guard sprint?.playerDone != true && lesson == nil && qualifying?.result == nil else { return }
            if autoDriveEnabled {
                autoDriveEnabled = false
                announce("已切回手动驾驶", duration: 2)
            } else if serviceRemaining == 0 && !inPitLane && ComputerDriver.canDrive(vehicle, at: location, on: circuit) {
                autoDriveEnabled = true
                announce(activeCup == nil ? "自动驾驶开启 · 操作油门、刹车或转向可接管" :
                    "自动驾驶开启 · 行驶中使用时只保留普通比赛成绩",duration:5)
            } else {
                announce("请挂入前进挡并对准赛道方向", duration: 3)
            }
        case "racingLine":
            racingLineEnabled.toggle();world.showRacingLine=racingLineEnabled;savePractice()
            announce(racingLineEnabled ? "理想线路开启 · 绿加速 / 黄收油 / 红制动" : "理想线路关闭",duration:3)
        case "hud": showHUD.toggle(); savePractice()
        case "compactHUD":
            compactHUD.toggle()
            savePractice()
        case "statistics": sceneView.showsStatistics.toggle()
        case "fovDown", "fovUp":
            world.cockpitFOV = clamp(world.cockpitFOV+(action == "fovUp" ? 2 : -2),42,84)
            world.resetCamera(); savePractice()
        case "seatUp", "seatDown":
            world.seatHeight = clamp(world.seatHeight+(action == "seatUp" ? 0.02 : -0.02),1.00,1.10)
            world.resetCamera(); savePractice()
        case "capture": captureFrame()
        case "confirm":
            if !hasStarted && !showingRaceSetup && !showingRaceHistory { self.action("start") }
            else if isPaused { self.action("resume") }
        case "start":
            guard sprint == nil && lesson == nil && qualifying == nil else { return }
            sprint = nil
            hasStarted = true
            isPaused = false
            showHelp = false
            resetAtStart()
            announce("驶出发车区 · 先熟悉制动点和赛道", duration: 5)
        case "startSprint":
            guard isPaused && serviceRemaining == 0 && sprint == nil && lesson == nil && qualifying == nil else { return }
            saveTelemetry()
            showingRaceSetup = false
            if raceConfiguration.usesQualifying { startQualifying(raceConfiguration) }
            else { startSprint(raceConfiguration) }
        case "qualifyingSkip":
            guard isPaused, qualifying != nil, qualifying?.result == nil else { return }
            qualifying?.skip()
            completeQualifying()
        case "qualifyingRetry":
            guard isPaused, qualifying != nil, let setup = qualifyingSetup else { return }
            saveTelemetry()
            startQualifying(setup)
        case "launchQualifiedRace":
            guard isPaused, let setup = qualifyingSetup, let grid = qualifyingGrid else { return }
            saveTelemetry()
            clearQualifying()
            startSprint(setup,grid:grid)
        case "leaveQualifying":
            guard isPaused, qualifying != nil else { return }
            saveTelemetry()
            clearQualifying()
            hasStarted = false
            resetAtStart()
            showingRaceSetup = true
            noticeRemaining = 0
        case "retireSprint":
            guard isPaused && sprint?.retire(index:0) == true else { return }
            sprint?.finalizeUnfinished()
            completeRace()
        case "raceAgain":
            guard isPaused, raceResultReady, let configuration = activeRaceConfiguration else { return }
            guard !cupRoundRecorded else { return }
            startSprint(configuration,cup:activeCup,grid:activeRaceGrid)
        case "openReplay":
            guard canReplay, isPaused, let start = raceReplay.startTime, let end = raceReplay.endTime,
                  end > start else { return }
            sound.cancelCue()
            replay = RacePlayback(interval:start...end)
            replayView = .chase
            replayFrameClock = 0
            replayLookRemaining = 0
            world.showRacingLine = false
            resetReplayCamera()
            updateReplay(0)
        case "nextRaceSetup":
            guard isPaused, raceResultReady else { return }
            if activeCup != nil { self.action("cupContinue"); return }
            self.action("leaveSprint")
            self.action("raceSetup")
        case "leaveSprint":
            guard sprint != nil else { return }
            saveTelemetry()
            sound.cancelCue()
            sprint = nil
            activeRaceConfiguration = nil
            activeRaceGrid = nil
            plannedRaceTyres = nil
            reviewedRaceLaps = nil
            racePitStops = 0
            activeRaceID = nil
            raceReplay.reset()
            raceFlags.reset()
            activeCup = nil
            cupRoundRecorded = false
            cooldownSpeed = nil
            autoDriveEnabled = false
            hasStarted = false
            isPaused = true
            leaveActivitySelection()
            resetAtStart()
            noticeRemaining = 0
        case "leavePractice":
            guard hasStarted && isPaused && sprint == nil && lesson == nil && qualifying == nil else { return }
            saveTelemetry()
            savePractice()
            autoDriveEnabled = false
            hasStarted = false
            resetAtStart()
            session.lap = 1; session.last = nil; session.completedLaps = 0
            noticeRemaining = 0
        case "menuBack":
            if editingHUD { self.action("cancelHUDLayout"); return }
            if raceResultReady { self.action("leaveSprint"); return }
            if lesson?.result != nil { self.action("leaveLesson"); return }
            if qualifying?.result != nil { self.action("leaveQualifying"); return }
            guard hasStarted && isPaused else { return }
            self.action("resume")
        case "pause":
            if editingHUD { self.action("cancelHUDLayout"); return }
            if raceResultReady { self.action("leaveSprint"); return }
            if lesson?.result != nil { self.action("leaveLesson"); return }
            if qualifying?.result != nil { self.action("leaveQualifying"); return }
            guard hasStarted else { return }
            isPaused.toggle()
            showHelp = false
            controlClock.reset()
            input.clear()
            if isPaused { saveTelemetry() }
        case "resume":
            guard !raceResultReady && lesson?.result == nil && qualifying?.result == nil else { return }
            isPaused = false
            showHelp = false
            controlClock.reset()
            input.clear()
        case "help":
            if hasStarted && !isPaused { saveTelemetry() }
            isPaused = true
            showHelp = true
            input.clear()
        case "restart":
            saveTelemetry()
            if let lesson { startLesson(lesson.kind); break }
            if let setup = qualifyingSetup { startQualifying(setup); break }
            if sprint != nil {
                guard sprint?.playerDone != true else { return }
                startSprint(activeRaceConfiguration ?? raceConfiguration,cup:activeCup,grid:activeRaceGrid)
                break
            }
            resetAtStart()
            session.lap = 1
            session.last = nil
            session.completedLaps = 0
            isPaused = false
            showHelp = false
        case "reset":
            guard hasStarted && !isPaused else { return }
            guard serviceRemaining == 0 else { return }
            if let lesson { startLesson(lesson.kind); return }
            if let setup = qualifyingSetup { saveTelemetry(); startQualifying(setup); return }
            if sprint != nil {
                announce("短赛中可从暂停菜单重新发车", duration: 3)
                return
            }
            let outLap = inPitLane || session.waitingForStart
            let sample = circuit.sample(at: location.progress)
            vehicle.reset(at: sample, preservingCondition: true)
            previousVehicle = nil
            controlClock.reset()
            sideTrafficHold = SideTrafficHold()
            sideTraffic = SideTraffic()
            world.breakTyreMarkStreaks()
            gTrace.removeAll(keepingCapacity: true)
            inputHistory.reset()
            location = circuit.nearest(to: vehicle.position)
            inPitLane = false
            if outLap {session.beginOutLap(at:location.progress)} else {session.resetLap(at:location.progress)}
            world.resetCamera()
            announce(session.waitingForStart ? "已复位，保留车损 · 通过起点后计时" : "已复位，保留车损 · 本圈重新开始", duration: 4)
        case "camera", "cameraPrevious", "viewCabin", "viewChase":
            drivingView = action == "viewCabin" ? .cockpit : (action == "viewChase" ? .chase : drivingView.next(action == "cameraPrevious" ? -1 : 1))
            world.resetCamera()
            if hasStarted { announce(drivingView.label, duration: 1.5) }
            savePractice()
        case "upshift", "downshift":
            guard hasStarted && !autoDriveEnabled && !isPaused && serviceRemaining == 0 &&
                  sprint?.playerDone != true && lesson == nil else { return }
            let previous = vehicle.gear
            let result = vehicle.requestShift(action == "upshift" ? 1 : -1, pedals: input.pedals,
                                              automatic: assists.automatic,queueIfBusy:true)
            if result == .stopAndBrake {
                announce("接近静止后踩住刹车，并松开油门再换挡", duration: 3)
            } else if result == .overRev {
                announce("降挡转速过高 · 减速后再降挡",duration:2.5)
            } else if result == .shifted && (previous <= 0 || vehicle.gear <= 0) {
                announce("挡位 \(vehicle.gearLabel)", duration: 1.2)
            }
        case "brakeBiasDown", "brakeBiasUp":
            let change = action == "brakeBiasUp" ? 0.005 : -0.005
            let value = DrivingAssists.validatedBrakeBias(assists.frontBrakeBias + change)
            guard value != assists.frontBrakeBias else { return }
            assists.frontBrakeBias = value
            savePractice()
            announce(String(format:"前轴制动力 %.1f%%",value*100), duration: 2)
        case "abs": assists.absLevel = (assists.absLevel+1)%6; savePractice(); announce("ABS \(assists.absLevel)/5 · 0 关闭，5 强介入",duration:2)
        case "tc": assists.tcLevel = (assists.tcLevel+1)%6; savePractice(); announce("TCS \(assists.tcLevel)/5 · 0 关闭，5 强介入",duration:2)
        case "automatic": assists.automatic.toggle(); vehicle.cancelQueuedShift(); savePractice()
        case "brakeCurve":
            guard isPaused else { return }
            let next = (assists.brakeCurve.rawValue + 1) % BrakeCurve.allCases.count
            assists.brakeCurve = BrakeCurve(rawValue:next) ?? .progressive
            savePractice()
        case "steeringCurve":
            guard isPaused else { return }
            let next = (assists.steeringCurve.rawValue + 1) % SteeringCurve.allCases.count
            assists.steeringCurve = SteeringCurve(rawValue:next) ?? .standard
            savePractice()
        case "hapticLevel":
            input.hapticLevel = (input.hapticLevel+1)%5; input.stopHaptics(); savePractice()
        case "hapticRoute":
            guard showingControllerReview else { return }
            input.selectHapticRoute(input.hapticRoute.next)
            savePractice()
        case "hapticTest":
            guard isPaused else { return }
            if input.hapticLevel == 0 {
                announce("震动强度为 0% · 请先开启震动",duration:3)
            } else {
                announce(input.testHaptics() ? "震动测试 · 四次脉冲" : "震动测试未启动 · " + input.hapticStatus,duration:3)
            }
        case "mute": sound.muted.toggle(); savePractice()
        case "masterDown","masterUp","motorDown","motorUp","effectsDown","effectsUp":
            let delta = action.hasSuffix("Up") ? 0.1 : -0.1
            func level(_ current: Double) -> Double { clamp(((current+delta)*10).rounded()/10,0,1) }
            if action.hasPrefix("master") { sound.masterVolume = level(sound.masterVolume) }
            else if action.hasPrefix("motor") { sound.motorVolume = level(sound.motorVolume) }
            else { sound.effectsVolume = level(sound.effectsVolume) }
            savePractice()
        case "ghost": ghostEnabled.toggle(); savePractice()
        case "deadzoneDown": assists.steeringDeadzone = max(0.02, assists.steeringDeadzone - 0.02); savePractice()
        case "deadzoneUp": assists.steeringDeadzone = min(0.30, assists.steeringDeadzone + 0.02); savePractice()
        case "controllerDisconnected":
            resumeAfterHUDEdit = false
            autoDriveEnabled = false
            if hasStarted { isPaused = true; input.clear(); announce("手柄连接断开 · 已暂停", duration: 6) }
        default: break
        }
        hud.needsDisplay = true
    }

    func pickShowcasePanel(at windowPoint: CGPoint) {
        guard let showcase else { return }
        let local = sceneView.convert(windowPoint,from:nil)
        let hit = sceneView.sceneHitTest(local,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,
                                                  .ignoreHiddenNodes:true,.backFaceCulling:false]).first
        guard let hit, let panel = showcase.panel(containing:hit.node) else { return }
        action("showcasePanel:"+panel.rawValue)
    }

    func consumeSettingsReturnFocus() -> String? {
        defer { returningSettingsControl = nil }
        return returningSettingsControl
    }

    func currentSettingsChoice(_ choice: SettingsChoice) -> Int {
        switch choice {
        case .camera: return drivingView.rawValue
        case .steering: return assists.steeringCurve.rawValue
        case .braking: return assists.brakeCurve.rawValue
        case .antialiasing: return graphicsQuality.rawValue
        case .tyres: return tyreSetup.compound.rawValue
        }
    }

    private func applySettingsChoice(_ choice: SettingsChoice,index: Int) {
        guard currentSettingsChoice(choice) != index else { return }
        switch choice {
        case .camera:
            drivingView = DrivingView(rawValue:index) ?? .chase
            world.resetCamera()
        case .steering: assists.steeringCurve = SteeringCurve(rawValue:index) ?? .standard
        case .braking: assists.brakeCurve = BrakeCurve(rawValue:index) ?? .progressive
        case .antialiasing:
            graphicsQuality = GraphicsQuality(rawValue:index) ?? .quality
            applyGraphicsQuality()
        case .tyres:
            guard canPlanTyres else { return }
            tyreSetup.compound = TyreCompound(rawValue:index) ?? .medium
        }
        sceneDirty = true
        savePractice()
    }

    private func closeSettingsChoice(_ choice: SettingsChoice) {
        settingsChoice = nil
        returningSettingsControl = "choice:"+choice.rawValue
        hud.needsDisplay = true
    }

    private func settingsResetAction(_ reset: SettingsReset) -> String {
        switch reset {
        case .display: return "resetDisplaySettings"
        case .controller: return "resetControllerSettings"
        case .audio: return "resetAudioSettings"
        }
    }

    func loseFocus() {
        replay?.isPlaying = false
        sound.cancelCue()
        resumeAfterHUDEdit = false
        autoDriveEnabled = false
        if hasStarted && !isPaused { saveTelemetry(background:true) }
        controlClock.reset()
        input.clear()
        if hasStarted { isPaused = true }
        sound.update(rpm: vehicle.rpm, throttle: vehicle.engineThrottle, ignition: vehicle.ignitionFraction,
                     powertrain: vehicle.powertrainSound, cockpit: cockpit, kind: vehicle.kind, paused: true)
        hud.needsDisplay = true
    }

    func shutdown() {
        timer?.invalidate()
        qualifyingReferenceJob?.cancel()
        input.clear()
        if editingHUD { hudPositions = hudLayoutBeforeEdit }
        savePractice(background:false)
        saveTelemetry()
    }

    private func resetAtStart(resetPracticeTraffic: Bool = true) {
        gTrace.removeAll(keepingCapacity: true)
        wrongWay.reset()
        trackDrying = nil
        dryingClock = 0
        dryingHistory.removeAll(keepingCapacity:true)
        displayTrackDrying(nil)
        inputHistory.reset()
        feedback.reset(); impactFeedback = .zero; input.stopHaptics()
        sideTrafficHold = SideTrafficHold()
        sideTraffic = SideTraffic()
        collisionCooldown = 0
        serviceRemaining = 0
        activeRaceService = nil
        inPitLane = false
        vehicle.reset(at: circuit.start)
        previousVehicle = nil
        vehicle.service(setup: tyreSetup)
        location = circuit.nearest(to: vehicle.position)
        if resetPracticeTraffic {
            traffic.reset(count:opponentCount,kind:vehicle.kind,circuit:circuit,from:location.progress)
        }
        session.resetLap(at: location.progress)
        controlClock.reset()
        telemetry = TelemetryRecording()
        telemetrySampleCount = 0
        telemetrySaveRevision += 1
        telemetryClock = 0
        telemetryElapsed = 0
        world.resetCamera()
        world.clearTyreMarks()
    }

    private func selectVehicle(_ kind: VehicleKind) {
        guard kind != vehicle.kind else { return }
        saveTelemetry(); savePractice()
        configureSelection(PracticeSelection(vehicle:kind,circuit:circuit.kind,condition:circuit.condition))
        resetAtStart(); savePractice()
        sceneDirty = true
        announce("已切换 "+kind.label,duration:2)
    }

    private func selectCircuit(_ kind: CircuitKind, condition: TrackCondition) {
        guard kind != circuit.kind || condition != circuit.condition else { return }
        saveTelemetry(); savePractice()
        configureSelection(PracticeSelection(vehicle:vehicle.kind,circuit:kind,condition:condition))
        resetAtStart(); savePractice()
        announce("已切换 "+kind.label+" · "+condition.label,duration:2)
    }

    private var currentSelection: PracticeSelection {
        PracticeSelection(vehicle:vehicle.kind,circuit:circuit.kind,condition:circuit.condition)
    }

    private func configureSelection(_ selection: PracticeSelection) {
        let changedVehicle = selection.vehicle != vehicle.kind
        vehicle.kind = selection.vehicle
        if selection.circuit != circuit.kind || selection.condition != circuit.condition {
            changeCircuit(selection.circuit,condition:selection.condition)
        } else if changedVehicle {
            world.selectVehicle(selection.vehicle)
            mirrorImage = nil
            mirrorSequenceIndex = 0
            focusedMirror = nil
        }
        applyVehicleSettings()
        session = RaceSession()
        session.restore(records[recordKey])
    }

    private func enterActivitySelection(_ selection: PracticeSelection) {
        saveTelemetry()
        savePractice()
        if activityReturnSelection == nil { activityReturnSelection = currentSelection }
        configureSelection(selection)
    }

    private func leaveActivitySelection() {
        guard let selection = activityReturnSelection else { return }
        activityReturnSelection = nil
        configureSelection(selection)
    }

    private func startCupRound(_ series: CupSeries) {
        let index = cupProgress(series).records.count
        guard series.rounds.indices.contains(index) else { return }
        let round = series.rounds[index]
        showingCupMenu = false
        enterActivitySelection(PracticeSelection(vehicle:round.vehicle,circuit:round.circuit,condition:round.condition))
        startSprint(round.configuration,cup:CupEntry(series:series,roundIndex:index))
    }

    private func startQualifying(_ configuration: RaceConfiguration) {
        sound.cancelCue()
        let fittedTyres = configuration.fittedTyres(from:tyreSetup,on:circuit.condition)
        resetAtStart(resetPracticeTraffic:false)
        traffic = ComputerTraffic()
        vehicle = QualifyingSession.rollingCar(kind:vehicle.kind,circuit:circuit,line:world.racingLine,tyres:fittedTyres)
        location = circuit.nearest(to:vehicle.position)
        qualifying = QualifyingSession(startingAt:location.progress)
        qualifyingSetup = configuration
        hasStarted = true
        isPaused = false
        autoDriveEnabled = false
        showHelp = false
        rollingCountdown = 3
        rollingGo = 0
        noticeRemaining = 0
        input.clear()
        sceneDirty = true
        if qualifyingReferenceTimes == nil && qualifyingReferenceJob == nil {
            let job = QualifyingReferenceJob()
            qualifyingReferenceJob = job
            let venue = circuit, line = world.racingLine, kind = vehicle.kind
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let times = QualifyingSession.referenceTimes(kind:kind,circuit:venue,line:line,
                    rivals:configuration.rivals,paceScale:configuration.difficulty.paceScale,
                    shouldCancel:{ job.isCancelled })
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.qualifyingReferenceJob === job, !job.isCancelled else { return }
                    self.qualifyingReferenceJob = nil
                    self.qualifyingReferenceTimes = times
                    self.hud.needsDisplay = true
                }
            }
        }
    }

    private func completeQualifying() {
        rollingCountdown = 0
        rollingGo = 0
        isPaused = true
        autoDriveEnabled = false
        input.clear()
        controlClock.reset()
        saveTelemetry(background:true)
        hud.needsDisplay = true
    }

    private func clearQualifying() {
        qualifyingReferenceJob?.cancel()
        qualifyingReferenceJob = nil
        qualifyingReferenceTimes = nil
        qualifyingSetup = nil
        qualifying = nil
        rollingCountdown = 0
        rollingGo = 0
    }

    private func startLesson(_ kind: DrivingLessonKind) {
        sound.cancelCue()
        if lesson?.kind != kind {
            enterActivitySelection(PracticeSelection(vehicle:kind.vehicleKind,circuit:kind.circuitKind,condition:kind.condition))
        } else {
            saveTelemetry()
        }
        resetAtStart(resetPracticeTraffic:false)
        traffic = ComputerTraffic()
        let run = DrivingLessonRun(kind:kind)
        guard run.prepare(&vehicle,circuit:circuit) else {
            announce("无法载入课程场景",duration:4)
            return
        }
        lesson = run
        selectedLesson = kind
        showingSchool = false
        lessonPersonalBest = false
        rollingCountdown = 3
        rollingGo = 0
        location = circuit.nearest(to:vehicle.position)
        hasStarted = true
        isPaused = false
        autoDriveEnabled = false
        showHelp = false
        noticeRemaining = 0
        input.clear()
        var markers: [LessonTrackMarker] = []
        if let mark = kind.firstCoachingMark {
            switch kind {
            case .braking: markers.append(LessonTrackMarker(progress:mark,kind:.brake))
            case .trailBraking: markers.append(LessonTrackMarker(progress:mark,kind:.turn))
            case .wetExit: markers.append(LessonTrackMarker(progress:mark,kind:.accelerate))
            }
        }
        if kind.stopZone == nil { markers.append(LessonTrackMarker(progress:kind.finishProgress,kind:.finish)) }
        world.setLessonMarkers(markers,stopZone:kind.stopZone)
        sceneDirty = true
        hud.needsDisplay = true
    }

    private func completeLesson(_ run: DrivingLessonRun,outcome: DrivingLessonOutcome) {
        rollingGo = 0
        noticeRemaining = 0
        isPaused = true
        input.clear()
        controlClock.reset()
        saveTelemetry(background:true)
        if case .passed(let medal) = outcome {
            sound.playCue(.trainingPassed)
            let record = DrivingLessonRecord(medal:medal,time:run.elapsed,
                peakSpeedKPH:run.peakSpeedKPH,exitSpeedKPH:run.exitSpeedKPH)
            if record.improves(lessonRecords[run.kind]) {
                lessonPersonalBest = true
                lessonRecords[run.kind] = record
                savePractice(background:true)
            }
        } else { sound.playCue(.trainingFailed) }
        hud.needsDisplay = true
    }

    private func leaveLesson() {
        saveTelemetry()
        sound.cancelCue()
        lesson = nil
        rollingCountdown = 0
        rollingGo = 0
        isPaused = true
        hasStarted = false
        noticeRemaining = 0
        world.setLessonMarkers([])
        leaveActivitySelection()
        resetAtStart()
        showingSchool = true
        hud.needsDisplay = true
    }

    private func applyRaceOption(_ option: String) {
        let choice = option.split(separator:":",maxSplits:1)
        guard choice.count == 2, let value = Int(choice[1]) else { return }
        var next = raceConfiguration
        switch choice[0] {
        case "laps":
            guard RaceConfiguration.lapOptions.contains(value) else { return }
            next.laps = value
        case "rivals":
            guard (1...3).contains(value) else { return }
            next.rivals = value
        case "difficulty":
            guard let difficulty = RaceDifficulty(rawValue:value) else { return }
            next.difficulty = difficulty
        case "grid":
            guard (0...2).contains(value) else { return }
            next.startAtFront = value == 1
            next.qualifying = value == 2 ? true : nil
        case "tyres": next.matchTyresToWeather = value == 1
        case "surface":
            guard circuit.condition == .wet, (0...1).contains(value) else { return }
            next.drying = value == 1 ? true : nil
        default: return
        }
        if next != raceConfiguration {
            raceConfiguration = next
            savePractice()
        }
    }

    private func startSprint(_ configuration: RaceConfiguration,cup: CupEntry? = nil,grid: QualifyingSession.Grid? = nil) {
        sound.cancelCue()
        autoDriveEnabled = false
        hasStarted = true
        isPaused = false
        showHelp = false
        noticeRemaining = 0
        activeRaceConfiguration = configuration
        activeRaceGrid = grid
        racePitStops = 0
        activeCup = cup
        cupRoundRecorded = false
        activeRaceID = UUID()
        raceReplay.reset()
        raceFlags.reset()
        cooldownSpeed = nil
        finishRolloutRemaining = 0
        classifiedRolloutTime = 0
        checkeredDeadline = nil
        showingRaceHistory = false
        reviewedRaceLaps = nil
        resetAtStart(resetPracticeTraffic:false)
        if circuit.condition == .wet && configuration.usesDryingTrack { trackDrying = TrackDrying(circuit:circuit) }
        let slot = grid?.playerGridSlot ?? configuration.gridSlot
        vehicle.reset(at:circuit.gridSlot(slot))
        let fitted = configuration.fittedTyres(from:tyreSetup,on:circuit.condition)
        plannedRaceTyres = fitted
        plannedRaceWork = .both
        vehicle.service(setup:fitted)
        location = circuit.nearest(to: vehicle.position)
        traffic.lineUp(count:configuration.rivals,kind:vehicle.kind,circuit:circuit,
                       paceScale:configuration.difficulty.paceScale,playerGridSlot:slot,rivalGridOrder:grid?.rivalOrder)
        let positions = ([vehicle] + traffic.cars.map(\.vehicle)).map { circuit.nearest(to: $0.position).progress }
        sprint = SprintRace(lapCount:configuration.laps,positions:positions,trackLength:circuit.length)
        input.clear()
    }

    private func completeRace() {
        guard let race = sprint, race.finished, let player = race.playerClassification,
              let id = activeRaceID, let configuration = activeRaceConfiguration else { return }
        recordTrackDrying(final:true)
        raceReplay.record(time:race.elapsed+classifiedRolloutTime,player:vehicle,rivals:traffic.cars.map(\.vehicle),final:true)
        let record = RaceRecord(id:id,date:Date(),vehicle:vehicle.kind,circuit:circuit.kind,
            wet:circuit.condition == .wet,configuration:configuration,completedLaps:player.laps,
            place:player.finishTime == nil ? nil : player.position,totalTime:player.classifiedTime,
            bestLap:player.bestLap,penaltySeconds:player.penaltySeconds,assisted:race.assisted,cup:activeCup,
            qualifiedGridPlace:activeRaceGrid.map { $0.playerGridSlot+1 },pitStops:racePitStops,
            lappedFinish:player.finishTime != nil && player.laps < race.lapCount ? true : nil,
            timedOut:player.status == .timedOut ? true : nil,lapHistory:race.playerLaps)
        raceRecords = RaceRecord.recent([record]+raceRecords)
        if let cup = activeCup {
            cupRoundRecorded = cups[cup.series,default:CupProgress()].recordRound(record,for:cup.series)
        }
        activeRaceID = nil
        cooldownSpeed = nil
        autoDriveEnabled = false
        isPaused = true
        noticeRemaining = 0
        controlClock.reset()
        input.clear()
        saveTelemetry(background:true)
        savePractice(background:true)
        hud.needsDisplay = true
    }

    func seekReplay(fraction: Double) {
        guard replay != nil else { return }
        replay?.isPlaying = false
        replay?.seek(fraction:fraction)
        resetReplayCamera()
        updateReplay(0)
    }

    private func resetReplayCamera() {
        replayContactTime = replay?.time
        sound.cancelContact()
        world.resetCamera()
        replayNeedsFrame = true
        replayNeedsCameraReset = true
        mirrorRevision += 1
        if nextMirrorFrame != 0 {
            for mirror in VehicleMirror.allCases { world.setMirrorImage(nil,for:mirror) }
            mirrorImage = nil
        }
        replayMirrorsPending = Set(VehicleMirror.allCases)
        mirrorSequenceIndex = 0
        nextMirrorFrame = 0
    }

    private func updateReplay(_ dt: Double) {
        guard let before = replay else { return }
        replay?.advance(dt)
        guard let state = replay else { return }
        if !state.playsSound { replayContactTime = nil }
        else if replayContactTime == nil { replayContactTime = before.time }
        if !state.playsSound && replaySoundActive {
            sound.pausePlayback()
            replaySoundActive = false
        }
        if sceneView.isPlaying != state.isPlaying { sceneView.isPlaying = state.isPlaying }
        if sceneView.rendersContinuously { sceneView.rendersContinuously = false }
        replayFrameClock += dt
        let moved = before.time != state.time
        let inCabin = replayView == .cockpit
        if inCabin && before.isPlaying && !state.isPlaying { replayMirrorsPending = Set(VehicleMirror.allCases) }
        let glance = inCabin ? input.sideLook : 0
        replayLookRemaining = abs(glance-world.sideLook) > 0.0001 ? 0.28 : max(0,replayLookRemaining-dt)
        let looking = inCabin && replayLookRemaining > 0
        let frameInterval = 1.0/Double(renderingRate.rawValue)
        guard replayNeedsFrame || ((moved || looking) && (replayFrameClock+0.0004 >= frameInterval || (moved && !state.isPlaying))),
              let frame = raceReplay.frame(at:state.time) else { return }
        let elapsed = replayNeedsFrame ? 0 : min(0.1,replayFrameClock)
        replayFrame = frame
        replayFrameClock = 0
        replayNeedsFrame = false
        let reset = replayNeedsCameraReset
        replayNeedsCameraReset = false
        if !dryingHistory.isEmpty {
            displayTrackDrying(dryingHistory.last { $0.elapsed <= state.time+1e-6 },
                               transitioning:state.isPlaying && !reset,force:reset)
            world.advanceTrackDryingDisplay(elapsed)
        }
        world.sideLook = glance
        world.updateTraffic(frame.rivals)
        world.updateSpray(player:frame.player,opponents:frame.rivals,cockpit:inCabin,active:true)
        world.update(vehicle:frame.player,input:DrivingInput(),dt:elapsed,cockpit:inCabin,ghost:nil,view:replayView.drivingView)
        let camera = replayView == .trackside
            ? world.tracksideReplayCamera(for:frame.player,dt:elapsed,reset:reset,opponents:frame.rivals) : world.camera
        if sceneView.pointOfView !== camera { sceneView.pointOfView = camera }
        if state.playsSound {
            publishDrivingSound(vehicle:frame.player,rivals:frame.rivals,camera:camera,inCabin:inCabin,active:true,recorded:frame)
            if let from = replayContactTime {
                raceReplay.playContacts(after:from,through:state.time) { playContact($0,camera:camera,cockpit:inCabin) }
            }
            replayContactTime = state.time
            replaySoundActive = true
        }
        sceneView.requestFrame()
        hud.needsDisplay = true
    }

    private func closeReplay() {
        replay = nil
        replayFrame = nil
        sound.pausePlayback()
        replaySoundActive = false
        replayNeedsFrame = false
        replayNeedsCameraReset = false
        replayLookRemaining = 0
        replayMirrorsPending.removeAll()
        updateMirror(at:0)
        sceneView.isPlaying = false
        sceneView.pointOfView = world.camera
        world.showRacingLine = racingLineEnabled
        displayTrackDrying(trackDrying,force:true)
        world.resetCamera()
        sceneDirty = true
        input.clear()
    }

    private func announce(_ message: String, duration: Double) {
        notice = message
        noticeRemaining = duration
        hud.needsDisplay = true
    }

    private func changeCircuit(_ kind: CircuitKind, condition: TrackCondition? = nil) {
        let fov = world.cockpitFOV, eye = world.seatHeight
        circuit = Circuit(kind:kind,condition:condition ?? circuit.condition)
        previousVehicle = nil
        mirrorRenderer = nil
        mirrorPasses.removeAll()
        mirrorImage = nil
        nextMirrorFrame = 0
        mirrorSequenceIndex = 0
        focusedMirror = nil
        world = RacingWorld(circuit:circuit,vehicleKind:vehicle.kind)
        world.applyGraphicsQuality(graphicsQuality)
        world.showRacingLine=racingLineEnabled
        world.cockpitFOV = fov; world.seatHeight = eye
        sceneView.scene = world.scene; sceneView.pointOfView = world.camera
        location = circuit.nearest(to:circuit.start.point)
        sceneDirty = true
    }

    private static func readPractice(in dataDirectory: URL) -> PracticeLoad {
        let url = dataDirectory.appendingPathComponent("practice.json")
        let portable = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("APEX Lab Data",isDirectory:true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APEX Lab", isDirectory: true)
        func decode(_ data: Data?) -> SavedPractice? {
            guard let data, let saved = try? JSONDecoder().decode(SavedPractice.self,from:data),
                  (1...10).contains(saved.version) else { return nil }
            return saved
        }
        let primary = try? Data(contentsOf:url)
        if let saved = decode(primary) { return PracticeLoad(settings:saved,data:primary) }
        let recovery = try? Data(contentsOf:dataDirectory.appendingPathComponent(PracticeRecovery.filename))
        if let saved = decode(recovery) {
            return PracticeLoad(settings:saved,data:recovery,usedRecovery:true,unreadablePrimary:primary)
        }
        if dataDirectory == support && !FileManager.default.fileExists(atPath:url.path) {
            let transferred = try? Data(contentsOf:portable.appendingPathComponent("practice.json"))
            if let saved = decode(transferred) { return PracticeLoad(settings:saved,data:transferred) }
            let alternate = try? Data(contentsOf:portable.appendingPathComponent(PracticeRecovery.filename))
            if let saved = decode(alternate) { return PracticeLoad(settings:saved,data:alternate,usedRecovery:true) }
        }
        return PracticeLoad(unreadablePrimary:primary)
    }

    private func applyPractice(_ saved: SavedPractice,data: Data) {
        if saved.version < 10 { legacyPractice = (data,saved.version) }
        if saved.version >= 9 {
            // Keep retired-car data under its original key when this save is rewritten.
            func retiredTimingKey(_ key: String) -> Bool {
                let pieces = key.split(separator:"-")
                guard pieces.count >= 3, pieces[0] == "timing9", let raw = Int(pieces[1]) else { return false }
                return (0...7).contains(raw) && VehicleKind(rawValue:raw) == nil
            }
            records = (saved.records ?? [:]).filter { retiredTimingKey($0.key) && $0.value.isValid }
            analysis = (saved.analysis ?? [:]).filter { retiredTimingKey($0.key) }
            for car in VehicleKind.allCases {
                for track in CircuitKind.allCases {
                    for condition in TrackCondition.allCases {
                        for legacyLayout in track.hasElevation ? [false,true] : [false] {
                            for legacyMass in car == .porsche ? [false,true] : [false] {
                                let key = LapRecord.key(vehicle:car,circuit:track,condition:condition,
                                                        legacyLayout:legacyLayout,legacyPorscheMass:legacyMass)
                                if let record = saved.records?[key], record.isValid { records[key] = record }
                                if var laps = saved.analysis?[key] {
                                    laps.validate()
                                    analysis[key] = laps
                                }
                            }
                        }
                    }
                }
            }
            session.restore(records[recordKey])
        }
        assists.abs = saved.abs
        assists.tractionControl = saved.tractionControl
        if let level = saved.absLevel { assists.absLevel = clamp(level,0,5) }
        if let level = saved.tcLevel { assists.tcLevel = clamp(level,0,5) }
        input.hapticLevel = clamp(saved.hapticLevel ?? 3,0,4)
        input.selectHapticRoute(saved.hapticRoute.flatMap(HapticRoute.init(rawValue:)) ?? .automatic)
        assists.automatic = saved.automatic
        assists.steeringDeadzone = saved.deadzone.isFinite ? clamp(saved.deadzone, 0.02, 0.3) : 0.08
        if let compound = saved.compound, let value = TyreCompound(rawValue: compound) { tyreSetup.compound = value }
        if let pressure = saved.coldPressure, pressure.isFinite { tyreSetup.coldPressure = clamp(pressure, 1.3, 2.1) }
        vehicleSettings = (saved.vehicleSettings ?? [:]).filter { key,_ in
            guard let raw = Int(key) else { return false }
            return (0...7).contains(raw) && VehicleKind(rawValue:raw) == nil
        }
        for kind in VehicleKind.allCases {
            let key = String(kind.rawValue)
            if let settings = saved.vehicleSettings?[key] {
                vehicleSettings[key] = settings
            } else if saved.version < 10 {
                var migrated = VehicleSettings(tyres: tyreSetup, assists: assists)
                migrated.frontBrakeBias = saved.brakeBiasByVehicle?[key] ?? DrivingAssists.defaultBrakeBias
                vehicleSettings[key] = migrated
            }
        }
        applyVehicleSettings()
        pitLimiterEnabled = saved.pitLimiterEnabled ?? true
        mirrorEnabled = saved.mirrorEnabled ?? true
        compactHUD = saved.compactHUD ?? true
        graphicsQuality = saved.graphicsQuality.flatMap(GraphicsQuality.init(rawValue:)) ?? .quality
        renderingRate = saved.renderingRate.flatMap(RenderingRate.init(rawValue:)) ?? .hz120
        ghostEnabled = saved.ghostEnabled ?? true
        showHUD = saved.showHUD ?? true
        opponentCount = clamp(saved.opponentCount ?? 3, 0, 3)
        raceConfiguration = saved.raceConfiguration ?? RaceConfiguration(rivals:max(1,opponentCount))
        raceConfiguration.validate()
        raceRecords = RaceRecord.recent(saved.raceRecords ?? [])
        for series in CupSeries.allCases {
            if var progress = saved.cups?[series.rawValue] {
                progress.validate(for:series)
                cups[series] = progress
            }
        }
        for kind in DrivingLessonKind.allCases {
            if let record = saved.lessonRecords?[kind.rawValue], record.isValid {
                lessonRecords[kind] = record
            }
        }
        hudPositions = (saved.hudPositions ?? [:]).filter { $0.value.x.isFinite && $0.value.y.isFinite }
        racingLineEnabled=saved.racingLineEnabled ?? true
        world.showRacingLine=racingLineEnabled
        sound.muted = saved.muted
        func volume(_ value: Double?) -> Double {
            guard let value,value.isFinite else { return 1 }
            return clamp(value,0,1)
        }
        sound.masterVolume = volume(saved.masterVolume)
        sound.motorVolume = volume(saved.motorVolume)
        sound.effectsVolume = volume(saved.effectsVolume)
        drivingView = saved.drivingView.flatMap(DrivingView.init(rawValue:)) ?? ((saved.cockpit ?? false) ? .cockpit : .chase)
        if let v = saved.verticalFOV, v.isFinite { world.cockpitFOV = CGFloat(clamp(v,42,84)) }
        if let v = saved.eyeHeight, v.isFinite { world.seatHeight = clamp(v,1.00,1.10) }
    }

    private func applyVehicleSettings() {
        let settings = vehicleSettings[vehicleSettingsKey] ?? VehicleSettings(tyres: TyreSetup(), assists: DrivingAssists())
        settings.apply(to: &tyreSetup, assists: &assists)
    }

    private func applyGraphicsQuality() {
        sceneView.preferredFramesPerSecond = renderingRate.rawValue
        world.applyGraphicsQuality(graphicsQuality)
        switch graphicsQuality {
        case .performance: sceneView.antialiasingMode = .none
        case .balanced: sceneView.antialiasingMode = .multisampling2X
        case .quality: sceneView.antialiasingMode = .multisampling4X
        }
    }

    private func resetSettings(_ category: SettingsReset) {
        switch category {
        case .controller:
            let defaults = DrivingAssists()
            assists.steeringDeadzone = defaults.steeringDeadzone
            assists.brakeCurve = defaults.brakeCurve
            assists.steeringCurve = defaults.steeringCurve
            input.hapticLevel = 3
            input.selectHapticRoute(.automatic)
            input.stopHaptics()
        case .display:
            graphicsQuality = .quality
            renderingRate = .hz120
            world.cockpitFOV = 62; world.seatHeight = 1
            drivingView = .chase
            world.resetCamera()
            applyGraphicsQuality()
        case .audio:
            sound.muted = false
            sound.masterVolume = 1; sound.motorVolume = 1; sound.effectsVolume = 1
        }
        sceneDirty = true
        announce("已恢复此类别默认值",duration:3)
        savePractice()
    }

    private func savePractice(background: Bool? = nil) {
        if records[recordKey]?.time != session.best, let record = session.record {
            records[recordKey] = record
        }
        vehicleSettings[vehicleSettingsKey] = VehicleSettings(tyres: tyreSetup, assists: assists)
        let selection = activityReturnSelection ?? currentSelection
        let cupSaves = Dictionary(uniqueKeysWithValues:cups.map { ($0.key.rawValue,$0.value) })
        let lessonSaves = Dictionary(uniqueKeysWithValues:lessonRecords.map { ($0.key.rawValue,$0.value) })
        let saved = SavedPractice(version: 10, best: nil, ghost: [],
            abs: assists.abs, tractionControl: assists.tractionControl, automatic: assists.automatic,
            deadzone: assists.steeringDeadzone, muted: sound.muted, cockpit: cockpit,
            verticalFOV: Double(world.cockpitFOV), eyeHeight: world.seatHeight,
            compound: tyreSetup.compound.rawValue, coldPressure: tyreSetup.coldPressure,
            drivingView:drivingView.rawValue,vehicleKind:selection.vehicle.rawValue,
            circuitKind:selection.circuit.rawValue, absLevel:assists.absLevel, tcLevel:assists.tcLevel,
            hapticLevel:input.hapticLevel,hapticRoute:input.hapticRoute.rawValue,records:records,
            racingLineEnabled:racingLineEnabled,opponentCount:opponentCount,hudPositions:hudPositions,
            pitLimiterEnabled:pitLimiterEnabled,mirrorEnabled:mirrorEnabled,compactHUD:compactHUD,
            vehicleSettings:vehicleSettings,analysis:analysis,trackCondition:selection.condition.rawValue,
            graphicsQuality:graphicsQuality.rawValue,ghostEnabled:ghostEnabled,showHUD:showHUD,
            masterVolume:sound.masterVolume,motorVolume:sound.motorVolume,effectsVolume:sound.effectsVolume,
            renderingRate:renderingRate.rawValue,raceConfiguration:raceConfiguration,raceRecords:raceRecords,
            cups:cupSaves,lessonRecords:lessonSaves)
        practiceSaveRevision += 1
        let revision = practiceSaveRevision
        let directory = dataDirectory
        let legacy = legacyPractice
        let recovery = practiceRecovery
        let write = {
            do {
                try Self.writePractice(saved,directory:directory,legacy:legacy,recovery:recovery)
                return true
            } catch { return false }
        }
        if background ?? (hasStarted && !isPaused) {
            Self.persistenceQueue.async { [weak self] in
                let success = write()
                DispatchQueue.main.async { [weak self] in
                    self?.finishPracticeSave(success,revision:revision)
                }
            }
        } else {
            let success = Self.persistenceQueue.sync(execute:write)
            finishPracticeSave(success,revision:revision)
        }
    }

    private static func writePractice(_ saved: SavedPractice,directory: URL,legacy: (data: Data,version: Int)?,
                                      recovery: PracticeRecovery) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let legacyPractice = legacy {
            let name = legacyPractice.version < 9 ? "practice-before-1.6.json" : "practice-before-2.0.json"
            let backup = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:backup.path) {
                try legacyPractice.data.write(to:backup,options:.atomic)
            }
        }
        let data = try JSONEncoder().encode(saved)
        try recovery.preserveBeforeWriting(in:directory)
        try data.write(to:directory.appendingPathComponent("practice.json"),options:.atomic)
        recovery.didWrite(data)
    }

    private func finishPracticeSave(_ success: Bool,revision: Int) {
        guard revision == practiceSaveRevision else { return }
        if success {
            legacyPractice = nil
            settingsStatus = nil
        } else {
            settingsStatus = "未能写入设置 · 请检查练习数据目录"
            announce("设置保存失败 · 请检查练习数据目录的写入权限", duration: 4)
        }
    }

    private func saveTelemetry(background: Bool = false) {
        guard telemetrySampleCount > 0 else { return }
        telemetrySaveRevision += 1
        let revision = telemetrySaveRevision
        let recording = telemetry
        let directory = dataDirectory
        let name: String
        if lesson != nil { name = "latest-lesson.csv" }
        else if qualifying != nil { name = "latest-qualifying.csv" }
        else { name = sprint == nil ? "latest-session.csv" : "latest-sprint.csv" }
        let write = {
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try recording.write(to:directory.appendingPathComponent(name))
                return true
            } catch { return false }
        }
        if background {
            Self.persistenceQueue.async { [weak self] in
                guard !write() else { return }
                DispatchQueue.main.async { [weak self] in self?.reportTelemetryFailure(revision:revision) }
            }
        } else if !Self.persistenceQueue.sync(execute:write) {
            reportTelemetryFailure(revision:revision)
        }
    }

    private func reportTelemetryFailure(revision: Int) {
        guard revision == telemetrySaveRevision else { return }
        announce("遥测保存失败 · 请检查练习数据目录的写入权限",duration:4)
    }
}

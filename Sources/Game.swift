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
    case restart, leave, pit
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
}

struct DrivingTick {
    let timestamp: Double
    let processingTime: Double
    let physicsSteps: Int
    let sceneUpdated: Bool
}

final class RacingGame {
    private(set) var circuit: Circuit
    let input: InputManager
    let sound = EngineSound()
    private(set) var world: RacingWorld
    let hud = HUDView()
    let sceneView: SCNView
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
    private(set) var showingSeatPreview = false
    private(set) var settingsChoice: SettingsChoice?
    private(set) var returningSettingsControl: String?
    private(set) var sessionPrompt: SessionPrompt?
    private(set) var garageSelection: GarageSelection?
    private(set) var settingsReset: SettingsReset?
    private var calibrationReturnPage: SettingsPage?
    private(set) var settingsStatus: String?
    private(set) var graphicsQuality = GraphicsQuality.quality
    private(set) var renderingRate = RenderingRate.hz120
    private(set) var analysisPage = 0
    var drivingInput = DrivingInput()
    var session = RaceSession()
    private(set) var sprint: SprintRace?
    private var records: [String:LapRecord] = [:]
    private var legacyPractice: (data: Data, version: Int)?
    private var recordKey: String { LapRecord.key(vehicle:vehicle.kind,circuit:circuit.kind,condition:circuit.condition) }
    var location: TrackLocation
    var hasStarted = false
    var isPaused = true
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
    private var mirrorCost = 0.0
    private var mirrorSession: Bool {
        hasStarted && !isPaused && mirrorEnabled && serviceRemaining == 0 &&
            cockpit
    }
    var showMirror: Bool { mirrorSession && showHUD }
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
    var canPlanTyres: Bool { sprint == nil && serviceRemaining == 0 }
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
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var controlClock = DrivingStepClock()
    private var renderClock = 0.0
    private var nextSceneUpdate = 0.0
    private var lastSceneUpdate: Double?
    var inspectDrivingTick: ((DrivingTick) -> Void)?
    private var hudNoticeVisible = false
    private var hudControllerName: String?
    private var hudHapticStatus = ""
    private var sceneDirty = true
    private var collisionCooldown = 0.0
    private var impactFeedback = SIMD2<Double>.zero
    private var feedback = HapticFeedback()
    private static let persistenceQueue = DispatchQueue(label:"studio.apexlab.practice-persistence",qos:.utility)
    private var practiceSaveRevision = 0
    private var telemetrySaveRevision = 0
    private var telemetryClock = 0.0
    private var telemetryElapsed = 0.0
    private var telemetry: [String] = ["time_s,x_m,z_m,speed_kph,gear,rpm,throttle,brake,steering,lateral_g,longitudinal_g,valid_lap,fr_surface_c,fl_surface_c,rr_surface_c,rl_surface_c,fr_bar,fl_bar,rr_bar,rl_bar,fr_wear,fl_wear,rr_wear,rl_wear,front_damage,rear_damage,engine_damage,coolant_c,fr_travel_mm,fl_travel_mm,rr_travel_mm,rl_travel_mm,fr_load_n,fl_load_n,rr_load_n,rl_load_n,fr_kerb,fl_kerb,rr_kerb,rl_kerb,car_id,track_id,abs_level,tc_level,abs_release,tc_reduction,front_brake_bias,brake_line_pressure,yaw_rate_rad_s,aero_front_n,aero_rear_n,fr_grip_use,fl_grip_use,rr_grip_use,rl_grip_use,fr_contamination,fl_contamination,rr_contamination,rl_contamination,track_condition,tyre_compound,fr_water_mm,fl_water_mm,rr_water_mm,rl_water_mm,road_elevation_m,road_grade_pct,road_crossfall_pct,fr_tread_inner_c,fr_tread_middle_c,fr_tread_outer_c,fl_tread_inner_c,fl_tread_middle_c,fl_tread_outer_c,rr_tread_inner_c,rr_tread_middle_c,rr_tread_outer_c,rl_tread_inner_c,rl_tread_middle_c,rl_tread_outer_c,session_time_s,track_progress_m,track_lateral_m,rack_angle_rad,lap_index,fr_brake_pressure,fl_brake_pressure,rr_brake_pressure,rl_brake_pressure,fr_longitudinal_slip,fl_longitudinal_slip,rr_longitudinal_slip,rl_longitudinal_slip,fr_longitudinal_force_n,fl_longitudinal_force_n,rr_longitudinal_force_n,rl_longitudinal_force_n,wake_strength,applied_throttle,applied_brake,brake_steady_target,engine_throttle,fr_sliding_fraction,fl_sliding_fraction,rr_sliding_fraction,rl_sliding_fraction,fr_lateral_force_n,fl_lateral_force_n,rr_lateral_force_n,rl_lateral_force_n"]
    private let updateRate = 120

    private static func defaultDataDirectory() -> URL {
        let fm = FileManager.default
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let portable = parent.appendingPathComponent("APEX Lab Data", isDirectory: true)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APEX Lab", isDirectory: true)
        let portableExists = fm.fileExists(atPath: portable.path)
        if (portableExists ? fm.isWritableFile(atPath: portable.path) : fm.isWritableFile(atPath: parent.path)) &&
            (fm.fileExists(atPath: portable.appendingPathComponent("practice.json").path) ||
             !fm.fileExists(atPath: support.appendingPathComponent("practice.json").path)) {
            return portable
        }
        return support
    }
    private let dataDirectory: URL

    init(frame: NSRect, dataDirectory: URL? = nil, monitorControllers: Bool = true) {
        input = InputManager(monitorControllers: monitorControllers)
        self.dataDirectory = dataDirectory ?? Self.defaultDataDirectory()
        let circuit = Circuit()
        self.circuit = circuit
        world = RacingWorld(circuit: circuit)
        location = circuit.nearest(to: circuit.start.point)
        sceneView = SCNView(frame: frame, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        sceneView.autoresizingMask = [.width, .height]
        sceneView.scene = world.scene
        sceneView.pointOfView = world.camera
        sceneView.preferredFramesPerSecond = updateRate
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        sceneView.backgroundColor = NSColor(rgb: 0xB8CED8)
        hud.frame = frame
        hud.autoresizingMask = [.width, .height]
        hud.game = self
        input.onAction = { [weak self] action in self?.action(action) }
        vehicle.kind = .centenario
        loadPractice()
        applyGraphicsQuality()
        world.selectVehicle(vehicle.kind)
        vehicle.reset(at: self.circuit.start)
        vehicle.service(setup: tyreSetup)
        location = self.circuit.nearest(to: vehicle.position)
        session.resetLap(at: location.progress)
        world.update(vehicle: vehicle, input: drivingInput, dt: 0, cockpit: false, ghost: nil, view: .chase)
        updateMenuCamera()
        timer = Timer(timeInterval: 1.0 / Double(updateRate), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = clamp(now - lastTime, 0, 1.0 / 15)
        var physicsSteps = 0
        lastTime = now
        let wasPaused = isPaused
        drivingInput = input.read(dt: dt, deadzone: assists.steeringDeadzone, acceptDriving: hasStarted && !isPaused,
                                  diagnose: showingControllerReview, navigateMenu: isNavigatingMenu, now: now)
        // Button handlers can change pause state during polling.
        if isPaused || wasPaused { drivingInput = DrivingInput() }
        if !isPaused && hasStarted && serviceRemaining > 0 {
            drivingInput = DrivingInput()
            controlClock.reset()
            var parked = vehicle
            _ = traffic.step(dt, player: &parked, circuit: circuit, line: world.racingLine)
            serviceRemaining = max(0, serviceRemaining - dt)
            if serviceRemaining == 0 {
                vehicle.service(setup: tyreSetup)
                world.resetCamera()
                announce("维修完成 · 挂入 1 挡驶出维修道", duration: 5)
            }
        } else if !isPaused && hasStarted {
            if autoDriveEnabled && ComputerDriver.wantsControl(drivingInput) {
                autoDriveEnabled = false
                announce("已接管车辆", duration: 2)
            }
            if autoDriveEnabled {
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
            let batch = controlClock.advance(seconds:dt,to:drivingInput)
            physicsSteps = batch.count
            for index in 0..<batch.count {
                simulate(controlClock.step,input:batch[index])
            }
        } else { controlClock.reset() }
        if noticeRemaining > 0 { noticeRemaining -= dt }
        let driving = hasStarted && !isPaused && serviceRemaining == 0 && (sprint?.countdown ?? 0) == 0
        let adjacent = driving ? SideTraffic(player:vehicle,opponents:traffic.cars) : SideTraffic()
        sideTraffic = sideTrafficHold.update(adjacent,dt:dt,active:driving)
        inputHistory.update(input:drivingInput,absActive:vehicle.absActive,dt:dt,active:driving,
                            linePressure:vehicle.brakeLinePressure)
        impactFeedback *= exp(-dt*12)
        let signal = feedback.update(vehicle:vehicle,input:drivingInput,impact:impactFeedback,dt:dt,
                                     active:driving && input.hapticsAvailable)
        input.updateHaptics(signal,dt:dt,driving:driving)
        let ear = world.camera.simdWorldRight
        let earRight = SIMD2(Double(ear.x),Double(ear.z))
        let opponents = hasStarted ? traffic.cars.map(\.vehicle) : []
        let motorVoices = driving ? opponents.map { OpponentMotor.relative(to:vehicle,opponent:$0,listenerRight:earRight) } : []
        let raceSignal = sprint.map { $0.showGo ? 4 : $0.countdownSeconds } ?? 0
        sound.update(rpm: vehicle.rpm, throttle: drivingInput.throttle, ignition: vehicle.ignitionFraction,
                     cockpit: cockpit, kerb: vehicle.kerbFeedback, roadSpeed: vehicle.speed,
                     roadSound:RoadSound(vehicle:vehicle),spray:vehicle.wheels.map(\.spray).max() ?? 0,
                     kind:vehicle.kind,opponents:motorVoices,raceSignal:raceSignal,
                     paused: isPaused || !hasStarted || serviceRemaining > 0)
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
        let present = sceneDirty || (running && (renderingRate == .hz120 || now+0.0004 >= nextSceneUpdate))
        if present {
            let frameInterval = 1/Double(renderingRate.rawValue)
            let presentationDT = clamp(now-(lastSceneUpdate ?? now-dt),0,1.0/15)
            if sceneDirty || nextSceneUpdate == 0 || now-nextSceneUpdate > frameInterval {
                nextSceneUpdate = now+frameInterval
            } else {
                nextSceneUpdate += frameInterval
            }
            lastSceneUpdate = now
            let ghost = ghostEnabled && hasStarted && sprint == nil ? session.liveGhost : nil
            let displayCar = running && serviceRemaining == 0 && (sprint?.countdown ?? 0) == 0
                ? previousVehicle.map { vehicle.displayPose(previous:$0,fraction:controlClock.remainder/controlClock.step) } ?? vehicle : vehicle
            let displayTraffic = driving ? traffic.displayVehicles(remainder:controlClock.remainder) : opponents
            world.updateTraffic(displayTraffic)
            world.updateSpray(player:displayCar,opponents:displayTraffic,cockpit:cockpit,active:driving)
            if driving { world.updateTyreMarks(vehicle:displayCar,dt:presentationDT) }
            world.sideLook = showingSeatPreview ? 0 : input.sideLook
            let renderView: DrivingView = showingSeatPreview ? .cockpit : (hasStarted ? drivingView : .chase)
            world.update(vehicle:displayCar,input:drivingInput,dt:presentationDT,cockpit:renderView.isInterior,
                         ghost:showingSeatPreview ? nil : ghost,view:renderView)
            if !showingSeatPreview { updateMenuCamera() }
            if !continuous { sceneView.needsDisplay = true }
            sceneDirty = false
        }
        updateMirror(at: now)
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
            mirrorCost = 0
            return
        }
        guard now >= nextMirrorFrame, !mirrorInFlight else { return }
        let sequence: [VehicleMirror] = [.centre,.left,.centre,.right]
        let views = sequence.filter { mirror in
            mirror == .centre ? (showHUD || world.hasMirror(mirror)) : world.hasMirror(mirror)
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
        let encodeStart = ProcessInfo.processInfo.systemUptime
        renderer.render(atTime:now,viewport:CGRect(x:0,y:0,width:width,height:height),commandBuffer:command,passDescriptor:pass)
        let encodeTime = ProcessInfo.processInfo.systemUptime-encodeStart
        mirrorCost += (encodeTime-mirrorCost)*0.20
        nextMirrorFrame = now + clamp(mirrorCost*7,1.0/30,1.0/14)
        command.addCompletedHandler { [weak self, weak renderer] completed in
            let image: CGImage? = completed.status == .completed ? Self.readMirror(texture) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.mirrorInFlight = false
                guard let image, let renderer, self.mirrorSession, self.mirrorRenderer === renderer,
                      self.world === sourceWorld, self.vehicle.kind == sourceKind else { return }
                self.world.setMirrorImage(image,for:mirror)
                if mirror == .centre {
                    self.mirrorImage = NSImage(cgImage:image,size:NSSize(width:width,height:height))
                }
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

    private static func readMirror(_ texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        let stride = width * 4
        var pixels = Data(count:stride * height)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!,bytesPerRow:stride,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        }
        guard let provider = CGDataProvider(data:pixels as CFData),
              let space = CGColorSpace(name:CGColorSpace.sRGB) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
                       space:space,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue)],
                       provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }

    private func simulate(_ dt: Double,input controls: DrivingInput) {
        if let race = sprint, race.countdown > 0 {
            sprint?.advanceCountdown(dt)
            return
        }
        previousVehicle = vehicle.renderSample
        location = circuit.nearest(to: vehicle.position)
        let contacts = circuit.wheelContacts(at:vehicle.contactPoints)
        var activeAssists = assists
        if autoDriveEnabled {activeAssists.automatic = true}
        let pitTarget = pitLimiterEnabled ? circuit.pitLane.targetSpeed(at:location) : nil
        let command = pitTarget.map {
            pitLimitedInput(controls,speed:vehicle.speed,curve:assists.brakeCurve,limit:$0)
        } ?? controls
        vehicle.step(dt,input:command,assists:activeAssists,roadDistance:location.distance,roadWidth:circuit.width,
                     roadLateral:location.lateral,roadProgress:location.progress,kerbsEnabled:circuit.hasKerb(at:location.progress),
                     roadContacts:contacts,wake:AirWake.behind(vehicle,leaders:traffic.cars.map(\.vehicle)))
        collisionCooldown = max(0, collisionCooldown - dt)
        if let contact = traffic.step(dt, player: &vehicle, circuit: circuit, line: world.racingLine),
           contact.closingSpeed > 1.5, collisionCooldown <= 0 {
            vehicle.impact(normalSpeed: contact.closingSpeed, outwardNormal: contact.normal)
            let strength = clamp(contact.closingSpeed/12,0,1)
            let side = simd_dot(contact.normal,vehicle.modelX)
            impactFeedback = SIMD2(strength*(side < -0.2 ? 0.25 : 1),strength*(side > 0.2 ? 0.25 : 1))
            collisionCooldown = 0.4
            announce("与电脑车辆接触", duration: 2)
        }
        location = circuit.nearest(to: vehicle.position)
        if location.distance > 15.05 {
            let offset = vehicle.position - location.point
            let normal = simd_normalize(offset)
            vehicle.position = location.point + normal * 15.0
            let impact = vehicle.hitBarrier(outward:normal)
            if impact > 1.5 {
                if collisionCooldown <= 0 {
                    vehicle.impact(normalSpeed: impact, outwardNormal: normal)
                    let side = simd_dot(normal,vehicle.modelX), strength = clamp(impact/12,0,1)
                    impactFeedback = SIMD2(strength*(side < -0.2 ? 0.25 : 1),strength*(side > 0.2 ? 0.25 : 1))
                }
                collisionCooldown = 0.4
                announce(sprint == nil ? "碰撞损伤 · R 复位保留车损 · Shift+P 拖车" : "碰撞损伤 · 可从暂停菜单重新发车",duration:3)
            }
        }
        let onLane = circuit.pitLane.contains(location)
        if onLane != inPitLane {
            inPitLane = onLane
            if sprint == nil { session.beginOutLap(at: location.progress) }
            if onLane { autoDriveEnabled = false }
            if sprint == nil {
                announce(onLane ? "维修道 · 限速 60 km/h · 黄框停车后按 P" : "驶出维修道 · 出场圈",duration:3)
            } else if onLane {
                announce("短赛进入维修道 · 限速 60 km/h",duration:3)
            }
        }
        if let race = sprint, !race.finished {
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
            if let updatedRace = sprint { traffic.startCooldown(forRivalsFinishedIn:updatedRace) }
            if !wasFinished && sprint?.playerFinished == true {
                announce("已过终点 · 继续减速驶离", duration: 4)
            }
            if sprint?.finished == true { saveTelemetry(background:true) }
        } else if sprint == nil && !inPitLane && session.step(dt, vehicle: vehicle, location: location, trackLength: circuit.length,
            trackWidth: circuit.width, assisted: autoDriveEnabled, input: controls) {
            if let lap = session.analysedLap { analysis[recordKey, default: PracticeAnalysis()].append(lap) }
            if session.newBest {
                announce("个人最佳  \(lapTime(session.best))  ·  幽灵车已更新", duration: 6)
            } else { announce((session.lastValid ? "完成有效圈  " : "本圈无效 · 不计入最佳  ")+lapTime(session.last), duration:5) }
            if session.newBest || session.analysedLap != nil { savePractice(background:true) }
        }
        telemetryElapsed += dt
        telemetryClock += dt
        if telemetryClock + 1e-9 >= 0.1 && sprint?.finished != true {
            telemetryClock = max(0,telemetryClock-0.1)
            if telemetry.count < 36001 {
                let profile = circuit.roadProfile(at:location.progress,lateral:location.lateral)
                let base = String(format: "%.3f,%.3f,%.3f,%.2f,%d,%.0f,%.3f,%.3f,%.3f,%.3f,%.3f,%d",
                    sprint?.elapsed ?? session.elapsed, vehicle.position.x, vehicle.position.y, vehicle.speedKPH, vehicle.gear,
                    vehicle.rpm, controls.throttle, controls.brake, controls.steering,
                    vehicle.lateralG, vehicle.longitudinalG, sprint == nil && session.validLap ? 1 : 0)
                let wheels = vehicle.wheels
                let raceLap = sprint.map { min($0.lapCount,($0.entries.first?.laps ?? 0)+1) } ?? session.lap
                var data = wheels.map(\.temperature)
                data += wheels.map(\.pressure)
                data += wheels.map(\.wear)
                data += [vehicle.damage.front, vehicle.damage.rear, vehicle.damage.engine, vehicle.coolantTemperature]
                data += wheels.map { $0.suspensionTravel * 1000 }
                data += wheels.map(\.normalLoad)
                data += wheels.map(\.kerbFeedback)
                data += [Double(vehicle.kind.rawValue),Double(circuit.kind.rawValue),Double(assists.absLevel),
                         Double(assists.tcLevel),vehicle.absRelease,vehicle.tcReduction,assists.frontBrakeBias]
                data += [vehicle.brakeLinePressure,vehicle.yawRate,vehicle.aeroLoad.x,vehicle.aeroLoad.y]
                data += wheels.map(\.gripUsage)
                data += wheels.map(\.surfaceContamination)
                data += [Double(circuit.condition.rawValue),Double(wheels[0].setup.compound.rawValue)]
                data += wheels.map(\.waterFilm)
                data += [vehicle.roadElevation,profile.grade*100,profile.crossfall*100]
                data += wheels.flatMap { [$0.treadTemperatures.x,$0.treadTemperatures.y,$0.treadTemperatures.z] }
                data += [telemetryElapsed,location.progress,location.lateral,vehicle.steeringAngle,Double(raceLap)]
                data += wheels.map { vehicle.brakeLinePressure * $0.brakePressure }
                data += wheels.map(\.slipRatio)
                data += wheels.map(\.longitudinalForce)
                let pressureTarget = activeAssists.brakeCurve.pressure(for:command.brake)
                data += [vehicle.wakeStrength,command.throttle,command.brake,pressureTarget,vehicle.engineThrottle]
                data += wheels.map(\.slidingFraction)
                data += wheels.map(\.lateralForce)
                let decimals = String(repeating:",%.4f",count:data.count)
                let fields = String(format:decimals,arguments:data)
                telemetry.append(base+fields)
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
                if settingsPage == nil && sessionPrompt == nil && garageSelection == nil && !showHelp && !showingAnalysis && !showingControllerReview { self.action("confirm") }
            } else if action != "menuAccept" { hud.moveMenuFocus(action) }
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
            case "hapticTest", "hapticLevel", "deadzoneDown", "deadzoneUp", "brakeCurve", "steeringCurve", "controllerDisconnected":
                break
            default: return
            }
            if !showingControllerReview { hud.needsDisplay = true; return }
        }
        if showingAnalysis {
            switch action {
            case "analysis", "pause", "confirm", "menuBack": showingAnalysis = false
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
            switch action {
            case "pause", "menuBack", "cancelPrompt":
                sessionPrompt = nil; hud.needsDisplay = true; return
            case "confirmPrompt":
                guard prompt != .pit else { return }
                sessionPrompt = nil
                self.action(prompt == .restart ? "restart" : (sprint == nil ? "leavePractice" : "leaveSprint"))
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
        case "askRestart", "askLeavePractice", "pitMenu":
            guard isPaused && hasStarted && (action != "pitMenu" || sprint == nil) else { return }
            sessionPrompt = action == "pitMenu" ? .pit : (action == "askRestart" ? .restart : .leave)
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
            guard !editingHUD, sprint == nil else { return }
            isPaused = true
            showingAnalysis = true
            analysisPage = 0
            input.clear()
            saveTelemetry()
        case "service", "tow":
            guard hasStarted && serviceRemaining == 0 && sprint == nil else { return }
            let lane = circuit.pitLane
            let contact = circuit.nearest(to:vehicle.position)
            if action == "service" {
                guard lane.inServiceBox(contact) && vehicle.speed < 0.55 else {
                    announce("请在维修黄框内停稳 · Shift+P 拖车",duration:3)
                    return
                }
            }
            saveTelemetry()
            let sample = action == "tow" ? lane.serviceSample(on:circuit) :
                TrackSample(point:vehicle.position,tangent:vehicle.forward,distance:contact.progress)
            vehicle.reset(at:sample,preservingCondition:true)
            world.breakTyreMarkStreaks()
            previousVehicle = nil
            vehicle.gear = 0
            location = circuit.nearest(to:vehicle.position)
            inPitLane = true
            session.beginOutLap(at:location.progress)
            gTrace.removeAll(keepingCapacity:true)
            inputHistory.reset()
            autoDriveEnabled = false
            serviceRemaining = 12
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
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            let delta = action == "vehicleNext" ? 1 : -1
            let count = VehicleKind.allCases.count
            selectVehicle(VehicleKind(rawValue:(vehicle.kind.rawValue+delta+count)%count)!)
        case "trackNext", "trackPrevious":
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            let count = CircuitKind.allCases.count
            let shift = action == "trackNext" ? 1 : -1
            selectCircuit(CircuitKind(rawValue:(circuit.kind.rawValue+count+shift)%count)!,condition:circuit.condition)
        case "trackCondition":
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            let next: TrackCondition = circuit.condition == .dry ? .wet : .dry
            selectCircuit(circuit.kind,condition:next)
        case "compound":
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            tyreSetup.compound = TyreCompound(rawValue: (tyreSetup.compound.rawValue + 1) % TyreCompound.allCases.count)!
            savePractice()
        case "pressureDown", "pressureUp":
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            tyreSetup.coldPressure = clamp(tyreSetup.coldPressure + (action == "pressureUp" ? 0.05 : -0.05), 1.3, 2.1)
            savePractice()
        case "hudLayout","cancelHUDLayout":
            guard hasStarted else { return }
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
            guard isPaused && sprint == nil else { return }
            opponentCount = (opponentCount + 1) % 4
            traffic.reset(count: opponentCount, kind: vehicle.kind, circuit: circuit, from: location.progress)
            savePractice()
        case "autoDrive":
            if autoDriveEnabled {
                autoDriveEnabled = false
                announce("已切回手动驾驶", duration: 2)
            } else if serviceRemaining == 0 && !inPitLane && ComputerDriver.canDrive(vehicle, at: location, on: circuit) {
                autoDriveEnabled = true
                announce("自动驾驶开启 · 操作油门、刹车或转向可接管", duration: 4)
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
            if !hasStarted { self.action("start") }
            else if isPaused { self.action("resume") }
        case "start":
            sprint = nil
            hasStarted = true
            isPaused = false
            showHelp = false
            resetAtStart()
            announce("驶出发车区 · 先熟悉制动点和赛道", duration: 5)
        case "startSprint":
            guard isPaused && serviceRemaining == 0 && sprint == nil else { return }
            saveTelemetry()
            startSprint()
        case "leaveSprint":
            guard sprint != nil else { return }
            saveTelemetry()
            sprint = nil
            autoDriveEnabled = false
            hasStarted = false
            isPaused = true
            resetAtStart()
            noticeRemaining = 0
        case "leavePractice":
            guard hasStarted && isPaused && sprint == nil else { return }
            saveTelemetry()
            savePractice()
            autoDriveEnabled = false
            hasStarted = false
            resetAtStart()
            session.lap = 1; session.last = nil; session.completedLaps = 0
            noticeRemaining = 0
        case "menuBack":
            if editingHUD { self.action("cancelHUDLayout"); return }
            guard hasStarted && isPaused else { return }
            self.action("resume")
        case "pause":
            if editingHUD { self.action("cancelHUDLayout"); return }
            guard hasStarted else { return }
            isPaused.toggle()
            showHelp = false
            controlClock.reset()
            input.clear()
            if isPaused { saveTelemetry() }
        case "resume":
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
            if sprint != nil { startSprint(); break }
            resetAtStart()
            session.lap = 1
            session.last = nil
            session.completedLaps = 0
            isPaused = false
            showHelp = false
        case "reset":
            guard hasStarted && !isPaused else { return }
            guard serviceRemaining == 0 else { return }
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
            guard hasStarted && !autoDriveEnabled && !isPaused && serviceRemaining == 0 else { return }
            let previous = vehicle.gear
            let result = vehicle.requestShift(action == "upshift" ? 1 : -1, pedals: input.pedals, automatic: assists.automatic)
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
        case "automatic": assists.automatic.toggle(); savePractice()
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
        resumeAfterHUDEdit = false
        autoDriveEnabled = false
        if hasStarted && !isPaused { saveTelemetry(background:true) }
        controlClock.reset()
        input.clear()
        if hasStarted { isPaused = true }
        sound.update(rpm: vehicle.rpm, throttle: 0, paused: true)
        hud.needsDisplay = true
    }

    func shutdown() {
        timer?.invalidate()
        input.clear()
        if editingHUD { hudPositions = hudLayoutBeforeEdit }
        savePractice(background:false)
        saveTelemetry()
    }

    private func resetAtStart() {
        gTrace.removeAll(keepingCapacity: true)
        inputHistory.reset()
        feedback.reset(); impactFeedback = .zero; input.stopHaptics()
        sideTrafficHold = SideTrafficHold()
        sideTraffic = SideTraffic()
        collisionCooldown = 0
        serviceRemaining = 0
        inPitLane = false
        vehicle.reset(at: circuit.start)
        previousVehicle = nil
        vehicle.service(setup: tyreSetup)
        location = circuit.nearest(to: vehicle.position)
        traffic.reset(count: opponentCount, kind: vehicle.kind, circuit: circuit, from: location.progress)
        session.resetLap(at: location.progress)
        controlClock.reset()
        telemetry = [telemetry[0]]
        telemetrySaveRevision += 1
        telemetryClock = 0
        telemetryElapsed = 0
        world.resetCamera()
        world.clearTyreMarks()
    }

    private func selectVehicle(_ kind: VehicleKind) {
        guard kind != vehicle.kind else { return }
        saveTelemetry(); savePractice()
        vehicle.kind = kind
        world.selectVehicle(kind)
        mirrorImage = nil
        mirrorSequenceIndex = 0
        applyVehicleSettings()
        session = RaceSession(); session.restore(records[recordKey])
        resetAtStart(); savePractice()
        sceneDirty = true
        announce("已切换 "+kind.label,duration:2)
    }

    private func selectCircuit(_ kind: CircuitKind, condition: TrackCondition) {
        guard kind != circuit.kind || condition != circuit.condition else { return }
        saveTelemetry(); savePractice()
        changeCircuit(kind,condition:condition)
        session = RaceSession(); session.restore(records[recordKey])
        resetAtStart(); savePractice()
        announce("已切换 "+kind.label+" · "+condition.label,duration:2)
    }

    private func startSprint() {
        autoDriveEnabled = false
        hasStarted = true
        isPaused = false
        showHelp = false
        noticeRemaining = 0
        resetAtStart()
        let count = max(1, opponentCount)
        vehicle.reset(at: circuit.gridSlot(count))
        vehicle.service(setup: tyreSetup)
        location = circuit.nearest(to: vehicle.position)
        traffic.lineUp(count: count, kind: vehicle.kind, circuit: circuit)
        let positions = ([vehicle] + traffic.cars.map(\.vehicle)).map { circuit.nearest(to: $0.position).progress }
        sprint = SprintRace(positions: positions, trackLength: circuit.length)
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
        world = RacingWorld(circuit:circuit)
        world.applyGraphicsQuality(graphicsQuality)
        world.showRacingLine=racingLineEnabled
        world.cockpitFOV = fov; world.seatHeight = eye
        world.selectVehicle(vehicle.kind)
        sceneView.scene = world.scene; sceneView.pointOfView = world.camera
        location = circuit.nearest(to:circuit.start.point)
        sceneDirty = true
    }

    private func loadPractice() {
        let url = dataDirectory.appendingPathComponent("practice.json")
        let portable = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("APEX Lab Data/practice.json")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APEX Lab", isDirectory: true)
        let fallback = dataDirectory == support && !FileManager.default.fileExists(atPath: url.path) ? portable : url
        guard let data = try? Data(contentsOf: fallback), let saved = try? JSONDecoder().decode(SavedPractice.self, from: data), (1...10).contains(saved.version) else { return }
        if saved.version < 10 { legacyPractice = (data, saved.version) }
        if let raw = saved.vehicleKind, let kind = VehicleKind(rawValue:raw) { vehicle.kind = kind }
        let condition = saved.trackCondition.flatMap(TrackCondition.init(rawValue:)) ?? .dry
        let track = saved.circuitKind.flatMap(CircuitKind.init(rawValue:)) ?? .north
        if track != circuit.kind || condition != circuit.condition { changeCircuit(track,condition:condition) }
        if saved.version >= 9 {
            for car in VehicleKind.allCases {
                for track in CircuitKind.allCases {
                    for condition in TrackCondition.allCases {
                        for legacyLayout in track == .ridge ? [false,true] : [false] {
                            let key = LapRecord.key(vehicle:car,circuit:track,condition:condition,legacyLayout:legacyLayout)
                            if let record=saved.records?[key],record.isValid {records[key]=record}
                            if var laps = saved.analysis?[key] {
                                laps.validate()
                                analysis[key] = laps
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
        assists.automatic = saved.automatic
        assists.steeringDeadzone = saved.deadzone.isFinite ? clamp(saved.deadzone, 0.02, 0.3) : 0.08
        if let compound = saved.compound, let value = TyreCompound(rawValue: compound) { tyreSetup.compound = value }
        if let pressure = saved.coldPressure, pressure.isFinite { tyreSetup.coldPressure = clamp(pressure, 1.3, 2.1) }
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
        let saved = SavedPractice(version: 10, best: nil, ghost: [],
            abs: assists.abs, tractionControl: assists.tractionControl, automatic: assists.automatic,
            deadzone: assists.steeringDeadzone, muted: sound.muted, cockpit: cockpit,
            verticalFOV: Double(world.cockpitFOV), eyeHeight: world.seatHeight,
            compound: tyreSetup.compound.rawValue, coldPressure: tyreSetup.coldPressure,
            drivingView: drivingView.rawValue, vehicleKind: vehicle.kind.rawValue,
            circuitKind:circuit.kind.rawValue, absLevel:assists.absLevel, tcLevel:assists.tcLevel,hapticLevel:input.hapticLevel,records:records,racingLineEnabled:racingLineEnabled,opponentCount:opponentCount,hudPositions:hudPositions,pitLimiterEnabled:pitLimiterEnabled,mirrorEnabled:mirrorEnabled,compactHUD:compactHUD,
            vehicleSettings:vehicleSettings,analysis:analysis,trackCondition:circuit.condition.rawValue,
            graphicsQuality:graphicsQuality.rawValue,ghostEnabled:ghostEnabled,showHUD:showHUD,
            masterVolume:sound.masterVolume,motorVolume:sound.motorVolume,effectsVolume:sound.effectsVolume,
            renderingRate:renderingRate.rawValue)
        practiceSaveRevision += 1
        let revision = practiceSaveRevision
        let directory = dataDirectory
        let legacy = legacyPractice
        let write = {
            do {
                try Self.writePractice(saved,directory:directory,legacy:legacy)
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

    private static func writePractice(_ saved: SavedPractice,directory: URL,legacy: (data: Data,version: Int)?) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let legacyPractice = legacy {
            let name = legacyPractice.version < 9 ? "practice-before-1.6.json" : "practice-before-2.0.json"
            let backup = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:backup.path) {
                try legacyPractice.data.write(to:backup,options:.atomic)
            }
        }
        let data = try JSONEncoder().encode(saved)
        try data.write(to:directory.appendingPathComponent("practice.json"),options:.atomic)
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
        guard telemetry.count > 1 else { return }
        telemetrySaveRevision += 1
        let revision = telemetrySaveRevision
        let rows = telemetry
        let directory = dataDirectory
        let name = sprint == nil ? "latest-session.csv" : "latest-sprint.csv"
        let write = {
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try (rows.joined(separator:"\n")+"\n").write(to:directory.appendingPathComponent(name),
                                                               atomically:true,encoding:.utf8)
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

import AppKit
import SceneKit
import Metal
import simd

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
}

final class RacingGame {
    private(set) var circuit: Circuit
    let input = InputManager()
    let sound = EngineSound()
    private(set) var world: RacingWorld
    let hud = HUDView()
    let sceneView: SCNView
    var vehicle = Vehicle()
    var assists = DrivingAssists()
    private var brakeBiasByVehicle: [String:Double] = [:]
    private var brakeBiasKey: String { String(vehicle.kind.rawValue) }
    var drivingInput = DrivingInput()
    var session = RaceSession()
    private var records: [String:LapRecord] = [:]
    private var legacyPractice: Data?
    private var recordKey: String { LapRecord.key(vehicle:vehicle.kind,circuit:circuit.kind) }
    var location: TrackLocation
    var hasStarted = false
    var isPaused = true
    var showHelp = false
    var drivingView = DrivingView.chase
    var cockpit: Bool { drivingView.isInterior }
    var ghostEnabled = true
    var showHUD = true
    private(set) var compactHUD = false
    private(set) var mirrorEnabled = true
    private(set) var mirrorImage: NSImage?
    private var mirrorRenderer: SCNRenderer?
    private var nextMirrorFrame = 0.0
    var showMirror: Bool { hasStarted && !isPaused && showHUD && cockpit && mirrorEnabled && serviceRemaining == 0 }
    var sideTraffic: SideTraffic { SideTraffic(player: vehicle, opponents: traffic.cars) }
    var hudPositions: [String:HUDPosition] = [:]
    private(set) var editingHUD = false
    private var resumeAfterHUDEdit = false
    var racingLineEnabled = true
    private(set) var opponentCount = 3
    private(set) var traffic = ComputerTraffic()
    private(set) var autoDriveEnabled = false
    var tyreSetup = TyreSetup()
    var serviceRemaining = 0.0
    private(set) var inPitLane = false
    var pitLimiterEnabled = true
    var inPitSpeedZone: Bool { circuit.pitLane.isLimited(location) }
    var pitOverspeed: Bool { inPitSpeedZone && vehicle.speed > PitLane.speedLimit + 0.28 }
    var gTrace: [SIMD2<Double>] = []
    var inputHistory = InputHistory()
    var notice = ""
    var noticeRemaining = 0.0
    private var timer: Timer?
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var accumulator = 0.0
    private var renderClock = 0.0
    private var sceneDirty = true
    private var collisionCooldown = 0.0
    private var impactFeedback = SIMD2<Double>.zero
    private var feedback = HapticFeedback()
    private var telemetryClock = 0.0
    private var telemetry: [String] = ["time_s,x_m,z_m,speed_kph,gear,rpm,throttle,brake,steering,lateral_g,longitudinal_g,valid_lap,fr_surface_c,fl_surface_c,rr_surface_c,rl_surface_c,fr_bar,fl_bar,rr_bar,rl_bar,fr_wear,fl_wear,rr_wear,rl_wear,front_damage,rear_damage,engine_damage,coolant_c,fr_travel_mm,fl_travel_mm,rr_travel_mm,rl_travel_mm,fr_load_n,fl_load_n,rr_load_n,rl_load_n,fr_kerb,fl_kerb,rr_kerb,rl_kerb,car_id,track_id,abs_level,tc_level,abs_release,tc_reduction,front_brake_bias"]
    private let fixedStep = 1.0 / 240

    private var dataDirectory: URL {
        // Keep a portable prototype self-contained beside the app bundle.
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("APEX Lab Data", isDirectory: true)
    }

    init(frame: NSRect) {
        let circuit = Circuit()
        self.circuit = circuit
        world = RacingWorld(circuit: circuit)
        location = circuit.nearest(to: circuit.start.point)
        sceneView = SCNView(frame: frame, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        sceneView.autoresizingMask = [.width, .height]
        sceneView.scene = world.scene
        sceneView.pointOfView = world.camera
        sceneView.preferredFramesPerSecond = 60
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        sceneView.backgroundColor = NSColor(rgb: 0xB8CED8)
        hud.frame = frame
        hud.autoresizingMask = [.width, .height]
        hud.game = self
        input.onAction = { [weak self] action in self?.action(action) }
        vehicle.kind = .ferrari
        loadPractice()
        world.selectVehicle(vehicle.kind)
        vehicle.reset(at: self.circuit.start)
        location = self.circuit.nearest(to: vehicle.position)
        session.resetLap(at: location.progress)
        world.update(vehicle: vehicle, input: drivingInput, dt: 0, cockpit: cockpit, ghost: nil, view: drivingView)
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = clamp(now - lastTime, 0, 1.0 / 15)
        lastTime = now
        let wasPaused = isPaused
        drivingInput = input.read(dt: dt, deadzone: assists.steeringDeadzone, acceptDriving: hasStarted && !isPaused)
        // Button handlers can change pause state during polling.
        if isPaused || wasPaused { drivingInput = DrivingInput() }
        if !isPaused && hasStarted && serviceRemaining > 0 {
            drivingInput = DrivingInput()
            accumulator = 0
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
                        line: world.racingLine, pace: 0.82, traffic: traffic.cars.map(\.vehicle))
                } else {
                    autoDriveEnabled = false
                    drivingInput = DrivingInput(brake: 1)
                    announce("自动驾驶已退出 · 请对准赛道方向", duration: 3)
                }
            }
            accumulator += dt
            while accumulator >= fixedStep {
                simulate(fixedStep)
                accumulator -= fixedStep
            }
        } else { accumulator = 0 }
        if noticeRemaining > 0 { noticeRemaining -= dt }
        let driving = hasStarted && !isPaused && serviceRemaining == 0
        inputHistory.update(input:drivingInput,absActive:vehicle.absActive,dt:dt,active:driving)
        impactFeedback *= exp(-dt*12)
        let signal = feedback.update(vehicle:vehicle,input:drivingInput,impact:impactFeedback,dt:dt,active:driving)
        input.updateHaptics(signal,dt:dt,driving:driving)
        sound.update(rpm: vehicle.rpm, throttle: drivingInput.throttle, ignition: vehicle.ignitionFraction, cockpit: cockpit, kerb: vehicle.kerbFeedback, roadSpeed: vehicle.speed, paused: isPaused || !hasStarted || serviceRemaining > 0)
        let ghost = ghostEnabled && hasStarted ? session.ghost(at: session.elapsed) : nil
        let running = hasStarted && !isPaused
        if sceneView.isPlaying != running {
            sceneView.isPlaying = running
            sceneView.rendersContinuously = running
            sceneDirty = true
        }
        if running || sceneDirty {
            world.updateTraffic(hasStarted ? traffic.cars.map(\.vehicle) : [])
            world.sideLook = input.sideLook
            world.update(vehicle:vehicle,input:drivingInput,dt:dt,cockpit:cockpit,ghost:ghost,view:drivingView)
            if !running { sceneView.needsDisplay = true }
            sceneDirty = false
        }
        updateMirror(at: now)
        renderClock += dt
        if renderClock >= 1.0 / 30 {
            renderClock = 0
            if hasStarted && !isPaused && serviceRemaining == 0 {
                gTrace.append(vehicle.driverG)
                if gTrace.count > 45 { gTrace.removeFirst(gTrace.count - 45) }
            }
            hud.needsDisplay = true
        }
    }

    private func updateMirror(at now: Double) {
        guard showMirror else {
            mirrorImage = nil
            nextMirrorFrame = 0
            return
        }
        guard now >= nextMirrorFrame else { return }
        if mirrorRenderer == nil {
            guard let device = sceneView.device ?? MTLCreateSystemDefaultDevice() else { return }
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = world.scene
            renderer.pointOfView = world.mirrorCamera
            mirrorRenderer = renderer
        }
        mirrorImage = mirrorRenderer?.snapshot(atTime: now, with: CGSize(width: 360, height: 96), antialiasingMode: .none)
        nextMirrorFrame = ProcessInfo.processInfo.systemUptime + 1.0 / 15
    }

    private func simulate(_ dt: Double) {
        location = circuit.nearest(to: vehicle.position)
        let contacts = vehicle.contactPoints.map { point -> WheelRoadContact in
            let contact = circuit.nearest(to: point)
            if circuit.pitLane.hasAsphalt(at: contact) {
                return WheelRoadContact(distance:0,progress:contact.progress,kerbsEnabled:false)
            }
            return WheelRoadContact(distance:contact.distance, progress:contact.progress,
                                    kerbsEnabled:circuit.hasKerb(at:contact.progress))
        }
        var activeAssists = assists
        if autoDriveEnabled {activeAssists.automatic = true}
        let command = pitLimiterEnabled && inPitSpeedZone ? pitLimitedInput(drivingInput,speed:vehicle.speed) : drivingInput
        vehicle.step(dt, input: command, assists: activeAssists, roadDistance: location.distance, roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress, kerbsEnabled: circuit.hasKerb(at: location.progress), roadContacts: contacts)
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
            let impact = simd_dot(vehicle.velocity, normal)
            if impact > 0 {
                if collisionCooldown <= 0 {
                    vehicle.impact(normalSpeed: impact, outwardNormal: normal)
                    let side = simd_dot(normal,vehicle.modelX), strength = clamp(impact/12,0,1)
                    impactFeedback = SIMD2(strength*(side < -0.2 ? 0.25 : 1),strength*(side > 0.2 ? 0.25 : 1))
                }
                vehicle.velocity -= normal * impact * 1.20
                vehicle.velocity *= 0.62
                vehicle.yawRate *= 0.5
                collisionCooldown = 0.4
                announce("碰撞损伤 · R 复位保留车损 · Shift+P 拖车", duration: 3)
            }
        }
        let onLane = circuit.pitLane.contains(location)
        if onLane != inPitLane {
            inPitLane = onLane
            session.beginOutLap(at: location.progress)
            if onLane { autoDriveEnabled = false }
            announce(onLane ? "维修道 · 限速 60 km/h · 黄框停车后按 P" : "驶出维修道 · 出场圈", duration: 3)
        }
        if !inPitLane && session.step(dt, vehicle: vehicle, location: location, trackLength: circuit.length, trackWidth: circuit.width, assisted: autoDriveEnabled) {
            if session.newBest {
                announce("个人最佳  \(lapTime(session.best))  ·  幽灵车已更新", duration: 6)
                savePractice()
            } else { announce((session.lastValid ? "完成有效圈  " : "本圈无效 · 不计入最佳  ")+lapTime(session.last), duration:5) }
        }
        telemetryClock += dt
        if telemetryClock >= 0.1 {
            telemetryClock = 0
            if telemetry.count < 36001 {
                telemetry.append(String(format: "%.3f,%.3f,%.3f,%.2f,%d,%.0f,%.3f,%.3f,%.3f,%.3f,%.3f,%d",
                    session.elapsed, vehicle.position.x, vehicle.position.y, vehicle.speedKPH, vehicle.gear,
                    vehicle.rpm, drivingInput.throttle, drivingInput.brake, drivingInput.steering,
                    vehicle.lateralG, vehicle.longitudinalG, session.validLap ? 1 : 0)
                    + (vehicle.wheels.map { $0.temperature } + vehicle.wheels.map { $0.pressure }
                        + vehicle.wheels.map { $0.wear } + [vehicle.damage.front, vehicle.damage.rear,
                            vehicle.damage.engine, vehicle.coolantTemperature]
                        + vehicle.wheels.map { $0.suspensionTravel * 1000 }
                        + vehicle.wheels.map { $0.normalLoad } + vehicle.wheels.map { $0.kerbFeedback }
                        + [Double(vehicle.kind.rawValue),Double(circuit.kind.rawValue),Double(assists.absLevel),Double(assists.tcLevel),vehicle.absRelease,vehicle.tcReduction,assists.frontBrakeBias]).map { String(format: ",%.4f", $0) }.joined())
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
            announce("驾驶画面已保存到 APEX Lab Data / driving-view.png",duration:3)
        } catch { announce("截图保存失败：\(error.localizedDescription)",duration:5) }
    }

    func action(_ action: String) {
        if editingHUD && !["hudLayout", "hudLayoutReset", "pause", "controllerDisconnected"].contains(action) { return }
        sceneDirty = true
        switch action {
        case "service", "tow":
            guard hasStarted && serviceRemaining == 0 else { return }
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
            accumulator = 0
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
            guard isPaused && serviceRemaining == 0 else { return }
            saveTelemetry(); savePractice()
            let delta = action == "vehicleNext" ? 1 : -1
            vehicle.kind = VehicleKind(rawValue:(vehicle.kind.rawValue+delta+VehicleKind.allCases.count)%VehicleKind.allCases.count)!
            world.selectVehicle(vehicle.kind)
            assists.frontBrakeBias = brakeBiasByVehicle[brakeBiasKey] ?? DrivingAssists.defaultBrakeBias
            session = RaceSession(); session.restore(records[recordKey])
            resetAtStart(); savePractice()
            announce("已切换 \(vehicle.kind.label) · 新练习",duration:2)
        case "trackNext":
            guard isPaused && serviceRemaining == 0 else { return }
            saveTelemetry(); savePractice()
            changeCircuit(CircuitKind(rawValue:(circuit.kind.rawValue+1)%CircuitKind.allCases.count)!)
            session = RaceSession(); session.restore(records[recordKey]); resetAtStart(); savePractice()
            announce("已切换 \(circuit.kind.label) · 新练习",duration:2)
        case "compound":
            guard isPaused && serviceRemaining == 0 else { return }
            tyreSetup.compound = TyreCompound(rawValue: (tyreSetup.compound.rawValue + 1) % 3)!
            savePractice()
        case "pressureDown", "pressureUp":
            guard isPaused && serviceRemaining == 0 else { return }
            tyreSetup.coldPressure = clamp(tyreSetup.coldPressure + (action == "pressureUp" ? 0.05 : -0.05), 1.3, 2.1)
            savePractice()
        case "hudLayout":
            guard hasStarted else { return }
            if editingHUD {
                editingHUD = false
                isPaused = !resumeAfterHUDEdit
                savePractice()
            } else {
                resumeAfterHUDEdit = !isPaused
                isPaused = true
                editingHUD = true
            }
            input.clear()
            hud.layoutModeChanged()
        case "hudLayoutReset":
            guard editingHUD else { return }
            hudPositions.removeAll()
        case "opponents":
            guard isPaused else { return }
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
        case "hud": showHUD.toggle()
        case "compactHUD":
            compactHUD.toggle()
            savePractice()
        case "statistics": sceneView.showsStatistics.toggle()
        case "fovDown": world.cockpitFOV = max(42,world.cockpitFOV-2)
        case "fovUp": world.cockpitFOV = min(84,world.cockpitFOV+2)
        case "seatUp": world.seatHeight = min(1.10,world.seatHeight+0.02)
        case "seatDown": world.seatHeight = max(1.00,world.seatHeight-0.02)
        case "capture": captureFrame()
        case "confirm":
            if !hasStarted { self.action("start") }
            else if isPaused { self.action("resume") }
        case "start":
            hasStarted = true
            isPaused = false
            showHelp = false
            resetAtStart()
            announce("驶出发车区 · 先熟悉制动点和赛道", duration: 5)
        case "pause":
            if editingHUD { self.action("hudLayout"); return }
            if !hasStarted { self.action("start"); return }
            isPaused.toggle()
            showHelp = false
            input.clear()
            if isPaused { saveTelemetry() }
        case "resume":
            isPaused = false
            showHelp = false
            input.clear()
        case "help":
            if !hasStarted { hasStarted = true; resetAtStart() }
            isPaused = true
            showHelp = true
            input.clear()
        case "restart":
            saveTelemetry()
            resetAtStart()
            session.lap = 1
            session.last = nil
            session.completedLaps = 0
            isPaused = false
            showHelp = false
        case "reset":
            guard hasStarted else { self.action("start"); return }
            guard serviceRemaining == 0 else { return }
            let outLap = inPitLane || session.waitingForStart
            let sample = circuit.sample(at: location.progress)
            vehicle.reset(at: sample, preservingCondition: true)
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
            } else if result == .shifted && (previous <= 0 || vehicle.gear <= 0) {
                announce("挡位 \(vehicle.gearLabel)", duration: 1.2)
            }
        case "brakeBiasDown", "brakeBiasUp":
            let change = action == "brakeBiasUp" ? 0.005 : -0.005
            let value = DrivingAssists.validatedBrakeBias(assists.frontBrakeBias + change)
            guard value != assists.frontBrakeBias else { return }
            assists.frontBrakeBias = value
            brakeBiasByVehicle[brakeBiasKey] = value
            savePractice()
            announce(String(format:"前轴制动力 %.1f%%",value*100), duration: 2)
        case "abs": assists.absLevel = (assists.absLevel+1)%6; savePractice(); announce("ABS \(assists.absLevel)/5 · 0 关闭，5 强介入",duration:2)
        case "tc": assists.tcLevel = (assists.tcLevel+1)%6; savePractice(); announce("TCS \(assists.tcLevel)/5 · 0 关闭，5 强介入",duration:2)
        case "automatic": assists.automatic.toggle(); savePractice()
        case "hapticLevel":
            input.hapticLevel = (input.hapticLevel+1)%5; input.stopHaptics(); savePractice()
        case "hapticTest":
            guard isPaused else { return }
            announce(input.testHaptics() ? "震动测试：左 → 右 → 刹车 → 油门" : "震动不可用或强度为 0 · " + input.hapticStatus,duration:3)
        case "mute": sound.muted.toggle(); savePractice()
        case "ghost": ghostEnabled.toggle()
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

    func loseFocus() {
        resumeAfterHUDEdit = false
        autoDriveEnabled = false
        input.clear()
        if hasStarted { isPaused = true }
        sound.update(rpm: vehicle.rpm, throttle: 0, paused: true)
        hud.needsDisplay = true
    }

    func shutdown() {
        timer?.invalidate()
        input.clear()
        savePractice()
        saveTelemetry()
    }

    private func resetAtStart() {
        gTrace.removeAll(keepingCapacity: true)
        inputHistory.reset()
        feedback.reset(); impactFeedback = .zero; input.stopHaptics()
        collisionCooldown = 0
        serviceRemaining = 0
        inPitLane = false
        vehicle.reset(at: circuit.start)
        vehicle.service(setup: tyreSetup)
        location = circuit.nearest(to: vehicle.position)
        traffic.reset(count: opponentCount, kind: vehicle.kind, circuit: circuit, from: location.progress)
        session.resetLap(at: location.progress)
        accumulator = 0
        telemetry = [telemetry[0]]
        telemetryClock = 0
        world.resetCamera()
    }

    private func announce(_ message: String, duration: Double) {
        notice = message
        noticeRemaining = duration
    }

    private func changeCircuit(_ kind: CircuitKind) {
        let fov = world.cockpitFOV, eye = world.seatHeight
        circuit = Circuit(kind:kind)
        mirrorRenderer = nil
        mirrorImage = nil
        world = RacingWorld(circuit:circuit)
        world.showRacingLine=racingLineEnabled
        world.cockpitFOV = fov; world.seatHeight = eye
        world.selectVehicle(vehicle.kind)
        sceneView.scene = world.scene; sceneView.pointOfView = world.camera
        location = circuit.nearest(to:circuit.start.point)
        sceneDirty = true
    }

    private func loadPractice() {
        let url = dataDirectory.appendingPathComponent("practice.json")
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedPractice.self, from: data), (1...9).contains(saved.version) else { return }
        if saved.version<9 {legacyPractice=data}
        if let raw = saved.vehicleKind, let kind = VehicleKind(rawValue:raw) { vehicle.kind = kind }
        if let raw = saved.circuitKind, let kind = CircuitKind(rawValue:raw), kind != circuit.kind { changeCircuit(kind) }
        if saved.version==9, let savedRecords=saved.records {
            for car in VehicleKind.allCases { for track in CircuitKind.allCases {
                let key=LapRecord.key(vehicle:car,circuit:track)
                if let record=savedRecords[key],record.isValid {records[key]=record}
            }}
            session.restore(records[recordKey])
        }
        assists.abs = saved.abs
        assists.tractionControl = saved.tractionControl
        if let level = saved.absLevel { assists.absLevel = clamp(level,0,5) }
        if let level = saved.tcLevel { assists.tcLevel = clamp(level,0,5) }
        input.hapticLevel = clamp(saved.hapticLevel ?? 3,0,4)
        assists.automatic = saved.automatic
        for kind in VehicleKind.allCases {
            let key = String(kind.rawValue)
            if let value = saved.brakeBiasByVehicle?[key], value.isFinite {
                brakeBiasByVehicle[key] = DrivingAssists.validatedBrakeBias(value)
            }
        }
        assists.frontBrakeBias = brakeBiasByVehicle[brakeBiasKey] ?? DrivingAssists.defaultBrakeBias
        assists.steeringDeadzone = saved.deadzone.isFinite ? clamp(saved.deadzone, 0.02, 0.3) : 0.08
        if let compound = saved.compound, let value = TyreCompound(rawValue: compound) { tyreSetup.compound = value }
        if let pressure = saved.coldPressure, pressure.isFinite { tyreSetup.coldPressure = clamp(pressure, 1.3, 2.1) }
        pitLimiterEnabled = saved.pitLimiterEnabled ?? true
        mirrorEnabled = saved.mirrorEnabled ?? true
        compactHUD = saved.compactHUD ?? false
        opponentCount = clamp(saved.opponentCount ?? 3, 0, 3)
        hudPositions = (saved.hudPositions ?? [:]).filter { $0.value.x.isFinite && $0.value.y.isFinite }
        racingLineEnabled=saved.racingLineEnabled ?? true
        world.showRacingLine=racingLineEnabled
        sound.muted = saved.muted
        drivingView = saved.drivingView.flatMap(DrivingView.init(rawValue:)) ?? ((saved.cockpit ?? false) ? .cockpit : .chase)
        if let v = saved.verticalFOV, v.isFinite { world.cockpitFOV = CGFloat(clamp(v,42,84)) }
        if let v = saved.eyeHeight, v.isFinite { world.seatHeight = clamp(v,1.00,1.10) }
    }

    private func savePractice() {
        if let record=session.record {records[recordKey]=record}
        let saved = SavedPractice(version: 9, best: session.best, ghost: session.bestGhost,
            abs: assists.abs, tractionControl: assists.tractionControl, automatic: assists.automatic,
            deadzone: assists.steeringDeadzone, muted: sound.muted, cockpit: cockpit,
            verticalFOV: Double(world.cockpitFOV), eyeHeight: world.seatHeight,
            compound: tyreSetup.compound.rawValue, coldPressure: tyreSetup.coldPressure,
            drivingView: drivingView.rawValue, vehicleKind: vehicle.kind.rawValue,
            circuitKind:circuit.kind.rawValue, absLevel:assists.absLevel, tcLevel:assists.tcLevel,hapticLevel:input.hapticLevel,records:records,racingLineEnabled:racingLineEnabled,opponentCount:opponentCount,hudPositions:hudPositions,brakeBiasByVehicle:brakeBiasByVehicle,pitLimiterEnabled:pitLimiterEnabled,mirrorEnabled:mirrorEnabled,compactHUD:compactHUD)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            if let legacyPractice {
                let backup=dataDirectory.appendingPathComponent("practice-before-1.6.json")
                if !FileManager.default.fileExists(atPath:backup.path) {try legacyPractice.write(to:backup,options:.atomic)}
                self.legacyPractice=nil
            }
            let data = try JSONEncoder().encode(saved)
            try data.write(to: dataDirectory.appendingPathComponent("practice.json"), options: .atomic)
        } catch { announce("设置保存失败：请将应用放在可写文件夹中", duration: 4) }
    }

    private func saveTelemetry() {
        guard telemetry.count > 1 else { return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try (telemetry.joined(separator: "\n") + "\n").write(to: dataDirectory.appendingPathComponent("latest-session.csv"), atomically: true, encoding: .utf8)
        } catch { announce("遥测保存失败：请检查应用所在文件夹的写入权限", duration: 4) }
    }
}

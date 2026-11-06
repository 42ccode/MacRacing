import AppKit
import SceneKit
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
}

final class RacingGame {
    let circuit: Circuit
    let input = InputManager()
    let sound = EngineSound()
    let world: RacingWorld
    let hud = HUDView()
    let sceneView: SCNView
    var vehicle = Vehicle()
    var assists = DrivingAssists()
    var drivingInput = DrivingInput()
    var session = RaceSession()
    var location: TrackLocation
    var hasStarted = false
    var isPaused = true
    var showHelp = false
    var cockpit = true
    var ghostEnabled = true
    var showHUD = true
    var notice = ""
    var noticeRemaining = 0.0
    private var timer: Timer?
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var accumulator = 0.0
    private var renderClock = 0.0
    private var sceneDirty = true
    private var collisionCooldown = 0.0
    private var telemetryClock = 0.0
    private var telemetry: [String] = ["time_s,x_m,z_m,speed_kph,gear,rpm,throttle,brake,steering,lateral_g,longitudinal_g,valid_lap"]
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
        loadPractice()
        vehicle.reset(at: circuit.start)
        session.resetLap(at: location.progress)
        world.update(vehicle: vehicle, input: drivingInput, dt: 0, cockpit: cockpit, ghost: nil)
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
        if !isPaused && hasStarted {
            accumulator += dt
            while accumulator >= fixedStep {
                simulate(fixedStep)
                accumulator -= fixedStep
            }
        } else { accumulator = 0 }
        if noticeRemaining > 0 { noticeRemaining -= dt }
        let kerb = location.distance > 5.75 && location.distance < 7.15 && vehicle.speed > 3 && circuit.hasKerb(at: location.progress)
        let rumble = isPaused ? 0 : ((kerb ? 0.22 : 0) + vehicle.tyreSlip * min(vehicle.speed / 12, 1) * 0.3 + (collisionCooldown > 0.2 ? 0.4 : 0))
        input.rumble(rumble, dt: dt)
        sound.update(rpm: vehicle.rpm, throttle: drivingInput.throttle, ignition: vehicle.ignitionFraction, cockpit: cockpit, paused: isPaused || !hasStarted)
        let ghost = ghostEnabled && hasStarted ? session.ghost(at: session.elapsed) : nil
        let running = hasStarted && !isPaused
        if sceneView.isPlaying != running {
            sceneView.isPlaying = running
            sceneView.rendersContinuously = running
            sceneDirty = true
        }
        if running || sceneDirty {
            world.exteriorLook = input.exteriorLook
            world.update(vehicle:vehicle,input:drivingInput,dt:dt,cockpit:cockpit,ghost:ghost)
            if !running { sceneView.needsDisplay = true }
            sceneDirty = false
        }
        renderClock += dt
        if renderClock >= 1.0 / 30 {
            renderClock = 0
            hud.needsDisplay = true
        }
    }

    private func simulate(_ dt: Double) {
        location = circuit.nearest(to: vehicle.position)
        vehicle.step(dt, input: drivingInput, assists: assists, roadDistance: location.distance, roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress, kerbsEnabled: circuit.hasKerb(at: location.progress))
        location = circuit.nearest(to: vehicle.position)
        collisionCooldown = max(0, collisionCooldown - dt)
        if location.distance > 15.05 {
            let offset = vehicle.position - location.point
            let normal = simd_normalize(offset)
            vehicle.position = location.point + normal * 15.0
            let impact = simd_dot(vehicle.velocity, normal)
            if impact > 0 {
                vehicle.velocity -= normal * impact * 1.20
                vehicle.velocity *= 0.62
                vehicle.yawRate *= 0.5
                collisionCooldown = 0.4
                announce("碰到护栏 · 长按 A 或按 R 回到赛道", duration: 3)
            }
        }
        if session.step(dt, vehicle: vehicle, location: location, trackLength: circuit.length, trackWidth: circuit.width) {
            if session.newBest {
                announce("个人最佳  \(lapTime(session.best))  ·  幽灵车已更新", duration: 6)
                savePractice()
            } else { announce("完成一圈  \(lapTime(session.last))", duration: 5) }
        }
        telemetryClock += dt
        if telemetryClock >= 0.1 {
            telemetryClock = 0
            if telemetry.count < 36001 {
                telemetry.append(String(format: "%.3f,%.3f,%.3f,%.2f,%d,%.0f,%.3f,%.3f,%.3f,%.3f,%.3f,%d",
                    session.elapsed, vehicle.position.x, vehicle.position.y, vehicle.speedKPH, vehicle.gear,
                    vehicle.rpm, drivingInput.throttle, drivingInput.brake, drivingInput.steering,
                    vehicle.lateralG, vehicle.longitudinalG, session.validLap ? 1 : 0))
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
        sceneDirty = true
        switch action {
        case "hud": showHUD.toggle()
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
            let sample = circuit.sample(at: location.progress)
            vehicle.reset(at: sample)
            location = circuit.nearest(to: vehicle.position)
            session.resetLap(at: location.progress)
            world.resetCamera()
            announce(location.progress > 20 ? "车辆已复位 · 通过起点后重新计时" : "车辆已复位 · 本圈重新开始", duration: 4)
        case "camera", "viewCabin", "viewChase":
            cockpit = action == "camera" ? !cockpit : action == "viewCabin"
            world.resetCamera()
            if hasStarted { announce(cockpit ? "车内 · 驾驶舱" : "车外 · 后方跟车", duration: 1.5) }
            savePractice()
        case "upshift": if !assists.automatic && !isPaused { vehicle.shift(1) }
        case "downshift": if !assists.automatic && !isPaused { vehicle.shift(-1) }
        case "abs": assists.abs.toggle(); savePractice()
        case "tc": assists.tractionControl.toggle(); savePractice()
        case "automatic": assists.automatic.toggle(); savePractice()
        case "mute": sound.muted.toggle(); savePractice()
        case "ghost": ghostEnabled.toggle()
        case "deadzoneDown": assists.steeringDeadzone = max(0.02, assists.steeringDeadzone - 0.02); savePractice()
        case "deadzoneUp": assists.steeringDeadzone = min(0.30, assists.steeringDeadzone + 0.02); savePractice()
        case "controllerDisconnected":
            if hasStarted { isPaused = true; input.clear(); announce("手柄连接断开 · 已暂停", duration: 6) }
        default: break
        }
        hud.needsDisplay = true
    }

    func loseFocus() {
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
        vehicle.reset(at: circuit.start)
        location = circuit.nearest(to: vehicle.position)
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

    private func loadPractice() {
        let url = dataDirectory.appendingPathComponent("practice.json")
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedPractice.self, from: data), [1, 2, 3].contains(saved.version) else { return }
        if saved.version == 3, let best = saved.best, best.isFinite, best > 15, saved.ghost.count <= 100000,
           saved.ghost.allSatisfy({ $0.time.isFinite && $0.x.isFinite && $0.z.isFinite && $0.heading.isFinite }) {
            session.best = best
            session.bestGhost = saved.ghost
        }
        assists.abs = saved.abs
        assists.tractionControl = saved.tractionControl
        assists.automatic = saved.automatic
        assists.steeringDeadzone = saved.deadzone.isFinite ? clamp(saved.deadzone, 0.02, 0.3) : 0.08
        sound.muted = saved.muted
        cockpit = saved.cockpit ?? true
        if let v = saved.verticalFOV, v.isFinite { world.cockpitFOV = CGFloat(clamp(v,42,84)) }
        if let v = saved.eyeHeight, v.isFinite { world.seatHeight = clamp(v,1.00,1.10) }
    }

    private func savePractice() {
        let saved = SavedPractice(version: 3, best: session.best, ghost: session.bestGhost,
            abs: assists.abs, tractionControl: assists.tractionControl, automatic: assists.automatic,
            deadzone: assists.steeringDeadzone, muted: sound.muted, cockpit: cockpit,
            verticalFOV: Double(world.cockpitFOV), eyeHeight: world.seatHeight)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
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

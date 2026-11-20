import AppKit
import GameController
import CoreHaptics

enum HapticRoute: Int, CaseIterable {
    case automatic, handles, split, all

    var label: String {
        switch self {
        case .automatic: return "自动"
        case .handles: return "合并握把"
        case .split: return "左右分离"
        case .all: return "全手柄"
        }
    }

    var next: Self { Self(rawValue:(rawValue+1)%Self.allCases.count) ?? .automatic }
}

final class InputManager {
    var keys: Set<UInt16> = []
    var onAction: ((String) -> Void)?
    private(set) var controller: GCController?
    private(set) var samples = ControllerSamples()
    private var heldButtons: Set<String> = []
    private enum ConfirmMode: Equatable { case menu, driving, inactive }
    private var confirmMode: ConfirmMode?
    private var confirmPress: Double?
    private var confirmDown = false
    private var confirmCanReset = false
    private var resetHold = 0.0
    private var resetFired = false
    private var menuStickArmed = false
    private var lastControllerPoll: Double?
    private static let buttonEdgeLifetime = 0.18
    private var shiftPresses: [(drive: String, menu: String?, time: Double)] = []
    private var observers: [NSObjectProtocol] = []
    var keyboard = KeyboardDrivingTimeline()
    private final class HapticChannel {
        let locality: GCHapticsLocality
        let engine: CHHapticEngine
        private var continuous: CHHapticPatternPlayer?
        private var continuousSpan = 1.10
        private var legacyPlayers: [Int: CHHapticPatternPlayer] = [:]
        private var activePlayer: CHHapticPatternPlayer?
        private var legacyKey: Int?
        private var legacyLevel = 0
        private var refreshAt = 0.0
        private var lastValue = 0.0
        private var lastSharpness = 0.0

        init(locality: GCHapticsLocality, engine: CHHapticEngine) throws {
            self.locality = locality
            self.engine = engine
            do {
                continuous = try makeContinuousPlayer()
            } catch {
                continuousSpan = 0.24
                continuous = try? makeContinuousPlayer()
                if continuous == nil { legacyPlayers[12] = try makeLegacyPlayer(level:12,sharp:false) }
            }
        }

        private func makeContinuousPlayer() throws -> CHHapticPatternPlayer {
            let event = Self.event(strength:1,sharpness:0.35,duration:continuousSpan)
            let silentStart = CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:0,relativeTime:0)
            return try engine.makeAdvancedPlayer(with:CHHapticPattern(events:[event],parameters:[silentStart]))
        }

        private static func event(strength: Float,sharpness: Float,duration: Double) -> CHHapticEvent {
            CHHapticEvent(eventType:.hapticContinuous,parameters:[
                CHHapticEventParameter(parameterID:.hapticIntensity,value:strength),
                CHHapticEventParameter(parameterID:.hapticSharpness,value:sharpness)
            ],relativeTime:0,duration:duration)
        }

        func play(_ value: Double, sharpness: Double, now: Double) throws {
            guard value >= (activePlayer == nil ? 0.014 : 0.009) else { stop(); return }
            let strength = clamp(value,0,0.8)
            while let continuous {
                let renew = activePlayer == nil || now >= refreshAt
                do {
                    if renew {
                        stop()
                        try continuous.start(atTime:CHHapticTimeImmediate)
                        activePlayer = continuous
                        refreshAt = now + continuousSpan - 0.06
                    }
                    if renew || abs(strength-lastValue) >= 0.003 || abs(sharpness-lastSharpness) >= 0.02 {
                        try continuous.sendParameters([
                            CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:Float(strength),relativeTime:0),
                            CHHapticDynamicParameter(parameterID:.hapticSharpnessControl,value:Float(sharpness-0.35),relativeTime:0)
                        ],atTime:CHHapticTimeImmediate)
                        lastValue = strength
                        lastSharpness = sharpness
                    }
                    return
                } catch {
                    stop()
                    if continuousSpan > 0.24 {
                        continuousSpan = 0.24
                        self.continuous = try? makeContinuousPlayer()
                    } else { self.continuous = nil }
                }
            }
            try playLegacy(strength,sharpness:sharpness,now:now)
        }

        private func makeLegacyPlayer(level: Int,sharp: Bool) throws -> CHHapticPatternPlayer {
            let event = Self.event(strength:Float(level)*0.05,sharpness:sharp ? 0.56 : 0.25,duration:0.24)
            return try engine.makePlayer(with:CHHapticPattern(events:[event],parameters:[]))
        }

        private func playLegacy(_ strength: Double, sharpness: Double, now: Double) throws {
            let level = HapticOutput.compatibilityLevel(for:strength,previous:legacyLevel)
            let sharp = sharpness > 0.5
            let key = level + (sharp ? 16 : 0)
            guard key != legacyKey || now >= refreshAt else { return }
            let player: CHHapticPatternPlayer
            if let cached = legacyPlayers[key] {
                player = cached
            } else {
                player = try makeLegacyPlayer(level:level,sharp:sharp)
                legacyPlayers[key] = player
            }
            stop()
            try player.start(atTime:CHHapticTimeImmediate)
            activePlayer = player
            legacyKey = key
            legacyLevel = level
            refreshAt = now + 0.18
        }

        func stop() {
            try? activePlayer?.stop(atTime:CHHapticTimeImmediate)
            activePlayer = nil
            legacyKey = nil
            legacyLevel = 0
        }
    }
    private var hapticChannels: [HapticChannel] = []
    private var hapticClock = 0.0
    private var hapticRetry = 0.0
    private var hapticGeneration = 0
    private var preferCombinedHaptics = false
    private var failedHapticLocalities: Set<GCHapticsLocality> = []
    private var testTime: Double? = nil
    private(set) var hapticError: String?
    var hapticLevel = 3
    private(set) var hapticRoute = HapticRoute.automatic
    var hapticsAvailable: Bool { !hapticChannels.isEmpty }
    private(set) var hapticStatus = "未连接手柄"
    var controllerName: String? { controller?.vendorName ?? controller?.productCategory }

    init(monitorControllers: Bool = true) {
        guard monitorControllers else { return }
        GCController.shouldMonitorBackgroundEvents = false
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshController()
            })
        }
        refreshController()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let pad = controller?.extendedGamepad { Self.detachButtons(pad) }
        stopHaptics()
        if !observers.isEmpty { GCController.stopWirelessControllerDiscovery() }
    }

    private func refreshController() {
        selectController(GCController.controllers().first(where: { $0.extendedGamepad != nil }))
    }

    func selectController(_ selected: GCController?) {
        guard selected !== controller else { return }
        let lostController = controller != nil
        if let pad = controller?.extendedGamepad { Self.detachButtons(pad) }
        controller = selected
        samples.reset()
        heldButtons = []
        shiftPresses.removeAll(keepingCapacity:true)
        clearConfirmAndMenuStick()
        releaseHaptics()
        hapticError = nil
        failedHapticLocalities.removeAll()
        preferCombinedHaptics = selected?.productCategory.localizedCaseInsensitiveContains("Xbox") == true
        hapticStatus = selected == nil ? "未连接手柄" : "正在检测震动"
        if let controller, let pad = controller.extendedGamepad {
            controller.playerIndex = .index1
            controller.handlerQueue = .main
            pad.buttonMenu.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                guard pressed, let self, let controller, self.controller === controller else { return }
                self.onAction?("pause")
            }
            pad.buttonA.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                guard let self, let controller, self.controller === controller else { return }
                self.observeConfirm(pressed:pressed,now:ProcessInfo.processInfo.systemUptime)
            }
            for (button,drive,menu) in Self.shiftButtons(pad) {
                button.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                    guard pressed, let self, let controller, self.controller === controller else { return }
                    if self.shiftPresses.count == 8 { self.shiftPresses.removeFirst() }
                    self.shiftPresses.append((drive,menu,ProcessInfo.processInfo.systemUptime))
                }
            }
            prepareHaptics(controller)
        }
        if lostController { onAction?("controllerDisconnected") }
    }

    private static func shiftButtons(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput,String,String?)] {
        [(pad.buttonB,"upshift","menuBack"),(pad.buttonX,"downshift",nil),
         (pad.leftShoulder,"downshift","menuPrevious"),(pad.rightShoulder,"upshift","menuNext")]
    }

    private static func detachButtons(_ pad: GCExtendedGamepad) {
        pad.buttonMenu.pressedChangedHandler = nil
        pad.buttonA.pressedChangedHandler = nil
        for (button,_,_) in shiftButtons(pad) { button.pressedChangedHandler = nil }
    }

    private func releaseHaptics() {
        hapticGeneration += 1
        testTime = nil; hapticClock = 0
        for channel in hapticChannels { Self.shutdownHapticChannel(channel) }
        hapticChannels = []
    }

    private static func shutdownHapticChannel(_ channel: HapticChannel) {
        channel.stop()
        channel.engine.resetHandler = {}
        channel.engine.stoppedHandler = { _ in }
        channel.engine.stop(completionHandler:nil)
    }

    private var hasHapticGrip: Bool {
        hapticChannels.contains { channel in
            channel.locality != .leftTrigger && channel.locality != .rightTrigger
        }
    }

    func selectHapticRoute(_ route: HapticRoute) {
        guard route != hapticRoute else { return }
        hapticRoute = route
        failedHapticLocalities.removeAll()
        hapticRetry = 0
        if let controller { prepareHaptics(controller) }
    }

    private func updateHapticStatus() {
        let sides = Set(hapticChannels.map(\.locality))
        if sides.contains(.leftHandle), sides.contains(.rightHandle) {
            let left = sides.contains(.leftTrigger), right = sides.contains(.rightTrigger)
            hapticStatus = left && right ? "左右马达 + LT / RT" :
                (left ? "左右马达 + LT" : (right ? "左右马达 + RT" : "左右马达"))
        } else if sides.contains(.leftHandle) {
            hapticStatus = "左握把震动 · 兼容模式"
        } else if sides.contains(.rightHandle) {
            hapticStatus = "右握把震动 · 兼容模式"
        } else if sides.contains(.all) {
            hapticStatus = "全手柄通道 · 兼容模式"
        } else if sides.contains(.handles) {
            hapticStatus = "合并握把通道 · 兼容模式"
        } else {
            hapticStatus = "默认震动通道 · 兼容模式"
        }
    }

    private func prepareHaptics(_ controller: GCController) {
        releaseHaptics()
        hapticError = nil
        guard let haptics = controller.haptics else { hapticStatus = "macOS 未提供此手柄的震动"; return }
        let supported = haptics.supportedLocalities
        var attempted: Set<GCHapticsLocality> = []
        func prepare(_ locality: GCHapticsLocality) -> Bool {
            guard supported.contains(locality), !failedHapticLocalities.contains(locality),
                  attempted.insert(locality).inserted else { return false }
            let generation = hapticGeneration
            do {
                guard let engine = haptics.createEngine(withLocality:locality) else { throw NSError(domain:"Haptics",code:1) }
                let recover: (Bool) -> Void = { [weak self, weak engine] routeFailed in
                    DispatchQueue.main.async { [weak self, weak engine] in
                        guard let self, let engine, self.hapticGeneration == generation,
                              let index = self.hapticChannels.firstIndex(where: { $0.engine === engine }) else { return }
                        if routeFailed { self.failedHapticLocalities.insert(locality) }
                        Self.shutdownHapticChannel(self.hapticChannels.remove(at:index))
                        if self.hasHapticGrip {
                            self.updateHapticStatus()
                        } else {
                            self.releaseHaptics()
                            self.hapticRetry = 1
                            self.hapticStatus = "震动中断 · 等待恢复"
                        }
                    }
                }
                engine.resetHandler = { recover(false) }
                engine.stoppedHandler = { recover($0 == .systemError) }
                do {
                    try engine.start()
                    hapticChannels.append(try HapticChannel(locality:locality,engine:engine))
                } catch {
                    engine.resetHandler = {}
                    engine.stoppedHandler = { _ in }
                    engine.stop(completionHandler:nil)
                    throw error
                }
                return true
            } catch {
                let issue = error as NSError
                hapticError = "\(locality.rawValue): \(issue.domain) \(issue.code)"
                return false
            }
        }
        func combined() -> Bool { prepare(.default) || prepare(.handles) }
        func split() -> Bool {
            let left = prepare(.leftHandle), right = prepare(.rightHandle)
            guard left || right else { return false }
            if left && right {
                _ = prepare(.leftTrigger)
                _ = prepare(.rightTrigger)
            }
            return true
        }

        let preferred: Bool
        switch hapticRoute {
        case .automatic: preferred = false
        case .handles: preferred = prepare(.handles)
        case .split: preferred = split()
        case .all: preferred = prepare(.all)
        }
        if preferred || (preferCombinedHaptics ? (combined() || split()) : (split() || combined())) || prepare(.all) {
            updateHapticStatus()
            return
        }
        // A later retry starts a new pass through the routes after every option was exhausted.
        failedHapticLocalities.removeAll()
        hapticRetry = 2
        hapticStatus = "震动启动失败 · 将重试"
    }

    func stopHaptics() {
        testTime = nil; hapticClock = 0
        for channel in hapticChannels { channel.stop() }
    }

    @discardableResult func testHaptics() -> Bool {
        if let controller, hapticChannels.isEmpty { prepareHaptics(controller) }
        guard hapticsAvailable && hapticLevel > 0 else { return false }
        stopHaptics()
        let signal = HapticOutput.test(at:0).scaled(Double(hapticLevel)/4)
        if !playHaptics(signal) {
            guard let controller else { return false }
            prepareHaptics(controller)
            guard hapticsAvailable, playHaptics(signal) else { return false }
        }
        testTime = 0
        return true
    }

    func updateHaptics(_ feedback: HapticOutput, dt: Double, driving: Bool) {
        hapticRetry = max(0,hapticRetry-dt)
        if hapticChannels.isEmpty, hapticRetry == 0, let controller, controller.haptics != nil {
            prepareHaptics(controller)
        }
        let signal: HapticOutput
        if let time = testTime {
            signal = HapticOutput.test(at:time)
            testTime = time+dt < HapticOutput.testDuration ? time+dt : nil
        } else { signal = driving ? feedback : .zero }
        let output = signal.scaled(Double(clamp(hapticLevel,0,4))/4)
        if output.peak < 0.009 {
            for channel in hapticChannels { channel.stop() }
            hapticClock = 0; return
        }
        hapticClock -= dt
        guard hapticClock <= 0 else { return }
        hapticClock = max(0, hapticClock + 1.0/60)
        _ = playHaptics(output)
    }

    @discardableResult private func playHaptics(_ output: HapticOutput) -> Bool {
        guard hasHapticGrip else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let localities = Set(hapticChannels.map(\.locality))
        var merged = output
        if localities.contains(.leftTrigger) { merged.brake = 0 }
        if localities.contains(.rightTrigger) { merged.throttle = 0 }
        var failures: [HapticChannel] = []
        for channel in hapticChannels {
            let value: Double
            switch channel.locality {
            case .leftHandle:
                value = localities.contains(.rightHandle) ? output.left + merged.brake*0.45 : merged.combinedGrip
            case .rightHandle:
                value = localities.contains(.leftHandle) ? output.right + merged.throttle*0.45 : merged.combinedGrip
            case .leftTrigger: value = output.brake
            case .rightTrigger: value = output.throttle
            default: value = output.combinedGrip
            }
            do {
                try channel.play(value,sharpness:output.sharpness,now:now)
            } catch {
                let issue = error as NSError
                hapticError = "\(channel.locality.rawValue): \(issue.domain) \(issue.code)"
                failures.append(channel)
                failedHapticLocalities.insert(channel.locality)
            }
        }
        guard !failures.isEmpty else { return true }
        for channel in failures {
            Self.shutdownHapticChannel(channel)
        }
        hapticChannels.removeAll { channel in failures.contains { $0 === channel } }
        if hasHapticGrip {
            updateHapticStatus()
            return true
        }
        releaseHaptics()
        hapticRetry = 2
        hapticStatus = "震动播放失败 · 将重试"
        return false
    }

    func keyDown(_ event: NSEvent, navigateMenu: Bool = false) {
        if navigateMenu {
            let navigation: [UInt16:String] = [36:"menuAccept",76:"menuAccept",123:"menuLeft",124:"menuRight",
                125:"menuDown",126:"menuUp",48:event.modifierFlags.contains(.shift) ? "menuPrevious" : "menuNext"]
            if let action = navigation[event.keyCode] {
                if !event.isARepeat { onAction?(action) }
                return
            }
        }
        // A held menu key can generate repeats after leaving the overlay.
        // Require its next physical key-down before using it to drive.
        guard !event.isARepeat else { return }
        if navigateMenu && KeyboardDrivingTimeline.isDrivingKey(event.keyCode) { return }
        setKey(event.keyCode,pressed:true,at:event.timestamp)
        let action: String?
        switch event.keyCode {
        case 36: action = "confirm"       // Return
        case 45: action = "trackNext" // N, only while paused
        case 8: action = "vehicleNext" // C, only while paused
        case 48: action = "camera"       // Tab
        case 35: action = event.modifierFlags.contains(.shift) ? "tow" : "service" // P
        case 40: action = "pitLimiter"  // K
        case 15: action = "reset"        // R
        case 53: action = "pause"        // Escape
        case 14: action = "upshift"      // E
        case 12: action = "downshift"    // Q
        case 18: action = "abs"          // 1
        case 19: action = "tc"           // 2
        case 21: action = "brakeBiasDown" // 4
        case 23: action = "brakeBiasUp"   // 5
        case 20: action = "automatic"    // 3
        case 4: action = "help"          // H
        case 46: action = "mute"         // M
        case 98: action = "compactHUD"  // F7
        case 100: action = "analysis"   // F8
        case 101: action = "trackCondition" // F9
        case 109: action = "startSprint" // F10
        case 103: action = "controllerReview" // F11
        case 97: action = "hudLayout"   // F6
        case 32: action = "autoDrive"   // U
        case 31: action = "opponents"   // O, in menus
        case 34: action = "racingLine"  // I
        case 11: action = "mirror"      // B
        case 9: action = "hud"           // V
        case 33: action = "fovDown"      // [
        case 30: action = "fovUp"        // ]
        case 116: action = "seatUp"      // Page Up
        case 121: action = "seatDown"    // Page Down
        case 96: action = "statistics"   // F5
        case 111: action = "capture"     // F12
        case 5: action = "ghost"         // G
        default: action = nil
        }
        if let action { onAction?(action) }
    }

    func setKey(_ code: UInt16,pressed: Bool,at timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        let changed = pressed ? keys.insert(code).inserted : keys.remove(code) != nil
        if changed { keyboard.record(code,pressed:pressed,at:timestamp) }
    }

    func clear() {
        keys = []
        shiftPresses.removeAll(keepingCapacity:true)
        keyboard = KeyboardDrivingTimeline()
        clearConfirmAndMenuStick()
        stopHaptics()
    }

    private func clearConfirmAndMenuStick() {
        confirmMode = nil
        confirmPress = nil
        confirmDown = controller?.extendedGamepad?.buttonA.isPressed ?? false
        cancelResetHold()
        menuStickArmed = false
        lastControllerPoll = nil
    }

    private func cancelResetHold() {
        confirmCanReset = false
        resetHold = 0
        resetFired = false
    }

    private func observeConfirm(pressed: Bool,now: Double) {
        guard pressed != confirmDown else { return }
        confirmDown = pressed
        cancelResetHold()
        if pressed { confirmPress = now }
    }

    private func readConfirm(_ mode: ConfirmMode,pressed: Bool,dt: Double,now: Double) {
        if let previous = confirmMode, previous != mode {
            // A queued driving press belongs to the previous context.
            confirmPress = nil
            cancelResetHold()
        }
        confirmMode = mode
        if let edge = confirmPress {
            confirmPress = nil
            if (0...Self.buttonEdgeLifetime).contains(now-edge) {
                switch mode {
                case .menu: onAction?("menuAccept")
                case .driving:
                    confirmCanReset = confirmDown && pressed
                    onAction?("confirm")
                case .inactive: break
                }
            }
        }
        guard mode == .driving, confirmCanReset, pressed else { return }
        resetHold += dt
        if resetHold > 0.8 && !resetFired {
            resetFired = true
            onAction?("reset")
        }
    }

    private func menuStickAction(x: Double,y: Double,enabled: Bool) -> String? {
        guard enabled else { menuStickArmed = false; return nil }
        let radius = hypot(x,y)
        if radius <= 0.28 { menuStickArmed = true }
        guard menuStickArmed, radius >= 0.66 else { return nil }
        menuStickArmed = false
        if abs(x) > abs(y) { return x > 0 ? "menuRight" : "menuLeft" }
        return y > 0 ? "menuUp" : "menuDown"
    }

    private var keyboardThrottle: Bool { keys.contains(13) || keys.contains(126) }
    private var keyboardBrake: Bool { keys.contains(1) || keys.contains(125) || keys.contains(49) }
    private var controllerPedals: DrivingInput {
        let pad = controller?.extendedGamepad
        return DrivingInput(throttle:Double(pad?.rightTrigger.value ?? 0),brake:Double(pad?.leftTrigger.value ?? 0))
    }

    // Gear interlocks need the current intent even on the first frame of
    // holding a keyboard brake. It remains ramped in the physics command.
    var pedals: DrivingInput {
        var result = controllerPedals
        if keyboardThrottle { result.throttle = 1 }
        if keyboardBrake { result.brake = 1 }
        return result
    }

    func read(dt: Double, deadzone: Double, acceptDriving: Bool = true, diagnose: Bool = false, navigateMenu: Bool = false,
              now: Double = ProcessInfo.processInfo.systemUptime) -> DrivingInput {
        var input = controllerPedals
        if !acceptDriving { keyboard.rebase(at:now,holding:keys) }
        if let pad = controller?.extendedGamepad {
            if let previous = lastControllerPoll, now-previous > 0.25 {
                // Waking or returning from a stalled frame needs fresh input.
                menuStickArmed = false
                cancelResetHold()
            }
            lastControllerPoll = now
            @discardableResult func press(_ name: String, _ isPressed: Bool, _ action: String) -> Bool {
                let fresh = isPressed && !heldButtons.contains(name)
                if fresh { onAction?(action) }
                if isPressed { heldButtons.insert(name) } else { heldButtons.remove(name) }
                return fresh
            }
            let mode: ConfirmMode = navigateMenu ? .menu : acceptDriving ? .driving : .inactive
            readConfirm(mode,pressed:pad.buttonA.isPressed,dt:dt,now:now)
            // A complete shoulder press can land between two game polls.
            let edges = shiftPresses
            shiftPresses.removeAll(keepingCapacity:true)
            for edge in edges where now - edge.time <= Self.buttonEdgeLifetime {
                onAction?(navigateMenu ? edge.menu ?? edge.drive : edge.drive)
            }
            press("y", pad.buttonY.isPressed, "camera")
            press("rightStick", pad.rightThumbstickButton?.isPressed ?? false, "autoDrive")
            press("leftStick", pad.leftThumbstickButton?.isPressed ?? false, "racingLine")
            let down = press("service",pad.dpad.down.isPressed,navigateMenu ? "menuDown" : "service")
            let up = press("trackNext",pad.dpad.up.isPressed,navigateMenu ? "menuUp" : "trackNext")
            let left = press("dpadLeft",pad.dpad.left.isPressed,navigateMenu ? "menuLeft" : "brakeBiasDown")
            let right = press("dpadRight",pad.dpad.right.isPressed,navigateMenu ? "menuRight" : "brakeBiasUp")
            let steering = Double(pad.leftThumbstick.xAxis.value)
            if let direction = menuStickAction(x:steering,y:Double(pad.leftThumbstick.yAxis.value),enabled:navigateMenu),
               !down && !up && !left && !right {
                onAction?(direction)
            }
            input.steering = ControllerCalibration.steering(steering,deadzone:deadzone)
            if diagnose {
                samples.update(raw:DrivingInput(throttle:Double(pad.rightTrigger.value),brake:Double(pad.leftTrigger.value),steering:steering),
                               deadzone:deadzone,at:now,systemEvent:pad.lastEventTimestamp)
            }
        }
        return acceptDriving ? input : DrivingInput()
    }

    func resetDiagnostics() { samples.reset() }


    var sideLook: Double {
        if keys.contains(38) { return -1 } // J
        if keys.contains(37) { return 1 }  // L
        let x = Double(controller?.extendedGamepad?.rightThumbstick.xAxis.value ?? 0)
        return abs(x) <= 0.16 ? 0 : copysign((abs(x)-0.16)/0.84,x)
    }

    var showcaseCamera: SIMD3<Double> {
        guard let pad = controller?.extendedGamepad else { return .zero }
        let x = Double(pad.rightThumbstick.xAxis.value)
        let y = Double(pad.rightThumbstick.yAxis.value)
        let radius = min(1,hypot(x,y))
        let magnitude = clamp((radius-0.16)/0.84,0,1)
        let stick = SIMD2(x,y) * (magnitude/max(0.16,hypot(x,y)))
        let zoom = Double(pad.rightTrigger.value - pad.leftTrigger.value)
        return SIMD3(stick.x,stick.y,abs(zoom) > 0.08 ? zoom : 0)
    }

}

import AppKit
import GameController
import CoreHaptics

final class InputManager {
    var keys: Set<UInt16> = []
    var onAction: ((String) -> Void)?
    private(set) var controller: GCController?
    private(set) var samples = ControllerSamples()
    private var heldButtons: Set<String> = []
    private var resetHold = 0.0
    private var resetFired = false
    private var heldMenuConfirm = false
    private var observers: [NSObjectProtocol] = []
    private var keyboardPedals = KeyboardPedals()
    private final class HapticChannel {
        let locality: GCHapticsLocality
        let engine: CHHapticEngine
        private var continuous: CHHapticPatternPlayer?
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
            let event = Self.event(strength: 1, sharpness: 0.35, duration: 0.24)
            let silentStart = CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:0,relativeTime:0)
            do {
                continuous = try engine.makePlayer(with:CHHapticPattern(events:[event],parameters:[silentStart]))
            } catch {
                // Some controllers can play the basic event even if they
                // reject parameters in the continuous pattern.
                legacyPlayers[12] = try makeLegacyPlayer(level:12,sharp:false)
            }
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
            if let continuous {
                let renew = activePlayer == nil || now >= refreshAt
                do {
                    if renew {
                        stop()
                        try continuous.start(atTime:CHHapticTimeImmediate)
                        activePlayer = continuous
                        refreshAt = now + 0.18
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
                    self.continuous = nil
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
    private var usingCombinedHaptics = false
    private var testTime: Double? = nil
    private(set) var hapticError: String?
    var hapticLevel = 3
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
        stopHaptics()
        if !observers.isEmpty { GCController.stopWirelessControllerDiscovery() }
    }

    private func refreshController() {
        let selected = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        guard selected !== controller else { return }
        let lostController = controller != nil
        controller?.extendedGamepad?.buttonMenu.pressedChangedHandler = nil
        controller = selected
        samples.reset()
        heldButtons = []
        heldMenuConfirm = false
        resetHold = 0
        resetFired = false
        releaseHaptics()
        hapticError = nil
        preferCombinedHaptics = selected?.productCategory.localizedCaseInsensitiveContains("Xbox") == true
        hapticStatus = selected == nil ? "未连接手柄" : "正在检测震动"
        if let controller {
            controller.playerIndex = .index1
            controller.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { DispatchQueue.main.async { self?.onAction?("pause") } }
            }
            prepareHaptics(controller)
        }
        if lostController { onAction?("controllerDisconnected") }
    }

    private func releaseHaptics() {
        hapticGeneration += 1
        stopHaptics()
        for channel in hapticChannels {
            channel.engine.resetHandler = {}; channel.engine.stoppedHandler = { _ in }
            channel.engine.stop(completionHandler:nil)
        }
        hapticChannels = []
        usingCombinedHaptics = false
    }

    private func prepareHaptics(_ controller: GCController) {
        releaseHaptics()
        guard let haptics = controller.haptics else { hapticStatus = "macOS 未提供此手柄的震动"; return }
        let supported = haptics.supportedLocalities
        func prepare(_ locality: GCHapticsLocality) -> Bool {
            let generation = hapticGeneration
            do {
                guard let engine = haptics.createEngine(withLocality:locality) else { throw NSError(domain:"Haptics",code:1) }
                do {
                    try engine.start()
                    hapticChannels.append(try HapticChannel(locality:locality,engine:engine))
                    let recover: () -> Void = { [weak self] in
                        DispatchQueue.main.async {
                            guard let self, self.hapticGeneration == generation else { return }
                            self.releaseHaptics(); self.hapticRetry = 1
                            self.hapticStatus = "震动中断 · 等待恢复"
                        }
                    }
                    engine.resetHandler = recover
                    engine.stoppedHandler = { _ in recover() }
                } catch { engine.stop(completionHandler:nil); throw error }
                return true
            } catch {
                let issue = error as NSError
                hapticError = "\(locality.rawValue): \(issue.domain) \(issue.code)"
                return false
            }
        }
        func combined() -> Bool {
            guard prepare(.default) || (supported.contains(.handles) && prepare(.handles)) else { return false }
            usingCombinedHaptics = true
            hapticStatus = "握把震动 · 兼容模式"
            hapticError = nil
            return true
        }
        hapticError = nil
        if preferCombinedHaptics && combined() { return }
        if supported.contains(.leftHandle), supported.contains(.rightHandle),
           prepare(.leftHandle), prepare(.rightHandle) {
            let left = supported.contains(.leftTrigger) && prepare(.leftTrigger)
            let right = supported.contains(.rightTrigger) && prepare(.rightTrigger)
            hapticStatus = left && right ? "左右马达 + LT / RT" :
                (left ? "左右马达 + LT" : (right ? "左右马达 + RT" : "左右马达"))
            return
        }
        releaseHaptics()
        if !preferCombinedHaptics && combined() { return }
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
        let now = ProcessInfo.processInfo.systemUptime
        do {
            for channel in hapticChannels {
                let value: Double
                switch channel.locality {
                case .leftHandle: value = output.left + (hapticChannels.contains { $0.locality == .leftTrigger } ? 0 : output.brake*0.45)
                case .rightHandle: value = output.right + (hapticChannels.contains { $0.locality == .rightTrigger } ? 0 : output.throttle*0.45)
                case .leftTrigger: value = output.brake
                case .rightTrigger: value = output.throttle
                default: value = output.combinedGrip
                }
                try channel.play(value,sharpness:output.sharpness,now:now)
            }
            return true
        } catch {
            let issue = error as NSError
            hapticError = "\(issue.domain) \(issue.code)"
            preferCombinedHaptics = !usingCombinedHaptics
            releaseHaptics()
            hapticRetry = 2
            hapticStatus = "震动播放失败 · 将重试"
            return false
        }
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
        keys.insert(event.keyCode)
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

    func clear() {
        keys = []
        keyboardPedals = KeyboardPedals()
        resetHold = 0
        resetFired = false
        stopHaptics()
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
        if acceptDriving {
            keyboardPedals.update(throttle:keyboardThrottle,brake:keyboardBrake,dt:dt)
            input.brake = max(input.brake,keyboardPedals.brake)
            input.throttle = max(input.throttle,keyboardPedals.throttle)
        } else {
            keyboardPedals = KeyboardPedals()
        }
        if let pad = controller?.extendedGamepad {
            func press(_ name: String, _ isPressed: Bool, _ action: String) {
                if isPressed && !heldButtons.contains(name) { onAction?(action) }
                if isPressed { heldButtons.insert(name) } else { heldButtons.remove(name) }
            }
            press("confirm", pad.buttonA.isPressed, navigateMenu ? "menuAccept" : "confirm")
            press("b", pad.buttonB.isPressed, navigateMenu ? "menuBack" : "upshift")
            press("x", pad.buttonX.isPressed, "downshift")
            press("y", pad.buttonY.isPressed, "camera")
            press("rightStick", pad.rightThumbstickButton?.isPressed ?? false, "autoDrive")
            press("leftStick", pad.leftThumbstickButton?.isPressed ?? false, "racingLine")
            press("lb", pad.leftShoulder.isPressed, navigateMenu ? "menuPrevious" : "downshift")
            press("rb", pad.rightShoulder.isPressed, navigateMenu ? "menuNext" : "upshift")
            press("service", pad.dpad.down.isPressed, navigateMenu ? "menuDown" : "service")
            press("trackNext",pad.dpad.up.isPressed,navigateMenu ? "menuUp" : "trackNext")
            press("dpadLeft", pad.dpad.left.isPressed, navigateMenu ? "menuLeft" : "brakeBiasDown")
            press("dpadRight", pad.dpad.right.isPressed, navigateMenu ? "menuRight" : "brakeBiasUp")
            if pad.buttonA.isPressed && acceptDriving && !heldMenuConfirm {
                resetHold += dt
                if resetHold > 0.8 && !resetFired { resetFired = true; onAction?("reset") }
            } else { resetHold = 0; resetFired = false }
            if !pad.buttonA.isPressed { heldMenuConfirm = false }
            else if navigateMenu { heldMenuConfirm = true }
            let steering = Double(pad.leftThumbstick.xAxis.value)
            input.steering = ControllerCalibration.steering(steering,deadzone:deadzone)
            if diagnose {
                samples.update(raw:DrivingInput(throttle:Double(pad.rightTrigger.value),brake:Double(pad.leftTrigger.value),steering:steering),
                               deadzone:deadzone,at:now)
            }
        }
        let left = keys.contains(0) || keys.contains(123)
        let right = keys.contains(2) || keys.contains(124)
        if left || right { input.steering = (right ? 1.0 : 0) - (left ? 1.0 : 0) }
        return acceptDriving ? input : DrivingInput()
    }

    func resetDiagnostics() { samples.reset() }

    var sideLook: Double {
        if keys.contains(38) { return -1 } // J
        if keys.contains(37) { return 1 }  // L
        let x = Double(controller?.extendedGamepad?.rightThumbstick.xAxis.value ?? 0)
        return abs(x) <= 0.16 ? 0 : copysign((abs(x)-0.16)/0.84,x)
    }

}

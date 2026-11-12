import AppKit
import GameController
import CoreHaptics

final class InputManager {
    var keys: Set<UInt16> = []
    var onAction: ((String) -> Void)?
    private(set) var controller: GCController?
    private var heldButtons: Set<String> = []
    private var resetHold = 0.0
    private var resetFired = false
    private var observers: [NSObjectProtocol] = []
    private struct HapticChannel {
        let locality: GCHapticsLocality
        let engine: CHHapticEngine
        let player: CHHapticAdvancedPatternPlayer
    }
    private var hapticChannels: [HapticChannel] = []
    private var hapticClock = 0.0
    private var hapticRetry = 0.0
    private var hapticGeneration = 0
    private var testTime: Double? = nil
    var hapticLevel = 3
    var hapticsAvailable: Bool { !hapticChannels.isEmpty }
    private(set) var hapticStatus = "未连接手柄"
    var controllerName: String? { controller?.vendorName ?? controller?.productCategory }

    init() {
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
        GCController.stopWirelessControllerDiscovery()
    }

    private func refreshController() {
        let selected = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        guard selected !== controller else { return }
        let lostController = controller != nil && selected == nil
        controller?.extendedGamepad?.buttonMenu.pressedChangedHandler = nil
        controller = selected
        heldButtons = []
        resetHold = 0
        resetFired = false
        releaseHaptics()
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
    }

    private func prepareHaptics(_ controller: GCController) {
        releaseHaptics()
        guard let haptics = controller.haptics else { hapticStatus = "macOS 未提供此手柄的震动"; return }
        let supported = haptics.supportedLocalities
        var localities: [GCHapticsLocality] = [.default]
        if supported.contains(.leftHandle) && supported.contains(.rightHandle) {
            localities = [.leftHandle,.rightHandle]
            if supported.contains(.leftTrigger) { localities.append(.leftTrigger) }
            if supported.contains(.rightTrigger) { localities.append(.rightTrigger) }
        }
        let generation = hapticGeneration
        do {
            for locality in localities {
                guard let engine = haptics.createEngine(withLocality:locality) else { throw NSError(domain:"Haptics",code:1) }
                try engine.start()
                do {
                    // Finite heartbeat: a stalled frame loop cannot leave motors
                    // running indefinitely. Each update restarts this short pulse.
                    let event = CHHapticEvent(eventType:.hapticContinuous,parameters:[
                        CHHapticEventParameter(parameterID:.hapticIntensity,value:1),
                        CHHapticEventParameter(parameterID:.hapticSharpness,value:0.3)
                    ],relativeTime:0,duration:0.12)
                    let player = try engine.makeAdvancedPlayer(with:CHHapticPattern(events:[event],parameters:[]))
                    hapticChannels.append(HapticChannel(locality:locality,engine:engine,player:player))
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
            }
            let triggers = localities.contains(.leftTrigger) && localities.contains(.rightTrigger)
            hapticStatus = localities == [.default] ? "合并震动" : (triggers ? "左右马达 + LT / RT" : "左右马达 · 扳机按可用能力")
        } catch {
            releaseHaptics(); hapticRetry = 2; hapticStatus = "震动启动失败 · 将重试"
        }
    }

    func stopHaptics() {
        testTime = nil; hapticClock = 0
        for channel in hapticChannels { try? channel.player.stop(atTime:CHHapticTimeImmediate) }
    }

    @discardableResult func testHaptics() -> Bool {
        if let controller, hapticChannels.isEmpty { prepareHaptics(controller) }
        guard hapticsAvailable && hapticLevel > 0 else { return false }
        testTime = 0; return true
    }

    func updateHaptics(_ feedback: HapticOutput, dt: Double, driving: Bool) {
        hapticRetry = max(0,hapticRetry-dt)
        if hapticChannels.isEmpty, hapticRetry == 0, let controller, controller.haptics != nil {
            prepareHaptics(controller)
        }
        let signal: HapticOutput
        if let time = testTime {
            signal = HapticOutput.test(at:time)
            testTime = time+dt < 1.4 ? time+dt : nil
        } else { signal = driving ? feedback : .zero }
        let output = signal.scaled(Double(clamp(hapticLevel,0,4))/4)
        if output.peak < 0.001 {
            for channel in hapticChannels { try? channel.player.stop(atTime:CHHapticTimeImmediate) }
            hapticClock = 0; return
        }
        hapticClock += dt
        guard hapticClock >= 1.0/30 else { return }
        hapticClock = 0
        do {
            for channel in hapticChannels {
                var value: Double
                switch channel.locality {
                case .leftHandle: value = output.left + (hapticChannels.contains { $0.locality == .leftTrigger } ? 0 : output.brake*0.45)
                case .rightHandle: value = output.right + (hapticChannels.contains { $0.locality == .rightTrigger } ? 0 : output.throttle*0.45)
                case .leftTrigger: value = output.brake
                case .rightTrigger: value = output.throttle
                default: value = max(output.left,output.right,output.brake*0.45,output.throttle*0.45)
                }
                try channel.player.stop(atTime:CHHapticTimeImmediate)
                guard value > 0.001 else { continue }
                try channel.player.sendParameters([
                    CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:Float(clamp(value,0,0.8)),relativeTime:0),
                    CHHapticDynamicParameter(parameterID:.hapticSharpnessControl,value:Float(output.sharpness),relativeTime:0)
                ],atTime:CHHapticTimeImmediate)
                try channel.player.start(atTime:CHHapticTimeImmediate)
            }
        } catch { releaseHaptics(); hapticRetry = 2; hapticStatus = "震动中断 · 将重试" }
    }

    func keyDown(_ event: NSEvent) {
        keys.insert(event.keyCode)
        guard !event.isARepeat else { return }
        let action: String?
        switch event.keyCode {
        case 36: action = "confirm"       // Return
        case 45: action = "trackNext" // N, only while paused
        case 8: action = "vehicleNext" // C, only while paused
        case 48: action = "camera"       // Tab
        case 35: action = "service"      // P
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
        case 97: action = "hudLayout"   // F6
        case 32: action = "autoDrive"   // U
        case 31: action = "opponents"   // O, in menus
        case 34: action = "racingLine"  // I
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
        resetHold = 0
        resetFired = false
        stopHaptics()
    }

    var pedals: DrivingInput {
        let pad = controller?.extendedGamepad
        let throttle = keys.contains(13) || keys.contains(126) ? 1 : Double(pad?.rightTrigger.value ?? 0)
        let brake = keys.contains(1) || keys.contains(125) || keys.contains(49) ? 1 : Double(pad?.leftTrigger.value ?? 0)
        return DrivingInput(throttle: throttle, brake: brake)
    }

    func read(dt: Double, deadzone: Double, acceptDriving: Bool = true) -> DrivingInput {
        var input = pedals
        if let pad = controller?.extendedGamepad {
            func press(_ name: String, _ isPressed: Bool, _ action: String) {
                if isPressed && !heldButtons.contains(name) { onAction?(action) }
                if isPressed { heldButtons.insert(name) } else { heldButtons.remove(name) }
            }
            press("confirm", pad.buttonA.isPressed, "confirm")
            press("b", pad.buttonB.isPressed, "upshift")
            press("x", pad.buttonX.isPressed, "downshift")
            press("y", pad.buttonY.isPressed, "camera")
            press("rightStick", pad.rightThumbstickButton?.isPressed ?? false, "autoDrive")
            press("leftStick", pad.leftThumbstickButton?.isPressed ?? false, "racingLine")
            press("lb", pad.leftShoulder.isPressed, "downshift")
            press("rb", pad.rightShoulder.isPressed, "upshift")
            press("service", pad.dpad.down.isPressed, "service")
            press("trackNext",pad.dpad.up.isPressed,"trackNext")
            press("dpadLeft", pad.dpad.left.isPressed, acceptDriving ? "brakeBiasDown" : "vehiclePrevious")
            press("dpadRight", pad.dpad.right.isPressed, acceptDriving ? "brakeBiasUp" : "vehicleNext")
            if pad.buttonA.isPressed {
                resetHold += dt
                if resetHold > 0.8 && !resetFired { resetFired = true; onAction?("reset") }
            } else { resetHold = 0; resetFired = false }
            let steering = Double(pad.leftThumbstick.xAxis.value)
            let magnitude = abs(steering)
            input.steering = magnitude > deadzone ? (steering < 0 ? -1 : 1) * (magnitude - deadzone) / (1 - deadzone) : 0
        }
        let left = keys.contains(0) || keys.contains(123)
        let right = keys.contains(2) || keys.contains(124)
        if left || right { input.steering = (right ? 1.0 : 0) - (left ? 1.0 : 0) }
        return acceptDriving ? input : DrivingInput()
    }

    var exteriorLook: Double {
        if keys.contains(38) { return -1 } // J
        if keys.contains(37) { return 1 }  // L
        let x = Double(controller?.extendedGamepad?.rightThumbstick.xAxis.value ?? 0)
        return abs(x) <= 0.16 ? 0 : copysign((abs(x)-0.16)/0.84,x)
    }

}

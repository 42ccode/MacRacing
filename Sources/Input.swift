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
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?
    private var hapticClock = 0.0
    var hapticsAvailable: Bool { controller?.haptics != nil }
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
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        hapticPlayer = nil
        if let controller {
            controller.playerIndex = .index1
            controller.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { DispatchQueue.main.async { self?.onAction?("pause") } }
            }
            prepareHaptics(controller)
        }
        if lostController { onAction?("controllerDisconnected") }
    }

    private func prepareHaptics(_ controller: GCController) {
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.65),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ], relativeTime: 0, duration: 1)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            hapticEngine = engine
            hapticPlayer = player
            engine.resetHandler = { [weak self, weak controller] in
                DispatchQueue.main.async {
                    if let controller { self?.prepareHaptics(controller) }
                }
            }
        } catch {
            // Unsupported haptics must never prevent driving.
            hapticEngine = nil
            hapticPlayer = nil
        }
    }

    func keyDown(_ event: NSEvent) {
        keys.insert(event.keyCode)
        guard !event.isARepeat else { return }
        let action: String?
        switch event.keyCode {
        case 36: action = "confirm"       // Return
        case 48: action = "camera"       // Tab
        case 35: action = "service"      // P
        case 15: action = "reset"        // R
        case 53: action = "pause"        // Escape
        case 14: action = "upshift"      // E
        case 12: action = "downshift"    // Q
        case 18: action = "abs"          // 1
        case 19: action = "tc"           // 2
        case 20: action = "automatic"    // 3
        case 4: action = "help"          // H
        case 46: action = "mute"         // M
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
        rumble(0, dt: 1)
    }

    func read(dt: Double, deadzone: Double, acceptDriving: Bool = true) -> DrivingInput {
        var input = DrivingInput()
        if let pad = controller?.extendedGamepad {
            func press(_ name: String, _ isPressed: Bool, _ action: String) {
                if isPressed && !heldButtons.contains(name) { onAction?(action) }
                if isPressed { heldButtons.insert(name) } else { heldButtons.remove(name) }
            }
            press("confirm", pad.buttonA.isPressed, "confirm")
            press("b", pad.buttonB.isPressed, "upshift")
            press("x", pad.buttonX.isPressed, "downshift")
            press("y", pad.buttonY.isPressed, "camera")
            press("lb", pad.leftShoulder.isPressed, "downshift")
            press("rb", pad.rightShoulder.isPressed, "upshift")
            press("service", pad.dpad.down.isPressed, "service")
            if pad.buttonA.isPressed {
                resetHold += dt
                if resetHold > 0.8 && !resetFired { resetFired = true; onAction?("reset") }
            } else { resetHold = 0; resetFired = false }
            let steering = Double(pad.leftThumbstick.xAxis.value)
            let magnitude = abs(steering)
            input.steering = magnitude > deadzone ? (steering < 0 ? -1 : 1) * (magnitude - deadzone) / (1 - deadzone) : 0
            input.throttle = Double(pad.rightTrigger.value)
            input.brake = Double(pad.leftTrigger.value)
        }
        if keys.contains(13) || keys.contains(126) { input.throttle = 1 }
        if keys.contains(1) || keys.contains(125) || keys.contains(49) { input.brake = 1 }
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

    func rumble(_ intensity: Double, dt: Double) {
        hapticClock += dt
        guard hapticClock >= 1.0 / 30 else { return }
        hapticClock = 0
        try? hapticPlayer?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(clamp(intensity, 0, 0.7)), relativeTime: 0)
        ], atTime: CHHapticTimeImmediate)
    }
}

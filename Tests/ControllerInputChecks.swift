import Foundation
import GameController

@main struct ControllerInputChecks {
    static var failures = 0

    static func check(_ valid: Bool,_ name: String) {
        print("\(valid ? "PASS" : "FAIL")  \(name)")
        if !valid { failures += 1 }
    }

    static func main() {
        let manager = InputManager(monitorControllers:false)
        let controller = GCController.withExtendedGamepad()
        let pad = controller.extendedGamepad!
        manager.selectController(controller)
        var actions = [String]()
        var clearOnAccept = false
        manager.onAction = { [weak manager] action in
            actions.append(action)
            if action == "menuAccept", clearOnAccept { manager?.clear() }
        }
        func deliver() { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005)) }
        func read(menu: Bool = true,driving: Bool = false,now: Double = ProcessInfo.processInfo.systemUptime) -> DrivingInput {
            manager.read(dt:1/120,deadzone:0.08,acceptDriving:driving,navigateMenu:menu,now:now)
        }
        func tap(_ button: GCControllerButtonInput) {
            button.setValue(1)
            button.setValue(0)
            deliver()
        }
        func set(_ button: GCControllerButtonInput,_ pressed: Bool) {
            button.setValue(pressed ? 1 : 0)
            deliver()
        }
        _ = read()
        tap(pad.buttonA)
        _ = read()
        _ = read()
        check(actions == ["menuAccept"],"A complete Xbox A tap between two polls confirms exactly once")

        actions.removeAll()
        clearOnAccept = true
        set(pad.buttonA,true)
        _ = read()
        for _ in 0..<150 { _ = read(menu:false,driving:true) }
        check(actions == ["menuAccept"],"Holding a menu confirmation through a synchronous resume clear never resets the car")
        clearOnAccept = false
        set(pad.buttonA,false)
        actions.removeAll()
        _ = read()
        set(pad.buttonA,true)
        _ = read()
        for _ in 0..<150 { _ = read(menu:false,driving:true) }
        check(actions == ["menuAccept"],"A direct menu-to-driving transition also suppresses the held confirmation")
        set(pad.buttonA,false)
        tap(pad.buttonA)
        _ = read(menu:false,driving:true)
        check(actions == ["menuAccept","confirm"],"A new short tap in driving keeps the existing action without arming a reset")

        actions.removeAll()
        set(pad.buttonA,true)
        for _ in 0..<120 { _ = read(menu:false,driving:true) }
        check(actions == ["confirm","reset"],"A fresh driving press retains exactly one long-hold reset")
        set(pad.buttonA,false)
        actions.removeAll()
        tap(pad.buttonA)
        _ = read()
        check(actions.isEmpty,"A driving edge still queued when a menu opens does not confirm that menu")

        tap(pad.buttonA)
        manager.clear()
        _ = read()
        check(actions.isEmpty,"Clearing on focus loss drops queued confirmations")
        let beforePause = ProcessInfo.processInfo.systemUptime
        tap(pad.buttonA)
        _ = read(now:beforePause+0.4)
        check(actions.isEmpty,"A confirmation queued before a long input interruption expires")
        manager.clear()

        _ = read(menu:false,driving:true)
        set(pad.buttonA,true)
        for _ in 0..<48 { _ = read(menu:false,driving:true) }
        let heldBeforeWake = ProcessInfo.processInfo.systemUptime
        _ = read(menu:false,driving:true,now:heldBeforeWake+0.5)
        for _ in 0..<150 { _ = read(menu:false,driving:true) }
        check(actions == ["confirm"],"A suspended driving hold cannot reset the car after wake")
        set(pad.buttonA,false)
        actions.removeAll()
        tap(pad.buttonA)
        _ = read(menu:false,driving:false)
        check(actions.isEmpty,"Inactive controls consume stale A without driving or navigating")

        let replacement = GCController.withExtendedGamepad()
        let replacementPad = replacement.extendedGamepad!
        replacementPad.buttonA.setValue(1)
        replacementPad.leftThumbstick.setValueForXAxis(0.9,yAxis:0)
        deliver()
        manager.selectController(replacement)
        actions.removeAll()
        tap(pad.buttonA)
        _ = read()
        check(actions.isEmpty,"Reconnect ignores a held A, deflected stick and late events from the former controller")
        set(replacementPad.buttonA,false)
        tap(replacementPad.buttonA)
        _ = read()
        check(actions == ["menuAccept"],"A fresh press is recognized after the reconnected pad releases")

        actions.removeAll()
        let stick = replacementPad.leftThumbstick
        stick.setValueForXAxis(0,yAxis:0)
        _ = read()
        stick.setValueForXAxis(0.61,yAxis:0)
        _ = read()
        check(actions.isEmpty,"Stick motion below the radial engage threshold stays quiet")
        stick.setValueForXAxis(0.70,yAxis:0)
        _ = read()
        stick.setValueForXAxis(0.63,yAxis:0)
        _ = read()
        stick.setValueForXAxis(0.90,yAxis:0)
        _ = read()
        check(actions == ["menuRight"],"Threshold jitter and a held stick produce one navigation step")

        stick.setValueForXAxis(0.36,yAxis:0)
        _ = read()
        stick.setValueForXAxis(-0.83,yAxis:0)
        _ = read()
        check(actions == ["menuRight"],"Changing direction above the recenter threshold cannot repeat")
        stick.setValueForXAxis(0.20,yAxis:0.05)
        _ = read()
        stick.setValueForXAxis(-0.48,yAxis:0.59)
        _ = read()
        check(actions == ["menuRight","menuUp"],"Recentering rearms navigation and a diagonal picks its dominant axis")

        stick.setValueForXAxis(0,yAxis:0)
        _ = read()
        stick.setValueForXAxis(0.8,yAxis:0)
        replacementPad.dpad.setValueForXAxis(-1,yAxis:0)
        _ = read()
        check(actions == ["menuRight","menuUp","menuLeft"],"A D-pad edge takes priority over simultaneous stick motion")
        replacementPad.dpad.setValueForXAxis(0,yAxis:0)
        let steering = read(menu:false,driving:true)
        _ = read()
        check(abs(steering.steering-ControllerCalibration.steering(Double(stick.xAxis.value),deadzone:0.08)) < 1e-6 &&
              actions == ["menuRight","menuUp","menuLeft"],"Driving keeps analogue steering and held steering cannot navigate on entry to a menu")

        stick.setValueForXAxis(0,yAxis:0)
        let awake = ProcessInfo.processInfo.systemUptime
        _ = read(now:awake)
        stick.setValueForXAxis(0,yAxis:-0.90)
        _ = read(now:awake+0.5)
        check(actions == ["menuRight","menuUp","menuLeft"],"A long input gap requires a fresh neutral stick sample")

        replacementPad.rightThumbstick.setValueForXAxis(0.75,yAxis:-0.45)
        replacementPad.rightTrigger.setValue(0.8)
        let camera = manager.showcaseCamera
        check(camera.x > 0.60 && camera.y < -0.30 && camera.z > 0.75,
              "Showroom orbit and zoom continue to use the right stick and triggers")
        manager.selectController(nil)
        check(manager.showcaseCamera == .zero,"Disconnecting clears the active showroom controls")
        if failures > 0 { exit(1) }
    }
}

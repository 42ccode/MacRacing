import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var game: RacingGame!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 APEX Lab", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 APEX Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        let fullscreen = windowMenu.addItem(withTitle: "全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        windowItem.title = "窗口"
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width - 50), height: min(900, screen.height - 55))
        let rect = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "APEX Lab — Circuit Test"
        window.subtitle = "Mac 原生驾驶模拟原型 · v1.9"
        window.minSize = NSSize(width: 1100, height: 740)
        window.backgroundColor = NSColor(rgb: 0x10191D)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        game = RacingGame(frame: rect)
        let content = NSView(frame: rect)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(game.hud)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--quick-start") { game.action("start") }
    }

    func applicationDidResignActive(_ notification: Notification) { game?.loseFocus() }
    func applicationWillTerminate(_ notification: Notification) { game?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

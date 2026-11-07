import AppKit
import simd

final class HUDView: NSView {
    weak var game: RacingGame?
    private var actions: [(NSRect, String)] = []
    private var nativeButtons: [String: NSButton] = [:]
    private var buttonLabels: [String: String] = [:]

    @objc private func activateButton(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        if let action = sender.identifier?.rawValue { game?.action(action) }
    }

    private func synchronizeAccessibleButtons() {
        var visible: Set<String> = []
        for (rect, action) in actions {
            visible.insert(action)
            let button: NSButton
            if let existing = nativeButtons[action] { button = existing }
            else {
                button = NSButton(title: "", target: self, action: #selector(activateButton(_:)))
                button.isBordered = false
                button.isTransparent = true
                button.refusesFirstResponder = true
                button.focusRingType = .none
                button.identifier = NSUserInterfaceItemIdentifier(action)
                addSubview(button)
                nativeButtons[action] = button
            }
            button.frame = rect
            button.setAccessibilityLabel(buttonLabels[action] ?? action)
            button.isHidden = false
        }
        for (action, button) in nativeButtons where !visible.contains(action) { button.isHidden = true }
    }
    private let ink = NSColor(rgb: 0x151617, alpha: 0.91)
    private let muted = NSColor(rgb: 0xA3B3B9)
    private let lime = NSColor(rgb: 0xE1E5E7)
    private let white = NSColor(rgb: 0xF1F5F1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func keyDown(with event: NSEvent) { game?.input.keyDown(event) }
    override func keyUp(with event: NSEvent) { game?.input.keys.remove(event.keyCode) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = actions.reversed().first(where: { $0.0.contains(point) }) { game?.action(hit.1) }
    }

    private func panel(_ rect: NSRect, color: NSColor? = nil, radius: CGFloat = 12) {
        (color ?? ink).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(0.07).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat = 12,
                      color: NSColor? = nil, weight: NSFont.Weight = .regular, mono: Bool = false,
                      width: CGFloat = 700, align: NSTextAlignment = .left) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 1.65), withAttributes: [
            .font: font, .foregroundColor: color ?? white, .paragraphStyle: paragraph
        ])
    }

    private func line(_ a: CGPoint, _ b: CGPoint, color: NSColor, width: CGFloat = 1) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func button(_ label: String, _ rect: NSRect, action: String, primary: Bool = false, active: Bool = false) {
        panel(rect, color: primary ? lime : NSColor(rgb: active ? 0x3D4850 : 0x303337, alpha: 0.98), radius: 7)
        text(label, x: rect.minX + 12, y: rect.minY + (rect.height - 19) / 2, size: 12,
             color: primary ? NSColor(rgb: 0x162012) : (active ? lime : white), weight: .semibold, width: rect.width - 24, align: .center)
        actions.append((rect, action))
        buttonLabels[action] = label
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let game else { return }
        actions = []
        defer { synchronizeAccessibleButtons() }
        let w = bounds.width
        let h = bounds.height
        if !game.hasStarted { drawHeader(game, width: w) }
        if game.hasStarted {
            if game.showHUD {
                drawCompactTiming(game, width: w, height: h)
                drawPedals(game, height: h)
                drawCondition(game, width: w)
                if !game.cockpit { drawDashboard(game, width: w, height: h) }
            }
            if game.noticeRemaining > 0 {
                let rect = NSRect(x: (w - 460) / 2, y: 30, width: 460, height: 30)
                panel(rect)
                text(game.notice, x: rect.minX + 14, y: rect.minY + 6, size: 11, color: lime, weight: .semibold, width: 432, align: .center)
            }
            if !game.session.validLap && !game.isPaused {
                text("本圈无效 · 驶回赛道，下圈重新计时", x: (w - 440) / 2, y: h - 266, size: 13,
                     color: NSColor(rgb: 0xFFD19A), weight: .semibold, width: 440, align: .center)
            }
            if game.serviceRemaining > 0 {
                panel(NSRect(x: (w-400)/2, y: 76, width: 400, height: 62))
                text(String(format: "维修与换胎 · 剩余 %.1f 秒", game.serviceRemaining),
                     x: (w-380)/2, y: 85, size: 17, weight: .semibold, width: 380, align: .center)
                text("已拖回发车区 · 暂停时维修也暂停", x: (w-380)/2, y: 113,
                     size: 11, color: muted, width: 380, align: .center)
            }
            if game.isPaused { drawPause(game, width: w, height: h) }
        } else {
            drawWelcome(game, width: w, height: h)
        }
    }

    private func drawCondition(_ game: RacingGame, width: CGFloat) {
        let x = width - 266, y: CGFloat = 78
        panel(NSRect(x:x,y:y,width:250,height:229),color:NSColor(white:0.04,alpha:0.80),radius:3)
        let car = game.vehicle
        let warning = NSColor(rgb: 0xF2B875)
        text("轮胎 / 车损",x:x+12,y:y+9,size:11,weight:.semibold)
        text(car.wheels[0].setup.compound.label,x:x+170,y:y+9,size:11,color:muted,width:67,align:.right)
        for (row, entry) in [("左前",1),("右前",0),("左后",3),("右后",2)].enumerated() {
            let wheel = car.wheels[entry.1]
            let rowY = y+34+CGFloat(row)*28
            let alert = wheel.punctured || wheel.wear > 0.65 || wheel.temperature > 120 || wheel.pressure < 1.2
            text(entry.0,x:x+12,y:rowY,size:11,color:muted,width:32)
            text(String(format:"%.0f°C  %.2f bar",wheel.temperature,wheel.pressure),
                 x:x+49,y:rowY,size:11,color:alert ? warning : white,mono:true,width:112)
            let status = wheel.punctured ? "爆胎" : String(format:"余量 %.0f%%",(1-wheel.wear)*100)
            text(status,x:x+167,y:rowY,size:10,color:alert ? warning : muted,width:74,align:.right)
        }
        line(CGPoint(x:x+12,y:y+148),CGPoint(x:x+238,y:y+148),color:white.withAlphaComponent(0.15))
        let suspension = car.damage.suspension.max() ?? 0
        text(String(format:"车头 %.0f%%   车尾 %.0f%%",car.damage.front*100,car.damage.rear*100),
             x:x+12,y:y+156,size:11,color:car.damage.worst > 0.3 ? warning : muted)
        text(String(format:"悬架 %.0f%%   引擎 %.0f%%   水温 %.0f°C",suspension*100,car.damage.engine*100,car.coolantTemperature),
             x:x+12,y:y+176,size:10,color:car.damage.worst > 0.3 ? warning : muted,width:230)
        text("损伤 0% 为完好 · P / 十字键↓ 维修",x:x+12,y:y+205,size:9,color:muted,width:230)
    }

    private func drawCompactTiming(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        let x = width - 238, y = height - 151
        panel(NSRect(x:x,y:y,width:222,height:132), color:NSColor(white:0.04,alpha:0.76),radius:1)
        text("LAP TIMING",x:x+10,y:y+8,size:10,color:muted,weight:.semibold)
        text(String(format:"LAP %02d",game.session.lap),x:x+140,y:y+8,size:10,color:white,mono:true,width:70,align:.right)
        line(CGPoint(x:x+10,y:y+27),CGPoint(x:x+211,y:y+27),color:.white.withAlphaComponent(0.2))
        for (i,item) in [("Current",lapTime(game.session.elapsed)),("Last lap",lapTime(game.session.last)),("Best lap",lapTime(game.session.best))].enumerated() {
            let row = y+34+CGFloat(i)*23
            text(item.0,x:x+10,y:row,size:11,color:muted)
            text(item.1,x:x+90,y:row,size:13,color:i==0 && !game.session.validLap ? NSColor(rgb:0xE69B69) : white,mono:true,width:120,align:.right)
        }
        text("Y / Tab 切换视角  ·  V 隐藏仪表",x:x+10,y:y+109,size:9,color:muted)
    }

    private func drawPedals(_ game: RacingGame, height: CGFloat) {
        let y = height-78
        panel(NSRect(x:16,y:y-9,width:111,height:68),color:NSColor(white:0.04,alpha:0.62),radius:1)
        for (i, entry) in [("T",game.drivingInput.throttle,NSColor(rgb:0x68A571)),("B",game.drivingInput.brake,NSColor(rgb:0xD9715E))].enumerated() {
            let x = CGFloat(29+i*24)
            NSColor(white:0.28,alpha:1).setFill(); NSRect(x:x,y:y,width:10,height:36).fill()
            entry.2.setFill(); NSRect(x:x,y:y+36*(1-entry.1),width:10,height:36*entry.1).fill()
            text(entry.0,x:x,y:y+38,size:8,color:muted,width:10,align:.center)
        }
        text("\(game.vehicle.gear)",x:79,y:y-3,size:26,weight:.semibold,mono:true,width:35,align:.center)
        text(game.assists.automatic ? "AUTO" : "MAN",x:78,y:y+32,size:8,color:muted,width:35,align:.center)
    }

    private func drawHeader(_ game: RacingGame, width: CGFloat) {
        let diamond = NSBezierPath()
        diamond.move(to: CGPoint(x: 29, y: 49))
        diamond.line(to: CGPoint(x: 44, y: 24))
        diamond.line(to: CGPoint(x: 59, y: 49))
        diamond.line(to: CGPoint(x: 49, y: 49))
        diamond.line(to: CGPoint(x: 44, y: 39))
        diamond.line(to: CGPoint(x: 38, y: 49))
        diamond.close()
        lime.setFill()
        diamond.fill()
        text("APEX", x: 72, y: 20, size: 29, weight: .black)
        text("/ LAB", x: 162, y: 28, size: 18, color: muted, weight: .light)
        text("原生驾驶实验室    /    CIRCUIT TEST  1.0", x: 31, y: 63, size: 10, color: white.withAlphaComponent(0.7), weight: .medium)

        let connected = game.input.controller != nil
        let status = connected ? "●  XBOX / 手柄已连接" : "○  手柄未连接 · 可用键盘"
        panel(NSRect(x: width - 310, y: 25, width: 222, height: 35), radius: 7)
        text(status, x: width - 300, y: 34, size: 11, color: connected ? lime : muted, weight: .medium, width: 203, align: .center)
        button("?", NSRect(x: width - 73, y: 25, width: 45, height: 35), action: "help")
    }

    private func drawDashboard(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        let y = height-87
        panel(NSRect(x:135,y:y,width:160,height:68), color:NSColor(white:0.04,alpha:0.72),radius:1)
        text(String(format:"%03d",Int(game.vehicle.speedKPH)),x:147,y:y+4,size:28,color:white,weight:.semibold,mono:true,width:75)
        text("KM/H",x:218,y:y+20,size:9,color:muted)
        text(String(format:"%4d RPM",Int(game.vehicle.rpm)),x:148,y:y+43,size:10,color:muted,mono:true)
    }

    private func drawWelcome(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        let x: CGFloat = 56
        let y = max(133, (height - 414) / 2 - 6)
        let rect = NSRect(x: x, y: y, width: 430, height: 414)
        panel(rect, color: NSColor(rgb: 0x191B1D, alpha: 0.95), radius: 16)
        text("01   /   CIRCUIT TEST", x: x + 28, y: y + 27, size: 11, color: lime, weight: .bold)
        text("赛道练习", x: x + 27, y: y + 65, size: 34, weight: .bold)
        text("North Loop · 日间干地 · 单车测试", x: x + 29, y: y + 123, size: 14, color: muted)
        text("驾驶视角", x:x+29,y:y+180,size:13,color:muted)
        button("车内",NSRect(x:x+149,y:y+172,width:115,height:32),action:"viewCabin",active:game.cockpit)
        button("车外",NSRect(x:x+276,y:y+172,width:115,height:32),action:"viewChase",active:!game.cockpit)
        text(String(format: "%.2f 公里  /  干地练习  /  自动挡", game.circuit.length / 1000), x: x + 29, y: y + 209, size: 12, color: muted)
        line(CGPoint(x: x + 29, y: y + 247), CGPoint(x: x + 400, y: y + 247), color: white.withAlphaComponent(0.12))
        text(game.input.controller != nil ? "手柄已就绪 · RT 油门 / LT 刹车 / 左摇杆转向" : "Xbox 手柄或 W A S D 驾驶 · 回车进入赛道", x: x + 29, y: y + 266, size: 12, color: white)
        button("进入赛道    →", NSRect(x: x + 28, y: y + 310, width: 374, height: 49), action: "start", primary: true)
        text("Y / Tab 切换 · 车外右摇杆或 J / L 环视", x: x + 29, y: y + 378, size: 10, color: muted)
        panel(NSRect(x: width - 260, y: height - 179, width: 232, height: 125))
        text("BUILT FOR MAC", x: width - 243, y: height - 160, size: 10, color: lime, weight: .bold)
        text("CLUB PROTOTYPE", x: width - 244, y: height - 138, size: 24, weight: .bold)
        text("RWD   /   1,260 KG   /   6 SPEED", x: width - 243, y: height - 99, size: 10, color: muted, mono: true)
    }

    private func drawPause(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()
        // Clear obscured click targets: only this modal can receive clicks.
        actions = []
        let x = (width - 550) / 2
        let y = max(20, (height - 626) / 2)
        panel(NSRect(x: x, y: y, width: 550, height: 626), color: NSColor(rgb: 0x191B1D, alpha: 0.99), radius: 16)
        text("SESSION PAUSED", x: x + 28, y: y + 24, size: 10, color: lime, weight: .bold)
        text(game.showHelp ? "驾驶操作" : "练习已暂停", x: x + 27, y: y + 52, size: 26, weight: .bold)
        button(game.cockpit ? "车内 → 车外" : "车外 → 车内", NSRect(x:x+380,y:y+51,width:142,height:32), action:"camera")
        let rows = [
            ("转向", "左摇杆", "A / D 或 ← / →"),
            ("油门 / 刹车", "RT / LT", "W / S 或 ↑ / ↓"),
            ("升挡 / 降挡", "B / X 或 RB / LB", "E / Q"),
            ("切换视角", "Y", "Tab"),
            ("复位（保留车损）", "长按 A", "R"),
            ("暂停 / 继续", "Menu", "Esc")
        ]
        text("操作", x: x + 29, y: y + 111, size: 10, color: muted)
        text("XBOX", x: x + 169, y: y + 111, size: 10, color: lime, weight: .bold)
        text("键盘", x: x + 352, y: y + 111, size: 10, color: muted)
        for (index, row) in rows.enumerated() {
            let rowY = y + 141 + CGFloat(index) * 31
            text(row.0, x: x + 29, y: rowY, size: 12)
            text(row.1, x: x + 169, y: rowY, size: 12, color: white)
            text(row.2, x: x + 352, y: rowY, size: 11, color: muted, width: 180)
        }
        button(game.assists.abs ? "ABS 开" : "ABS 关", NSRect(x: x + 28, y: y + 344, width: 106, height: 32), action: "abs", active: game.assists.abs)
        button(game.assists.tractionControl ? "TCS 开" : "TCS 关", NSRect(x: x + 143, y: y + 344, width: 106, height: 32), action: "tc", active: game.assists.tractionControl)
        button(game.assists.automatic ? "自动挡" : "手动挡", NSRect(x: x + 258, y: y + 344, width: 106, height: 32), action: "automatic", active: game.assists.automatic)
        button(game.sound.muted ? "声音 关" : "声音 开", NSRect(x: x + 373, y: y + 344, width: 149, height: 32), action: "mute", active: !game.sound.muted)
        text(String(format: "摇杆死区  %.0f%%", game.assists.steeringDeadzone * 100), x: x + 29, y: y + 393, size: 12, color: muted)
        button("−", NSRect(x: x + 147, y: y + 386, width: 34, height: 28), action: "deadzoneDown")
        button("+", NSRect(x: x + 190, y: y + 386, width: 34, height: 28), action: "deadzoneUp")
        button(game.ghostEnabled ? "幽灵车 开" : "幽灵车 关", NSRect(x: x + 373, y: y + 386, width: 149, height: 28), action: "ghost", active: game.ghostEnabled)
        button("下次换胎：\(game.tyreSetup.compound.label)",NSRect(x:x+28,y:y+433,width:174,height:32),action:"compound")
        text(String(format:"冷压 %.2f bar",game.tyreSetup.coldPressure),x:x+219,y:y+442,size:11,color:muted,width:118)
        button("−",NSRect(x:x+373,y:y+435,width:65,height:28),action:"pressureDown")
        button("+",NSRect(x:x+450,y:y+435,width:72,height:28),action:"pressureUp")
        text("配方 / 冷压在维修换胎或重新开始时生效",x:x+29,y:y+475,size:10,color:muted,width:490)
        button(game.serviceRemaining > 0 ? "正在维修 · 继续后完成" : "拖回维修区 · 修车换胎 12 秒  [ P / 十字键↓ ]",
               NSRect(x:x+28,y:y+500,width:494,height:32),action:"service")
        button("重新开始", NSRect(x: x + 28, y: y + 555, width: 150, height: 42), action: "restart")
        button("继续驾驶    →", NSRect(x: x + 190, y: y + 555, width: 332, height: 42), action: "resume", primary: true)
    }
}

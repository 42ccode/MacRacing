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
                drawVehicleInfo(game)
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

    private func drawVehicleInfo(_ game: RacingGame) {
        let x: CGFloat = 18, y: CGFloat = 18, car = game.vehicle
        panel(NSRect(x:x,y:y,width:238,height:262),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text(car.kind.label,x:x+12,y:y+10,size:14,weight:.semibold,width:214)
        text(String(format:"实验预设 · %.0f kg · 后驱 / 6 挡",car.mass),x:x+12,y:y+34,size:10,color:muted,width:214)
        button("ABS \(game.assists.absLevel)/5",NSRect(x:x+12,y:y+57,width:100,height:28),action:"abs",active:car.absActive)
        button("TCS \(game.assists.tcLevel)/5",NSRect(x:x+124,y:y+57,width:100,height:28),action:"tc",active:car.tcActive)
        text("点击循环调节 · 0 关闭 / 5 强介入",x:x+12,y:y+91,size:9,color:muted,width:214)
        let active = NSColor(rgb:0xF2B875)
        text(String(format:"ABS 卸压 %2.0f%%   TCS 限扭 %2.0f%%",car.absRelease*100,car.tcReduction*100),
             x:x+12,y:y+109,size:10,color:car.absActive || car.tcActive ? active : muted,mono:true,width:214)
        line(CGPoint(x:x+12,y:y+131),CGPoint(x:x+225,y:y+131),color:white.withAlphaComponent(0.12))
        text(String(format:"水温 %.0f°C   可用动力 %.0f%%",car.coolantTemperature,car.powerFactor*100),x:x+12,y:y+142,size:11,width:214)
        text(String(format:"车头损伤 %.0f%%   车尾 %.0f%%",car.damage.front*100,car.damage.rear*100),x:x+12,y:y+164,size:10,color:muted,width:214)
        text(String(format:"引擎损伤 %.0f%%   悬架 %.0f%%",car.damage.engine*100,(car.damage.suspension.max() ?? 0)*100),x:x+12,y:y+184,size:10,color:muted,width:214)
        text(String(format:"刹车 %.0f°C   制动力 %.0f%%",car.wheels.map(\.brakeTemperature).max() ?? 40,(car.wheels.map(\.brakeFadeFactor).min() ?? 1)*100),x:x+12,y:y+205,size:10,color:muted,width:214)
        text(String(format:"滑移 %.0f%%   复位后 %.2f km",car.tyreSlip*100,car.distanceTravelled/1000),x:x+12,y:y+225,size:10,color:muted,width:214)
        text("损伤 0% 完好 · 1 / 2 调节辅助",x:x+12,y:y+244,size:8,color:muted,width:214)
        drawTrackMap(game,x:x,y:y+272)
    }

    private func drawTrackMap(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:238,height:192),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text(game.circuit.kind.label,x:x+12,y:y+10,size:12,weight:.semibold,width:140)
        text(String(format:"%.2f km",game.circuit.length/1000),x:x+154,y:y+12,size:10,color:muted,mono:true,width:72,align:.right)
        let points = game.circuit.samples.map(\.point)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minZ = points.map(\.y).min()!, maxZ = points.map(\.y).max()!
        let scale = min(206/(maxX-minX),120/(maxZ-minZ))
        func project(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x:x+119+CGFloat((p.x-(minX+maxX)/2)*scale),y:y+98+CGFloat((p.y-(minZ+maxZ)/2)*scale))
        }
        let path = NSBezierPath(); path.move(to:project(points[0]))
        for p in points.dropFirst() { path.line(to:project(p)) }
        path.close(); path.lineWidth = 4; NSColor(white:0.5,alpha:0.8).setStroke(); path.stroke()
        let start = project(game.circuit.start.point)
        white.setFill(); NSRect(x:start.x-3,y:start.y-3,width:6,height:6).fill()
        let p = project(game.vehicle.position)
        lime.setFill(); NSBezierPath(ovalIn:NSRect(x:p.x-4,y:p.y-4,width:8,height:8)).fill()
        line(p,CGPoint(x:p.x+CGFloat(sin(game.vehicle.heading))*10,y:p.y+CGFloat(cos(game.vehicle.heading))*10),color:lime,width:2)
        text(game.circuit.kind.detail,x:x+12,y:y+171,size:9,color:muted,width:214)
    }

    private func drawCondition(_ game: RacingGame, width: CGFloat) {
        let x = width - 286, y: CGFloat = 18
        let car = game.vehicle
        let amber = NSColor(rgb:0xF2B875)
        let green = NSColor(rgb:0x7EBB9C)
        let blue = NSColor(rgb:0x80AFD4)
        panel(NSRect(x:x,y:y,width:270,height:240),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text("轮胎状态",x:x+12,y:y+10,size:12,weight:.semibold,width:90)
        text("↑ 车头",x:x+111,y:y+12,size:9,color:muted,width:50,align:.center)
        text(car.wheels[0].setup.compound.label,x:x+193,y:y+10,size:11,color:muted,width:64,align:.right)
        for (slot, entry) in [("左前",1),("右前",0),("左后",3),("右后",2)].enumerated() {
            let wheel = car.wheels[entry.1]
            let tx = x+12+CGFloat(slot%2)*130, ty = y+36+CGFloat(slot/2)*81
            let warning = wheel.punctured || wheel.wear > 0.65 || wheel.pressure < 1.2
            let tone = warning ? NSColor(rgb:0xE77B6D) :
                (wheel.temperature > 115 ? amber : (wheel.temperature < 60 ? blue : green))
            panel(NSRect(x:tx,y:ty,width:116,height:74),color:NSColor(white:0.09,alpha:0.9),radius:4)
            let tyre = NSRect(x:tx+8,y:ty+21,width:21,height:39)
            tone.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect:tyre,xRadius:5,yRadius:5).fill()
            tone.setStroke()
            let outline = NSBezierPath(roundedRect:tyre,xRadius:5,yRadius:5)
            outline.lineWidth = 1.4; outline.stroke()
            for stripe in 0..<5 {
                let sy = tyre.minY+6+CGFloat(stripe)*6
                line(CGPoint(x:tyre.minX+4,y:sy),CGPoint(x:tyre.maxX-4,y:sy),color:tone.withAlphaComponent(0.65))
            }
            if wheel.punctured {
                line(CGPoint(x:tyre.minX,y:tyre.minY),CGPoint(x:tyre.maxX,y:tyre.maxY),color:tone,width:2)
            }
            text(entry.0,x:tx+8,y:ty+4,size:9,color:muted,width:30)
            let surface = wheel.surface == .kerb ? "路肩" : (wheel.surface == .grass ? "草地" : "沥青")
            text(surface,x:tx+57,y:ty+4,size:9,color:wheel.surface == .kerb ? amber : muted,width:51,align:.right)
            text(String(format:"%.0f°C",wheel.temperature),x:tx+37,y:ty+21,size:14,color:tone,weight:.medium,mono:true,width:72)
            text(String(format:"%.2f bar",wheel.pressure),x:tx+37,y:ty+40,size:10,color:white,mono:true,width:72)
            text(wheel.punctured ? "爆胎" : String(format:"余量 %.0f%%",(1-wheel.wear)*100),x:tx+37,y:ty+56,size:9,color:warning ? tone : muted,width:72)
            // Amber outline remains on actual kerb contact; its strength follows excitation.
            if wheel.surface == .kerb || wheel.kerbFeedback > 0.02 {
                amber.withAlphaComponent(CGFloat(0.3+wheel.kerbFeedback*0.7)).setStroke()
                let edge = NSBezierPath(roundedRect:NSRect(x:tx,y:ty,width:116,height:74).insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
                edge.lineWidth = 1.5; edge.stroke()
            }
        }
        text("蓝 冷胎   绿 工作区   橙 过热 / 路肩",x:x+12,y:y+197,size:9,color:muted,width:247)
        text(String(format:"车损 %.0f%%   水温 %.0f°C   P / ↓ 维修",car.damage.worst*100,car.coolantTemperature),
             x:x+12,y:y+217,size:10,color:car.damage.worst>0.3 ? amber : muted,width:247)
        drawSuspension(game,x:x,y:y+248)
        drawGForce(game,x:x,y:y+376)
    }

    private func drawSuspension(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:270,height:120),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text("悬挂动态",x:x+12,y:y+9,size:12,weight:.semibold,width:86)
        text("+ 压缩 / − 伸张 · mm",x:x+106,y:y+11,size:9,color:muted,width:152,align:.right)
        for (slot,entry) in [("左前",1),("右前",0),("左后",3),("右后",2)].enumerated() {
            let wheel = game.vehicle.wheels[entry.1]
            let cx = x+36+CGFloat(slot)*66
            let tone = wheel.surface == .kerb ? NSColor(rgb:0xF2B875) : NSColor(rgb:0x7EBB9C)
            let travel = CGFloat(clamp(wheel.suspensionTravel / 0.06,-1,1))
            let top = y+43, bottom = y+76-travel*16
            text(entry.0,x:cx-25,y:y+28,size:9,color:muted,width:50,align:.center)
            line(CGPoint(x:cx-20,y:y+76),CGPoint(x:cx+20,y:y+76),color:muted.withAlphaComponent(0.3))
            line(CGPoint(x:cx-11,y:top),CGPoint(x:cx+11,y:top),color:muted,width:2)
            let spring = NSBezierPath(); spring.move(to:CGPoint(x:cx,y:top))
            for step in 1...8 { spring.line(to:CGPoint(x:cx+(step==8 ? 0 : (step%2==0 ? -7 : 7)),y:top+(bottom-top)*CGFloat(step)/8)) }
            tone.setStroke(); spring.lineWidth = 1.5; spring.stroke()
            tone.setFill(); NSBezierPath(ovalIn:NSRect(x:cx-4,y:bottom-3,width:8,height:6)).fill()
            text(String(format:"%+.0f",wheel.suspensionTravel*1000),x:cx-29,y:y+92,size:11,color:tone,mono:true,width:58,align:.center)
            text(String(format:"%.1f kN",wheel.normalLoad/1000),x:cx-29,y:y+107,size:8,color:muted,mono:true,width:58,align:.center)
        }
    }

    private func drawGForce(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:270,height:150),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text("车辆加速度",x:x+12,y:y+9,size:12,weight:.semibold,width:112)
        text("外圈 2 G",x:x+171,y:y+11,size:9,color:muted,width:86,align:.right)
        let cx = x+73, cy = y+83, radius: CGFloat = 44
        for scale: CGFloat in [0.5,1] {
            muted.withAlphaComponent(0.28).setStroke()
            NSBezierPath(ovalIn:NSRect(x:cx-radius*scale,y:cy-radius*scale,width:radius*scale*2,height:radius*scale*2)).stroke()
        }
        line(CGPoint(x:cx-radius,y:cy),CGPoint(x:cx+radius,y:cy),color:muted.withAlphaComponent(0.25))
        line(CGPoint(x:cx,y:cy-radius),CGPoint(x:cx,y:cy+radius),color:muted.withAlphaComponent(0.25))
        text("加速",x:cx-18,y:y+26,size:8,color:muted,width:36,align:.center)
        text("制动",x:cx-18,y:y+132,size:8,color:muted,width:36,align:.center)
        text("左",x:x+10,y:cy-6,size:8,color:muted,width:16)
        text("右",x:x+121,y:cy-6,size:8,color:muted,width:16)
        func point(_ g: SIMD2<Double>) -> CGPoint {
            let scale = max(2,simd_length(g))
            return CGPoint(x:cx+CGFloat(g.x/scale)*radius,y:cy-CGFloat(g.y/scale)*radius)
        }
        for (i,g) in game.gTrace.enumerated() {
            let p = point(g)
            NSColor(rgb:0x83BBD0,alpha:CGFloat(i+1)/CGFloat(max(1,game.gTrace.count))*0.65).setFill()
            NSBezierPath(ovalIn:NSRect(x:p.x-1.3,y:p.y-1.3,width:2.6,height:2.6)).fill()
        }
        let g = game.vehicle.driverG, p = point(g)
        NSColor(rgb:0xDCEBE6).setFill()
        NSBezierPath(ovalIn:NSRect(x:p.x-3.5,y:p.y-3.5,width:7,height:7)).fill()
        text(String(format:"横向 %+.2f G",g.x),x:x+143,y:y+41,size:11,mono:true,width:118)
        text(String(format:"纵向 %+.2f G",g.y),x:x+143,y:y+62,size:11,mono:true,width:118)
        text("横向正值 = 向右",x:x+143,y:y+84,size:8,color:muted,width:118)
        let pulse = game.isPaused || game.serviceRemaining>0 ? 0 : game.vehicle.kerbFeedback
        text("路肩反馈",x:x+143,y:y+105,size:9,color:muted,width:114)
        NSColor(white:0.2,alpha:1).setFill(); NSRect(x:x+143,y:y+123,width:110,height:5).fill()
        NSColor(rgb:0xF2B875).setFill(); NSRect(x:x+143,y:y+123,width:110*CGFloat(pulse),height:5).fill()
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
        text("Y / Tab 六种视角  ·  V 隐藏仪表",x:x+10,y:y+109,size:9,color:muted)
    }

    private func drawPedals(_ game: RacingGame, height: CGFloat) {
        let x: CGFloat = 18, y = height-100
        let green = NSColor(rgb:0x78D947), red = NSColor(rgb:0xDF404A), yellow = NSColor(rgb:0xFFD644)
        let rect = NSRect(x:x,y:y,width:414,height:82)
        panel(rect,color:NSColor(rgb:0x23242A,alpha:0.94),radius:10)
        let plot = NSRect(x:x+7,y:y+10,width:185,height:62)
        NSColor(white:0.18,alpha:1).setFill();plot.fill()
        for tick in 0...10 {
            let gx=plot.minX+plot.width*CGFloat(tick)/10
            line(CGPoint(x:gx,y:plot.minY),CGPoint(x:gx,y:plot.maxY),color:white.withAlphaComponent(tick%2==0 ? 0.07 : 0.025))
        }
        for tick in 0...2 {
            let gy=plot.minY+plot.height*CGFloat(tick)/2
            line(CGPoint(x:plot.minX,y:gy),CGPoint(x:plot.maxX,y:gy),color:white.withAlphaComponent(0.06))
        }
        func point(_ sample:InputHistory.Sample,_ value:Double) -> CGPoint {
            CGPoint(x:plot.maxX-CGFloat((game.inputHistory.time-sample.time)/InputHistory.duration)*plot.width,
                    y:plot.maxY-CGFloat(value)*plot.height)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:plot.insetBy(dx:-1,dy:-1)).addClip()
        let samples=game.inputHistory.samples
        func trace(color:NSColor,value:(InputHistory.Sample)->Double,enabled:(InputHistory.Sample)->Bool) {
            let path=NSBezierPath();path.lineWidth=1.8;path.lineJoinStyle = .round;path.lineCapStyle = .round
            var connected=false
            for i in 1..<max(1,samples.count) {
                let a=samples[i-1], b=samples[i]
                if enabled(b) {
                    if !connected {path.move(to:point(a,value(a)))}
                    path.line(to:point(b,value(b)));connected=true
                } else {connected=false}
            }
            color.setStroke();path.stroke()
        }
        trace(color:green,value:{$0.throttle},enabled:{_ in true})
        trace(color:red,value:{$0.brake},enabled:{_ in true})
        trace(color:yellow,value:{$0.brake},enabled:{$0.absActive && $0.brake>0.01})
        NSGraphicsContext.restoreGraphicsState()
        // The two bars are LT (left, brake) and RT (right, throttle).
        for (i,raw) in [game.drivingInput.brake,game.drivingInput.throttle].enumerated() {
            let value=CGFloat(raw.isFinite ? clamp(raw,0,1) : 0)
            let bar=NSRect(x:x+204+CGFloat(i)*19,y:y+10,width:13,height:62)
            NSColor(white:0.12,alpha:1).setFill();bar.fill()
            NSColor.white.withAlphaComponent(0.06).setFill();NSRect(x:bar.minX+2,y:bar.minY+2,width:bar.width-4,height:bar.height-4).fill()
            (i==0 ? (game.vehicle.absActive && value>0 ? yellow : red) : green).setFill()
            NSRect(x:bar.minX,y:bar.maxY-bar.height*value,width:bar.width,height:bar.height*value).fill()
            for t in [0.0,1.0] {
                line(CGPoint(x:bar.minX,y:bar.minY+bar.height*t),CGPoint(x:bar.maxX,y:bar.minY+bar.height*t),color:white.withAlphaComponent(0.16))
            }
        }
        text("\(game.vehicle.gear)",x:x+241,y:y+14,size:40,color:yellow,weight:.bold,mono:true,width:38,align:.center)
        text(String(format:"%.0f",game.vehicle.speedKPH),x:x+281,y:y+21,size:18,weight:.bold,mono:true,width:48,align:.center)
        text("km/h",x:x+281,y:y+44,size:11,color:muted,weight:.semibold,width:48,align:.center)

        // Positive controller input is driver-right; the flipped HUD rotates
        // clockwise for a positive angle. This is an input indicator, not FFB.
        let raw=game.drivingInput.steering
        let angle=CGFloat(raw.isFinite ? clamp(raw,-1,1) : 0)*CGFloat.pi*0.75
        let centre=CGPoint(x:x+371,y:y+41), radius:CGFloat=28
        func rotated(_ dx:CGFloat,_ dy:CGFloat) -> CGPoint {
            CGPoint(x:centre.x+dx*cos(angle)-dy*sin(angle),y:centre.y+dx*sin(angle)+dy*cos(angle))
        }
        let rim=NSBezierPath(ovalIn:NSRect(x:centre.x-radius,y:centre.y-radius,width:radius*2,height:radius*2))
        white.setStroke();rim.lineWidth=6;rim.stroke()
        for end in [rotated(-25,-6),rotated(25,-6),rotated(0,25)] { line(centre,end,color:white,width:7) }
        white.setFill();NSBezierPath(ovalIn:NSRect(x:centre.x-8,y:centre.y-8,width:16,height:16)).fill()
        line(rotated(0,-31),rotated(0,-25),color:red,width:3)
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
        text("原生驾驶实验室    /    CIRCUIT TEST  1.5.2", x: 31, y: 63, size: 10, color: white.withAlphaComponent(0.7), weight: .medium)

        let connected = game.input.controller != nil
        let status = connected ? "●  XBOX / 手柄已连接" : "○  手柄未连接 · 可用键盘"
        panel(NSRect(x: width - 310, y: 25, width: 222, height: 35), radius: 7)
        text(status, x: width - 300, y: 34, size: 11, color: connected ? lime : muted, weight: .medium, width: 203, align: .center)
        button("?", NSRect(x: width - 73, y: 25, width: 45, height: 35), action: "help")
    }

    private func drawWelcome(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        let x: CGFloat = 56
        let y = max(133, (height - 414) / 2 - 6)
        let rect = NSRect(x: x, y: y, width: 430, height: 414)
        panel(rect, color: NSColor(rgb: 0x191B1D, alpha: 0.95), radius: 16)
        text("01   /   CIRCUIT TEST", x: x + 28, y: y + 27, size: 11, color: lime, weight: .bold)
        text("赛道练习", x: x + 27, y: y + 65, size: 34, weight: .bold)
        button(game.circuit.kind.label + String(format:" · %.2f km  ›",game.circuit.length/1000),NSRect(x:x+28,y:y+116,width:374,height:35),action:"trackNext")
        drawTrackMap(game,x:width-266,y:140)
        text("驾驶视角", x:x+29,y:y+180,size:13,color:muted)
        button("‹",NSRect(x:x+149,y:y+172,width:34,height:32),action:"cameraPrevious")
        text(game.drivingView.label,x:x+188,y:y+180,size:12,width:160,align:.center)
        button("›",NSRect(x:x+357,y:y+172,width:34,height:32),action:"camera")
        text("选择车辆",x:x+29,y:y+219,size:13,color:muted)
        button("‹",NSRect(x:x+149,y:y+210,width:34,height:30),action:"vehiclePrevious")
        text(game.vehicle.kind.label,x:x+185,y:y+219,size:12,width:169,align:.center)
        button("›",NSRect(x:x+357,y:y+210,width:34,height:30),action:"vehicleNext")
        line(CGPoint(x: x + 29, y: y + 247), CGPoint(x: x + 400, y: y + 247), color: white.withAlphaComponent(0.12))
        text(game.input.controller != nil ? "手柄已就绪 · RT 油门 / LT 刹车 / 左摇杆转向" : "Xbox 手柄或 W A S D 驾驶 · 回车进入赛道", x: x + 29, y: y + 266, size: 12, color: white)
        button("进入赛道    →", NSRect(x: x + 28, y: y + 310, width: 374, height: 49), action: "start", primary: true)
        text("Y / Tab 切视角 · N / 十字键↑ 换赛道", x: x + 29, y: y + 378, size: 10, color: muted)
        panel(NSRect(x: width - 260, y: height - 179, width: 232, height: 125))
        text("BUILT FOR MAC", x: width - 243, y: height - 160, size: 10, color: lime, weight: .bold)
        text(game.vehicle.kind.label, x: width - 244, y: height - 138, size: 20, weight: .bold, width:215)
        text(game.vehicle.kind == .porsche ? "实验驾驶预设 · 简化座舱" : "实验驾驶预设 · 非实车标定", x: width - 243, y: height - 108, size: 10, color: muted)
        text(game.vehicle.kind.credit,x:width-243,y:height-88,size:8,color:muted,width:215)
    }

    private func drawPause(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()
        // Clear obscured click targets: only this modal can receive clicks.
        actions = []
        let x = (width - 550) / 2
        let y = max(20, (height - 674) / 2)
        panel(NSRect(x: x, y: y, width: 550, height: 674), color: NSColor(rgb: 0x191B1D, alpha: 0.99), radius: 16)
        text("SESSION PAUSED", x: x + 28, y: y + 24, size: 10, color: lime, weight: .bold)
        text(game.showHelp ? "驾驶操作" : "练习已暂停", x: x + 27, y: y + 52, size: 26, weight: .bold)
        button(game.drivingView.label + " ›", NSRect(x:x+380,y:y+51,width:142,height:32), action:"camera")
        button("车辆：" + game.vehicle.kind.label + " ›  换车重开 [C / ←→]",NSRect(x:x+28,y:y+86,width:494,height:22),action:"vehicleNext")
        button("赛道：" + game.circuit.kind.label + " ›  换图重开 [N / ↑]",NSRect(x:x+28,y:y+115,width:494,height:24),action:"trackNext")
        let rows = [
            ("转向", "左摇杆", "A / D 或 ← / →"),
            ("油门 / 刹车", "RT / LT", "W / S 或 ↑ / ↓"),
            ("升挡 / 降挡", "B / X 或 RB / LB", "E / Q"),
            ("切换视角", "Y", "Tab"),
            ("复位（保留车损）", "长按 A", "R"),
            ("暂停 / 继续", "Menu", "Esc")
        ]
        text("操作", x: x + 29, y: y + 148, size: 10, color: muted)
        text("XBOX", x: x + 169, y: y + 148, size: 10, color: lime, weight: .bold)
        text("键盘", x: x + 352, y: y + 148, size: 10, color: muted)
        for (index, row) in rows.enumerated() {
            let rowY = y + 174 + CGFloat(index) * 24
            text(row.0, x: x + 29, y: rowY, size: 12)
            text(row.1, x: x + 169, y: rowY, size: 12, color: white)
            text(row.2, x: x + 352, y: rowY, size: 11, color: muted, width: 180)
        }
        text("辅助等级 0 关闭 / 5 最强 · 点击按钮循环，或按 1 / 2",x:x+29,y:y+321,size:10,color:muted,width:494)
        button("ABS \(game.assists.absLevel)/5", NSRect(x: x + 28, y: y + 344, width: 106, height: 32), action: "abs", active: game.assists.abs)
        button("TCS \(game.assists.tcLevel)/5", NSRect(x: x + 143, y: y + 344, width: 106, height: 32), action: "tc", active: game.assists.tractionControl)
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
        button("震动强度 \(game.input.hapticLevel * 25)%",NSRect(x:x+28,y:y+500,width:150,height:30),action:"hapticLevel",active:game.input.hapticLevel>0)
        button("测试手柄震动",NSRect(x:x+193,y:y+500,width:150,height:30),action:"hapticTest")
        text(game.input.hapticStatus,x:x+29,y:y+537,size:10,color:muted,width:494)
        button(game.serviceRemaining > 0 ? "正在维修 · 继续后完成" : "拖回维修区 · 修车换胎 12 秒  [ P / 十字键↓ ]",
               NSRect(x:x+28,y:y+558,width:494,height:32),action:"service")
        button("重新开始", NSRect(x: x + 28, y: y + 606, width: 150, height: 42), action: "restart")
        button("继续驾驶    →", NSRect(x: x + 190, y: y + 606, width: 332, height: 42), action: "resume", primary: true)
    }
}

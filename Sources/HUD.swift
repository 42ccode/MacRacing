import AppKit
import simd

struct HUDPosition: Codable {
    let x: Double
    let y: Double

    init(origin: CGPoint, size: CGSize, viewport: CGSize) {
        x = Double(clamp((origin.x - 12) / max(1, viewport.width-size.width-24), 0, 1))
        y = Double(clamp((origin.y - 12) / max(1, viewport.height-size.height-24), 0, 1))
    }

    func origin(size: CGSize, viewport: CGSize) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: 12 + clamp(x,0,1)*max(0,viewport.width-size.width-24),
                       y: 12 + clamp(y,0,1)*max(0,viewport.height-size.height-24))
    }
}

private enum HUDPanel: String, CaseIterable {
    case vehicle, map, tyres, suspension, acceleration, timing, delta, pedals, mirror, dash

    var shownInCompactMode: Bool {
        switch self {
        case .map, .timing, .delta, .mirror, .dash: return true
        case .vehicle, .tyres, .suspension, .acceleration, .pedals: return false
        }
    }

    func defaultFrame(in viewport: CGSize) -> CGRect {
        let width = viewport.width, height = viewport.height
        switch self {
        case .vehicle: return CGRect(x:18,y:18,width:238,height:292)
        case .map: return CGRect(x:18,y:320,width:238,height:192)
        case .tyres: return CGRect(x:width-286,y:18,width:270,height:240)
        case .suspension: return CGRect(x:width-286,y:266,width:270,height:120)
        case .acceleration: return CGRect(x:width-286,y:394,width:270,height:150)
        case .timing: return CGRect(x:width-214,y:height-123,width:196,height:105)
        case .delta: return CGRect(x:(width-340)/2,y:18,width:340,height:84)
        case .pedals: return CGRect(x:18,y:height-162,width:414,height:144)
        case .mirror: return CGRect(x:(width-356)/2,y:18,width:356,height:96)
        case .dash: return CGRect(x:(width-338)/2,y:height-113,width:338,height:95)
        }
    }
}

final class HUDView: NSView {
    weak var game: RacingGame?
    private var actions: [(NSRect, String)] = []
    private var nativeButtons: [String: NSButton] = [:]
    private var buttonLabels: [String: String] = [:]
    private var menuFocus: String?
    private var hoveredAction: String?
    private var pointerLocation: CGPoint?
    private var renderedMenu: String?
    private var interactionTransform = AffineTransform()
    private var pressedMenuFocus = false
    private var analysisCursorIndex: Int?
    var analysisMarker: Int? { analysisCursorIndex }
    private var analysisHitArea = CGRect.zero
    private var analysisTraceOrigin: CGFloat = 0
    private var analysisTraceWidth: CGFloat = 1
    private var menuMouseTracking: NSTrackingArea?
    private var mapGeometry: (circuit: Circuit, path: NSBezierPath, lane: NSBezierPath, project: (SIMD2<Double>) -> CGPoint)?
    private var panelFrames: [(HUDPanel, CGRect)] = []
    private var drag: (panel: HUDPanel, offset: CGPoint, size: CGSize)?

    func layoutModeChanged() {
        drag = nil
        actions.removeAll()
        synchronizeAccessibleButtons()
        needsDisplay = true
    }

    private var menuIdentity: String? {
        guard let game, game.isNavigatingMenu else { return nil }
        if game.editingHUD { return "hudEditor" }
        if game.showingControllerReview { return "calibration" }
        if game.showingAnalysis { return "analysis" }
        if game.showHelp { return "help" }
        if let selection = game.garageSelection { return "garage:"+String(describing:selection) }
        if let prompt = game.sessionPrompt { return "prompt:"+String(describing:prompt) }
        if game.settingsReset != nil { return "resetSettings" }
        if game.showingSeatPreview { return "seatPreview" }
        if let choice = game.settingsChoice { return "choice:"+choice.rawValue }
        if let page = game.settingsPage { return "settings:"+page.rawValue }
        if !game.hasStarted { return "welcome" }
        return game.sprint == nil ? "pause" : "sprint"
    }

    var menuFocusAction: String? { renderedMenu == menuIdentity ? menuFocus : nil }
    var visibleActionFrames: [(NSRect,String)] { actions }
    var visibleDrivingPanels: [(String,CGRect)] { panelFrames.map { ($0.0.rawValue,$0.1) } }
    var editablePanelKeys: [String] {
        guard let game else { return [] }
        return HUDPanel.allCases.filter { game.compactHUD ? $0.shownInCompactMode : $0 != .dash }.map(\.rawValue)
    }

    func moveMenuFocus(_ direction: String) {
        guard let current = menuIdentity, current == renderedMenu, !actions.isEmpty else { return }
        if current == "analysis", analysisTraceWidth > 1, ["menuLeft","menuRight"].contains(direction) {
            let delta = direction == "menuLeft" ? -2 : 2
            analysisCursorIndex = clamp((analysisCursorIndex ?? 100)+delta,0,LapInputs.intervals)
            needsDisplay = true
            return
        }
        pressedMenuFocus = true
        hoveredAction = nil
        pointerLocation = nil
        guard let id = menuFocus, let index = actions.firstIndex(where: { $0.1 == id }) else {
            menuFocus = (direction == "menuPrevious" ? actions.last : actions.first)?.1
            needsDisplay = true
            return
        }
        if direction == "menuNext" || direction == "menuPrevious" {
            menuFocus = actions[(index + actions.count + (direction == "menuNext" ? 1 : -1)) % actions.count].1
        } else {
            let origin = actions[index].0
            let horizontal = direction == "menuLeft" || direction == "menuRight"
            let sign: CGFloat = direction == "menuLeft" || direction == "menuUp" ? -1 : 1
            let best = actions.enumerated().compactMap { offset, item -> (String,CGFloat)? in
                guard offset != index else { return nil }
                let dx = item.0.midX-origin.midX, dy = item.0.midY-origin.midY
                let primary = (horizontal ? dx : dy)*sign
                let lateral = abs(horizontal ? dy : dx)
                guard primary > 6 else { return nil }
                return (item.1,primary + lateral*3.3)
            }.min { $0.1 < $1.1 }
            if let best { menuFocus = best.0 }
        }
        needsDisplay = true
    }

    @discardableResult func activateMenuFocus() -> Bool {
        guard menuIdentity != nil else { return false }
        // An event arriving between menu transitions cannot reuse the previous screen's controls.
        guard menuIdentity == renderedMenu else { return true }
        guard let id = menuFocus, actions.contains(where: { $0.1 == id }) else { return false }
        game?.action(id)
        return true
    }

    @objc private func activateButton(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        if let action = sender.identifier?.rawValue { activate(action) }
    }

    private func activate(_ action: String) {
        guard renderedMenu == menuIdentity else { return }
        if menuIdentity != nil { menuFocus = action; pressedMenuFocus = false }
        game?.action(action)
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
    private let lime = NSColor(rgb: 0xD9F885)
    private let white = NSColor(rgb: 0xF1F5F1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func keyDown(with event: NSEvent) { game?.input.keyDown(event,navigateMenu:game?.isNavigatingMenu == true) }
    override func keyUp(with event: NSEvent) { game?.input.keys.remove(event.keyCode) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = actions.reversed().first(where: { $0.0.contains(point) }) {
            activate(hit.1)
        } else if game?.editingHUD == true, let (panel, frame) = panelFrames.reversed().first(where: { $0.1.contains(point) }) {
            drag = (panel, CGPoint(x: point.x-frame.minX, y: point.y-frame.minY), frame.size)
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let menuMouseTracking { removeTrackingArea(menuMouseTracking) }
        let tracking = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking)
        menuMouseTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from:nil)
        pointerLocation = point
        let hover = renderedMenu == menuIdentity && renderedMenu != nil
            ? actions.last(where:{ $0.0.contains(point) })?.1 : nil
        if hover != hoveredAction { hoveredAction = hover; needsDisplay = true }
        guard game?.showingAnalysis == true else { return }
        guard analysisHitArea.contains(point) else { return }
        let fraction = clamp((point.x-analysisTraceOrigin)/analysisTraceWidth,0,1)
        let index = Int((fraction*CGFloat(LapInputs.intervals)).rounded())
        if analysisCursorIndex != index { analysisCursorIndex = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        if hoveredAction != nil { hoveredAction = nil; needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let game, game.editingHUD, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = CGPoint(x: point.x-drag.offset.x, y: point.y-drag.offset.y)
        game.hudPositions[drag.panel.rawValue] = HUDPosition(origin: origin, size: drag.size, viewport: bounds.size)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if drag != nil { drag = nil; needsDisplay = true }
    }

    private func drawDrivingPanels(_ game: RacingGame) {
        panelFrames.removeAll(keepingCapacity: true)
        for item in HUDPanel.allCases {
            if game.compactHUD && !item.shownInCompactMode { continue }
            if item == .dash && !game.compactHUD { continue }
            if item == .pedals && game.compactHUD { continue }
            if item == .acceleration && (bounds.width < 960 || bounds.height < 690) && !game.compactHUD &&
                !game.editingHUD && game.hudPositions[item.rawValue] == nil { continue }
            if item == .delta && game.serviceRemaining > 0 && !game.editingHUD { continue }
            if item == .mirror && !game.showMirror && !game.editingHUD { continue }
            if item == .delta && game.sprint != nil && !game.editingHUD { continue }
            var frame = item.defaultFrame(in: bounds.size)
            if item == .map && game.compactHUD { frame.origin.y = 18 }
            if item == .map && !game.compactHUD && bounds.height < 690 {
                frame.origin.y = 315
                frame.size.height = 158
            }
            if item == .delta && (game.showMirror || game.editingHUD) { frame.origin.y = 123 }
            if game.editingHUD && item == .mirror { frame.origin.y = 61 }
            if game.editingHUD && item == .delta { frame.origin.y = 166 }
            if !game.compactHUD && bounds.width < 960 {
                let left: CGFloat = 268, right = bounds.width-296
                if item == .delta || item == .mirror {
                    frame.size.width = min(frame.width,right-left)
                    frame.origin.x = (left+right-frame.width)/2
                }
            }
            if let origin = game.hudPositions[item.rawValue]?.origin(size:frame.size,viewport:bounds.size) {
                frame.origin = origin
            }
            let x = frame.minX, y = frame.minY
            switch item {
            case .vehicle: drawVehicleInfo(game,x:x,y:y)
            case .map:
                if frame.height < 192 {
                    NSGraphicsContext.saveGraphicsState()
                    let transform = NSAffineTransform(); transform.translateX(by:x,yBy:y)
                    transform.scaleX(by:1,yBy:frame.height/192); transform.concat()
                    drawTrackMap(game,x:0,y:0)
                    NSGraphicsContext.restoreGraphicsState()
                } else { drawTrackMap(game,x:x,y:y) }
            case .tyres: drawCondition(game,x:x,y:y)
            case .suspension: drawSuspension(game,x:x,y:y)
            case .acceleration: drawGForce(game,x:x,y:y)
            case .timing:
                if let race = game.sprint { drawSprint(race, x:x, y:y) }
                else { drawCompactTiming(game,x:x,y:y) }
            case .delta:
                if frame.width < 340 {
                    NSGraphicsContext.saveGraphicsState()
                    let transform = NSAffineTransform(); transform.translateX(by:x,yBy:y)
                    transform.scaleX(by:frame.width/340,yBy:1); transform.concat()
                    drawLapDelta(game,x:0,y:0)
                    NSGraphicsContext.restoreGraphicsState()
                } else { drawLapDelta(game,x:x,y:y) }
            case .pedals: drawPedals(game,x:x,y:y+62)
            case .mirror: drawMirror(game, frame: frame)
            case .dash: drawDash(game,frame:frame)
            }
            panelFrames.append((item, frame))
            if game.editingHUD {
                NSColor(rgb:0x78DCE8,alpha:drag?.panel == item ? 1 : 0.65).setStroke()
                let border = NSBezierPath(roundedRect:frame,xRadius:5,yRadius:5)
                border.lineWidth = drag?.panel == item ? 2.5 : 1.5
                border.stroke()
            }
        }
    }

    private func drawDash(_ game: RacingGame,frame: CGRect) {
        let r = frame, car = game.vehicle
        panel(r,color:NSColor(rgb:0x141B28,alpha:0.93),radius:10)
        let gear = r.minX+13
        panel(NSRect(x:gear,y:r.minY+19,width:64,height:61),color:NSColor(rgb:0x242F38),radius:7)
        text(car.gearLabel,x:gear,y:r.minY+26,size:29,color:lime,weight:.bold,mono:true,width:64,align:.center)
        text(String(format:"%.0f",car.speedKPH),x:r.minX+87,y:r.minY+17,size:35,weight:.bold,mono:true,width:100,align:.right)
        text("km/h",x:r.minX+195,y:r.minY+41,size:11,color:muted,width:36)
        let fill = car.rpm/max(1,car.kind.redline)
        for i in 0..<12 {
            let isOn = Double(i+1)/12 <= fill
            let color = i >= 10 ? NSColor(rgb:0xFF826E) : lime
            (isOn ? color : NSColor(rgb:0x29333E)).setFill()
            NSRect(x:r.minX+89+CGFloat(i)*11,y:r.minY+67,width:8,height:4).fill()
        }
        let bars: [(String,Double,NSColor)] = [
            ("制动",car.brakeLinePressure,car.absActive ? NSColor(rgb:0xFFE083) : NSColor(rgb:0xFF8E85)),
            ("油门",game.drivingInput.throttle,NSColor(rgb:0x9ADF9E))
        ]
        for (i,row) in bars.enumerated() {
            let y = r.minY+23+CGFloat(i)*29, x = r.minX+242
            text(row.0,x:x,y:y,size:9,color:muted,width:36)
            NSColor(rgb:0x2E3A45).setFill(); NSRect(x:x,y:y+15,width:79,height:5).fill()
            row.2.setFill(); NSRect(x:x,y:y+15,width:79*clamp(row.1,0,1),height:5).fill()
        }
        if car.absActive || car.tcActive {
            let warning = NSColor(rgb:0xFFE083)
            text([car.absActive ? "ABS" : nil,car.tcActive ? "TCS" : nil].compactMap{$0}.joined(separator:" / "),
                 x:r.minX+93,y:r.minY+75,size:9,color:warning,weight:.bold,width:130,align:.center)
        }
        if game.inPitLane {
            let status = game.pitOverspeed ? "维修道超速 · 减速至 60 km/h" :
                (game.pitApproachLabel ?? (game.inPitSpeedZone ? "维修道 · 限速 60 km/h" : "驶出限速区 · 注意并线"))
            drawDashStatus(status,above:r,warning:game.pitOverspeed)
        } else if car.wheels.contains(where: \.punctured) {
            drawDashStatus("轮胎失压 · 减速并返回维修区",above:r,warning:true)
        } else if game.autoDriveEnabled {
            drawDashStatus("自动驾驶 · 操作踏板或转向接管",above:r,warning:false)
        }
    }

    private func drawDashStatus(_ label: String, above rect: CGRect, warning: Bool) {
        let r = NSRect(x:rect.minX,y:rect.minY-32,width:rect.width,height:25)
        panel(r,color:NSColor(rgb:0x141B28,alpha:0.94),radius:5)
        text(label,x:r.minX+10,y:r.minY+4,size:10,color:warning ? NSColor(rgb:0xFFB06B) : lime,
             weight:.semibold,width:r.width-20,align:.center)
    }

    private func drawMirror(_ game: RacingGame, frame: NSRect) {
        panel(frame, color: NSColor(rgb:0x15181B), radius: 8)
        guard let image = game.mirrorImage, !game.editingHUD else {
            text("虚拟后视镜",x:frame.minX+8,y:frame.midY-9,size:12,width:frame.width-16,align:.center)
            return
        }
        let glass = frame.insetBy(dx:3,dy:3)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect:glass,xRadius:4,yRadius:4).addClip()
        let reflection = AffineTransform(m11:-1,m12:0,m21:0,m22:1,tX:2*glass.midX,tY:0)
        (reflection as NSAffineTransform).concat()
        image.draw(in:glass,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        NSGraphicsContext.restoreGraphicsState()

        let traffic = game.sideTraffic
        let alert = NSColor(rgb:0xFFC15E)
        alert.setFill()
        for (active, x) in [(traffic.left,glass.minX+3),(traffic.right,glass.maxX-6)] where active {
            NSBezierPath(roundedRect:NSRect(x:x,y:glass.midY-19,width:3,height:38),xRadius:1.5,yRadius:1.5).fill()
        }
    }

    private func drawLayoutToolbar() {
        actions.removeAll()
        let x = max(268,(bounds.width-538)/2), y = 8.0
        panel(NSRect(x:x,y:y,width:538,height:43),color:NSColor(rgb:0x172A31),radius:7)
        text("拖动面板调整位置",x:x+14,y:y+13,size:11,width:128)
        button("恢复本布局",NSRect(x:x+140,y:y+6,width:104,height:31),action:"hudLayoutReset")
        button("取消  Esc / B",NSRect(x:x+256,y:y+6,width:118,height:31),action:"cancelHUDLayout")
        button("保存布局  F6",NSRect(x:x+386,y:y+6,width:139,height:31),action:"hudLayout",primary:true)
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

    private func button(_ label: String, _ rect: NSRect, action: String, primary: Bool = false, active: Bool = false, accessibility: String? = nil) {
        panel(rect, color: primary ? lime : NSColor(rgb: active ? 0x38452F : 0x272E39, alpha: 0.98), radius: 7)
        text(label, x: rect.minX + 12, y: rect.minY + (rect.height - 19) / 2, size: 12,
             color: primary ? NSColor(rgb: 0x162012) : (active ? lime : white), weight: .semibold, width: rect.width - 24, align: .center)
        let a = interactionTransform.transform(rect.origin)
        let b = interactionTransform.transform(CGPoint(x:rect.maxX,y:rect.maxY))
        actions.append((NSRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y),action))
        buttonLabels[action] = accessibility ?? label
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let game else { return }
        actions = []
        panelFrames.removeAll(keepingCapacity:true)
        defer { synchronizeAccessibleButtons() }
        let w = bounds.width
        let h = bounds.height
        let identity = menuIdentity
        if identity != renderedMenu {
            renderedMenu = identity
            hoveredAction = nil
            pointerLocation = nil
            analysisCursorIndex = nil
            analysisTraceWidth = 1
            analysisHitArea = .zero
            switch identity {
            case "welcome": menuFocus = "start"
            case "pause","sprint": menuFocus = "resume"
            case "help": menuFocus = "help"
            case "analysis": menuFocus = "analysis"
            case "calibration": menuFocus = "controllerReview"
            case "garage:vehicles": menuFocus = "car:"+String(game.vehicle.kind.rawValue)
            case "garage:circuits": menuFocus = "circuit:"+String(game.circuit.kind.rawValue)
            case "prompt:restart","prompt:leave","prompt:pit": menuFocus = "cancelPrompt"
            case "resetSettings": menuFocus = "cancelSettingsReset"
            case "seatPreview": menuFocus = "seatPreview"
            case "hudEditor": menuFocus = "hudLayout"
            default:
                if let choice = game.settingsChoice { menuFocus = "setChoice:"+String(game.currentSettingsChoice(choice)) }
                else if identity?.hasPrefix("settings:") == true { menuFocus = game.consumeSettingsReturnFocus() ?? identity }
                else { menuFocus = nil }
            }
        }
        defer {
            if let pointerLocation, let hover = actions.last(where: { $0.0.contains(pointerLocation) })?.1,
               let rect = actions.first(where: { $0.1 == hover })?.0, identity != nil {
                hoveredAction = hover
                let path = NSBezierPath(roundedRect:rect.insetBy(dx:-1,dy:-1),xRadius:8,yRadius:8)
                white.withAlphaComponent(0.55).setStroke(); path.lineWidth = 1; path.stroke()
            }
            if let selection = menuFocus, let rect = actions.first(where: { $0.1 == selection })?.0, identity != nil {
                if pressedMenuFocus {
                    let path = NSBezierPath(roundedRect:rect.insetBy(dx:-2,dy:-2),xRadius:9,yRadius:9)
                    lime.setStroke(); path.lineWidth = 2; path.stroke()
                }
            } else { menuFocus = nil }
        }
        if game.showingControllerReview {
            drawControllerReview(game,width:w,height:h)
            return
        }
        if game.showingAnalysis {
            drawFitting(width:w,height:h,preferredWidth:1060,preferredHeight:674) { width,height in
                drawAnalysis(game,width:width,height:height)
            }
            return
        }
        if let reset = game.settingsReset {
            drawSettingsReset(reset,width:w,height:h)
            return
        }
        if game.showingSeatPreview {
            drawSeatPreview(game,width:w,height:h)
            return
        }
        if let choice = game.settingsChoice {
            drawSettingsChoice(game,choice:choice,width:w,height:h)
            return
        }
        if let page = game.settingsPage {
            drawSettings(game,page:page,width:w,height:h)
            return
        }
        if game.showHelp {
            drawHelp(width:w,height:h)
            return
        }
        if let prompt = game.sessionPrompt {
            drawSessionPrompt(game,prompt:prompt,width:w,height:h)
            return
        }
        if let selection = game.garageSelection {
            drawGarage(game,selection:selection,width:w,height:h)
            return
        }
        if !game.hasStarted { drawHeader(game, width: w) }
        if game.hasStarted {
            if game.isPaused && !game.editingHUD { drawPause(game,width:w,height:h); return }
            if game.showHUD || game.editingHUD {
                drawDrivingPanels(game)
                if !game.showMirror && !game.editingHUD { drawSideAlerts(game,width:w,height:h) }
            }
            if game.editingHUD {
                drawLayoutToolbar()
                return
            }
            if game.noticeRemaining > 0, game.serviceRemaining == 0,
               (game.sprint?.countdown ?? 0) == 0, game.sprint?.showGo != true {
                let font = NSFont.systemFont(ofSize:11,weight:.semibold)
                let rect = statusCard(width:clamp(ceil((game.notice as NSString).size(withAttributes:[.font:font]).width)+36,118,440),
                                      height:27,game:game,at:game.showHUD ? (game.showMirror ? 216 : 111) : 18)
                panel(rect,radius:6)
                text(game.notice,x:rect.minX+12,y:rect.minY+5,size:11,color:lime,weight:.semibold,width:rect.width-24,align:.center)
            }
            if game.sprint == nil && !game.session.validLap && !game.isPaused {
                text(game.session.status, x: (w - 440) / 2, y: h - 266, size: 13,
                     color: NSColor(rgb: 0xFFD19A), weight: .semibold, width: 440, align: .center)
            }
            if game.serviceRemaining > 0 {
                let rect = statusCard(width:400,height:62,game:game,at:76)
                panel(rect)
                text(String(format: "维修与换胎 · 剩余 %.1f 秒", game.serviceRemaining),
                     x:rect.minX+10,y:rect.minY+9,size:17,weight:.semibold,width:rect.width-20,align:.center)
                text("维修位停车中 · 暂停时计时冻结",x:rect.minX+10,y:rect.minY+37,
                     size:11,color:muted,width:rect.width-20,align:.center)
            }
            if let race = game.sprint, !game.isPaused {
                if race.countdown > 0 || race.showGo {
                    let rect = NSRect(x: (w-188)/2, y: game.showMirror ? 130 : 24, width: 188, height: 70)
                    panel(rect, radius: 9)
                    let waiting = race.countdown > 0
                    text(waiting ? "准备发车" : "绿灯",x:rect.minX+12,y:rect.minY+7,size:11,color:muted,width:164,align:.center)
                    text(waiting ? String(race.countdownSeconds) : "GO",x:rect.minX+12,y:rect.minY+22,size:32,
                         color:NSColor(rgb:waiting ? 0xF26759 : 0x86D786),weight:.bold,mono:true,width:164,align:.center)
                }
                if race.playerFinished || race.entries.first?.runningOffTrack == true {
                    let warning = race.playerFinished ? "已过终点 · Esc 查看结果" : "四轮出界 · 持续 1.5 秒加罚 2 秒"
                    text(warning,x:(w-380)/2,y:h-221,size:13,color:NSColor(rgb:0xFFD19A),weight:.semibold,width:380,align:.center)
                }
            }
        } else {
            drawWelcome(game, width: w, height: h)
        }
    }

    private func statusCard(width requested: CGFloat,height: CGFloat,game: RacingGame,at top: CGFloat) -> CGRect {
        let viewport = bounds.width
        if game.showHUD && !game.compactHUD {
            let minimum: CGFloat = 268, maximum = viewport-296
            let width = min(requested,max(1,maximum-minimum))
            return CGRect(x:(minimum+maximum-width)/2,y:top,width:width,height:height)
        }
        return CGRect(x:(viewport-requested)/2,y:top,width:requested,height:height)
    }

    private func drawFitting(width: CGFloat,height: CGFloat,preferredWidth: CGFloat,preferredHeight: CGFloat,
                             draw: (CGFloat,CGFloat) -> Void) {
        let scale = min(1,width/preferredWidth,height/preferredHeight)
        guard scale < 1 else { draw(width,height); return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.scale(by:scale); transform.concat()
        interactionTransform = AffineTransform(scale:scale)
        draw(width/scale,height/scale)
        interactionTransform = AffineTransform()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSideAlerts(_ game: RacingGame,width: CGFloat,height: CGFloat) {
        let alert = game.sideTraffic
        let amber = NSColor(rgb:0xFFC266)
        for (active,left) in [(alert.left,true),(alert.right,false)] where active {
            let x = left ? max(12,width*0.26-54) : min(width-66,width*0.74)
            let y = height*0.50
            panel(NSRect(x:x,y:y,width:54,height:40),color:NSColor(rgb:0x211D18,alpha:0.94),radius:7)
            text(left ? "‹ 左侧" : "右侧 ›",x:x+4,y:y+10,size:12,color:amber,weight:.bold,width:46,align:.center)
        }
    }

    private func drawSprint(_ race: SprintRace, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:196,height:105))
        let driver = race.entries[0]
        let status = driver.finishTime != nil ? "已完赛" : "第 \(min(driver.laps+1,race.lapCount)) / \(race.lapCount) 圈"
        text("短赛   P\(race.driverPosition) / \(race.entries.count)   \(status)",x:x+12,y:y+6,size:11,color:lime,weight:.semibold,width:172)
        for (place,index) in race.order.enumerated() {
            let entry = race.entries[index]
            let name = index == 0 ? "你" : "电脑 \(index)"
            let time = entry.classifiedTime.map { lapTime($0) } ?? (entry.penalties > 0 ? "+\(entry.penalties*2)s" : "—")
            let row = y + 25 + CGFloat(place) * 16
            text("\(place+1)   \(name)",x:x+12,y:row,size:10,color:index == 0 ? white : muted,mono:true,width:92)
            text(time,x:x+104,y:row,size:10,color:muted,mono:true,width:80,align:.right)
        }
    }

    private func drawVehicleInfo(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        let car = game.vehicle
        panel(NSRect(x:x,y:y,width:238,height:292),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text(car.kind.label,x:x+12,y:y+10,size:14,weight:.semibold,width:214)
        let drive = car.kind.frontDriveShare > 0 ? "四驱" : "后驱"
        text(String(format:"实验预设 · %.0f kg · %@ / 6 挡",car.mass,drive),x:x+12,y:y+34,size:10,color:muted,width:214)
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
        let drivingCue = car.wakeStrength > 0.15 ?
            String(format:"尾流 %.0f%%   前轴下压力 %.0f N",car.wakeStrength*100,car.aeroLoad.x) :
            String(format:"滑移 %.0f%%   复位后 %.2f km",car.tyreSlip*100,car.distanceTravelled/1000)
        text(drivingCue,x:x+12,y:y+225,size:10,color:car.wakeStrength > 0.15 ? lime : muted,width:214)
        button("−",NSRect(x:x+12,y:y+246,width:32,height:23),action:"brakeBiasDown")
        text(String(format:"前轴制动力 %.1f%%",game.assists.frontBrakeBias*100),x:x+49,y:y+249,size:10,mono:true,width:140,align:.center)
        button("+",NSRect(x:x+194,y:y+246,width:32,height:23),action:"brakeBiasUp")
        text("4 / 5 或十字键 ← / → 调节制动力分配",x:x+12,y:y+275,size:8,color:muted,width:214)
    }

    private func drawTrackMap(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:238,height:192),color:NSColor(white:0.035,alpha:0.86),radius:5)
        text(game.circuit.kind.label,x:x+12,y:y+10,size:12,weight:.semibold,width:140)
        text(String(format:"%.2f km",game.circuit.length/1000),x:x+154,y:y+12,size:10,color:muted,mono:true,width:72,align:.right)
        if mapGeometry?.circuit !== game.circuit {
            let circuit = game.circuit
            let points = circuit.samples.map(\.point)
            let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minZ = points.map(\.y).min()!, maxZ = points.map(\.y).max()!
            let scale = min(206/(maxX-minX),120/(maxZ-minZ))
            let project: (SIMD2<Double>) -> CGPoint = {
                CGPoint(x:119+($0.x-(minX+maxX)/2)*scale,y:98-($0.y-(minZ+maxZ)/2)*scale)
            }
            let path = NSBezierPath(); path.move(to:project(points[0]))
            for p in points.dropFirst() { path.line(to:project(p)) }
            path.close(); path.lineJoinStyle = .round; path.lineWidth = 3.2
            let lane = NSBezierPath(); lane.lineWidth = 1.6
            for (i,distance) in stride(from:PitLane.entry,through:PitLane.exit,by:4).enumerated() {
                let sample = circuit.sample(at:distance)
                let point = project(sample.point+sample.right*circuit.pitLane.lateral(at:distance))
                if i == 0 { lane.move(to:point) } else { lane.line(to:point) }
            }
            mapGeometry = (circuit,path,lane,project)
        }
        guard let geometry = mapGeometry else { return }
        NSGraphicsContext.saveGraphicsState()
        let offset = NSAffineTransform(); offset.translateX(by:x,yBy:y); offset.concat()
        NSColor(white:0.58,alpha:0.78).setStroke(); geometry.path.stroke()
        NSColor(rgb:0x73C7D2).setStroke(); geometry.lane.stroke()
        NSGraphicsContext.restoreGraphicsState()
        func project(_ p: SIMD2<Double>) -> CGPoint {
            let scaled = geometry.project(p)
            return CGPoint(x:x+scaled.x,y:y+scaled.y)
        }
        for sector in 1...2 {
            let p = project(game.circuit.sample(at:game.circuit.length*Double(sector)/3).point)
            NSColor(rgb:0x78B8C8).setFill(); NSRect(x:p.x-2.5,y:p.y-2.5,width:5,height:5).fill()
            text("S\(sector)",x:p.x+5,y:p.y-8,size:8,color:white,width:20)
        }
        let start = project(game.circuit.sample(at:0).point)
        white.setFill(); NSRect(x:start.x-3,y:start.y-3,width:6,height:6).fill()
        if game.hasStarted {
            let colors: [UInt32] = [0x5AA4E7, 0xDB943B, 0x83AE7F]
            for (index, opponent) in game.traffic.cars.enumerated() {
                let dot = project(opponent.vehicle.position)
                NSColor(rgb: colors[index]).setFill()
                NSBezierPath(ovalIn: NSRect(x:dot.x-3,y:dot.y-3,width:6,height:6)).fill()
            }
        }
        if game.hasStarted {
            let p = project(game.vehicle.position)
            lime.setFill(); NSBezierPath(ovalIn:NSRect(x:p.x-4,y:p.y-4,width:8,height:8)).fill()
            line(p,CGPoint(x:p.x+CGFloat(sin(game.vehicle.heading))*10,y:p.y-CGFloat(cos(game.vehicle.heading))*10),color:lime,width:2)
        }
        text("起终点  ▪   ·   青线  维修道",x:x+12,y:y+171,size:9,color:muted,width:214)
    }

    private func drawCondition(_ game: RacingGame, x: CGFloat, y: CGFloat) {
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
            func tyreColour(_ temperature: Double) -> NSColor {
                if warning { return NSColor(rgb:0xE77B6D) }
                let target = wheel.setup.compound.optimum
                return temperature > target+22 ? amber : (temperature < target-22 ? blue : green)
            }
            let tone = tyreColour(wheel.temperature)
            panel(NSRect(x:tx,y:ty,width:116,height:74),color:NSColor(white:0.09,alpha:0.9),radius:4)
            let tyre = NSRect(x:tx+8,y:ty+21,width:21,height:39)
            tone.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect:tyre,xRadius:5,yRadius:5).fill()
            tone.setStroke()
            let outline = NSBezierPath(roundedRect:tyre,xRadius:5,yRadius:5)
            outline.lineWidth = 1.4; outline.stroke()
            for stripe in 0..<3 {
                let sx = tyre.minX+3+CGFloat(stripe)*5
                tyreColour(wheel.treadTemperatures[stripe]).withAlphaComponent(0.72).setFill()
                NSRect(x:sx,y:tyre.minY+4,width:4,height:tyre.height-8).fill()
            }
            if wheel.punctured {
                line(CGPoint(x:tyre.minX,y:tyre.minY),CGPoint(x:tyre.maxX,y:tyre.maxY),color:tone,width:2)
            }
            text(entry.0,x:tx+8,y:ty+4,size:9,color:muted,width:30)
            let surface = wheel.surface == .kerb ? "路肩" : (wheel.surface == .grass ? "草地" : "沥青")
            let dirty = wheel.surfaceContamination > 0.18
            let standing = wheel.waterFilm >= 0.85 && wheel.surface == .asphalt
            text(dirty ? "胎面带泥" : (standing ? String(format:"水 %.1f",wheel.waterFilm) : surface),x:tx+57,y:ty+4,size:9,
                 color:dirty || wheel.surface == .kerb ? amber : (standing ? blue : muted),width:51,align:.right)
            let t = wheel.treadTemperatures
            text(String(format:"%.0f  %.0f  %.0f",t.x,t.y,t.z),x:tx+34,y:ty+24,size:10,color:tone,weight:.medium,mono:true,width:77)
            text(String(format:"%.2f bar",wheel.pressure),x:tx+37,y:ty+40,size:10,color:white,mono:true,width:72)
            text(wheel.punctured ? "爆胎" : String(format:"余量 %.0f%%",(1-wheel.wear)*100),x:tx+37,y:ty+56,size:9,color:warning ? tone : muted,width:72)
            // Amber outline remains on actual kerb contact; its strength follows excitation.
            if wheel.surface == .kerb || wheel.kerbFeedback > 0.02 || standing {
                (standing ? blue : amber).withAlphaComponent(CGFloat(standing ? 0.75 : 0.3+wheel.kerbFeedback*0.7)).setStroke()
                let edge = NSBezierPath(roundedRect:NSRect(x:tx,y:ty,width:116,height:74).insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
                edge.lineWidth = 1.5; edge.stroke()
            }
        }
        let legend = game.circuit.condition == .wet ? "内 / 中 / 外胎温 °C · 水膜读数为 mm" : "内 / 中 / 外胎温 °C · 蓝 冷  绿 工作区  橙 热"
        text(legend,x:x+12,y:y+197,size:9,color:muted,width:247)
        text(String(format:"车损 %.0f%%   水温 %.0f°C",car.damage.worst*100,car.coolantTemperature),
             x:x+12,y:y+217,size:10,color:car.damage.worst>0.3 ? amber : muted,width:247)
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
            let travelMM = (wheel.suspensionTravel*1000).rounded()
            text(travelMM == 0 ? "0" : String(format:"%+.0f",travelMM),x:cx-29,y:y+92,size:11,color:tone,mono:true,width:58,align:.center)
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

    private func drawCompactTiming(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:196,height:105),color:NSColor(rgb:0x12161A,alpha:0.84),radius:6)
        text("圈时",x:x+11,y:y+8,size:10,color:muted,weight:.semibold,width:42)
        text(String(format:"第 %02d 圈",game.session.lap),x:x+93,y:y+8,size:10,color:white,mono:true,width:92,align:.right)
        line(CGPoint(x:x+11,y:y+26),CGPoint(x:x+185,y:y+26),color:white.withAlphaComponent(0.12))
        let rows = [("当前",lapTime(game.session.elapsed)),("上圈",lapTime(game.session.last)),("最佳",lapTime(game.session.best))]
        for (i,item) in rows.enumerated() {
            let row = y+32+CGFloat(i)*22
            let invalid = (i==0 && !game.session.validLap) || (i==1 && game.session.last != nil && !game.session.lastValid)
            text(item.0,x:x+11,y:row+1,size:10,color:muted,width:42)
            text(item.1,x:x+56,y:row,size:13,color:invalid ? NSColor(rgb:0xE69B69) : white,mono:true,width:129,align:.right)
        }
    }

    private func drawLapDelta(_ game:RacingGame,x:CGFloat,y:CGFloat) {
        let session = game.session
        let green = NSColor(rgb:0x89C98A), red = NSColor(rgb:0xEA8079)
        panel(NSRect(x:x,y:y,width:340,height:84),color:NSColor(rgb:0x12161A,alpha:0.84),radius:6)
        let delta = session.delta
        text("圈速差",x:x+12,y:y+8,size:9,color:muted,width:100)
        text(delta.map {String(format:"%+.3f",$0)} ?? "—.——",x:x+12,y:y+19,size:21,
             color:delta.map {$0<=0 ? green : red} ?? muted,weight:.semibold,mono:true,width:135)
        text(session.status,x:x+134,y:y+12,size:10,color:session.validLap ? white : red,width:194,align:.right)
        let previous = session.sectors.isEmpty && session.last != nil
        let values = previous ? session.lastSectors : session.sectors
        text(previous ? "上圈分段" : "本圈分段",x:x+134,y:y+29,size:9,color:muted,width:194,align:.right)
        line(CGPoint(x:x+12,y:y+49),CGPoint(x:x+328,y:y+49),color:white.withAlphaComponent(0.12))
        for i in 0..<3 {
            let sx = x+12+CGFloat(i)*108
            let value = i<values.count ? values[i] : nil
            let valid = previous ? session.lastValid : session.validLap
            let reference = i<session.bestSectors.count ? session.bestSectors[i] : nil
            let personalBest = value.map { time in reference.map { time <= $0+0.001 } ?? false } ?? false
            let color: NSColor = !valid ? red : (personalBest ? green : white)
            text("S\(i+1)",x:sx,y:y+59,size:10,color:muted,width:22)
            text(value.map {String(format:"%.3f",$0)} ?? "—.——",x:sx+22,y:y+57,size:12,color:color,mono:true,width:77,align:.right)
        }
    }

    private func drawPedals(_ game: RacingGame, x: CGFloat, y: CGFloat) {
        if game.autoDriveEnabled {
            let top = y - (game.racingLineEnabled || game.inPitLane ? 62 : 31)
            panel(NSRect(x:x,y:top,width:282,height:24),color:NSColor(rgb:0x162C33,alpha:0.92),radius:4)
            text("自动驾驶 · 操作油门、刹车或转向接管",x:x+10,y:top+4,size:10,color:NSColor(rgb:0x9EE7F2),width:262)
        }
        if game.inPitLane {
            let box = game.circuit.pitLane.inServiceBox(game.location)
            panel(NSRect(x:x,y:y-34,width:414,height:27),color:NSColor(rgb:0x162C33,alpha:0.94),radius:3)
            let status: String
            if game.serviceRemaining > 0 { status = "维修进行中" }
            else if game.pitOverspeed { status = "维修道超速 · 请减速" }
            else if box && game.sprint == nil { status = "黄框内停车后按 P 维修" }
            else if game.inPitSpeedZone { status = "维修道 · 限速 60 km/h" }
            else { status = game.pitApproachLabel ?? "驶出限速区 · 注意并线" }
            text(status,x:x+10,y:y-28,size:10,color:game.pitOverspeed ? NSColor(rgb:0xFF8669) : white,width:233)
            button("限速 \(game.pitLimiterEnabled ? "开" : "关")  [ K ]",NSRect(x:x+258,y:y-33,width:148,height:25),action:"pitLimiter",active:game.pitLimiterEnabled)
        } else if game.racingLineEnabled {
            panel(NSRect(x:x,y:y-34,width:414,height:27),color:NSColor(white:0.03,alpha:0.8),radius:3)
            text("绿 加速 · 黄 收油 · 红 制动",x:x+10,y:y-28,size:10,color:muted,width:245)
            let target=game.world.racingLine.sample(at:game.location.progress).targetSpeed*3.6
            text(String(format:"参考 %.0f km/h",target),x:x+259,y:y-28,size:10,color:muted,mono:true,width:145,align:.right)
        }
        let green = NSColor(rgb:0x85C86A), red = NSColor(rgb:0xE96162), yellow = NSColor(rgb:0xF3CF61)
        let rect = NSRect(x:x,y:y,width:414,height:82)
        panel(rect,color:NSColor(rgb:0x171A1E,alpha:0.94),radius:8)
        let plot = NSRect(x:x+7,y:y+10,width:185,height:62)
        NSColor(rgb:0x24282D).setFill()
        NSBezierPath(roundedRect:plot,xRadius:3,yRadius:3).fill()
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
        let orange = NSColor(rgb:0xE7AD74)
        trace(color:orange,value:{$0.linePressure},enabled:{_ in true})
        trace(color:yellow,value:{$0.linePressure},enabled:{$0.absActive && $0.linePressure>0.01})
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
        text(game.vehicle.gearLabel,x:x+241,y:y+14,size:40,color:lime,weight:.bold,mono:true,width:38,align:.center)
        text(String(format:"%.0f",game.vehicle.speedKPH),x:x+273,y:y+13,size:24,weight:.bold,mono:true,width:57,align:.center)
        text("km/h",x:x+278,y:y+44,size:10,color:muted,weight:.semibold,width:48,align:.center)
        let pressure = game.vehicle.brakeLinePressure
        if pressure > 0.005 {
            let brakeLabel = String(format:"制动压力 %.0f%%",pressure*100)
            text(brakeLabel,x:x+329,y:y+72,size:8,color:game.vehicle.absActive ? yellow : red,mono:true,width:77,align:.center)
        }

        for lamp in 0..<8 {
            let shift = game.vehicle.kind.upshiftRPM
            let active=game.vehicle.rpm>=3500+Double(lamp)*(shift-3500)/7
            let color=lamp<4 ? green : (lamp<6 ? yellow : red)
            (active ? color : NSColor(white:0.15,alpha:1)).setFill()
            NSRect(x:x+242+CGFloat(lamp)*11,y:y+68,width:8,height:4).fill()
        }

        // The wheel follows the same steering rack angle as the car animation.
        let angle=CGFloat(clamp(-game.vehicle.steeringAngle*9,-2.45,2.45))
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

    private func menuScrim(_ opacity: CGFloat = 0.58) {
        NSColor.black.withAlphaComponent(opacity).setFill()
        bounds.fill()
    }

    private func screenHeader(_ title: String, subtitle: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        text(title,x:x+28,y:y+20,size:29,weight:.bold,width:width-56)
        text(subtitle,x:x+29,y:y+64,size:12,color:muted,width:width-58)
        line(CGPoint(x:x+28,y:y+93),CGPoint(x:x+width-28,y:y+93),color:white.withAlphaComponent(0.13))
    }

    private func drawHeader(_ game: RacingGame, width: CGFloat) {
        let header = NSRect(x:0,y:0,width:width,height:78)
        panel(header,color:NSColor(rgb:0x111722,alpha:0.97),radius:0)
        lime.setFill()
        NSRect(x:28,y:21,width:5,height:36).fill()
        text("APEX LAB",x:48,y:16,size:26,weight:.black,width:235)
        text("驾驶实验室  /  3.0 预览",x:49,y:50,size:10,color:muted,width:200)
        let status = game.input.controllerName ?? "键盘可用  ·  手柄未连接"
        text(status,x:width-532,y:31,size:12,color:game.input.controller == nil ? muted : lime,width:224,align:.right)
        button("驾驶指南",NSRect(x:width-288,y:21,width:112,height:37),action:"help")
        button("设置  ⌘,",NSRect(x:width-164,y:21,width:136,height:37),action:"settings")
    }

    private func drawWelcome(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        let x: CGFloat = 28, w: CGFloat = 446, y = max(96,(height-461)/2+30)
        panel(NSRect(x:x,y:y,width:w,height:461),color:NSColor(rgb:0x141B28,alpha:0.96),radius:14)
        screenHeader("开始驾驶",subtitle:"选择车辆与赛道，再决定练习或参加两圈短赛。",x:x,y:y,width:w)

        func choice(_ title: String, value: String, at offset: CGFloat, action: String) {
            text(title,x:x+28,y:y+offset+10,size:12,color:muted,width:80)
            button(value+"   ›",NSRect(x:x+113,y:y+offset,width:305,height:36),action:action,accessibility:"选择"+title+"，当前 "+value)
        }
        choice("车辆",value:game.vehicle.kind.label,at:113,action:"selectVehicle")
        choice("赛道",value:game.circuit.kind.label,at:158,action:"selectCircuit")
        button("路况 · "+game.circuit.condition.label,NSRect(x:x+28,y:y+210,width:187,height:38),action:"trackCondition")
        button("电脑对手 · \(game.opponentCount)",NSRect(x:x+231,y:y+210,width:187,height:38),action:"opponents")
        text(game.circuit.kind.detail,x:x+29,y:y+261,size:11,color:muted,width:388)
        text(game.input.controller == nil ? "WASD 驾驶  ·  Esc 暂停" : "RT 油门  ·  LT 制动  ·  Menu 暂停",
             x:x+29,y:y+291,size:12,color:muted,width:388)
        button("进入练习  ↵",NSRect(x:x+28,y:y+329,width:222,height:49),action:"start",primary:true)
        button("两圈短赛",NSRect(x:x+262,y:y+329,width:156,height:49),action:"startSprint")
        button("练习分析",NSRect(x:x+28,y:y+395,width:132,height:37),action:"analysis")
        text("方向键 / 十字键选择 · A / 回车确认",x:x+174,y:y+405,size:10,color:muted,width:244,align:.right)
        drawTrackMap(game,x:width-266,y:112)
    }

    private func drawGarage(_ game: RacingGame, selection: GarageSelection, width: CGFloat, height: CGFloat) {
        menuScrim(0.66)
        let vehicles = selection == .vehicles
        let rows = ((vehicles ? VehicleKind.allCases.count : CircuitKind.allCases.count)+1)/2
        let rowHeight = min(100,max(68,(height-219)/CGFloat(rows)))
        let panelHeight = 190+CGFloat(rows)*rowHeight
        let x = (width-762)/2, y = max(16,(height-panelHeight)/2)
        panel(NSRect(x:x,y:y,width:762,height:panelHeight),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader(vehicles ? "选择车辆" : "选择赛道",
                     subtitle:vehicles ? "选择后会恢复该车的调校和个人最佳。" : "选一条赛道。干地与湿地分别保留圈速。",
                     x:x,y:y,width:762)
        let entries: [(String,String,String,Bool)] = vehicles
            ? VehicleKind.allCases.map { car in
                (car.label,String(format:"%@  ·  %.0f kg",car.frontDriveShare > 0 ? "四轮驱动" : "后轮驱动",car.mass),
                 "car:"+String(car.rawValue),car == game.vehicle.kind)
            }
            : CircuitKind.allCases.map { track in
                (track.label,track.detail,"circuit:"+String(track.rawValue),track == game.circuit.kind)
            }
        for (i, entry) in entries.enumerated() {
            let offsetX = x+28+CGFloat(i%2)*358, offsetY = y+116+CGFloat(i/2)*rowHeight
            panel(NSRect(x:offsetX,y:offsetY,width:348,height:rowHeight-13),color:NSColor(rgb:0x1D2838),radius:8)
            button(entry.0+(entry.3 ? "  ✓" : ""),NSRect(x:offsetX+10,y:offsetY+9,width:328,height:37),action:entry.2,active:entry.3)
            text(entry.1,x:offsetX+16,y:offsetY+55,size:11,color:muted,width:316,align:.center)
        }
        button("返回",NSRect(x:x+560,y:y+panelHeight-62,width:174,height:40),action:"closeGarage")
    }

    private func drawPause(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        menuScrim()
        let x = (width-560)/2
        if let race = game.sprint {
            drawSprintPause(game,race:race,x:(width-550)/2,y:max(18,(height-456)/2))
            return
        }
        let y = max(18,(height-438)/2)
        panel(NSRect(x:x,y:y,width:560,height:438),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader("练习已暂停",subtitle:game.vehicle.kind.label+"  /  "+game.circuit.kind.label+"  ·  "+game.circuit.condition.label,x:x,y:y,width:560)
        button("继续驾驶  ↵",NSRect(x:x+28,y:y+114,width:504,height:47),action:"resume",primary:true)
        for (i, row) in [("设置","settings"),("练习分析","analysis"),("驾驶指南","help"),("重新开始练习","askRestart"),
                         ("返回开始界面","askLeavePractice"),("维修与拖车","pitMenu")].enumerated() {
            button(row.0,NSRect(x:x+28+CGFloat(i%2)*258,y:y+181+CGFloat(i/2)*52,width:246,height:39),action:row.1)
        }
        let message = game.serviceRemaining > 0 ? "正在维修 · 继续后完成" : "返回后可换车、换赛道或开始短赛。"
        text(message,x:x+29,y:y+349,size:12,color:muted,width:504)
        text("Esc / B 返回  ·  方向键 / 十字键选择",x:x+29,y:y+394,size:11,color:muted,width:504)
    }

    private func drawHelp(width: CGFloat, height: CGFloat) {
        menuScrim(0.7)
        let x = (width-650)/2, y = max(16,(height-498)/2)
        panel(NSRect(x:x,y:y,width:650,height:498),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader("驾驶指南",subtitle:"练习时可以随时打开设置调整手感。",x:x,y:y,width:650)
        let rows = [("油门 / 制动","W / S 或 ↑ / ↓","RT / LT"),("转向","A / D 或 ← / →","左摇杆"),
                    ("升挡 / 降挡","E / Q","RB / LB"),("切换视角","Tab","Y"),
                    ("复位车辆","驾驶中按 R","驾驶中长按 A"),("暂停","Esc","Menu"),
                    ("菜单选择 / 确认","方向键 / 回车","十字键 / A")]
        text("操作",x:x+29,y:y+112,size:11,color:muted)
        text("键盘",x:x+243,y:y+112,size:11,color:lime)
        text("Xbox",x:x+443,y:y+112,size:11,color:lime)
        for (index,row) in rows.enumerated() {
            let ry = y+139+CGFloat(index)*36
            line(CGPoint(x:x+28,y:ry-3),CGPoint(x:x+622,y:ry-3),color:white.withAlphaComponent(0.10))
            text(row.0,x:x+29,y:ry+5,size:12,width:192)
            text(row.1,x:x+243,y:ry+5,size:12,color:muted,width:180)
            text(row.2,x:x+443,y:ry+5,size:12,color:muted,width:175)
        }
        button("返回",NSRect(x:x+455,y:y+423,width:167,height:44),action:"help",primary:true)
    }

    private func drawSessionPrompt(_ game: RacingGame, prompt: SessionPrompt, width: CGFloat, height: CGFloat) {
        menuScrim(0.73)
        let x = (width-550)/2, y = max(14,(height-274)/2)
        panel(NSRect(x:x,y:y,width:550,height:274),color:NSColor(rgb:0x141B28),radius:16)
        switch prompt {
        case .restart, .leave:
            let restart = prompt == .restart
            screenHeader(restart ? "重新开始？" : "返回开始界面？",subtitle:game.vehicle.kind.label+"  /  "+game.circuit.kind.label,x:x,y:y,width:550)
            text("当前驾驶进度会结束，已完成的个人最佳与设置会保留。",x:x+28,y:y+116,size:13,width:494)
            button("取消",NSRect(x:x+28,y:y+197,width:241,height:43),action:"cancelPrompt",primary:true)
            button(restart ? "重新开始" : "返回开始界面",NSRect(x:x+281,y:y+197,width:241,height:43),action:"confirmPrompt")
        case .pit:
            screenHeader("维修与拖车",subtitle:"进站限速 60 km/h。维修与换胎需要 12 秒。",x:x,y:y,width:550)
            let ready = game.serviceRemaining == 0 && game.circuit.pitLane.inServiceBox(game.location) && game.vehicle.speed < 0.55
            text(game.serviceRemaining > 0 ? "维修正在进行 · 返回后继续驾驶即可恢复计时" :
                    (ready ? "已在维修位停稳，可以开始服务。" : "进入维修道并在黄框里停稳，或用拖车返回维修位。"),
                 x:x+28,y:y+122,size:13,width:494)
            button("返回",NSRect(x:x+28,y:y+197,width:135,height:43),action:"cancelPrompt",primary:true)
            if ready { button("开始维修",NSRect(x:x+175,y:y+197,width:160,height:43),action:"service") }
            if game.serviceRemaining == 0 { button("拖车回站",NSRect(x:x+347,y:y+197,width:175,height:43),action:"tow") }
        }
    }

    private func drawSettings(_ game: RacingGame, page: SettingsPage, width: CGFloat, height: CGFloat) {
        menuScrim(0.74)
        let x = (width-802)/2, y = max(12,(height-582)/2)
        panel(NSRect(x:x,y:y,width:802,height:582),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader("设置",subtitle:"当前车型  "+game.vehicle.kind.label,x:x,y:y,width:802)
        text("更改自动保存",x:x+525,y:y+64,size:11,color:muted,width:249,align:.right)
        for (i, tab) in SettingsPage.allCases.enumerated() {
            button(tab.title,NSRect(x:x+28+CGFloat(i)*111,y:y+111,width:102,height:38),
                   action:"settings:"+tab.rawValue,active:tab == page)
        }
        button("返回  Esc / B",NSRect(x:x+625,y:y+111,width:149,height:38),action:"settings")
        let rowX = x+28, controlX = x+552
        func setting(_ row: Int, title: String, detail: String, value: String, action: String? = nil,
                     stepper: (String,String)? = nil) {
            let by = y+170+CGFloat(row)*53
            panel(NSRect(x:rowX,y:by,width:746,height:48),color:NSColor(rgb:0x1A2331),radius:6)
            text(title,x:rowX+12,y:by+5,size:13,weight:.semibold,width:430)
            text(detail,x:rowX+12,y:by+25,size:10,color:muted,width:493)
            if let stepper {
                button("−",NSRect(x:controlX,y:by+7,width:38,height:34),action:stepper.0,accessibility:title+" 减少")
                text(value,x:controlX+47,y:by+14,size:12,mono:true,width:128,align:.center)
                button("+",NSRect(x:controlX+183,y:by+7,width:38,height:34),action:stepper.1,accessibility:title+" 增加")
            } else if let action {
                button(value,NSRect(x:controlX,y:by+7,width:221,height:34),action:action,accessibility:title+"："+value)
            } else {
                text(value,x:controlX+4,y:by+13,size:12,color:muted,width:212,align:.right)
            }
        }
        func toggle(_ enabled: Bool) -> String { enabled ? "开启" : "关闭" }
        func assist(_ level: Int) -> String { level == 0 ? "关闭" : "\(level) / 5" }
        switch page {
        case .driving:
            setting(0,title:"变速箱",detail:"自动升降挡，或用 E / Q、RB / LB 手动换挡",value:game.assists.automatic ? "自动挡" : "手动挡",action:"automatic")
            setting(1,title:"防抱死 ABS",detail:"等级越高，系统越早降低锁止车轮的制动压力",value:assist(game.assists.absLevel),action:"abs")
            setting(2,title:"牵引力控制 TCS",detail:"等级越高，系统越早限制打滑车轮的驱动扭矩",value:assist(game.assists.tcLevel),action:"tc")
            setting(3,title:"前轴制动力",detail:"向前增加制动力分配，整车制动压力不变",value:String(format:"%.1f%%",game.assists.frontBrakeBias*100),stepper:("brakeBiasDown","brakeBiasUp"))
            let fitted = game.vehicle.wheels[0].setup
            let fittedSummary = String(format:"已装 %@ · %.2f bar 冷压",fitted.compound.label,fitted.coldPressure)
            let tyreState = game.hasPendingTyres ? "待安装" : "下次轮胎"
            setting(4,title:tyreState,detail:game.canPlanTyres ? fittedSummary+" · 重开或换胎生效" : fittedSummary+" · 本场暂不可改",
                    value:game.tyreSetup.compound.label+(game.canPlanTyres ? "  ›" : ""),action:game.canPlanTyres ? "choice:tyres" : nil)
            setting(5,title:"下次轮胎冷压",detail:"当前方案范围 1.30–2.10 bar",value:String(format:"%.2f bar",game.tyreSetup.coldPressure),
                    stepper:game.canPlanTyres ? ("pressureDown","pressureUp") : nil)
            setting(6,title:"维修道限速",detail:"行驶到限速区时，限制油门与车速",value:toggle(game.pitLimiterEnabled),action:"pitLimiter")
        case .controller:
            setting(0,title:"手柄状态",detail:game.input.hapticStatus,value:game.input.controllerName ?? "未连接")
            setting(1,title:"摇杆死区",detail:"忽略回中时的轻微漂移",value:String(format:"%.0f%%",100*game.assists.steeringDeadzone),stepper:("deadzoneDown","deadzoneUp"))
            setting(2,title:"转向响应",detail:"细腻档降低小幅转向，保留打满时的幅度",value:game.assists.steeringCurve.label+"  ›",action:"choice:steering")
            setting(3,title:"制动响应",detail:"长行程档给轻刹更多余量 · 按车型保存",value:game.assists.brakeCurve.label+"  ›",action:"choice:braking")
            setting(4,title:"震动强度",detail:"调整路肩、轮胎滑移与 ABS 的手柄反馈",value:"\(game.input.hapticLevel*25)%",action:"hapticLevel")
            setting(5,title:"校准与震动测试",detail:"查看原始输入及处理后的转向，播放四段震动",value:"打开校准",action:"controllerReview")
            setting(6,title:"恢复手柄默认值",detail:"恢复全局死区、震动，以及当前车型的制动和转向曲线",value:"恢复默认",action:"resetControllerSettings")
        case .display:
            setting(0,title:"画质档位",detail:"调整抗锯齿、阴影和环境光影",value:game.graphicsQuality.title+"  ›",action:"choice:antialiasing")
            setting(1,title:"渲染帧率目标",detail:"仅调整画面绘制目标，物理和输入更新独立运行",value:game.renderingRate.title,action:"renderingRate")
            setting(2,title:"驾驶视角",detail:"驾驶时可用 Tab / Y 切换",value:game.drivingView.label+"  ›",action:"choice:camera")
            setting(3,title:"座舱预览",detail:String(format:"垂直视野 %.0f°  ·  当前座高 %.2f m",game.world.cockpitFOV,game.world.seatHeight),
                    value:"预览并调整",action:"seatPreview")
            setting(4,title:"仪表布局",detail:"精简保留核心信息，完整显示轮胎和悬挂等数据",value:game.compactHUD ? "精简" : "完整",action:"compactHUD")
            setting(5,title:"恢复画面默认值",detail:"恢复画质、帧率目标、镜头和座高",value:"恢复默认",action:"resetDisplaySettings")
        case .audio:
            setting(0,title:"游戏声音",detail:"发动机、轮胎、来车与比赛提示音",value:game.sound.muted ? "静音" : "开启",action:"mute")
            func level(_ volume: Double) -> String { String(format:"%.0f%%",volume*100) }
            setting(1,title:"总音量",detail:"同时调整所有声音，0% 为静音",value:level(game.sound.masterVolume),stepper:("masterDown","masterUp"))
            setting(2,title:"引擎音量",detail:"调整自己的发动机声和电脑车辆来车声",value:level(game.sound.motorVolume),stepper:("motorDown","motorUp"))
            setting(3,title:"效果音量",detail:"调整轮胎、路肩、水花和发车提示音",value:level(game.sound.effectsVolume),stepper:("effectsDown","effectsUp"))
            setting(4,title:"恢复声音默认值",detail:"总音量、引擎和效果音恢复 100%，并取消静音",value:"恢复默认",action:"resetAudioSettings")
        case .aids:
            setting(0,title:"后视镜",detail:"控制车身镜面反射和虚拟后视镜",value:toggle(game.mirrorEnabled),action:"mirror")
            setting(1,title:"理想线路",detail:"绿色建议加速，黄色收油，红色制动",value:toggle(game.racingLineEnabled),action:"racingLine")
            setting(2,title:"个人最佳幽灵车",detail:"练习时显示此车、此赛道和当前路况的最佳圈",value:toggle(game.ghostEnabled),action:"ghost")
            setting(3,title:"自动驾驶",detail:"在赛道面向前方时可启用，操作油门、刹车或转向接管",value:toggle(game.autoDriveEnabled),action:"autoDrive")
            setting(4,title:"仪表显示",detail:"按 V 可随时显示或隐藏驾驶仪表",value:toggle(game.showHUD),action:"hud")
            setting(5,title:"调整面板位置",detail:"进入练习后可拖动面板位置",value:game.hasStarted ? "编辑布局" : "进入练习后可用",action:game.hasStarted ? "hudLayout" : nil)
        }
        if let error = game.settingsStatus {
            text(error,x:x+28,y:y+551,size:11,color:NSColor(rgb:0xFF9C7D),width:746)
        } else if game.noticeRemaining > 0 {
            text(game.notice,x:x+28,y:y+551,size:11,color:lime,width:746)
        } else {
            text("方向键 / 十字键选择   ·   回车 / A 更改",x:x+28,y:y+551,size:10,color:muted,width:746)
        }
    }

    private func drawSettingsChoice(_ game: RacingGame,choice: SettingsChoice,width: CGFloat,height: CGFloat) {
        menuScrim(0.74)
        let options = choice.options
        let panelHeight = CGFloat(197 + options.count*53 + (choice.showsResponseGraph ? 183 : 0))
        let x = (width-652)/2, y = (height-panelHeight)/2
        let live = game.currentSettingsChoice(choice)
        panel(NSRect(x:x,y:y,width:652,height:panelHeight),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader(choice.title,subtitle:choice.detail,x:x,y:y,width:652)
        for (i,option) in options.enumerated() {
            let row = y+113+CGFloat(i)*53
            panel(NSRect(x:x+28,y:row,width:596,height:45),color:NSColor(rgb:0x1A2331),radius:6)
            text(option.detail,x:x+41,y:row+14,size:12,color:muted,width:318)
            button(option.title+(i == live ? "  ✓" : ""),NSRect(x:x+379,y:row+5,width:233,height:35),
                   action:"setChoice:"+String(i),active:i == live,accessibility:option.title+"，"+option.detail+(i == live ? "，当前值" : ""))
        }
        if choice.showsResponseGraph {
            let graph = NSRect(x:x+28,y:y+276,width:596,height:173)
            drawResponseGraph(choice,index:live,frame:graph)
        }
        button("返回  Esc / B",NSRect(x:x+455,y:y+panelHeight-61,width:169,height:38),action:"closeChoice")
    }

    private func drawResponseGraph(_ choice: SettingsChoice,index active: Int,frame: CGRect) {
        let brake = choice == .braking
        let columns = [NSColor(rgb:0x80CFFF),NSColor(rgb:0xD9F885),NSColor(rgb:0xFDA66A)]
        panel(frame,color:NSColor(rgb:0x101723),radius:8)
        text(brake ? "目标制动压力" : "转向输入",x:frame.minX+13,y:frame.minY+10,size:10,color:muted,width:240)
        let plot = CGRect(x:frame.minX+50,y:frame.minY+32,width:305,height:105)
        for tick in 0...4 {
            let fraction = CGFloat(tick)/4
            let x = plot.minX+plot.width*fraction, y = plot.maxY-plot.height*fraction
            let rule = muted.withAlphaComponent(tick == 0 ? 0.5 : (tick == 2 ? 0.28 : 0.14))
            line(CGPoint(x:x,y:plot.minY),CGPoint(x:x,y:plot.maxY),color:rule)
            line(CGPoint(x:plot.minX,y:y),CGPoint(x:plot.maxX,y:y),color:rule)
            if tick%2 == 0 {
                text("\(tick*25)%",x:plot.minX-41,y:y-7,size:9,color:muted,mono:true,width:34,align:.right)
                text("\(tick*25)%",x:x-20,y:plot.maxY+6,size:9,color:muted,mono:true,width:40,align:.center)
            }
        }
        for i in choice.options.indices.sorted(by:{ ($0 == active ? 100 : $0) < ($1 == active ? 100 : $1) }) {
            let color = columns[i]
            let path = NSBezierPath()
            path.lineWidth = i == active ? 2.7 : 1.5
            for segment in 0...48 {
                let f = Double(segment)/48
                let point = CGPoint(x:plot.minX+plot.width*f,y:plot.maxY-plot.height*choice.response(at:f,index:i))
                if segment == 0 { path.move(to:point) } else { path.line(to:point) }
            }
            color.withAlphaComponent(i == active ? 1 : 0.72).setStroke()
            path.stroke()
        }
        text(brake ? "扳机行程 50% 时" : "推杆至 50% 时",x:frame.minX+392,y:frame.minY+25,size:11,color:muted,width:172)
        for (i,option) in choice.options.enumerated() {
            let row = frame.minY+50+CGFloat(i)*29
            let response = Int((choice.response(at:0.5,index:i)*100).rounded())
            columns[i].setFill(); NSRect(x:frame.minX+392,y:row+7,width:15,height:3).fill()
            text(option.title+(i == active ? "  ✓" : ""),x:frame.minX+418,y:row,size:11,
                 color:i == active ? white : muted,width:100)
            text("\(response)%",x:frame.maxX-79,y:row,size:11,color:columns[i],mono:true,width:53,align:.right)
        }
        text(brake ? "扳机行程" : "死区后的推杆量",x:plot.minX+92,y:plot.maxY+19,size:9,color:muted,width:121,align:.center)
    }

    private func drawSeatPreview(_ game: RacingGame,width: CGFloat,height: CGFloat) {
        let x = (width-802)/2, y = height-137
        panel(NSRect(x:x,y:17,width:360,height:56),color:NSColor(rgb:0x141B28,alpha:0.93),radius:10)
        text("座舱预览",x:x+15,y:23,size:16,weight:.bold,width:310)
        text(game.vehicle.kind.label+"  ·  驾驶已暂停",x:x+15,y:47,size:10,color:muted,width:322)
        panel(NSRect(x:x,y:y,width:802,height:120),color:NSColor(rgb:0x141B28,alpha:0.97),radius:13)
        func stepper(_ title: String,_ value: String,_ offset: CGFloat,_ down: String,_ up: String) {
            let left = x+offset
            text(title,x:left,y:y+16,size:11,color:muted,width:216)
            button("−",NSRect(x:left,y:y+37,width:42,height:42),action:down,accessibility:title+" 减少")
            text(value,x:left+48,y:y+46,size:17,weight:.semibold,mono:true,width:120,align:.center)
            button("+",NSRect(x:left+174,y:y+37,width:42,height:42),action:up,accessibility:title+" 增加")
        }
        stepper("垂直视野",String(format:"%.0f°",game.world.cockpitFOV),24,"fovDown","fovUp")
        stepper("座椅高度",String(format:"%.2f m",game.world.seatHeight),271,"seatDown","seatUp")
        button("完成  Esc / B",NSRect(x:x+551,y:y+37,width:227,height:42),action:"seatPreview",primary:true)
        text(game.settingsStatus ?? "更改自动保存 · 原驾驶视角保持不变",x:x+24,y:y+92,size:10,
             color:game.settingsStatus == nil ? muted : NSColor(rgb:0xFF9C7D),width:754)
    }

    private func drawSettingsReset(_ reset: SettingsReset,width: CGFloat,height: CGFloat) {
        menuScrim(0.74)
        let name = reset == .audio ? "声音" : (reset == .controller ? "手柄" : "画面")
        let x = (width-538)/2, y = max(12,(height-252)/2)
        panel(NSRect(x:x,y:y,width:538,height:252),color:NSColor(rgb:0x141B28),radius:16)
        screenHeader("恢复"+name+"默认值？",subtitle:"只会重置此类别，圈速和其他调校会保留。",x:x,y:y,width:538)
        text("恢复后会自动保存。",x:x+28,y:y+121,size:13,color:muted,width:482)
        button("取消",NSRect(x:x+28,y:y+181,width:231,height:43),action:"cancelSettingsReset",primary:true)
        button("恢复默认",NSRect(x:x+271,y:y+181,width:239,height:43),action:"confirmSettingsReset")
    }

    private func drawSprintPause(_ game: RacingGame, race: SprintRace, x: CGFloat, y: CGFloat) {
        panel(NSRect(x:x,y:y,width:550,height:456),color:NSColor(rgb:0x191B1D,alpha:0.99),radius:16)
        text(race.finished ? "短赛结果" : (race.playerFinished ? "暂定结果" : "短赛已暂停"),x:x+28,y:y+24,size:27,weight:.bold)
        text("\(game.circuit.kind.label) · \(game.circuit.condition.label) · \(game.vehicle.kind.label)",
             x:x+28,y:y+71,size:13,color:muted,width:494)
        text("名次 / 车手",x:x+28,y:y+112,size:12,color:muted)
        text("圈数",x:x+245,y:y+112,size:12,color:muted,width:63,align:.center)
        text("罚时",x:x+319,y:y+112,size:12,color:muted,width:63,align:.center)
        text("总时间",x:x+400,y:y+112,size:12,color:muted,width:122,align:.right)
        for (place,index) in race.order.enumerated() {
            let entry = race.entries[index], row = y+143+CGFloat(place)*38
            let name = index == 0 ? "你" : "电脑 \(index)"
            panel(NSRect(x:x+28,y:row-3,width:494,height:33),
                  color:NSColor(rgb:index == 0 ? 0x374249 : 0x242729),radius:5)
            text("\(place+1)     \(name)",x:x+40,y:row+4,size:13,weight:.semibold,width:190)
            text("\(entry.laps) / \(race.lapCount)",x:x+245,y:row+4,size:12,mono:true,width:63,align:.center)
            text(entry.penalties > 0 ? "+\(entry.penalties*2)s" : "—",x:x+319,y:row+4,size:12,mono:true,width:63,align:.center)
            let status = race.countdown > 0 ? "等待发车" : "行驶中"
            text(entry.classifiedTime.map { lapTime($0) } ?? status,x:x+400,y:row+4,size:12,mono:true,width:110,align:.right)
        }
        text(race.assisted ? "本场使用过自动驾驶" : "四轮持续出界或维修道超速，均加罚 2 秒。",
             x:x+28,y:y+311,size:11,color:muted,width:494)
        button(game.drivingView.label+"  ›",NSRect(x:x+28,y:y+342,width:156,height:28),action:"camera")
        button(game.autoDriveEnabled ? "自动驾驶 开 [ U ]" : "自动驾驶 关 [ U ]",
               NSRect(x:x+194,y:y+342,width:158,height:28),action:"autoDrive",active:game.autoDriveEnabled)
        button("设置",NSRect(x:x+363,y:y+342,width:159,height:28),action:"settings")
        button("返回开始界面",NSRect(x:x+28,y:y+391,width:151,height:39),action:"askLeavePractice")
        button("重新发车",NSRect(x:x+192,y:y+391,width:148,height:39),action:"askRestart")
        button("继续驾驶",NSRect(x:x+353,y:y+391,width:169,height:39),action:"resume",primary:true)
    }

    private func drawControllerReview(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        NSColor.black.withAlphaComponent(0.64).setFill()
        bounds.fill()
        let x = (width-640)/2, y = max(18,(height-620)/2)
        let samples = game.input.samples
        let connected = game.input.controllerName
        panel(NSRect(x:x,y:y,width:640,height:620),color:NSColor(rgb:0x191B1D),radius:16)
        text("手柄校准",x:x+28,y:y+22,size:28,weight:.bold)
        text(connected ?? "尚未连接手柄 · 连接后会自动显示读数",x:x+28,y:y+68,size:13,color:connected == nil ? muted : lime,width:575)
        button("返回 [ Esc ]",NSRect(x:x+473,y:y+29,width:139,height:33),action:"controllerReview")
        let raw = samples.reading?.raw ?? DrivingInput()
        let mapped = samples.reading?.mappedSteering ?? 0
        let green = NSColor(rgb:0x78C9A2), red = NSColor(rgb:0xE57E72), cyan = NSColor(rgb:0x84B9D8)
        let curve = game.assists.steeringCurve
        let rows = [("左摇杆 · 原始", raw.steering, true, cyan),("转向 · 曲线后", curve.response(mapped), true, green),
                    ("LT · 刹车行程", raw.brake, false, red),("RT · 油门行程", raw.throttle, false, green)]
        for (i,row) in rows.enumerated() {
            let top = y+112+CGFloat(i)*38
            text(row.0,x:x+28,y:top,size:12,width:132)
            text(connected == nil ? "—" : String(format:"%+.3f",row.1),x:x+540,y:top,size:13,mono:true,width:72,align:.right)
            let bar = NSRect(x:x+162,y:top+3,width:358,height:12)
            panel(bar,color:NSColor(rgb:0x2C3033),radius:3)
            if row.2 {
                line(CGPoint(x:bar.midX,y:bar.minY-2),CGPoint(x:bar.midX,y:bar.maxY+2),color:muted)
            }
            let origin = row.2 ? bar.midX : bar.minX
            let end = origin+bar.width*row.1*(row.2 ? 0.5 : 1)
            row.3.setFill()
            NSRect(x:min(origin,end),y:bar.minY,width:abs(end-origin),height:bar.height).fill()
        }
        let chart = NSRect(x:x+28,y:y+271,width:584,height:105)
        panel(chart,color:NSColor(rgb:0x111416),radius:6)
        line(CGPoint(x:chart.minX,y:chart.midY),CGPoint(x:chart.maxX,y:chart.midY),color:muted.withAlphaComponent(0.3))
        if let now = samples.reading?.time, samples.samples.count >= 2 {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:chart).addClip()
            for (color,mapped) in [(cyan,false),(green,true)] {
                let path = NSBezierPath(); path.lineWidth = 1.4
                for (i,reading) in samples.samples.enumerated() {
                    let value = mapped ? curve.response(reading.mappedSteering) : reading.raw.steering
                    let point = CGPoint(x:chart.maxX-chart.width*(now-reading.time)/2.5,y:chart.midY-chart.height*0.45*value)
                    if i == 0 { path.move(to:point) } else { path.line(to:point) }
                }
                color.setStroke(); path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        text("最近 2.5 秒 · 蓝 原始 / 绿 转向曲线后",x:x+28,y:y+382,size:10,color:muted,width:575)
        let cadence = samples.pollHz.map { String(format:"游戏读取 %.0f Hz", $0) } ?? "游戏读取 —"
        let gap = samples.p95Milliseconds.map { String(format:"95%% 读取间隔 ≤ %.1f ms", $0) } ?? "读取间隔 —"
        text(cadence+"   ·   "+gap,x:x+28,y:y+413,size:12,color:lime,width:575)
        text("变化 \(samples.distinctChanges) 次\(samples.isChanging ? " · 正在变化" : "")。上方只测游戏读取频率。",
             x:x+28,y:y+437,size:11,color:muted,width:584)
        button("−",NSRect(x:x+28,y:y+470,width:40,height:31),action:"deadzoneDown")
        text(String(format:"死区 %.0f%%",game.assists.steeringDeadzone*100),x:x+77,y:y+478,size:11,width:78,align:.center)
        button("+",NSRect(x:x+165,y:y+470,width:40,height:31),action:"deadzoneUp")
        button("震动 \(game.input.hapticLevel*25)%",NSRect(x:x+242,y:y+470,width:150,height:31),action:"hapticLevel")
        button("测试震动",NSRect(x:x+406,y:y+470,width:206,height:31),action:"hapticTest")
        let pressure = game.assists.brakeCurve.pressure(for:raw.brake)
        button("制动：\(game.assists.brakeCurve.label)",NSRect(x:x+28,y:y+516,width:175,height:31),action:"brakeCurve")
        button("转向：\(curve.label)",NSRect(x:x+215,y:y+516,width:174,height:31),action:"steeringCurve")
        text(connected == nil ? "踩 LT 预览压力" : String(format:"LT %.0f%% → 压力 %.0f%%",raw.brake*100,pressure*100),
             x:x+408,y:y+523,size:11,color:red,width:204,align:.right)
        text(game.input.hapticStatus,x:x+28,y:y+568,size:11,color:muted,width:570)
        if game.noticeRemaining > 0 {
            text(game.notice,x:x+28,y:y+589,size:10,color:lime,width:575)
        }
    }

    private func drawAnalysis(_ game: RacingGame, width: CGFloat, height: CGFloat) {
        NSColor.black.withAlphaComponent(0.65).setFill()
        bounds.fill()
        let x = (width - 1020) / 2
        let y = (height - 650) / 2
        panel(NSRect(x:x,y:y,width:1020,height:650), color:NSColor(rgb:0x191B1D), radius:16)
        let laps = game.practiceAnalysis
        text("练习分析", x:x+27,y:y+25,size:25,weight:.bold)
        text(game.vehicle.kind.label + "  ·  " + game.circuit.kind.label + "  ·  " + game.circuit.condition.label,
             x:x+28,y:y+64,size:13,color:muted,width:780)
        button("返回 [ Esc ]",NSRect(x:x+852,y:y+28,width:140,height:36),action:"analysis")
        line(CGPoint(x:x+28,y:y+96),CGPoint(x:x+992,y:y+96),color:white.withAlphaComponent(0.18))
        text("同一赛道位置的驾驶输入",x:x+28,y:y+118,size:16,weight:.semibold)
        let latestLabel = laps.latest.map { "最近有效圈  " + lapTime($0.summary.time) } ?? "最近有效圈"
        let fastestLabel = laps.fastest.map { "最快有遥测圈  " + lapTime($0.summary.time) } ?? "最快有遥测圈"
        text(latestLabel,x:x+28,y:y+148,size:12,color:NSColor(rgb:0x7FE1AB),mono:true,width:186)
        text(fastestLabel,x:x+217,y:y+148,size:12,color:NSColor(rgb:0xFFBE78),mono:true,width:215)
        text("油门 / 刹车 0–100% · 虚线为制动压力 · 转向 −100% 左 / +100% 右",x:x+28,y:y+179,size:10,color:muted)
        if let latest = laps.latest, let fastest = laps.fastest {
            let first = interactionTransform.transform(CGPoint(x:x+28,y:y+229))
            let last = interactionTransform.transform(CGPoint(x:x+578,y:y+544))
            analysisTraceOrigin = first.x
            analysisTraceWidth = last.x-first.x
            analysisHitArea = CGRect(x:first.x,y:first.y,width:last.x-first.x,height:last.y-first.y)
            let peak = (latest.inputs + fastest.inputs).lazy.map(\.speedKPH).max() ?? 0
            let maxSpeed = max(50, ceil(peak / 50) * 50)
            let rows: [(String, KeyPath<LapInputs, Double>, ClosedRange<Double>)] = [
                ("油门", \.throttle, 0...1), ("刹车", \.brake, 0...1),
                ("转向", \.steering, -1...1), ("速度 0–\(Int(maxSpeed)) km/h", \.speedKPH, 0...maxSpeed)
            ]
            for (index, row) in rows.enumerated() {
                let top = y + 211 + CGFloat(index) * 86
                text(row.0,x:x+28,y:top,size:10,color:muted)
                let frame = NSRect(x:x+28,y:top+18,width:550,height:57)
                panel(frame,color:NSColor(rgb:0x24292D),radius:3)
                for tick in 1...3 {
                    let guide = frame.minX + frame.width * CGFloat(tick) / 4
                    line(CGPoint(x:guide,y:frame.minY),CGPoint(x:guide,y:frame.maxY),color:white.withAlphaComponent(0.12))
                }
                if row.2.lowerBound < 0 {
                    line(CGPoint(x:frame.minX,y:frame.midY),CGPoint(x:frame.maxX,y:frame.midY),color:white.withAlphaComponent(0.2))
                }
                let reference = NSColor(rgb:0xFFBE78)
                let current = NSColor(rgb:0x7FE1AB)
                drawTrace(fastest.inputs, value:row.1, range:row.2, in:frame,color:reference,width:3.6)
                drawTrace(latest.inputs, value:row.1, range:row.2, in:frame,color:current,width:1.5)
                if index == 1 {
                    drawPressure(fastest.inputs,in:frame,color:reference.withAlphaComponent(0.68),phase:0)
                    drawPressure(latest.inputs,in:frame,color:current.withAlphaComponent(0.85),phase:2)
                }
                if let cursor = analysisCursorIndex {
                    let markerX = frame.minX+frame.width*CGFloat(cursor)/CGFloat(LapInputs.intervals)
                    line(CGPoint(x:markerX,y:frame.minY),CGPoint(x:markerX,y:frame.maxY),color:white.withAlphaComponent(0.75))
                }
            }
            for tick in 0...4 {
                text("\(tick * 25)%",x:x+8+CGFloat(tick)*137.5,y:y+551,size:10,color:muted,width:40,align:.center)
            }
            if let cursor = analysisCursorIndex, latest.inputs.indices.contains(cursor), fastest.inputs.indices.contains(cursor) {
                let a = latest.inputs[cursor], b = fastest.inputs[cursor]
                let distance = Double(cursor)/Double(LapInputs.intervals)*game.circuit.length
                func pressure(_ lap: LapInputs) -> String {
                    lap.linePressure.map { String(format:"%.0f%%",$0*100) } ?? "—"
                }
                text(String(format:"%.0f m  ·  最近 / 最快",distance),x:x+28,y:y+572,size:11,color:lime,mono:true,width:194)
                text(String(format:"速度 %.0f / %.0f km/h   刹车 %.0f / %.0f%%",a.speedKPH,b.speedKPH,a.brake*100,b.brake*100),
                     x:x+28,y:y+592,size:11,color:white,mono:true,width:545)
                text("管路压力 "+pressure(a)+" / "+pressure(b),x:x+28,y:y+612,size:11,color:muted,mono:true,width:545)
            } else {
                text("沿图移动鼠标，或按 ← / → 查看该位置",x:x+28,y:y+580,size:11,color:muted,width:545,align:.center)
            }
        } else {
            text("完成一个手动有效圈后显示输入曲线。",x:x+28,y:y+266,size:14,color:muted)
        }
        let tableX = x + 616
        text("有效圈分段历史",x:tableX,y:y+118,size:16,weight:.semibold)
        if let best = game.session.best {
            text("个人最佳  \(lapTime(best))",x:tableX,y:y+149,size:12,color:muted,mono:true)
        }
        if let best = game.session.best, laps.fastest.map({ best < $0.summary.time - 0.001 }) ?? true {
            text("个人最佳来自旧版，缺少输入曲线",x:tableX,y:y+172,size:10,color:muted)
        }
        if laps.history.isEmpty {
            text("暂无有效圈历史",x:tableX,y:y+266,size:14,color:muted)
            return
        }
        let rows = Array(laps.history.reversed().dropFirst(game.analysisPage * 10).prefix(10))
        let columns: [CGFloat] = [0, 96, 188, 280]
        for (index, label) in ["圈时", "S1", "S2", "S3"].enumerated() {
            text(label,x:tableX+columns[index],y:y+211,size:11,color:muted,width:87)
        }
        for (index, lap) in rows.enumerated() {
            let top = y + 237 + CGFloat(index) * 29
            line(CGPoint(x:tableX,y:top-5),CGPoint(x:x+992,y:top-5),color:white.withAlphaComponent(0.10))
            for (column, time) in ([lap.time] + lap.sectors).enumerated() {
                text(lapTime(time),x:tableX+columns[column],y:top,size:12,mono:true,width:87)
            }
        }
        if laps.history.count > 10 {
            button(game.analysisPage == 0 ? "较早的圈" : "最近的圈",NSRect(x:tableX,y:y+550,width:112,height:30),action:"analysisPage")
        }
        text("最近 \(laps.history.count) 个有效圈 · 从新到旧",x:tableX,y:y+603,size:11,color:muted)
    }

    private func drawTrace(_ samples: [LapInputs], value: KeyPath<LapInputs, Double>, range: ClosedRange<Double>,
                           in frame: NSRect, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let share = (sample[keyPath: value] - range.lowerBound) / (range.upperBound - range.lowerBound)
            let point = CGPoint(x:frame.minX + frame.width * CGFloat(index) / CGFloat(LapInputs.intervals),
                                y:frame.maxY - 2 - (frame.height - 4) * share)
            if index == 0 { path.move(to:point) } else { path.line(to:point) }
        }
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func drawPressure(_ samples: [LapInputs], in frame: NSRect, color: NSColor, phase: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.setLineDash([3,3],count:2,phase:phase)
        var started = false
        for (index,sample) in samples.enumerated() {
            guard let pressure = sample.linePressure else { started = false; continue }
            let point = CGPoint(x:frame.minX+frame.width*CGFloat(index)/CGFloat(LapInputs.intervals),
                                y:frame.maxY-2-(frame.height-4)*pressure)
            if started { path.line(to:point) } else { path.move(to:point); started = true }
        }
        color.setStroke(); path.stroke()
    }
}

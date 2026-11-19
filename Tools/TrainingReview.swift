import AppKit
import GameController
import Metal
import SceneKit
import simd

final class FrameMeasurements: NSObject, SCNSceneRendererDelegate {
    private let lock = NSLock()
    private var times: [Double] = []

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        times.append(ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    func take() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let result = times
        times.removeAll(keepingCapacity: true)
        return result
    }

    static func describe(_ intervals: [Double], elapsed: Double, frames: Int, rateLabel: String = "FPS") -> String {
        guard !intervals.isEmpty else { return "no render intervals" }
        let sorted = intervals.sorted()
        let p50 = sorted[sorted.count/2]
        let p95 = sorted[Int(Double(sorted.count-1)*0.95)]
        let p99 = sorted[Int(Double(sorted.count-1)*0.99)]
        return String(format:"%.1fs · %d frames · %.1f %@ · %.1f ms p50 · %.1f ms p95 · %.1f ms p99 · %d >50 ms · %.0f ms max",
                      elapsed,frames,Double(frames)/max(0.01,elapsed),rateLabel,p50,p95,p99,
                      sorted.filter { $0 > 50 }.count,sorted.last ?? 0)
    }
}

/// Compile into a dedicated scratch .app with bundled Assets. Generated practice
/// data lives beside that scratch app, never beside the actual release bundle.
@main struct TrainingReview {
    static var failures=0
    static func check(_ valid:Bool,_ title:String) {print("\(valid ? "PASS" : "FAIL")  \(title)");if !valid {failures += 1}}
    static func reviewWheelTelemetry(_ rows: [[Substring]], expectCornering: Bool) {
        let wheels = ["fr","fl","rr","rl"]
        let expected = ["applied_throttle","applied_brake","brake_steady_target","engine_throttle"]
            + wheels.map { $0+"_sliding_fraction" } + wheels.map { $0+"_lateral_force_n" }
        guard let header = rows.first, header.suffix(expected.count).map(String.init) == expected,
              rows.count > 1 else {
            check(false,"CSV appends four sliding fractions and four lateral forces after the control channels")
            return
        }
        let samples = rows.dropFirst()
        let readings = samples.map { $0.suffix(8).compactMap { Double($0) } }
        check(samples.allSatisfy { $0.count == header.count } && readings.allSatisfy { values in
            values.count == 8 && values.prefix(4).allSatisfy { (0...1).contains($0) }
                && values.suffix(4).allSatisfy { $0.isFinite }
        }, "CSV writes one bounded sliding fraction and one signed lateral force per wheel")
        if expectCornering {
            check(readings.contains { $0.prefix(4).contains { $0 > 0.02 } && $0.suffix(4).contains { $0 < -100 } },
                  "An imposed lateral velocity produces tread sliding and an opposing recorded tyre force")
        }
    }
    static func tick(_ session:inout RaceSession,progress:Double,speed:Double,dt:Double=0.1,off:Bool=false) {
        var car=Vehicle();car.position=SIMD2(progress,0);car.velocity=SIMD2(speed,0)
        let phase = progress / 1200 * 2 * Double.pi
        let controls = DrivingInput(throttle: 0.5 + 0.45 * sin(phase * 5 + speed),
            brake: 0.5 + 0.48 * cos(phase * 3 + speed), steering: 0.9 * sin(phase * 4 + speed))
        _ = session.step(dt,vehicle:car,location:TrackLocation(point:car.position,tangent:SIMD2(1,0),progress:progress,lateral:0,distance:off ? 20 : 0,segment:0),trackLength:1200,trackWidth:12,input:controls)
    }
    static func reference(speed:Double) -> RaceSession {
        var session=RaceSession();session.resetLap(at:0)
        for i in 1...1000 {tick(&session,progress:(Double(i)*speed*0.1).truncatingRemainder(dividingBy:1200),speed:speed);if session.completedLaps>0 {break}}
        return session
    }
    static func main() throws {
        _ = NSApplication.shared
        guard Bundle.main.bundleIdentifier=="studio.apexlab.trainingreview" else {fatalError("Use a dedicated scratch review bundle")}
        let flags = CommandLine.arguments
        let quality: GraphicsQuality = flags.contains("--graphics-performance") ? .performance :
            (flags.contains("--graphics-balanced") ? .balanced : .quality)
        if CommandLine.arguments.contains("--controller") {
            reviewController()
            return
        }
        if CommandLine.arguments.contains("--menus") {
            try reviewMenus()
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of:"--metal-replay"),
           CommandLine.arguments.indices.contains(flag+1), let frames = Int(CommandLine.arguments[flag+1]),
           (120...12_000).contains(frames) {
            try replayMetal(frames:frames,wet:flags.contains("--wet"),quality:quality)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--performance"),
           CommandLine.arguments.indices.contains(flag+1), let seconds = Double(CommandLine.arguments[flag+1]),
           (10...1800).contains(seconds) {
            let id = flags.first { $0.hasPrefix("--car=") }.flatMap { Int($0.dropFirst(6)) }
            try measurePerformance(seconds:seconds,wet:flags.contains("--wet"),fps60:flags.contains("--fps60"),quality:quality,
                                   circuit:flags.contains("--ridge") ? .ridge : .north,
                                   vehicle:id.flatMap(VehicleKind.init(rawValue:)) ?? (flags.contains("--mazda") ? .mazda : .centenario))
            return
        }
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/training-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:dataFolder) }
        let game=RacingGame(frame:NSRect(x:0,y:0,width:1100,height:718),dataDirectory:dataFolder,monitorControllers:false)
        game.hasStarted=true;game.isPaused=true
        game.vehicle.kind = .ferrari;game.world.selectVehicle(.ferrari)
        while game.circuit.kind != .north {game.action("trackNext")}
        let base=reference(speed:20), other=reference(speed:24)
        game.session=base
        game.action("compound")
        game.action("pressureUp")
        game.action("abs")
        game.action("tc")
        game.action("automatic")
        game.action("brakeBiasUp")
        game.action("brakeCurve")
        game.action("steeringCurve")
        let ferrariTyres = game.tyreSetup
        let ferrariBias = game.assists.frontBrakeBias
        check(game.vehicle.wheels[0].setup != ferrariTyres, "New tyre settings remain pending on the fitted tyres")
        game.action("vehicleNext")
        check(game.vehicle.kind == .porsche && game.session.best != base.best,"Switching car does not reuse another car's best")
        check(game.tyreSetup != ferrariTyres && game.assists.automatic && game.assists.absLevel == 3 &&
              game.assists.brakeCurve == .progressive && game.assists.steeringCurve == .standard,
              "Switching cars restores its own tyres, assists and transmission")
        game.session=other
        game.action("trackNext")
        check(game.session.best==nil,"New track does not reuse the old track's reference")
        for _ in 1..<CircuitKind.allCases.count {game.action("trackNext")}
        check(abs((game.session.best ?? 0)-50)<0.001,"Returning to track restores its own personal best")
        game.action("vehiclePrevious")
        check(abs((game.session.best ?? 0)-60)<0.001,"Returning to car restores its own personal best")
        check(game.tyreSetup == ferrariTyres && game.vehicle.wheels[0].setup == ferrariTyres &&
              game.assists.absLevel == 4 && game.assists.tcLevel == 4 && !game.assists.automatic &&
              game.assists.frontBrakeBias == ferrariBias && game.assists.brakeCurve == .deep && game.assists.steeringCurve == .precision,
              "Switching back fits the chosen tyres and restores the Ferrari setup")
        let reload=RacingGame(frame:game.hud.frame,dataDirectory:dataFolder,monitorControllers:false)
        check(reload.vehicle.kind == .ferrari && reload.circuit.kind == .north && abs((reload.session.best ?? 0)-60)<0.001,"Relaunch restores selected vehicle, circuit and record")
        check(reload.session.bestSectors.count==3 && !reload.session.bestTrace.isEmpty && !reload.session.bestGhost.isEmpty,"Relaunch restores sectors, distance reference and ghost together")
        check(reload.tyreSetup == ferrariTyres && reload.vehicle.wheels[0].setup == ferrariTyres &&
              reload.assists.frontBrakeBias == ferrariBias && reload.assists.brakeCurve == .deep && reload.assists.steeringCurve == .precision,
              "Relaunch restores the same setup and fits the chosen tyres")
        game.action("trackCondition")
        check(game.circuit.condition == .wet && game.session.best == nil && game.traffic.cars.allSatisfy {
            $0.vehicle.wheels.allSatisfy { $0.setup.compound == .wet }
        }, "Wet practice starts separately and rivals fit rain tyres")
        game.session = other
        game.action("trackCondition")
        check(game.circuit.condition == .dry && game.session.best == base.best, "Dry best lap survives switching conditions")
        game.action("trackCondition")
        let wetReload = RacingGame(frame:game.hud.frame,dataDirectory:dataFolder,monitorControllers:false)
        check(wetReload.circuit.condition == .wet && wetReload.session.best == other.best,
              "Relaunch restores the wet session and its independent best lap")
        game.action("trackCondition")
        let tempRace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:tempRace) }
        let sprintGame = RacingGame(frame:game.hud.frame,dataDirectory:tempRace,monitorControllers:false)
        sprintGame.session = base
        sprintGame.action("startSprint")
        let gridPosition = sprintGame.vehicle.position
        check(sprintGame.sprint?.countdownSeconds == 3 && sprintGame.sprint?.driverPosition == 4 &&
              sprintGame.traffic.cars.count == 3, "F10 starts a countdown with the player on the fourth grid slot")
        sprintGame.action("pause")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.15))
        check(sprintGame.sprint?.countdown == 3 && sprintGame.vehicle.position == gridPosition,
              "Pause freezes the countdown and grid")
        sprintGame.action("trackNext")
        check(sprintGame.circuit.kind == .north, "Practice changes cannot alter an active grid")
        sprintGame.action("restart")
        sprintGame.action("autoDrive")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:4.0))
        check(sprintGame.sprint?.countdown == 0 && sprintGame.sprint?.assisted == true &&
              sprintGame.vehicle.distanceTravelled > 0.4, "Green releases both player and AI into the same physical sprint")
        sprintGame.action("pause")
        let sprintCSV = tempRace.appendingPathComponent("latest-sprint.csv")
        check(FileManager.default.fileExists(atPath:sprintCSV.path) &&
              !FileManager.default.fileExists(atPath:tempRace.appendingPathComponent("latest-session.csv").path),
              "Short races write separate telemetry")
        let rows = try String(contentsOf:sprintCSV,encoding:.utf8).split(separator:"\n").map { $0.split(separator:",") }
        reviewWheelTelemetry(rows,expectCornering:false)
        if let header = rows.first, let index = header.firstIndex(of:"session_time_s") {
            let samples = rows.dropFirst()
            let times = samples.compactMap { $0.indices.contains(index) ? Double($0[index]) : nil }
            check(samples.count > 4 && samples.allSatisfy { $0.count == header.count } &&
                  times.count == samples.count && zip(times.dropFirst(),times).allSatisfy { abs($0-$1-0.1)<0.0002 } &&
                  header.contains("fr_brake_pressure") && header.contains("rl_longitudinal_force_n"),
                  "Race telemetry aligns every wheel column to a steady, continuous 10 Hz clock")
        } else {
            check(false,"Race telemetry contains the continuous session clock")
        }
        let raceWindow = NSWindow(contentRect:sprintGame.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        raceWindow.contentView = sprintGame.hud
        let raceImage = NSImage(size:sprintGame.hud.bounds.size)
        raceImage.lockFocusFlipped(true); sprintGame.hud.draw(sprintGame.hud.bounds); raceImage.unlockFocus()
        if let data = raceImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data) {
            try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("sprint-pause.png"))
        }
        sprintGame.action("leaveSprint")
        check(sprintGame.sprint == nil && !sprintGame.hasStarted && sprintGame.isPaused && sprintGame.session.best == base.best,
              "Returning to the menu preserves the existing practice record")
        sprintGame.action("controllerReview")
        sprintGame.action("confirm")
        check(!sprintGame.showingControllerReview && sprintGame.isPaused && !sprintGame.hasStarted,
              "Controller calibration closes safely without starting the car")
        sprintGame.action("controllerReview")
        let deadzone = sprintGame.assists.steeringDeadzone
        sprintGame.action("deadzoneUp")
        sprintGame.action("brakeCurve")
        sprintGame.action("steeringCurve")
        sprintGame.action("hapticTest")
        check(sprintGame.showingControllerReview && sprintGame.assists.steeringDeadzone > deadzone &&
              sprintGame.notice.contains("未连接") && sprintGame.assists.brakeCurve == .deep && sprintGame.assists.steeringCurve == .precision,
              "Calibration remains usable without a connected controller")
        let padWindow = NSWindow(contentRect:sprintGame.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        padWindow.contentView = sprintGame.hud
        let padImage = NSImage(size:sprintGame.hud.bounds.size)
        padImage.lockFocusFlipped(true); sprintGame.hud.draw(sprintGame.hud.bounds); padImage.unlockFocus()
        if let data = padImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data:data) {
            try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("controller-review.png"))
        }
        sprintGame.shutdown()
        let window=NSWindow(contentRect:game.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=game.hud
        game.isPaused=false;game.drivingView = .chase;game.noticeRemaining=0
        func capture(_ name:String,rect:NSRect?=nil) throws {
            game.hud.needsDisplay=true;game.hud.displayIfNeeded()
            let bounds=rect ?? game.hud.bounds
            let image=NSImage(size:bounds.size)
            image.lockFocusFlipped(true)
            let offset=NSAffineTransform();offset.translateX(by:-bounds.minX,yBy:-bounds.minY);offset.concat()
            game.hud.draw(game.hud.bounds)
            image.unlockFocus()
            let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        }
        for (name,speed) in [("ahead",24.0),("behind",15.0)] {
            game.session=RaceSession();game.session.restore(base.record);game.session.resetLap(at:0)
            for i in 1...Int(600/speed/0.1) {tick(&game.session,progress:Double(i)*speed*0.1,speed:speed)}
            game.vehicle.velocity=game.vehicle.forward*speed;game.vehicle.rpm=6500;game.vehicle.gear=3
            try capture(name,rect:NSRect(x:380,y:18,width:340,height:126))
            if name=="ahead" {try capture("minimum-window")}
        }
        tick(&game.session,progress:602,speed:15,off:true)
        try capture("invalid",rect:NSRect(x:380,y:18,width:340,height:126))
        game.session.resetLap(at:700)
        try capture("outlap",rect:NSRect(x:380,y:18,width:340,height:126))
        game.session=base;try capture("completed",rect:NSRect(x:380,y:18,width:340,height:126))
        game.hud.frame=NSRect(x:0,y:0,width:1440,height:900);try capture("large-window")
        let settings=dataFolder.appendingPathComponent("practice.json")
        let currentData = try Data(contentsOf:settings)
        var legacy=try JSONSerialization.jsonObject(with:currentData) as! [String:Any]
        legacy["version"]=9;legacy.removeValue(forKey:"vehicleSettings");legacy.removeValue(forKey:"analysis")
        legacy["brakeBiasByVehicle"] = ["1": 0.66, "2": 0.59]
        try JSONSerialization.data(withJSONObject:legacy).write(to:settings,options:.atomic)
        let migratedV9 = RacingGame(frame:game.hud.frame,dataDirectory:dataFolder,monitorControllers:false)
        check(migratedV9.session.best == base.best && migratedV9.tyreSetup == ferrariTyres &&
              migratedV9.assists.frontBrakeBias == 0.66 && migratedV9.practiceAnalysis.history.isEmpty,
              "Version 9 keeps its best lap and migrates existing settings without fabricating inputs")
        migratedV9.action("vehicleNext")
        check(migratedV9.tyreSetup == ferrariTyres && migratedV9.assists.frontBrakeBias == 0.59,
              "Version 9 global settings seed each car while existing brake bias stays per car")
        let backupV9 = try JSONDecoder().decode(SavedPractice.self,
            from:Data(contentsOf:dataFolder.appendingPathComponent("practice-before-2.0.json")))
        check(backupV9.version == 9, "Version 9 is backed up before conversion")
        legacy["version"]=8;legacy.removeValue(forKey:"records");legacy.removeValue(forKey:"vehicleSettings")
        legacy["automatic"]=false;legacy["absLevel"]=2
        try JSONSerialization.data(withJSONObject:legacy).write(to:settings,options:.atomic)
        let migrated=RacingGame(frame:game.hud.frame,dataDirectory:dataFolder,monitorControllers:false)
        check(!migrated.assists.automatic && migrated.assists.absLevel==2 && migrated.session.best==nil,"Legacy migration keeps driving preferences without inventing a distance reference")
        migrated.action("mute")
        let backup=try JSONSerialization.jsonObject(with:Data(contentsOf:dataFolder.appendingPathComponent("practice-before-1.6.json"))) as! [String:Any]
        let updated=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! [String:Any]
        check(backup["version"] as? Int==8 && updated["version"] as? Int==10,"First save preserves the legacy practice file before writing the new schema")
        var saved = try JSONDecoder().decode(SavedPractice.self, from: currentData)
        var analysis = PracticeAnalysis()
        analysis.append(other.analysedLap!)
        for _ in 0..<13 { analysis.append(base.analysedLap!) }
        let analysisKey = LapRecord.key(vehicle:.ferrari,circuit:.north)
        saved.analysis = [analysisKey: analysis]
        saved.records?[analysisKey] = other.record
        try JSONEncoder().encode(saved).write(to:settings,options:.atomic)
        let analysisGame = RacingGame(frame:NSRect(x:0,y:0,width:1100,height:740),dataDirectory:dataFolder,monitorControllers:false)
        let analysisWindow = NSWindow(contentRect:analysisGame.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        analysisWindow.contentView = analysisGame.hud
        check(analysisGame.practiceAnalysis.history.count == 14 && analysisGame.practiceAnalysis.fastest?.summary.time == other.best,
              "Analysis survives app reload with the correct car and track")
        analysisGame.action("analysis")
        check(analysisGame.isPaused && analysisGame.showingAnalysis, "Analysis opens as a paused modal")
        let image = NSImage(size:analysisGame.hud.bounds.size)
        image.lockFocusFlipped(true)
        analysisGame.hud.draw(analysisGame.hud.bounds)
        image.unlockFocus()
        analysisGame.action("menuRight")
        check(analysisGame.hud.analysisMarker == 102,"Analysis arrows move the cursor along recorded lap data")
        let analysisPNG = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try analysisPNG.write(to:output.appendingPathComponent("analysis.png"))
        analysisGame.action("analysisPage")
        check(analysisGame.analysisPage == 1, "Lap history can show the older page")
        analysisGame.action("pause")
        analysisGame.action("vehicleNext")
        check(!analysisGame.showingAnalysis && analysisGame.practiceAnalysis.history.isEmpty, "Analysis remains isolated when switching cars")
        try reviewBackgroundSave()
        print("Rendered five timing states and two window sizes")
        if failures>0 {exit(1)}
    }

    static func reviewBackgroundSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let game = RacingGame(frame:NSRect(x:0,y:0,width:900,height:664),dataDirectory:folder,monitorControllers:false)
        defer { game.shutdown() }
        game.action("start")
        let circuit = game.circuit
        var lap = RaceSession()
        lap.resetLap(at:0)
        let speed = 22.0
        let step = 0.02
        let lastIndex = Int((circuit.length-0.45)/(speed*step))
        var car = Vehicle()
        car.kind = game.vehicle.kind
        for index in 1...lastIndex {
            let sample = circuit.sample(at:Double(index)*speed*step)
            car.reset(at:sample)
            car.velocity = sample.tangent*speed
            _ = lap.step(step,vehicle:car,location:circuit.nearest(to:car.position),trackLength:circuit.length,trackWidth:circuit.width)
        }
        for i in car.wheels.indices { car.wheels[i].angularVelocity = speed/car.wheelRadius }
        game.vehicle = car
        game.session = lap
        let practice = folder.appendingPathComponent("practice.json")
        let deadline = Date(timeIntervalSinceNow:2)
        while !FileManager.default.fileExists(atPath:practice.path) && Date() < deadline {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.025))
        }
        let key = LapRecord.key(vehicle:car.kind,circuit:circuit.kind,condition:circuit.condition)
        func readPractice() -> SavedPractice? {
            guard let bytes = try? Data(contentsOf:practice) else { return nil }
            return try? JSONDecoder().decode(SavedPractice.self,from:bytes)
        }
        let best = readPractice()?.records?[key]?.time
        check(best != nil && best == game.session.best && !game.isPaused,
              "A valid crossing saves the lap in the background while the game keeps driving")
        game.vehicle.velocity += game.vehicle.modelX*3.5
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.16))
        game.action("brakeBiasUp")
        let bias = game.assists.frontBrakeBias
        game.action("pause")
        game.action("settings")
        game.action("settings:audio")
        game.action("masterDown")
        check(readPractice()?.masterVolume == 0.9 && readPractice()?.records?[key]?.time == best &&
              readPractice()?.vehicleSettings?[String(car.kind.rawValue)]?.frontBrakeBias == bias,
              "Track record, live brake-bias change and settings remain ordered across queued saves")
        let csv = try String(contentsOf:folder.appendingPathComponent("latest-session.csv"),encoding:.utf8)
        let rows = csv.split(separator:"\n").map { $0.split(separator:",") }
        reviewWheelTelemetry(rows,expectCornering:true)
        game.action("menuBack")
        game.action("resume")
        game.input.keys.insert(13)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.07))
        let stoppedPosition = game.vehicle.position
        game.loseFocus()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.10))
        check(game.isPaused && game.input.keys.isEmpty && game.vehicle.position == stoppedPosition,
              "Losing the window freezes the car and clears held driver inputs")
    }

    static func reviewMenus() throws {
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/menu-review")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = RacingGame(frame:frame,dataDirectory:data,monitorControllers:false)
        let window = NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = game.hud
        defer { game.shutdown() }

        func capture(_ name: String) throws {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.035))
            let rect = game.hud.bounds
            let screen = game.sceneView.snapshot()
            let canvas = NSImage(size:rect.size)
            canvas.lockFocusFlipped(true)
            screen.draw(in:rect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            game.hud.draw(rect)
            canvas.unlockFocus()
            let png = NSBitmapImageRep(data:canvas.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try png.write(to:output.appendingPathComponent(name+".png"))
            let controls = game.hud.visibleActionFrames
            check(!controls.isEmpty && Set(controls.map(\.1)).count == controls.count && controls.allSatisfy { rect.contains($0.0) },
                  "\(name) has unique, reachable controls at \(Int(rect.width)) × \(Int(rect.height))")
            let overlap = controls.indices.contains { i in
                controls.indices.contains { j in i < j && controls[i].0.intersects(controls[j].0) }
            }
            check(!overlap,"\(name) avoids overlapping controls")
        }
        try capture("01-start")
        game.action("pause")
        check(!game.hasStarted,"Esc on the start screen does not enter the track")
        game.action("selectVehicle")
        try capture("13-vehicle-picker")
        check(VehicleKind.allCases.allSatisfy { car in
            game.hud.visibleActionFrames.contains { $0.1 == "car:"+String(car.rawValue) }
        },"The complete vehicle roster fits and can be selected at the minimum window size")
        game.action("car:4")
        check(game.vehicle.kind == .mazda && game.garageSelection == nil,"Garage selects a vehicle without cycling other cars")
        game.action("selectCircuit")
        try capture("14-track-picker")
        game.action("circuit:4")
        check(game.circuit.kind == .ridge && game.garageSelection == nil,"Circuit picker selects the requested track")
        game.action("settings")
        game.action("choice:tyres")
        try capture("27-tyre-choice")
        let originalTyres = game.vehicle.wheels[0].setup
        game.action("setChoice:3")
        check(game.tyreSetup.compound == .wet && game.vehicle.wheels[0].setup == originalTyres && game.hasPendingTyres,
              "Choosing wet tyres changes the next set and leaves the installed tyres in place")
        game.action("choice:tyres")
        game.action("setChoice:1")
        game.action("settings")
        game.action("settings")
        try capture("02-driving")
        func key(_ keyCode: UInt16,_ characters: String,_ modifier: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifier,timestamp:0,
                                               windowNumber:window.windowNumber,context:nil,characters:characters,
                                               charactersIgnoringModifiers:characters,isARepeat:false,keyCode:keyCode) else {
                fatalError("Could not create test key")
            }
            game.hud.keyDown(with:event)
            game.hud.keyUp(with:event)
        }
        key(124,"")
        check(game.hud.menuFocusAction != nil,"Directional navigation establishes a visible focus")
        key(36,"\r")
        check(game.settingsPage == .controller,"Keyboard arrows and Return open the next settings page")
        try capture("03-controller")
        game.action("choice:braking")
        try capture("20-brake-choice")
        check(game.settingsChoice == .braking && game.hud.menuFocusAction == "setChoice:0",
              "Brake choices focus the current setting and expose all response profiles")
        game.action("menuDown")
        game.action("menuAccept")
        try capture("21-controller-after-choice")
        check(game.assists.brakeCurve == .deep && game.settingsChoice == nil &&
              game.hud.menuFocusAction == "choice:braking",
              "Selecting a brake profile returns focus to its setting")
        game.action("controllerReview")
        try capture("04-calibration")
        game.action("menuBack")
        check(game.settingsPage == .controller && !game.showingControllerReview,
              "Calibration returns to its original settings tab")
        game.action("settings:display")
        game.action("choice:antialiasing")
        game.action("setChoice:0")
        game.action("choice:camera")
        try capture("22-camera-choice")
        game.action("setChoice:99")
        game.action("menuBack")
        check(game.drivingView == .chase && game.settingsChoice == nil,
              "Invalid options and cancel leave the driving view unchanged")
        game.action("choice:camera")
        game.action("setChoice:5")
        game.action("renderingRate")
        if !game.compactHUD { game.action("compactHUD") }
        try capture("05-display")
        let savedView = game.drivingView
        let parked = game.vehicle.position
        game.action("seatPreview")
        try capture("18-seat-preview")
        let lowSeat = game.world.camera.simdPosition.y
        check(game.showingSeatPreview && !game.hasStarted && game.world.camera.camera?.fieldOfView == 62 &&
              game.hud.visibleActionFrames.contains(where: { $0.1 == "fovUp" }),
              "Seat preview renders the actual cockpit and exposes its adjustment controls")
        game.action("fovUp")
        game.action("seatUp")
        game.action("start")
        try capture("19-seat-adjusted")
        check(game.world.camera.camera?.fieldOfView == 64 && game.world.camera.simdPosition.y > lowSeat+0.015 &&
              game.vehicle.position == parked && game.drivingView == savedView && game.isPaused,
              "Seat preview changes the rendered field of view and eye position without moving the car")
        game.action("menuBack")
        check(game.settingsPage == .display && !game.showingSeatPreview && game.drivingView == savedView,
              "Closing the seat preview returns to the same tab and preserves the selected driving view")
        game.action("settings:aids")
        game.action("ghost")
        try capture("06-aids")
        game.action("settings:audio")
        game.action("masterDown")
        game.action("motorDown")
        game.action("effectsDown")
        try capture("07-audio")
        game.action("resetAudioSettings")
        try capture("17-reset-audio")
        check(Set(game.hud.visibleActionFrames.map(\.1)) == ["cancelSettingsReset","confirmSettingsReset"] &&
              game.hud.menuFocusAction == "cancelSettingsReset",
              "Reset confirmation is visible, owns its controls, and focuses Cancel")
        game.action("menuAccept")
        check(game.settingsPage == .audio && game.settingsReset == nil && game.sound.masterVolume == 0.9,
              "Canceling settings reset keeps the existing mix and the current page")
        game.action("resetAudioSettings")
        game.action("confirmSettingsReset")
        check(game.sound.masterVolume == 1 && game.sound.effectsVolume == 1 &&
              game.graphicsQuality == .performance && game.vehicle.kind == .mazda,
              "Restoring audio defaults changes only that category")
        game.action("masterDown")
        game.action("motorDown")
        game.action("effectsDown")
        game.action("startSprint")
        check(!game.hasStarted && game.settingsPage == .audio,"Settings prevent unrelated race actions")
        game.action("menuBack")
        game.action("help")
        try capture("08-help")
        game.action("menuBack")
        check(!game.hasStarted && !game.showHelp,"Help returns without changing practice state")
        game.action("start")
        game.vehicle.velocity = game.vehicle.forward*25
        game.vehicle.gear = 3
        game.vehicle.rpm = 4200
        for index in game.vehicle.wheels.indices { game.vehicle.wheels[index].angularVelocity = 25/game.vehicle.wheelRadius }
        try captureDrive("15-compact-driving")
        let compact = game.hud.visibleDrivingPanels.map(\.0)
        check(compact.contains("dash") && !compact.contains("pedals") && !compact.contains("vehicle"),
              "Compact HUD displays the new driving dashboard without its full telemetry panels")
        game.action("compactHUD")
        try captureDrive("16-full-driving")
        let full = game.hud.visibleDrivingPanels
        check(full.contains(where: { $0.0 == "pedals" }) && !full.contains(where: { $0.0 == "dash" }) &&
              full.allSatisfy { game.hud.bounds.contains($0.1) }, "Full HUD keeps its key telemetry inside the minimum window")
        let collision = full.indices.contains { i in
            full.indices.contains { j in i < j && full[i].1.intersects(full[j].1) }
        }
        check(!collision,"Default full HUD panels do not collide at minimum window size")
        game.action("compactHUD")
        game.action("settings")
        game.action("settings:aids")
        let savedDash = HUDPosition(origin:CGPoint(x:200,y:500),size:CGSize(width:338,height:95),viewport:frame.size)
        let hiddenFull = HUDPosition(origin:CGPoint(x:24,y:34),size:CGSize(width:238,height:292),viewport:frame.size)
        game.hudPositions = ["dash":savedDash,"vehicle":hiddenFull]
        game.action("hudLayout")
        try capture("23-hud-layout")
        check(game.editingHUD && game.hud.menuFocusAction == "hudLayout" &&
              !game.hud.visibleDrivingPanels.contains(where:{ $0.0 == "vehicle" }),
              "Compact layout editor has menu navigation and only shows panels in its layout")
        game.action("hudLayoutReset")
        check(game.hudPositions["dash"] == nil && game.hudPositions["vehicle"]?.x == hiddenFull.x,
              "Resetting compact layout keeps positions unique to the full layout")
        game.action("menuBack")
        check(!game.editingHUD && game.isPaused && game.settingsPage == .aids &&
              game.hudPositions["dash"]?.x == savedDash.x,
              "Cancel restores the old position and returns to the display aids tab")
        game.action("hudLayout")
        game.action("hudLayoutReset")
        game.action("hudLayout")
        check(game.hudPositions["dash"] == nil && game.hudPositions["vehicle"]?.x == hiddenFull.x,
              "Saving applies the layout draft")
        game.action("menuBack")
        check(game.hasStarted && game.isPaused && game.settingsPage == nil,
              "Settings entered while driving return to pause, not live controls")
        try capture("09-pause")
        game.action("askRestart")
        try capture("10-restart")
        game.action("menuBack")
        check(game.isPaused && game.sessionPrompt == nil,"Canceling restart retains paused practice")
        game.action("pitMenu")
        try capture("11-pit")
        game.action("menuBack")
        game.action("analysis")
        try capture("12-analysis")
        game.action("menuBack")
        game.action("askLeavePractice")
        game.action("confirmPrompt")
        check(!game.hasStarted && game.isPaused,"Leaving practice returns to the start screen")

        let reload = RacingGame(frame:frame,dataDirectory:data,monitorControllers:false)
        defer { reload.shutdown() }
        check(reload.vehicle.kind == .mazda && reload.circuit.kind == .ridge &&
              reload.graphicsQuality == .performance && reload.sceneView.antialiasingMode == .none &&
              reload.renderingRate == .hz60 && reload.sceneView.preferredFramesPerSecond == 60 &&
              reload.world.cockpitFOV == 64 && reload.world.seatHeight == 1.02 &&
              reload.drivingView == savedView && !reload.ghostEnabled && reload.compactHUD &&
              reload.assists.brakeCurve == .deep &&
              reload.sound.masterVolume == 0.9 && reload.sound.motorVolume == 0.9 && reload.sound.effectsVolume == 0.9,
              "Display, assists and three independent volume settings survive a relaunch")
        let blocked = data.appendingPathComponent("settings-file-instead-of-folder")
        try Data([0]).write(to:blocked)
        let failedSave = RacingGame(frame:frame,dataDirectory:blocked,monitorControllers:false)
        defer { failedSave.shutdown() }
        failedSave.action("settings")
        failedSave.action("settings:audio")
        failedSave.action("masterDown")
        check(failedSave.sound.masterVolume == 0.9 && failedSave.settingsStatus != nil,
              "Settings report write failure instead of claiming that the change was stored")
        game.action("startSprint")
        try captureDrive("24-sprint-grid")
        check(game.sprint?.countdownSeconds == 3 && !game.isPaused, "Sprint grid displays a live countdown")
        game.action("pause")
        try capture("25-sprint-pause")
        check(game.hud.visibleActionFrames.contains(where:{ $0.1 == "askRestart" }),
              "Sprint pause keeps the restart confirmation entry")
        game.hud.frame = NSRect(x:0,y:0,width:1280,height:800)
        game.sceneView.frame = game.hud.frame
        game.viewportChanged()
        game.action("settings")
        game.action("choice:tyres")
        check(game.settingsChoice == nil && !game.canPlanTyres, "Short race keeps the fitted tyres locked")
        game.action("settings:display")
        try capture("26-wide-display-settings")
        if failures > 0 { exit(1) }

        func captureDrive(_ name: String) throws {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.06))
            let rect = game.hud.bounds
            let canvas = NSImage(size:rect.size)
            canvas.lockFocusFlipped(true)
            game.sceneView.snapshot().draw(in:rect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            game.hud.draw(rect)
            canvas.unlockFocus()
            let png = NSBitmapImageRep(data:canvas.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try png.write(to:output.appendingPathComponent(name+".png"))
        }
    }

    static func measurePerformance(seconds: Double,wet: Bool,fps60: Bool,quality: GraphicsQuality,
                                   circuit: CircuitKind,vehicle: VehicleKind) throws {
        let clock = ProcessInfo.processInfo
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:1440,height:900)
        let game = RacingGame(frame:frame,dataDirectory:data,monitorControllers:false)
        if game.vehicle.kind != vehicle {
            game.action("selectVehicle")
            game.action("car:"+String(vehicle.rawValue))
        }
        if game.circuit.kind != circuit {
            game.action("selectCircuit")
            game.action("circuit:"+String(circuit.rawValue))
        }
        if fps60 || quality != .quality {
            game.action("settings")
            game.action("settings:display")
            if fps60 { game.action("renderingRate") }
            if quality != .quality {
                game.action("choice:antialiasing")
                game.action("setChoice:"+String(quality.rawValue))
            }
            game.action("menuBack")
        }
        var ticks: [DrivingTick] = []
        game.inspectDrivingTick = { ticks.append($0) }
        if wet {
            game.action("trackCondition")
            while game.tyreSetup.compound != .wet { game.action("compound") }
        }
        let measurements = FrameMeasurements()
        game.sceneView.delegate = measurements
        let window = NSWindow(contentRect:frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "APEX Lab · Performance Review"
        window.center()
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        game.action("viewCabin")
        game.action("start")
        game.action("autoDrive")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:5))
        _ = measurements.take()
        ticks.removeAll(keepingCapacity:true)
        let start = clock.systemUptime
        let initialDistance = game.vehicle.distanceTravelled
        RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds))
        let elapsed = clock.systemUptime - start
        let times = measurements.take()
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let distance = game.vehicle.distanceTravelled - initialDistance
        let tickIntervals = zip(ticks.dropFirst(),ticks).map { ($0.timestamp-$1.timestamp)*1000 }
        let processing = ticks.map { $0.processingTime*1000 }.sorted()
        let sceneUpdates = ticks.filter(\.sceneUpdated).count
        let steps = ticks.reduce(0) { $0+$1.physicsSteps }
        check(times.count > 1 && distance > 0 && game.mirrorImage != nil,
              "A visible Metal SCNView drove with the cockpit mirror active")
        let liveMirrors = VehicleMirror.allCases.filter { game.world.hasMirror($0) }
        check(!liveMirrors.isEmpty && liveMirrors.allSatisfy { game.world.mirrorHasImage($0) },
              "Metal command completion updates every authored player mirror material")
        print("\(game.circuit.kind.label) / \(game.vehicle.kind.label) / \(game.circuit.condition.label) / \(game.graphicsQuality.title) / \(game.renderingRate.rawValue) FPS")
        print(FrameMeasurements.describe(intervals,elapsed:elapsed,frames:times.count))
        print("Main timer: "+FrameMeasurements.describe(tickIntervals,elapsed:elapsed,frames:ticks.count,rateLabel:"ticks/s"))
        if !processing.isEmpty {
            print(String(format:"Game tick work: %.2f ms p50, %.2f ms p95 · %.1f scene updates/s · %.1f physics steps/s",
                         processing[processing.count/2],processing[Int(Double(processing.count-1)*0.95)],
                         Double(sceneUpdates)/elapsed,Double(steps)/elapsed))
        }
        let largest = zip(times.dropFirst(),intervals).sorted { $0.1 > $1.1 }.prefix(8)
        print("Longest gaps: " + largest.map { String(format:"%.1f ms @ %.1fs",$0.1,$0.0-start) }.joined(separator:", "))
        print(String(format:"Render coverage: first %.1fs, last %.1fs · car travelled %.1f m · %d laps",
                     (times.first ?? start)-start,(times.last ?? start)-start,distance,game.session.completedLaps))
        for offset in stride(from:0.0,to:seconds,by:30) {
            let count = times.filter { $0-start >= offset && $0-start < offset+30 }.count
            print(String(format:"%3.0fs–%3.0fs: %5d render callbacks",offset,min(seconds,offset+30),count))
        }
        check(game.autoDriveEnabled && !game.isPaused && distance / elapsed > 8,
              "Autodrive stays active and continues moving throughout the run")
        check((230...244).contains(Double(steps)/elapsed) && (!fps60 || Double(sceneUpdates)/elapsed < 64),
              "The selected frame rate limits presentation updates independently of physics")
        game.shutdown()
        if failures > 0 { exit(1) }
    }

    /// Measures rendered Metal commands without depending on window visibility
    /// or display refresh. This reports command time, not onscreen frame rate.
    static func replayMetal(frames: Int, wet: Bool, quality: GraphicsQuality) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        let circuit = Circuit(kind:.ridge,condition:wet ? .wet : .dry)
        let world = RacingWorld(circuit:circuit)
        world.applyGraphicsQuality(quality)
        world.selectVehicle(.mazda)
        var player = Vehicle(); player.kind = .mazda; player.reset(at:circuit.start)
        if wet { player.service(setup:TyreSetup(compound:.wet)) }
        var traffic = ComputerTraffic()
        traffic.reset(count:3,kind:.mazda,circuit:circuit,from:circuit.start.distance)
        let renderer = SCNRenderer(device:device,options:nil)
        renderer.scene = world.scene; renderer.pointOfView = world.camera
        let mirror = SCNRenderer(device:device,options:nil)
        mirror.scene = world.scene; mirror.pointOfView = world.mirrorCamera
        func target(width: Int, height: Int) throws -> MTLRenderPassDescriptor {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:width,height:height,mipmapped:false)
            color.usage = .renderTarget; color.storageMode = .private
            let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:width,height:height,mipmapped:false)
            depth.usage = .renderTarget; depth.storageMode = .private
            guard let colorTexture = device.makeTexture(descriptor:color), let depthTexture = device.makeTexture(descriptor:depth) else {
                throw CocoaError(.featureUnsupported)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colorTexture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
            return pass
        }
        let mainPass = try target(width:1440,height:900)
        let rearPass = try target(width:360,height:96)
        let mainViewport = CGRect(x:0,y:0,width:1440,height:900)
        let rearViewport = CGRect(x:0,y:0,width:360,height:96)
        var wall: [Double] = [], gpu: [Double] = []
        let dt = 1.0/240
        let clock = ProcessInfo.processInfo
        let started = clock.systemUptime
        for frame in 0..<(frames+120) {
            try autoreleasepool {
                let begin = clock.systemUptime
                var input = DrivingInput()
                for _ in 0..<2 {
                    let location = circuit.nearest(to:player.position)
                    input = ComputerDriver.input(for:player,at:location,circuit:circuit,line:world.racingLine,
                                                 pace:0.82,traffic:traffic.cars.map(\.vehicle))
                    player.step(dt,input:input,assists:DrivingAssists(),roadDistance:location.distance,roadWidth:circuit.width,
                                roadContacts:circuit.wheelContacts(at:player.contactPoints),
                                wake:AirWake.behind(player,leaders:traffic.cars.map(\.vehicle)))
                    _ = traffic.step(dt,player:&player,circuit:circuit,line:world.racingLine)
                }
                let cars = traffic.cars.map(\.vehicle)
                world.updateTraffic(cars)
                world.updateSpray(player:player,opponents:cars,cockpit:true,active:true)
                world.update(vehicle:player,input:input,dt:2*dt,cockpit:true,ghost:nil)
                guard let command = queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
                let time = Double(frame)*2*dt
                if frame.isMultiple(of:8) {
                    mirror.render(atTime:time,viewport:rearViewport,commandBuffer:command,passDescriptor:rearPass)
                }
                renderer.render(atTime:time,viewport:mainViewport,commandBuffer:command,passDescriptor:mainPass)
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else { throw command.error ?? CocoaError(.featureUnsupported) }
                if frame >= 120 {
                    wall.append((clock.systemUptime-begin)*1000)
                    if command.gpuEndTime > command.gpuStartTime {
                        gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
                    }
                }
            }
        }
        let elapsed = clock.systemUptime-started
        print("Offscreen 1440×900 · \(circuit.condition.label) · \(quality.title) · \(device.name) · \(frames) completed commands")
        print("CPU+GPU serial wall: " + FrameMeasurements.describe(wall,elapsed:wall.reduce(0,+)/1000,frames:wall.count,rateLabel:"commands/s"))
        print("GPU time: " + FrameMeasurements.describe(gpu,elapsed:gpu.reduce(0,+)/1000,frames:gpu.count,rateLabel:"commands/s"))
        print(String(format:"%.1fs real · %.1f m simulated",elapsed,player.distanceTravelled))
        check(wall.count == frames && gpu.count == frames && player.distanceTravelled > 1,
              "Every command rendered and completed while the four-car session was moving")
        if failures > 0 { exit(1) }
    }

    static func reviewController() {
        let input = InputManager()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:200),
                              styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "APEX Lab · Xbox 手柄验收"
        let label = NSTextField(wrappingLabelWithString:"依次操作左右摇杆、RT / LT、A、B、X、Y 和 Menu。确认震动后，关闭手柄再重新连接。")
        label.frame = NSRect(x:24,y:64,width:472,height:72)
        label.font = .systemFont(ofSize:17)
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps:true)
        GCController.shouldMonitorBackgroundEvents = true
        var observed: Set<String> = []
        var previousConnected = false
        func report(_ message: String) {
            guard observed.insert(message).inserted else { return }
            print(message)
            fflush(stdout)
        }
        input.onAction = { action in report("Action: " + action) }
        let timer = Timer.scheduledTimer(withTimeInterval:1.0/60, repeats:true) { _ in
            let connected = input.controller != nil
            if connected && !previousConnected {
                if observed.contains("Controller connected") {
                    report("Controller reconnected")
                } else {
                    report("Controller connected")
                    report("Haptics: " + input.hapticStatus)
                    DispatchQueue.main.asyncAfter(deadline:.now()+3) {
                        report(input.testHaptics() ? "Haptic test started" : "Haptic test unavailable")
                        if let error = input.hapticError { report("Haptic detail: " + error) }
                    }
                }
            }
            previousConnected = connected
            let state = input.read(dt:1.0/60,deadzone:0.08)
            if state.throttle > 0.7 { report("RT throttle") }
            if state.brake > 0.7 { report("LT brake") }
            if state.steering < -0.7 { report("Left stick left") }
            if state.steering > 0.7 { report("Left stick right") }
            if abs(input.sideLook) > 0.7 { report("Right stick look") }
            input.updateHaptics(.zero,dt:1.0/60,driving:false)
        }
        RunLoop.main.run(until:Date(timeIntervalSinceNow:180))
        timer.invalidate()
        input.stopHaptics()
        window.orderOut(nil)
    }
}

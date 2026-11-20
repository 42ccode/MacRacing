import AppKit
import AVFoundation
import GameController
import Metal
import SceneKit
import simd

final class FrameMeasurements: NSObject, SCNSceneRendererDelegate {
    private let lock = NSLock()
    private var times: [Double] = []

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        record(ProcessInfo.processInfo.systemUptime)
    }

    func record(_ timestamp: Double) {
        lock.lock()
        times.append(timestamp)
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
    private static func makeReviewGame(frame: NSRect, dataDirectory: URL) -> RacingGame {
        let game = RacingGame(frame:frame,dataDirectory:dataDirectory,monitorControllers:false)
        // Keep the review silent even when it exercises saved mute and volume settings.
        game.sound.engine.mainMixerNode.outputVolume = 0
        return game
    }

    static func reviewWheelTelemetry(_ rows: [[Substring]], expectCornering: Bool) {
        let wheels = ["fr","fl","rr","rl"]
        let expected = ["applied_throttle","applied_brake","brake_steady_target","engine_throttle"]
            + wheels.map { $0+"_sliding_fraction" } + wheels.map { $0+"_lateral_force_n" }
            + wheels.map { $0+"_aligning_moment_nm" }
        guard let header = rows.first, header.suffix(expected.count).map(String.init) == expected,
              rows.count > 1 else {
            check(false,"CSV appends four sliding fractions, lateral forces and aligning moments after the control channels")
            return
        }
        let samples = rows.dropFirst()
        let readings = samples.map { $0.suffix(12).compactMap { Double($0) } }
        check(samples.allSatisfy { $0.count == header.count } && readings.allSatisfy { values in
            values.count == 12 && values.prefix(4).allSatisfy { (0...1).contains($0) }
                && values.dropFirst(4).allSatisfy { $0.isFinite }
        }, "CSV writes bounded sliding fractions, signed lateral forces and finite aligning moments for each wheel")
        if expectCornering {
            check(readings.contains { $0.count == 12 && $0.prefix(4).contains { $0 > 0.02 } && $0[4..<8].contains { $0 < -100 } },
                  "An imposed lateral velocity produces tread sliding and an opposing recorded tyre force")
            check(readings.contains { $0.suffix(4).contains { abs($0) > 0.1 } },
                  "A cornering run exports measurable pneumatic aligning torque")
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
        let skipController = flags.contains("--skip-controller")
        let controllerModes = ["--controller", "--cup-live", "--endurance-live", "--fleet-drive", "--qualifying-live"]
        if skipController, let mode = controllerModes.first(where: { flags.contains($0) }) {
            fputs("Cannot run \(mode) with --skip-controller.\n",stderr)
            exit(2)
        }
        let quality: GraphicsQuality = flags.contains("--graphics-performance") ? .performance :
            (flags.contains("--graphics-balanced") ? .balanced : .quality)
        if CommandLine.arguments.contains("--controller") {
            reviewController()
            return
        }
        if CommandLine.arguments.contains("--menus") {
            try reviewMenus(skipController:skipController)
            return
        }
        if flags.contains("--race-weekend") || flags.contains("--race-weekend-live") {
            try reviewRaceWeekend(live:flags.contains("--race-weekend-live"),hidden:flags.contains("--hidden"),
                                  checkReplayAudio:flags.contains("--replay-audio"))
            return
        }
        if flags.contains("--cups") {
            try reviewCups()
            return
        }
        if flags.contains("--cup-live") {
            let series = flags.first { $0.hasPrefix("--series=") }.flatMap { CupSeries(rawValue:String($0.dropFirst(9))) }
            try reviewCupLive(series:series ?? .club,hidden:flags.contains("--hidden"))
            return
        }
        if flags.contains("--endurance-live") || flags.contains("--auto-endurance") {
            let id = flags.first { $0.hasPrefix("--car=") }.flatMap { Int($0.dropFirst(6)) }
            let drying = flags.contains("--drying")
            try reviewEndurance(wet:flags.contains("--wet") || drying,drying:drying,
                                vehicle:id.flatMap(VehicleKind.init(rawValue:)) ?? .porsche,
                                quality:quality,fps60:flags.contains("--fps60"),hidden:flags.contains("--hidden"),
                                assisted:flags.contains("--auto-endurance"))
            return
        }
        if flags.contains("--fleet-drive") {
            try reviewFleetDrive()
            return
        }
        if flags.contains("--school") {
            try reviewSchool()
            return
        }
        if flags.contains("--race-pit") {
            try reviewRacePit()
            return
        }
        if flags.contains("--race-drying") {
            try reviewRaceDrying()
            return
        }
        if flags.contains("--viewport-review") {
            try reviewViewport(hidden:flags.contains("--hidden"))
            return
        }
        if let index = flags.firstIndex(of:"--session-soak"), flags.indices.contains(index+1),
           let minutes = Double(flags[index+1]), (1...45).contains(minutes) {
            try reviewSessionTransitions(seconds:minutes*60,fps60:flags.contains("--fps60"))
            return
        }
        if flags.contains("--qualifying") || flags.contains("--qualifying-live") {
            try reviewQualifying(live:flags.contains("--qualifying-live"))
            return
        }
        if flags.contains("--corner-analysis") {
            try reviewCornerAnalysis()
            return
        }
        if flags.contains("--two-car-save") {
            try reviewTwoCarSave()
            return
        }
        if flags.contains("--save-recovery") {
            try reviewSaveRecovery(skipController:skipController)
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
                                   vehicle:id.flatMap(VehicleKind.init(rawValue:)) ?? (flags.contains("--porsche") ? .porsche : .centenario))
            return
        }
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/training-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:dataFolder) }
        let game=makeReviewGame(frame:NSRect(x:0,y:0,width:1100,height:718),dataDirectory:dataFolder)
        game.hasStarted=true;game.isPaused=true
        game.vehicle.kind = .centenario;game.world.selectVehicle(.centenario)
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
        let centenarioTyres = game.tyreSetup
        let centenarioBias = game.assists.frontBrakeBias
        check(game.vehicle.wheels[0].setup != centenarioTyres, "New tyre settings remain pending on the fitted tyres")
        game.action("vehicleNext")
        check(game.vehicle.kind == .porsche && game.session.best != base.best,"Switching car does not reuse another car's best")
        check(game.tyreSetup != centenarioTyres && game.assists.automatic && game.assists.absLevel == 3 &&
              game.assists.brakeCurve == .progressive && game.assists.steeringCurve == .standard,
              "Switching cars restores its own tyres, assists and transmission")
        game.session=other
        game.action("trackNext")
        check(game.session.best==nil,"New track does not reuse the old track's reference")
        for _ in 1..<CircuitKind.allCases.count {game.action("trackNext")}
        check(abs((game.session.best ?? 0)-50)<0.001,"Returning to track restores its own personal best")
        game.action("vehiclePrevious")
        check(abs((game.session.best ?? 0)-60)<0.001,"Returning to car restores its own personal best")
        check(game.tyreSetup == centenarioTyres && game.vehicle.wheels[0].setup == centenarioTyres &&
              game.assists.absLevel == 4 && game.assists.tcLevel == 4 && !game.assists.automatic &&
              game.assists.frontBrakeBias == centenarioBias && game.assists.brakeCurve == .deep && game.assists.steeringCurve == .precision,
              "Switching back fits the chosen tyres and restores the Centenario setup")
        let reload=makeReviewGame(frame:game.hud.frame,dataDirectory:dataFolder)
        check(reload.vehicle.kind == .centenario && reload.circuit.kind == .north && abs((reload.session.best ?? 0)-60)<0.001,"Relaunch restores selected vehicle, circuit and record")
        check(reload.session.bestSectors.count==3 && !reload.session.bestTrace.isEmpty && !reload.session.bestGhost.isEmpty,"Relaunch restores sectors, distance reference and ghost together")
        check(reload.tyreSetup == centenarioTyres && reload.vehicle.wheels[0].setup == centenarioTyres &&
              reload.assists.frontBrakeBias == centenarioBias && reload.assists.brakeCurve == .deep && reload.assists.steeringCurve == .precision,
              "Relaunch restores the same setup and fits the chosen tyres")
        game.action("trackCondition")
        check(game.circuit.condition == .wet && game.session.best == nil && game.traffic.cars.allSatisfy {
            $0.vehicle.wheels.allSatisfy { $0.setup.compound == .wet }
        }, "Wet practice starts separately and rivals fit rain tyres")
        game.session = other
        game.action("trackCondition")
        check(game.circuit.condition == .dry && game.session.best == base.best, "Dry best lap survives switching conditions")
        game.action("trackCondition")
        let wetReload = makeReviewGame(frame:game.hud.frame,dataDirectory:dataFolder)
        check(wetReload.circuit.condition == .wet && wetReload.session.best == other.best,
              "Relaunch restores the wet session and its independent best lap")
        game.action("trackCondition")
        let tempRace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:tempRace) }
        let sprintGame = makeReviewGame(frame:game.hud.frame,dataDirectory:tempRace)
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
        if !skipController {
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
        legacy["brakeBiasByVehicle"] = [String(VehicleKind.centenario.rawValue): 0.66,
                                       String(VehicleKind.porsche.rawValue): 0.59]
        try JSONSerialization.data(withJSONObject:legacy).write(to:settings,options:.atomic)
        let migratedV9 = makeReviewGame(frame:game.hud.frame,dataDirectory:dataFolder)
        check(migratedV9.session.best == base.best && migratedV9.tyreSetup == centenarioTyres &&
              migratedV9.assists.frontBrakeBias == 0.66 && migratedV9.practiceAnalysis.history.isEmpty,
              "Version 9 keeps its best lap and migrates existing settings without fabricating inputs")
        migratedV9.action("vehicleNext")
        check(migratedV9.tyreSetup == centenarioTyres && migratedV9.assists.frontBrakeBias == 0.59,
              "Version 9 global settings seed each car while existing brake bias stays per car")
        let backupV9 = try JSONDecoder().decode(SavedPractice.self,
            from:Data(contentsOf:dataFolder.appendingPathComponent("practice-before-2.0.json")))
        check(backupV9.version == 9, "Version 9 is backed up before conversion")
        legacy["version"]=8;legacy.removeValue(forKey:"records");legacy.removeValue(forKey:"vehicleSettings")
        legacy["automatic"]=false;legacy["absLevel"]=2
        try JSONSerialization.data(withJSONObject:legacy).write(to:settings,options:.atomic)
        let migrated=makeReviewGame(frame:game.hud.frame,dataDirectory:dataFolder)
        check(!migrated.assists.automatic && migrated.assists.absLevel==2 && migrated.session.best==nil,"Legacy migration keeps driving preferences without inventing a distance reference")
        migrated.action("mute")
        let backup=try JSONSerialization.jsonObject(with:Data(contentsOf:dataFolder.appendingPathComponent("practice-before-1.6.json"))) as! [String:Any]
        let updated=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! [String:Any]
        check(backup["version"] as? Int==8 && updated["version"] as? Int==10,"First save preserves the legacy practice file before writing the new schema")
        var saved = try JSONDecoder().decode(SavedPractice.self, from: currentData)
        var analysis = PracticeAnalysis()
        let referenceLap = other.analysedLap!
        let legacyInputs = stride(from:0,to:referenceLap.inputs.count,by:4).map { i in
            let input = referenceLap.inputs[i]
            return LapInputs(DrivingInput(throttle:input.throttle,brake:input.brake,steering:input.steering),
                             speedKPH:input.speedKPH,linePressure:input.linePressure)
        }
        analysis.append(AnalysedLap(summary:referenceLap.summary,inputs:legacyInputs))
        for _ in 0..<13 { analysis.append(base.analysedLap!) }
        let analysisKey = LapRecord.key(vehicle:.centenario,circuit:.north)
        let wetReference = reference(speed:22)
        saved.analysis = [analysisKey: analysis]
        saved.records?[analysisKey] = other.record
        saved.records?[LapRecord.key(vehicle:.centenario,circuit:.north,condition:.wet)] = wetReference.record
        saved.records?[LapRecord.key(vehicle:.porsche,circuit:.north)] = base.record
        try JSONEncoder().encode(saved).write(to:settings,options:.atomic)
        let analysisGame = makeReviewGame(frame:NSRect(x:0,y:0,width:1100,height:740),dataDirectory:dataFolder)
        let analysisWindow = NSWindow(contentRect:analysisGame.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        analysisWindow.contentView = analysisGame.hud
        check(analysisGame.practiceAnalysis.history.count == 14 && analysisGame.practiceAnalysis.fastest?.summary.time == other.best,
              "Analysis survives app reload with the correct car and track")
        let garageCar = analysisGame.vehicle.kind
        let garageCondition = analysisGame.circuit.condition
        analysisGame.action("raceHistory")
        analysisGame.action("historyBests")
        check(analysisGame.bestPracticeLap(at:.north)?.time == other.best &&
              analysisGame.bestPracticeLap(at:.north)?.sectors.count == 3,
              "Driving records read the saved practice time and three sectors")
        analysisGame.action("bestsWet")
        check(analysisGame.bestPracticeLap(at:.north)?.time == wetReference.best,"Practice bests isolate wet and dry lap records")
        analysisGame.action("bestsDry")
        analysisGame.action("bestsNextCar")
        check(analysisGame.bestPracticeLap(at:.north)?.time == base.best && analysisGame.vehicle.kind == garageCar &&
              analysisGame.circuit.condition == garageCondition,"Record filters neither change the garage nor mix cars")
        analysisGame.action("bestsPreviousCar")
        check(analysisGame.bestPracticeLap(at:.north)?.time == other.best,"Browsing back recovers the same record")
        let recordsImage = NSImage(size:analysisGame.hud.bounds.size)
        recordsImage.lockFocusFlipped(true)
        analysisGame.hud.draw(analysisGame.hud.bounds)
        recordsImage.unlockFocus()
        let recordsPNG = NSBitmapImageRep(data:recordsImage.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try recordsPNG.write(to:output.appendingPathComponent("practice-records.png"))
        check(Set(analysisGame.hud.visibleActionFrames.map(\.1)).isSuperset(of:["historyRaces","bestsWet","bestsNextCar","closeRaceHistory"]),
              "Practice records expose filter and return buttons in the native HUD")
        analysisGame.action("menuBack")
        analysisGame.action("analysis")
        check(analysisGame.isPaused && analysisGame.showingAnalysis, "Analysis opens as a paused modal")
        let image = NSImage(size:analysisGame.hud.bounds.size)
        image.lockFocusFlipped(true)
        analysisGame.hud.draw(analysisGame.hud.bounds)
        image.unlockFocus()
        analysisGame.action("menuRight")
        check(analysisGame.hud.analysisMarker == LapInputs.intervals*51/100,"Analysis arrows move the cursor along recorded lap data")
        analysisGame.action("analysisZoom")
        let zoom = analysisGame.hud.analysisVisibleIndices
        check(zoom == 368...448 && analysisGame.practiceAnalysis.fastest?.inputs.count == 201 &&
              analysisGame.practiceAnalysis.latest?.inputs.count == 801,
              "Native analysis compares the historic and current traces inside the same 10% distance window")
        analysisGame.action("menuRight")
        check(analysisGame.hud.analysisMarker == 409,"Detailed analysis steps a single high-resolution observation")
        let detail = NSImage(size:analysisGame.hud.bounds.size)
        detail.lockFocusFlipped(true)
        analysisGame.hud.draw(analysisGame.hud.bounds)
        detail.unlockFocus()
        let detailPNG = NSBitmapImageRep(data:detail.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try detailPNG.write(to:output.appendingPathComponent("brake-detail.png"))
        for _ in 0..<100 { analysisGame.action("menuLeft") }
        check(analysisGame.hud.analysisVisibleIndices.contains(analysisGame.hud.analysisMarker ?? -1) &&
              analysisGame.hud.analysisVisibleIndices.lowerBound < zoom.lowerBound,
              "Arrow inspection follows the selected point beyond the initial zoom window")
        analysisGame.action("analysisZoom")
        check(analysisGame.hud.analysisVisibleIndices == 0...LapInputs.intervals,
              "Returning to the whole lap retains a reachable cursor")
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
        let game = makeReviewGame(frame:NSRect(x:0,y:0,width:900,height:664),dataDirectory:folder)
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
        game.input.setKey(13,pressed:true)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.07))
        let stoppedPosition = game.vehicle.position
        game.loseFocus()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.10))
        check(game.isPaused && game.input.keys.isEmpty && game.vehicle.position == stoppedPosition,
              "Losing the window freezes the car and clears held driver inputs")
    }

    static func reviewRaceWeekend(live: Bool,hidden: Bool,checkReplayAudio: Bool) throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/race-weekend-review",isDirectory:true)
        let data = root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        let audioBuffer: AVAudioPCMBuffer?
        if live && checkReplayAudio,
           let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2),
           let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:735) {
            try game.sound.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:buffer.frameCapacity)
            game.sound.engine.mainMixerNode.outputVolume = 1
            audioBuffer = buffer
        } else {
            if hidden { game.sound.muted = true }
            audioBuffer = nil
        }
        let window = NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        if live && !hidden { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        func capture(_ title: String, expected: [String],rendered: Bool = false) throws {
            let image = NSImage(size:frame.size)
            image.lockFocusFlipped(true)
            if live && (!hidden || rendered) {
                game.sceneView.snapshot().draw(in:frame,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            } else {
                NSColor(rgb:0x283449).setFill()
                frame.fill()
            }
            game.hud.draw(frame)
            image.unlockFocus()
            let items = game.hud.visibleActionFrames
            check(Set(items.map(\.1)).isSuperset(of:expected) &&
                  items.allSatisfy { frame.contains($0.0) } &&
                  !items.enumerated().contains { i,item in
                      items.dropFirst(i+1).contains { item.0.intersects($0.0) }
                  }, "\(title) has distinct, in-bounds actions at the minimum window size")
            let png = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try png.write(to:root.appendingPathComponent(title+".png"))
        }
        game.action("raceSetup")
        try capture("race-setup",expected:["raceOption:laps:8","raceOption:difficulty:2","startSprint","selectCircuit"])
        game.action("selectVehicle")
        game.action("car:"+String(VehicleKind.porsche.rawValue))
        game.action("selectCircuit")
        game.action("circuit:"+String(CircuitKind.sprint.rawValue))
        check(game.showingRaceSetup && game.vehicle.kind == .porsche && game.circuit.kind == .sprint,
              "Selection returns to the in-progress race setup")
        if !live { game.action("trackCondition") }
        game.action("raceOption:laps:"+(live ? "2" : "5"))
        game.action("raceOption:rivals:"+(live ? "1" : "2"))
        game.action("raceOption:difficulty:0")
        game.action("raceOption:grid:1")
        try capture("race-setup-configured",expected:["trackCondition","raceOption:tyres:1","closeRaceSetup"])
        check(game.hud.menuFocusAction == "startSprint","Race setup focuses grid entry for keyboard and controller")
        game.action("menuAccept")
        let originalSetup = game.raceConfiguration
        check(game.sprint?.lapCount == originalSetup.laps && game.sprint?.driverPosition == 1 &&
              game.traffic.cars.count == originalSetup.rivals && game.sprint?.countdownSeconds == 3 &&
              game.traffic.cars.allSatisfy { $0.pace < 0.82 },
              "Confirmation starts the configured pole-position race at rookie pace")
        if live {
            game.action("autoDrive")
            let deadline = Date(timeIntervalSinceNow:420)
            var finishPosition: SIMD2<Double>?
            while !game.raceResultReady && deadline.timeIntervalSinceNow > 0 {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
                if game.sprint?.playerFinished == true && !game.raceResultReady && finishPosition == nil {
                    finishPosition = game.vehicle.position
                }
            }
            check(game.sprint?.playerFinished == true && game.raceResultReady && game.isPaused &&
                  game.raceRecords.first?.place != nil && game.raceRecords.first?.bestLap != nil &&
                  game.raceRecords.first?.assisted == true,
                  "One full physical race settles automatically and retains the classified result")
            check(finishPosition.map { simd_distance($0,game.vehicle.position) > 6 } == true,
                  "The player physically rolls out after the checkered flag before results appear")
        } else {
            check(game.vehicle.wheels.allSatisfy { $0.setup.compound == .wet } && game.tyreSetup.compound != .wet,
                  "Race gets rain tyres without changing the selected garage setup")
            game.action("pause")
            game.action("askRetireRace")
            try capture("race-retire",expected:["cancelPrompt","confirmPrompt"])
            game.action("confirmPrompt")
            check(game.sprint?.finished == true && game.isPaused &&
                  game.raceRecords.count == 1 && game.raceRecords[0].place == nil,
                  "Confirmed retirement resolves the race and creates exactly one DNF record")
        }
        try capture(live ? "race-live-result" : "race-result",
                    expected:["leaveSprint","raceHistory","nextRaceSetup","raceAgain"])
        if live {
            let firstRecord = game.raceRecords.first
            let timeline = firstRecord?.lapHistory ?? []
            check(timeline.count == firstRecord?.completedLaps && timeline.allSatisfy { $0.time > 0 } &&
                  abs(timeline.reduce(0) { $0+$1.time }+(firstRecord?.penaltySeconds ?? 0)-(firstRecord?.totalTime ?? 0)) < 0.01,
                  "Official splits and penalties sum to the live classified time")
            game.action("raceLaps")
            try capture("race-laps",expected:["closeRaceLaps"])
            check(game.reviewedRaceLaps?.id == firstRecord?.id && game.hud.menuFocusAction == "closeRaceLaps",
                  "The current result opens its correct lap timeline with controller focus")
            game.action("menuBack")
            try capture("race-return-from-laps",expected:["raceLaps","openReplay"])
            check(game.canReplay && game.hud.visibleActionFrames.contains { $0.1 == "openReplay" },
                  "Completed race offers a post-race replay")
            let finalPosition = game.vehicle.position
            let records = game.raceRecords
            game.action("openReplay")
            check(game.replay.map { $0.duration > 5 && $0.duration <= 90.01 } == true,
                  "Replay opens on the retained time window")
            if let audioBuffer {
                func blockPeak() throws -> Double {
                    guard try game.sound.engine.renderOffline(audioBuffer.frameCapacity,to:audioBuffer) == .success,
                          let left = audioBuffer.floatChannelData?[0] else { return 0 }
                    return (0..<Int(audioBuffer.frameLength)).reduce(0) { max($0,abs(Double(left[$1]))) }
                }
                func hearReplay() throws -> Double {
                    var peak = 0.0
                    for _ in 0..<12 {
                        RunLoop.main.run(until:Date(timeIntervalSinceNow:1/60))
                        peak = max(peak,try blockPeak())
                    }
                    return peak
                }
                let playing = try hearReplay()
                game.action("replayPlay")
                _ = try hearReplay()
                let paused = try blockPeak()
                game.action("replayPlay")
                let resumed = try hearReplay()
                game.action("replayRate")
                _ = try hearReplay()
                let accelerated = try blockPeak()
                game.action("replayRate")
                game.action("replayRate")
                print(String(format:"Replay peak playing %.3f, paused %.6f, resumed %.3f, 2× %.6f",playing,paused,resumed,accelerated))
                check(playing > 0.01 && resumed > 0.01 && paused < 1e-6 && accelerated < 1e-6,
                      "The native replay publishes audible recordings in normal time and fades on pause or speed change")
            }
            game.seekReplay(fraction:0.4)
            check(game.replay.map { !$0.isPlaying && abs($0.fraction-0.4) < 1e-9 } == true,
                  "Scrubbing seeks within the replay without advancing race state")
            game.action("replayRate")
            game.action("replayCamera")
            game.action("replayLater")
            check(game.replay?.rate == .double && game.replayView == .chaseFar && (game.replay?.fraction ?? 0) > 0.4,
                  "Playback speed, camera and skip controls work independently")
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.10))
            try capture("race-replay",expected:["replayPlay","replayRate","closeReplay"])
            for _ in ReplayViewpoint.allCases where game.replayView != .cockpit { game.action("replayCamera") }
            let mirrors = VehicleMirror.allCases.filter { game.world.hasMirror($0) }
            func waitForMirrors() {
                let deadline = Date(timeIntervalSinceNow:3)
                while deadline.timeIntervalSinceNow > 0 &&
                      (game.sceneView.pointOfView !== game.world.camera || mirrors.contains { !game.world.mirrorHasImage($0) }) {
                    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
                }
            }
            waitForMirrors()
            print("Replay mirror textures \(mirrors.map { String(describing:$0)+":"+(game.world.mirrorHasImage($0) ? "ready" : "missing") }.joined(separator:", "))")
            check(game.replayView == .cockpit && game.sceneView.pointOfView === game.world.camera &&
                  !mirrors.isEmpty && mirrors.allSatisfy { game.world.mirrorHasImage($0) },
                  "A paused cockpit replay shows rear views on the actual car's mirror surfaces")
            let pausedReplayTime = game.replay?.time
            let facing = game.world.camera.simdWorldFront
            game.input.keys.insert(38)
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
            game.input.keys.remove(38)
            check(simd_dot(facing,game.world.camera.simdWorldFront) < 0.92 && game.replay?.time == pausedReplayTime,
                  "Looking into a side mirror does not move the replay cursor")
            try capture("race-replay-left-mirror",expected:["replayPlay","replayCamera","closeReplay"],rendered:true)
            let previousCentre = game.mirrorImage?.tiffRepresentation
            game.seekReplay(fraction:0.8)
            waitForMirrors()
            check(game.replay?.isPlaying == false && mirrors.allSatisfy { game.world.mirrorHasImage($0) } &&
                  (!mirrors.contains(.centre) || (game.mirrorImage?.tiffRepresentation != nil &&
                                                  game.mirrorImage?.tiffRepresentation != previousCentre)),
                  "Seeking rebuilds the stationary cockpit mirrors from the new moment")
            check(game.replayFrame?.time == game.replay?.time &&
                  game.replayFrame.map { (0...1).contains($0.controls.brakeTravel) &&
                                         (0...1).contains($0.controls.linePressure) && $0.player.speedKPH > 0 } == true,
                  "Paused seeking publishes corresponding speed, travel and pressure for the replay display")
            try capture("race-replay-cockpit",expected:["replayPlay","replayCamera","closeReplay"],rendered:true)
            var brakingFrame: RaceReplay.Frame?
            for fraction in stride(from:0.14,through:0.94,by:0.02) {
                game.seekReplay(fraction:fraction)
                if let frame = game.replayFrame,
                   frame.controls.brakeTravel > 0.15,
                   frame.controls.linePressure+0.05 < frame.controls.brakeTravel,
                   frame.player.speedKPH > 30 {
                    brakingFrame = frame
                    break
                }
            }
            check(brakingFrame != nil,"Physical braking footage distinguishes pedal travel from actual line pressure")
            if let brakingFrame {
                waitForMirrors()
                print(String(format:"Paused braking %.1f km/h · travel %.1f%% · line %.1f%%",
                             brakingFrame.player.speedKPH,brakingFrame.controls.brakeTravel*100,brakingFrame.controls.linePressure*100))
                try capture("race-replay-braking",expected:["replayPlay","replayCamera","closeReplay"],rendered:true)
            }
            game.action("menuBack")
            check(game.replay == nil && game.replayFrame == nil && game.vehicle.position == finalPosition && game.raceRecords == records &&
                  mirrors.allSatisfy { !game.world.mirrorHasImage($0) },
                  "Closing replay returns to an unchanged official result")
        }
        game.action("raceHistory")
        try capture("race-history",expected:["closeRaceHistory"])
        if live, let record = game.raceRecords.first {
            let action = "viewRaceLaps:"+record.id.uuidString
            check(game.hud.visibleActionFrames.contains { $0.1 == action },"Race history exposes saved lap details")
            game.action(action)
            check(game.reviewedRaceLaps == record,"Historical lap details reference the same official record")
            game.action("menuBack")
        }
        game.action("menuBack")
        check(!game.showingRaceHistory && game.sprint?.finished == true,
              "Backing out of race history returns to the result")
        game.action("raceAgain")
        check(game.sprint?.countdownSeconds == 3 && !game.isPaused && game.raceRecords.count == 1 &&
              game.activeRaceConfiguration == originalSetup && !game.canReplay,
              "Rematch reapplies the setup, keeps the result, and clears previous footage")
        game.action("pause")
        game.action("askRetireRace")
        game.action("confirmPrompt")
        game.action("nextRaceSetup")
        check(game.showingRaceSetup && !game.hasStarted && game.sprint == nil,
              "Next race leads to setup with an idle world")
        game.shutdown()
        let restored = makeReviewGame(frame:frame,dataDirectory:data)
        check(restored.raceConfiguration == originalSetup && restored.raceRecords.count == 2 &&
              Set(restored.raceRecords.map(\.id)).count == 2 && restored.circuit.kind == .sprint && restored.vehicle.kind == .porsche,
              "Reload restores the race setup and both unique results")
        restored.shutdown()
        if failures > 0 { exit(1) }
    }

    static func reviewCups() throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/cup-review",isDirectory:true)
        let data = folder.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        func checkHUD(_ title: String, expected: [String]) throws {
            let image = NSImage(size:frame.size)
            image.lockFocusFlipped(true)
            NSColor(rgb:0x283449).setFill()
            frame.fill()
            game.hud.draw(frame)
            image.unlockFocus()
            let actions = game.hud.visibleActionFrames
            check(Set(actions.map(\.1)).isSuperset(of:expected) && actions.allSatisfy { frame.contains($0.0) } &&
                  !actions.enumerated().contains { i,item in actions.dropFirst(i+1).contains { item.0.intersects($0.0) } },
                  "\(title) keeps all controls reachable on a 900 × 664 window")
            let picture = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try picture.write(to:folder.appendingPathComponent(title+".png"))
        }
        let originalCircuit = game.circuit.kind, originalCar = game.vehicle.kind
        game.action("cups")
        try checkHUD("cup-selection",expected:["cup:club","cup:rain","cup:speed","startCupRound"])
        game.action("cup:rain")
        game.action("startCupRound")
        check(game.activeCup == CupEntry(series:.rain,roundIndex:0) && game.circuit.condition == .wet &&
              game.circuit.kind == .sprint && game.vehicle.kind == .porsche &&
              game.vehicle.wheels.allSatisfy { $0.setup.compound == .wet },
              "Rain Cup overrides the race route and fits the proper tyres")
        game.action("autoDrive")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:3.14))
        check(game.sprint?.assisted == true,"Auto-driving during the green flag marks this cup attempt")
        game.action("pause")
        game.action("askRetireRace")
        game.action("confirmPrompt")
        check(game.sprint?.finished == true && game.cupProgress(.rain).records.isEmpty && !game.cupRoundRecorded,
              "An assisted cup attempt remains replayable and does not award cup progress")
        game.action("raceAgain")
        game.action("pause")
        game.action("askRetireRace")
        game.action("confirmPrompt")
        check(game.cupRoundRecorded && game.cupProgress(.rain).records.count == 1 &&
              game.cupProgress(.rain).points == 0,
              "A manual retirement advances a zero-point round once")
        try checkHUD("cup-result",expected:["cupContinue","leaveSprint"])
        game.action("cupContinue")
        check(game.showingCupMenu && game.selectedCup == .rain && !game.hasStarted &&
              game.vehicle.kind == originalCar && game.circuit.kind == originalCircuit,
              "Cup results return to the next round while restoring garage and practice selections")
        try checkHUD("cup-standings",expected:["startCupRound","closeCupMenu"])
        game.action("startCupRound")
        game.action("pause")
        try checkHUD("cup-pause",expected:["askRetireRace","askLeavePractice"])
        game.action("askLeavePractice")
        game.action("confirmPrompt")
        check(game.showingCupMenu && game.selectedCup == .rain && game.activeCup == nil &&
              game.cupProgress(.rain).records.count == 1 && game.raceRecords.count == 2,
              "Leaving an unfinished cup round preserves the standings and omits the cancelled attempt")
        game.shutdown()
        let restored = makeReviewGame(frame:frame,dataDirectory:data)
        check(restored.cupProgress(.rain).records.count == 1 && restored.raceRecords.count == 2 &&
              restored.vehicle.kind == originalCar && restored.circuit.kind == originalCircuit,
              "Cup standings and garage selections reload from the same practice save")
        restored.shutdown()
        if failures > 0 { exit(1) }
    }

    private static func setDriverInput(_ pad: GCExtendedGamepad,_ command: DrivingInput,deadzone: Double) {
        let steering = command.steering == 0 ? 0 : copysign(abs(command.steering)*(1-deadzone)+deadzone,command.steering)
        pad.leftThumbstick.setValueForXAxis(Float(steering),yAxis:0)
        pad.rightTrigger.setValue(Float(command.throttle))
        pad.leftTrigger.setValue(Float(command.brake))
    }

    static func reviewFleetDrive() throws {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let data = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/fleet-drive",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        defer { game.shutdown() }
        let window = NSWindow(contentRect:frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = game.sceneView
        let format = AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
        let audio = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:368)!
        try game.sound.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:audio.frameCapacity)
        game.sound.engine.mainMixerNode.outputVolume = 1
        let controller = GCController.withExtendedGamepad()
        let pad = controller.extendedGamepad!
        game.input.selectController(controller)
        game.action("opponents")
        game.action("viewCabin")
        let circuits = CircuitKind.allCases
        for (index,kind) in VehicleKind.allCases.enumerated() {
            let venue = circuits[index%circuits.count]
            let wet = index.isMultiple(of:2)
            game.action("selectVehicle")
            game.action("car:"+String(kind.rawValue))
            game.action("selectCircuit")
            game.action("circuit:"+String(venue.rawValue))
            if (game.circuit.condition == .wet) != wet { game.action("trackCondition") }
            game.tyreSetup = TyreSetup(compound:wet ? .wet : .medium)
            let mirrors = VehicleMirror.allCases.filter { game.world.hasMirror($0) }
            var steps = 0, audible = 0, out = 0
            var peak = 0.0, speed = 0.0, pressure = 0.0
            var rearViews = Set<VehicleMirror>()
            game.inspectDrivingTick = { [weak game] tick in
                guard let game, !game.isPaused else { return }
                steps += tick.physicsSteps
                if game.vehicle.allWheelsOutside { out += 1 }
                speed = max(speed,game.vehicle.speedKPH)
                pressure = max(pressure,game.vehicle.brakeLinePressure)
                for mirror in mirrors where game.world.mirrorHasImage(mirror) { rearViews.insert(mirror) }
                let command = ComputerDriver.input(for:game.vehicle,at:game.location,circuit:game.circuit,
                    line:game.world.racingLine,pace:0.77,brakeCurve:game.assists.brakeCurve,
                    steeringCurve:game.assists.steeringCurve)
                setDriverInput(pad,command,deadzone:game.assists.steeringDeadzone)
                if game.sound.engine.isRunning,
                   (try? game.sound.engine.renderOffline(audio.frameCapacity,to:audio)) == .success,
                   let first = audio.floatChannelData?[0] {
                    audible += 1
                    for index in 0..<Int(audio.frameLength) { peak = max(peak,abs(Double(first[index]))) }
                }
            }
            let began = ProcessInfo.processInfo.systemUptime
            game.action("start")
            RunLoop.main.run(until:Date(timeIntervalSinceNow:30))
            let elapsed = ProcessInfo.processInfo.systemUptime-began
            game.inspectDrivingTick = nil
            let rate = Double(steps)/elapsed
            print(String(format:"%@ · %@ %@ · %.1f steps/s · %.1f km/h · peak pressure %.1f%% · mirrors %d/%d · audio %.3f",
                         kind.label,venue.label,game.circuit.condition.label,rate,speed,pressure*100,rearViews.count,mirrors.count,peak))
            check(game.vehicle.kind == kind && game.circuit.kind == venue && rate > 228 && speed > 50 && out == 0 &&
                  !game.autoDriveEnabled && !mirrors.isEmpty && rearViews.count == mirrors.count && audible > 100 && peak > 0.01,
                  "A virtual controller drives the native cockpit, with all authored mirrors and offline audio")
            setDriverInput(pad,DrivingInput(),deadzone:game.assists.steeringDeadzone)
            game.action("pause")
            game.action("leavePractice")
        }
        withExtendedLifetime((window,controller)) {}
        if failures > 0 { exit(1) }
    }

    static func reviewCupLive(series: CupSeries,hidden: Bool) throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/live-cup-review",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let frame = NSRect(x:0,y:0,width:1120,height:720)
        let game = makeReviewGame(frame:frame,dataDirectory:root)
        if hidden { game.sound.muted = true }
        let window = NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        if !hidden { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        let controller = GCController.withExtendedGamepad()
        let pad = controller.extendedGamepad!
        game.input.selectController(controller)
        game.action("cups")
        game.action("cup:"+series.rawValue)
        var totals: [Int] = []
        var sawTimedGap = false
        for (index,round) in series.rounds.enumerated() {
            game.action("startCupRound")
            check(game.activeCup == CupEntry(series:series,roundIndex:index) &&
                  game.vehicle.kind == round.vehicle && game.circuit.kind == round.circuit,
                  "Live cup enters the correct vehicle and circuit for round \(index+1)")
            var plan = PassingPlan()
            var previous = ProcessInfo.processInfo.systemUptime
            var firstTimedGap: Double?
            game.inspectDrivingTick = { [weak game] tick in
                guard let game, !game.isPaused, game.sprint?.playerDone == false else { return }
                if firstTimedGap == nil, case let .timed(seconds) = game.sprint?.driverGapAhead { firstTimedGap = seconds }
                let dt = max(0,tick.timestamp-previous)
                previous = tick.timestamp
                let field = game.traffic.cars.map(\.vehicle)
                plan.update(dt,car:game.vehicle,location:game.location,circuit:game.circuit,
                            line:game.world.racingLine,baseLane:0,pace:0.82,traffic:field)
                let command = ComputerDriver.input(for:game.vehicle,at:game.location,circuit:game.circuit,
                    line:game.world.racingLine,pace:0.82,lane:plan.lane,traffic:field,
                    brakeCurve:game.assists.brakeCurve,steeringCurve:game.assists.steeringCurve)
                setDriverInput(pad,command,deadzone:game.assists.steeringDeadzone)
            }
            let expires = Date(timeIntervalSinceNow:430)
            while !game.raceResultReady && expires.timeIntervalSinceNow > 0 {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
            }
            game.inspectDrivingTick = nil
            setDriverInput(pad,DrivingInput(),deadzone:game.assists.steeringDeadzone)
            let progress = game.cupProgress(series)
            let record = progress.records.last
            print("Round \(index+1) · P\(record?.place ?? 0) · \(record?.completedLaps ?? 0)/\(round.configuration.laps) laps · \(lapTime(record?.totalTime)) · \(progress.points) pts")
            if let firstTimedGap {
                sawTimedGap = true
                print(String(format:"First matched checkpoint gap %.3f s",firstTimedGap))
            }
            check(progress.records.count == index+1 && game.raceResultReady && game.cupRoundRecorded &&
                  record?.place != nil && record?.assisted == false &&
                  (record?.completedLaps == round.configuration.laps || record?.lappedFinish == true),
                  "A real unassisted physical result scores once in round \(index+1)")
            if failures > 0 { game.shutdown(); exit(1) }
            totals.append(progress.points)
            game.action("cupContinue")
        }
        let score = game.cupProgress(series)
        check(sawTimedGap,"A physical cup race measures a gap at a checkpoint crossed by both drivers")
        check(score.records.count == 3 && score.bestPoints == totals.last && score.points >= 9 &&
              game.showingCupMenu,"The third real result produces final standings and a saved best score")
        game.shutdown()
        let restored = makeReviewGame(frame:frame,dataDirectory:root)
        check(restored.cupProgress(series) == score && restored.raceRecords.count == 3,
              "All three physical standings survive a full reload")
        restored.shutdown()
        withExtendedLifetime(controller) {}
        if failures > 0 { exit(1) }
    }

    static func reviewEndurance(wet: Bool,drying: Bool,vehicle: VehicleKind,quality: GraphicsQuality,fps60: Bool,hidden: Bool,assisted: Bool) throws {
        setlinebuf(stdout)
        let data = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/endurance-review",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:1440,height:900)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        if hidden { game.sound.muted = true }
        game.action("selectVehicle")
        game.action("car:"+String(vehicle.rawValue))
        game.action("selectCircuit")
        game.action("circuit:"+String(CircuitKind.grand.rawValue))
        if wet { game.action("trackCondition") }
        game.action("settings")
        game.action("settings:display")
        game.action("choice:antialiasing")
        game.action("setChoice:"+String(quality.rawValue))
        if fps60 { game.action("renderingRate") }
        game.action("menuBack")
        let window = NSWindow(contentRect:frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "APEX Lab · Endurance Review"
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        if !hidden { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        let measurements = FrameMeasurements()
        game.sceneView.delegate = measurements
        let controller = assisted ? nil : GCController.withExtendedGamepad()
        if let controller { game.input.selectController(controller) }
        game.action("raceSetup")
        game.action("raceOption:laps:8")
        game.action("raceOption:grid:1")
        game.action("raceOption:difficulty:0")
        if drying { game.action("raceOption:surface:1") }
        game.action("startSprint")
        if assisted { game.action("autoDrive") }
        game.action("viewCabin")
        let clock = ProcessInfo.processInfo
        let started = clock.systemUptime
        var lapStarted = started, previous = started
        var steps = 0, sceneUpdates = 0
        var mirrorsDrew = false
        var plan = PassingPlan()
        let pace = 0.86
        game.inspectDrivingTick = { [weak game] tick in
            guard let game, !game.isPaused else { return }
            steps += tick.physicsSteps
            if tick.sceneUpdated { sceneUpdates += 1 }
            if game.mirrorImage != nil { mirrorsDrew = true }
            let dt = max(0,tick.timestamp-previous)
            previous = tick.timestamp
            guard let pad = controller?.extendedGamepad, game.sprint?.playerDone == false else { return }
            let field = game.traffic.cars.map(\.vehicle)
            plan.update(dt,car:game.vehicle,location:game.location,circuit:game.circuit,
                        line:game.world.racingLine,baseLane:0,pace:pace,traffic:field)
            let controls = ComputerDriver.input(for:game.vehicle,at:game.location,circuit:game.circuit,
                line:game.world.racingLine,pace:pace,lane:plan.lane,traffic:field,
                brakeCurve:game.assists.brakeCurve,steeringCurve:game.assists.steeringCurve)
            setDriverInput(pad,controls,deadzone:game.assists.steeringDeadzone)
        }
        var completed = 0
        let timeLimit = 1200.0
        let surface = drying ? "雨后渐干" : game.circuit.condition.label
        print("\(game.circuit.kind.label) · \(vehicle.label) · \(surface) · \(game.renderingRate.title) · \(game.graphicsQuality.title)")
        while !game.raceResultReady && clock.systemUptime-started < timeLimit {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.25))
            guard let entry = game.sprint?.entries[0], entry.laps > completed else { continue }
            completed = entry.laps
            let elapsed = clock.systemUptime-lapStarted
            lapStarted += elapsed
            let times = measurements.take()
            let intervals = zip(times.dropFirst(),times).map { ($0-$1)*1000 }
            let maximumBrakeC = game.vehicle.wheels.map(\.brakeTemperature).max() ?? 0
            let peakWear = game.vehicle.wheels.map(\.wear).max() ?? 0
            let film = game.vehicle.wheels.reduce(0) { $0+$1.waterFilm }/4
            print(String(format:"Lap %d · %.1f steps/s · %.1f scene updates/s · brakes %.0f °C · wear %.2f%% · film %.3f mm",
                         completed,Double(steps)/elapsed,Double(sceneUpdates)/elapsed,maximumBrakeC,peakWear*100,film))
            if !hidden {
                print(FrameMeasurements.describe(intervals,elapsed:elapsed,frames:times.count,rateLabel:"callbacks/s"))
            }
            steps = 0
            sceneUpdates = 0
        }
        game.inspectDrivingTick = nil
        if let pad = controller?.extendedGamepad { setDriverInput(pad,DrivingInput(),deadzone:game.assists.steeringDeadzone) }
        guard let race = game.sprint, let record = game.raceRecords.first else {
            check(false,"The endurance event produces an official result before its deadline")
            game.shutdown()
            exit(1)
        }
        check(race.finished && race.playerFinished && record.completedLaps == 8 && record.assisted == assisted && record.bestLap != nil,
              "Eight physical laps finish with the correct driving-assistance classification")
        check(record.penaltySeconds == 0 && race.entries.allSatisfy { $0.status == .finished },
              "The entire four-car field finishes within the limit and the tested driver stays within track limits")
        check(game.canReplay && mirrorsDrew,"Endurance uses live cockpit mirrors and leaves a saved result and rolling replay")
        let timeline = record.lapHistory ?? []
        check(timeline.count == record.completedLaps &&
              abs(timeline.reduce(0) { $0+$1.time }+record.penaltySeconds-(record.totalTime ?? 0)) < 0.01,
              "All eight logged laps sum to the classified time before rounding")
        print("Total \(lapTime(record.totalTime)) · P\(record.place ?? 0) · best \(lapTime(record.bestLap))")
        print("Classified laps: "+race.classifications.map{ "P\($0.position) \($0.laps)/8 \(lapTime($0.classifiedTime))" }.joined(separator:" · "))
        game.shutdown()
        let rows = try String(contentsOf:data.appendingPathComponent("latest-sprint.csv"),encoding:.utf8)
            .split(separator:"\n").map { $0.split(separator:",") }
        let session = rows.first?.firstIndex(of:"session_time_s")
        let samples = session.map { index in rows.dropFirst().compactMap { $0.indices.contains(index) ? Double($0[index]) : nil } } ?? []
        check(samples.count > 2000 && zip(samples.dropFirst(),samples).allSatisfy { abs($0-$1-0.1) < 0.003 },
              "Saved telemetry keeps 10 Hz alignment throughout the endurance event")
        if drying {
            check(record.configuration.usesDryingTrack && game.trackDrying?.elapsed ?? 0 > 120,
                  "A drying endurance result preserves its weather rule and active surface timeline")
        }
        let restored = makeReviewGame(frame:frame,dataDirectory:data)
        check(restored.raceRecords == [record] && restored.circuit.kind == .grand && restored.vehicle.kind == vehicle,
              "Eight-lap race result and venue survive a full reload")
        restored.shutdown()
        withExtendedLifetime(controller) {}
        if failures > 0 { exit(1) }
    }

    private static func processFootprint() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let limit = Int(count)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:limit) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint)/1_048_576 : nil
    }

    static func reviewSessionTransitions(seconds: Double,fps60: Bool) throws {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let data = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/session-soak",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        game.sound.muted = true
        let window = NSWindow(contentRect:frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        defer { window.orderOut(nil) }
        if fps60 {
            game.action("settings")
            game.action("settings:display")
            game.action("renderingRate")
            game.action("menuBack")
        }
        let deadline = Date(timeIntervalSinceNow:seconds)
        let cars = VehicleKind.allCases
        let tracks = CircuitKind.allCases
        let combinations = cars.count * tracks.count
        var visits = 0, snapshots: [Double] = []
        while deadline.timeIntervalSinceNow > 0 {
            autoreleasepool {
                let vehicle = cars[visits%cars.count]
                let track = visits / cars.count
                let circuit = tracks[track%tracks.count]
                game.action("selectVehicle")
                game.action("car:"+String(vehicle.rawValue))
                game.action("selectCircuit")
                game.action("circuit:"+String(circuit.rawValue))
                let wet = (visits+track+visits/combinations).isMultiple(of:2)
                if wet != (game.circuit.condition == .wet) { game.action("trackCondition") }
                game.action("openShowcase")
                game.action("showcaseAllPanels")
                game.action("showcaseCabinLight")
                game.action("showcaseLight:head")
                game.action("showcaseView:cabin")
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.86))
                check(game.showcase?.allPanelsOpen == true && game.showcase?.cabinLightOn == true &&
                      game.showcase?.kind == vehicle && game.sceneView.scene === game.showcase?.scene,
                      "Visit \(visits+1) brings the selected vehicle into the studio and opens its authored panels")
                if visits.isMultiple(of:5) {
                    let screenshot = game.sceneView.snapshot()
                    let bitmap = screenshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
                    let backing = game.sceneView.convertToBacking(game.sceneView.bounds).size
                    check(bitmap?.pixelsWide == Int(backing.width.rounded()) && bitmap?.pixelsHigh == Int(backing.height.rounded()),
                          "Visit \(visits+1) captures the studio at the full backing resolution")
                }
                game.action("closeShowcase")
                if visits.isMultiple(of:7) {
                    game.action("school")
                    game.action("startLesson")
                    game.action("pause")
                    game.action("leaveLesson")
                    game.action("closeSchool")
                    check(game.vehicle.kind == vehicle && game.circuit.kind == circuit,
                          "Visit \(visits+1) restores garage selection after leaving driving school")
                }
                game.action("raceSetup")
                game.action("raceOption:rivals:1")
                let trial = visits.isMultiple(of:5)
                game.action(trial ? "raceOption:grid:2" : "raceOption:grid:0")
                if game.circuit.condition == .wet { game.action("raceOption:surface:1") }
                game.action("startSprint")
                if trial {
                    game.action("pause")
                    game.action("qualifyingSkip")
                    let qualification = Date(timeIntervalSinceNow:8)
                    while game.qualifyingGrid == nil && qualification.timeIntervalSinceNow > 0 {
                        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.12))
                    }
                    game.action("launchQualifiedRace")
                    check(game.activeRaceGrid?.playerGridSlot == 1 && game.qualifying == nil,
                          "Visit \(visits+1) transfers the two-driver grid from qualifying to the race")
                }
                game.action("autoDrive")
                RunLoop.main.run(until:Date(timeIntervalSinceNow:7.2))
                game.action("pause")
                game.action("askRetireRace")
                game.action("confirmPrompt")
                game.action("openReplay")
                game.action("replayCamera")
                game.action("replayCamera")
                game.action("replayCamera")
                game.seekReplay(fraction:0.6)
                check(game.raceResultReady && game.replayView == .trackside && game.replay?.isPlaying == false &&
                      game.raceRecords.first?.vehicle == vehicle && game.raceRecords.first?.circuit == circuit,
                      "Visit \(visits+1) records one result and returns to its correct trackside replay")
                game.action("closeReplay")
                game.action("leaveSprint")
                check(game.sceneView.scene === game.world.scene && game.showcase == nil && game.trackDrying == nil,
                      "Visit \(visits+1) releases mode-specific state on main-menu return")
                if let footprint = processFootprint() {
                    snapshots.append(footprint)
                    print(String(format:"Memory after visit %d · %.1f MiB",visits+1,footprint))
                }
            }
            visits += 1
            if failures > 0 { break }
        }
        check(game.raceRecords.count == min(visits,RaceRecord.historyLimit) &&
              Set(game.raceRecords.map(\.id)).count == game.raceRecords.count,"Long runs retain the newest unique race results")
        game.shutdown()
        let restored = makeReviewGame(frame:frame,dataDirectory:data)
        check(restored.raceRecords == game.raceRecords,"The bounded race history survives reload after repeated world rebuilds")
        restored.shutdown()
        if let minimum = snapshots.dropFirst(8).min(), let maximum = snapshots.dropFirst(8).max(), let last = snapshots.last {
            print(String(format:"%d visits · warmed memory %.1f–%.1f MiB · final %.1f MiB",visits,minimum,maximum,last))
        }
        if failures > 0 { exit(1) }
    }

    static func reviewSchool() throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/school-review",isDirectory:true)
        let data = folder.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        let original = (game.vehicle.kind,game.circuit.kind)
        func capture(_ title: String, required: [String]) throws {
            let image = NSImage(size:frame.size)
            image.lockFocusFlipped(true)
            NSColor(rgb:0x283449).setFill()
            frame.fill()
            game.hud.draw(frame)
            image.unlockFocus()
            let items = game.hud.visibleActionFrames
            check(Set(items.map(\.1)).isSuperset(of:required) && items.allSatisfy { frame.contains($0.0) } &&
                  !items.enumerated().contains { i,item in items.dropFirst(i+1).contains { item.0.intersects($0.0) } },
                  "\(title) has reachable controls and no action overlaps")
            let png = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try png.write(to:folder.appendingPathComponent(title+".png"))
        }
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let limit = Date(timeIntervalSinceNow:seconds)
            while !done() && limit.timeIntervalSinceNow > 0 {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.015))
            }
            return done()
        }
        func key(_ code: UInt16,_ character: String,pressed: Bool) {
            let event = NSEvent.keyEvent(with:pressed ? .keyDown : .keyUp,location:.zero,modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,
                characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!
            if pressed { game.hud.keyDown(with:event) } else { game.hud.keyUp(with:event) }
        }
        game.action("school")
        try capture("school-menu",required:["startLesson","lesson:braking","lesson:trailBraking","lesson:wetExit"])
        game.action("menuAccept")
        check(game.lesson?.kind == .braking && game.circuit.kind == .grand && game.traffic.cars.isEmpty &&
              game.rollingCountdown == 3 && game.vehicle.kind == .porsche,
              "Keyboard confirmation places the authoring lesson in its isolated course")
        game.action("pause")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.09))
        check(game.rollingCountdown == 3,"Pausing freezes the lesson launch countdown")
        try capture("school-pause",required:["resume","lessonRetry","leaveLesson"])
        game.action("resume")
        check(wait(5.0,until:{ game.rollingCountdown == 0 }) && game.lesson?.hasStarted == false,
              "Green leaves the stationary exam ready for the first throttle press")
        game.action("autoDrive")
        check(!game.autoDriveEnabled,"Training scores are protected from autopilot")
        let brakeMark = DrivingLessonKind.braking.firstCoachingMark ?? DrivingLessonKind.braking.startProgress
        key(13,"w",pressed:true)
        let reached = wait(15,until:{ game.location.progress >= brakeMark || game.lesson?.result != nil })
        key(13,"w",pressed:false)
        key(1,"s",pressed:true)
        let completed = wait(8,until:{ game.lesson?.result != nil })
        key(1,"s",pressed:false)
        print(String(format:"Live braking lesson ended at %.1f m in %.2f s, peak %.1f km/h: %@",
                     game.location.progress,game.lesson?.elapsed ?? 0,game.lesson?.peakSpeedKPH ?? 0,
                     game.lesson?.result?.label ?? "pending"))
        let stored = game.lessonRecords[.braking]
        check(reached && completed && game.isPaused && stored != nil && game.lessonPersonalBest,
              "A real keyboard stop earns and saves the medal through the shipped game flow")
        try capture("school-result",required:["lessonNext","lessonRetry","leaveLesson"])
        game.action("lessonNext")
        check(game.lesson?.kind == .trailBraking && game.circuit.kind == .north &&
              abs(game.vehicle.speedKPH-90) < 0.1 && game.rollingCountdown == 3,
              "Next lesson loads its real rolling start and resets the course timer")
        game.action("pause")
        game.action("lessonRetry")
        check(game.lesson?.elapsed == 0 && game.rollingCountdown == 3 && !game.isPaused,
              "Retry resets the exercise without clearing earned medals")
        game.action("pause")
        game.action("leaveLesson")
        check(game.showingSchool && game.lesson == nil && game.vehicle.kind == original.0 && game.circuit.kind == original.1,
              "Returning to school restores the garage vehicle and practice circuit")
        game.shutdown()
        let reload = makeReviewGame(frame:frame,dataDirectory:data)
        check(reload.lessonRecords[.braking] == stored && stored != nil &&
              !FileManager.default.fileExists(atPath:data.appendingPathComponent("latest-session.csv").path),
              "The medal persists independently of practice telemetry")
        reload.shutdown()
        if failures > 0 { exit(1) }
    }

    static func reviewRacePit() throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/race-pit-review",isDirectory:true)
        let data = folder.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let game = makeReviewGame(frame:NSRect(x:0,y:0,width:900,height:664),dataDirectory:data)
        game.sound.muted = true
        game.action("trackCondition")
        game.action("startSprint")
        game.action("service")
        check(game.serviceRemaining == 0 && !game.canPitService,"Maintenance stays locked until green")
        wait(seconds:12) { game.canPitService }
        guard game.canPitService else {
            check(false,"The live race advances past the countdown before pit strategy is tested")
            game.shutdown()
            exit(1)
        }
        let initial = game.vehicle.position
        game.action("tow")
        check(game.vehicle.position == initial && game.serviceRemaining == 0,"A race cannot tow the player through timing gates")
        let garageTyres = game.tyreSetup
        game.action("pause")
        game.action("pitMenu")
        let frame = game.hud.bounds
        func captureStrategy(_ filename: String) throws {
            let preview = NSImage(size:frame.size)
            preview.lockFocusFlipped(true)
            game.hud.draw(frame)
            preview.unlockFocus()
            let png = NSBitmapImageRep(data:preview.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try png.write(to:folder.appendingPathComponent(filename))
        }
        try captureStrategy("pit-strategy.png")
        let controls = game.hud.visibleActionFrames
        check(Set(controls.map(\.1)).isSuperset(of:["pitTyres:0","pitTyres:1","pitTyres:2","pitTyres:3","pitTyres:down","pitTyres:up",
                                                "pitWork:tyres","pitWork:repairs","pitWork:both"]) &&
              controls.allSatisfy { frame.contains($0.0) } && !controls.contains { $0.1 == "service" },
              "The pit strategy is reachable from track but service is locked outside the bay")
        game.action("pitTyres:0")
        game.action("pitTyres:up")
        game.action("pitTyres:up")
        let plan = game.plannedRaceTyres
        check(plan?.compound == .soft && abs((plan?.coldPressure ?? 0)-garageTyres.coldPressure-0.1) < 0.001 &&
              game.vehicle.wheels.allSatisfy { $0.setup.compound == .wet } && game.tyreSetup == garageTyres,
              "Selecting the next tyre compound and cold pressure leaves the active tyre and garage setup alone")
        game.action("menuBack")
        game.action("resume")

        // Place the pit-stop fixture directly in the existing service bay.
        // Real physics, timing, traffic and the normal service action then run.
        let service = game.circuit.pitLane.serviceSample(on:game.circuit)
        game.vehicle.reset(at:service,preservingCondition:true)
        game.vehicle.damage.front = 0.38
        game.vehicle.wheels[0].wear = 0.45
        game.vehicle.wheels[0].brakeTemperature = 260
        game.action("service")
        let elapsed = game.sprint!.elapsed
        let rival = game.traffic.cars[0].vehicle.position
        let parked = game.vehicle.position
        check(game.serviceRemaining == 12 && game.vehicle.gear == 0 && game.vehicle.wheels[0].setup.compound == .wet,
              "The outgoing tyre stays fitted until the 12-second service is complete")
        wait(seconds:6) { game.sprint!.elapsed >= elapsed+1.6 }
        let rivalDistance = simd_distance(game.traffic.cars[0].vehicle.position,rival)
        print(String(format:"Pit service first sample · race %.2f s, rival %.2f m, stationary %.3f m, damage %.2f",
                     game.sprint!.elapsed-elapsed,rivalDistance,simd_distance(game.vehicle.position,parked),game.vehicle.damage.front))
        check(game.sprint!.elapsed > elapsed+1.35 && rivalDistance > 2 &&
              game.vehicle.position == parked && game.vehicle.damage.front == 0.38,
              "Race clocks and opponents advance while the player's repair is underway")
        game.action("pause")
        let pausedTimer = game.serviceRemaining
        let pausedRace = game.sprint!.elapsed
        let pausedRotor = game.vehicle.wheels[0].brakeTemperature
        game.action("pitMenu")
        game.action("pitTyres:2")
        game.action("pitWork:repairs")
        check(game.plannedRaceTyres == plan && game.plannedRaceWork == .both &&
              game.activeRaceService?.repairSeconds == 11 && game.activeRaceService?.tyreSeconds == 12,
              "A started stop retains its captured tyre and repair work")
        game.action("menuBack")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.12))
        check(game.serviceRemaining == pausedTimer && game.sprint!.elapsed == pausedRace &&
              game.vehicle.wheels[0].brakeTemperature == pausedRotor,"Pausing freezes both clocks and brake cooling")
        game.action("resume")
        wait(seconds:32) { game.serviceRemaining == 0 }
        check(game.serviceRemaining == 0 && abs(game.sprint!.elapsed-elapsed-12) < 0.2 &&
              game.vehicle.damage.front == 0 && game.vehicle.wheels[0].wear == 0 &&
              game.vehicle.gear == 1 && game.vehicle.wheels.allSatisfy { $0.setup == plan },
              "A complete stop fixes damage, fits the scheduled tyres and readies automatic departure")
        let rotor = game.vehicle.wheels[0].brakeTemperature
        check(rotor < pausedRotor && rotor > 160,"Hot brakes cool in the bay and retain heat after the tyre change")
        check(game.tyreSetup == garageTyres,"Race strategy never overwrites the garage settings")

        game.action("pause")
        game.action("pitMenu")
        game.action("pitWork:repairs")
        try captureStrategy("pit-repair-only.png")
        check(game.plannedRaceStop?.duration == 0 &&
              !game.hud.visibleActionFrames.contains { $0.1 == "service" || $0.1.hasPrefix("pitTyres:") },
              "An undamaged vehicle shows zero repair work and no tyre controls")
        game.action("menuBack")
        game.action("service")
        check(game.serviceRemaining == 0 && game.racePitStops == 1,"Declining a no-work stop leaves the count unchanged")

        game.vehicle.damage.suspension[0] = 0.55
        game.vehicle.wheels[0].wear = 0.28
        game.vehicle.wheels[0].flatSpot = 0.08
        game.vehicle.coolantTemperature = 108
        game.action("pitMenu")
        try captureStrategy("pit-repair-ready.png")
        check(game.plannedRaceStop?.duration == 14 &&
              game.hud.visibleActionFrames.contains { $0.1 == "service" && frame.contains($0.0) },
              "A suspension repair estimates 14 seconds and exposes the seated service action")
        let repairStart = game.sprint!.elapsed
        game.action("service")
        wait(seconds:36) { game.serviceRemaining == 0 }
        check(game.serviceRemaining == 0 && abs(game.sprint!.elapsed-repairStart-14) < 0.2 &&
              game.racePitStops == 2 && game.vehicle.damage.worst == 0 &&
              abs(game.vehicle.wheels[0].wear-0.28) < 0.0001 && abs(game.vehicle.wheels[0].flatSpot-0.08) < 0.0001 &&
              game.vehicle.wheels[0].setup == plan && abs(game.vehicle.coolantTemperature-108) < 0.15,
              "Repair-only clears chassis damage while preserving the fitted tyre condition and powertrain heat")

        game.action("pause")
        game.action("pitMenu")
        game.action("pitWork:tyres")
        game.action("pitTyres:3")
        game.vehicle.damage.engine = 0.51
        game.vehicle.wheels[0].brakeTemperature = 210
        let tyreStart = game.sprint!.elapsed
        game.action("service")
        wait(seconds:32) { game.serviceRemaining == 0 }
        check(game.serviceRemaining == 0 && abs(game.sprint!.elapsed-tyreStart-12) < 0.2 &&
              game.racePitStops == 3 && game.vehicle.damage.engine == 0.51 &&
              game.vehicle.wheels.allSatisfy { $0.setup.compound == .wet && $0.wear < 1e-6 } &&
              game.vehicle.wheels[0].brakeTemperature > 140 && game.vehicle.wheels[0].brakeTemperature < 210,
              "Tyres-only replaces worn tyres and retains both hot brakes and outstanding engine damage")

        game.action("pause")
        let csv = try String(contentsOf:data.appendingPathComponent("latest-sprint.csv"),encoding:.utf8)
        let rows = csv.split(separator:"\n")
        check(rows.count >= 380 && game.sprint!.entries[0].laps == 0,
              "The stationary period is recorded without earning race distance")
        game.shutdown()
        if failures > 0 { exit(1) }

        func wait(seconds: Double,until done: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow:seconds)
            while !done() && deadline.timeIntervalSinceNow > 0 {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.075))
            }
        }
    }

    static func reviewRaceDrying() throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/drying-review",isDirectory:true)
        let data = folder.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        game.action("trackCondition")
        game.action("raceSetup")
        game.action("raceOption:surface:1")
        game.action("raceOption:grid:1")
        game.action("raceOption:rivals:1")
        let picture = NSImage(size:frame.size)
        picture.lockFocusFlipped(true)
        game.hud.draw(frame)
        picture.unlockFocus()
        let controls = game.hud.visibleActionFrames
        check(Set(controls.map(\.1)).isSuperset(of:["raceOption:surface:0","raceOption:surface:1","startSprint"]) &&
              controls.allSatisfy { frame.contains($0.0) },"The optional drying surface can be selected at the minimum window size")
        let png = NSBitmapImageRep(data:picture.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try png.write(to:folder.appendingPathComponent("race-drying-setup.png"))
        guard let road = game.world.scene.rootNode.childNode(withName:"WetDrivingSurface",recursively:false),
              let original = road.geometry, let originalColor = original.sources(for:.color).first?.data else {
            check(false,"The native wet road provides a film color buffer")
            game.shutdown()
            exit(1)
        }
        game.action("startSprint")
        check(game.trackDrying?.elapsed == 0 && game.activeRaceConfiguration?.usesDryingTrack == true,
              "The selected wet race starts with the original water film")
        game.action("autoDrive")
        let finish = Date(timeIntervalSinceNow:21)
        while (game.trackDrying?.elapsed ?? 0) < 16 && finish.timeIntervalSinceNow > 0 {
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.09))
        }
        let fresherColor = road.geometry?.sources(for:.color).first?.data
        check(game.vehicle.distanceTravelled > 50 && game.trackDrying?.elapsed ?? 0 >= 15 &&
              fresherColor != nil && fresherColor != originalColor && road.geometry?.elements.count == original.elements.count,
              "Four-wheel physics and the native road mesh update after the green flag")
        game.action("pause")
        let pauseTime = game.trackDrying?.elapsed
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.18))
        check(game.trackDrying?.elapsed == pauseTime,"Track evolution pauses with the race clock")
        game.action("askRetireRace")
        game.action("confirmPrompt")
        let finalColor = road.geometry?.sources(for:.color).first?.data
        check(game.raceRecords.first?.configuration.usesDryingTrack == true && game.canReplay,
              "Race history retains the weather selection and the played segment can be replayed")
        game.action("openReplay")
        game.seekReplay(fraction:0)
        check(road.geometry === original,"Seeking to the start restores the corresponding wet road")
        game.seekReplay(fraction:1)
        check(road.geometry?.sources(for:.color).first?.data == finalColor,"Seeking to the end restores the ending road film")
        game.action("closeReplay")
        game.action("raceAgain")
        check(game.trackDrying?.elapsed == 0 && road.geometry === original,"A rematch starts from its initial water distribution")
        game.shutdown()
        let restored = makeReviewGame(frame:frame,dataDirectory:data)
        check(restored.raceConfiguration.usesDryingTrack && restored.trackDrying == nil,
              "Reloading saves the mode preference and starts the garage without active road evolution")
        restored.shutdown()
        if failures > 0 { exit(1) }
    }

    static func reviewQualifying(live: Bool) throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/qualifying-review",isDirectory:true)
        let data = folder.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow:seconds)
            while !done() && deadline.timeIntervalSinceNow > 0 {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.08))
            }
            return done()
        }
        game.action("raceSetup")
        game.action("selectCircuit")
        game.action("circuit:"+String(CircuitKind.sprint.rawValue))
        game.action("selectVehicle")
        game.action("car:"+String(VehicleKind.porsche.rawValue))
        game.action("raceOption:grid:2")
        game.action("raceOption:rivals:1")
        game.action("raceOption:difficulty:0")
        game.action("startSprint")
        check(game.raceConfiguration.usesQualifying && game.sprint == nil &&
              game.qualifying?.timing.waitingForStart == true && game.traffic.cars.isEmpty &&
              game.vehicle.speed > 8 && game.rollingCountdown == 3,
              "Qualifying starts in a rolling car before the timing seam")
        var virtualPad: GCController?
        if live {
            let controller = GCController.withExtendedGamepad()
            virtualPad = controller
            game.input.selectController(controller)
            let pad = controller.extendedGamepad!
            game.inspectDrivingTick = { [weak game] _ in
                guard let game, !game.isPaused else { return }
                let command = ComputerDriver.input(for:game.vehicle,at:game.location,circuit:game.circuit,
                    line:game.world.racingLine,pace:0.79,brakeCurve:game.assists.brakeCurve,
                    steeringCurve:game.assists.steeringCurve)
                let deadzone = game.assists.steeringDeadzone
                let steering = copysign(abs(command.steering)*(1-deadzone)+deadzone,command.steering)
                pad.leftThumbstick.setValueForXAxis(Float(steering),yAxis:0)
                pad.rightTrigger.setValue(Float(command.throttle))
                pad.leftTrigger.setValue(Float(command.brake))
            }
            check(wait(250,until:{ game.qualifying?.result != nil }) && game.qualifying?.result?.outcome == .valid,
                  "Live injected gamepad controls complete a true valid lap without auto-driving marks")
            game.inspectDrivingTick = nil
            check(game.qualifying?.result?.sectors.count == 3 && game.qualifying?.result?.time ?? 0 > 15,
                  "The valid flying lap has a classified time and three sectors")
        } else {
            game.action("pause")
            game.action("qualifyingSkip")
            check(game.qualifying?.result?.outcome == .skipped && game.isPaused,
                  "The normal skip action moves to a no-time classification")
        }
        let ready = wait(10,until:{ game.qualifyingGrid != nil })
        check(ready && game.qualifyingGrid?.rows.contains {
            $0.entrantIndex == 1 && $0.time != nil
        } == true, "The opponent time comes from asynchronous physical qualifying")
        if !live { check(game.qualifyingGrid?.playerGridSlot == 1,"A skipped lap starts at the back") }
        let image = NSImage(size:frame.size)
        image.lockFocusFlipped(true)
        NSColor(rgb:0x283449).setFill()
        frame.fill()
        game.hud.draw(frame)
        image.unlockFocus()
        let buttons = game.hud.visibleActionFrames
        check(buttons.contains { $0.1 == "launchQualifiedRace" } &&
              buttons.allSatisfy { frame.contains($0.0) } && game.hud.menuFocusAction == "launchQualifiedRace",
              "Actual reference availability exposes the next action and its default focus")
        let preview = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try preview.write(to:folder.appendingPathComponent(live ? "qualifying-live.png" : "qualifying-skipped.png"))
        let startingSlot = game.qualifyingGrid?.playerGridSlot ?? 1
        game.action("menuAccept")
        check(game.qualifying == nil && game.sprint?.countdownSeconds == 3 &&
              game.sprint?.driverPosition == startingSlot+1 && game.activeRaceGrid?.playerGridSlot == startingSlot,
              "The classified qualifying order places the race grid without reordering driver identities")
        game.action("pause")
        game.action("askRetireRace")
        game.action("confirmPrompt")
        check(game.raceRecords.first?.qualifiedGridPlace == startingSlot+1 &&
              !FileManager.default.fileExists(atPath:data.appendingPathComponent("latest-session.csv").path),
              "The result retains the earned start and leaves practice stats alone")
        game.action("raceAgain")
        check(game.qualifying == nil && game.sprint?.driverPosition == startingSlot+1,
              "The rematch repeats the earned grid without requiring requalification")
        withExtendedLifetime(virtualPad) { game.shutdown() }
        if failures > 0 { exit(1) }
    }

    /// Rehearses two different paces against the real car and records an isolated practice comparison.
    static func reviewCornerAnalysis() throws {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/corner-analysis",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let frame = NSRect(x:0,y:0,width:1180,height:740)
        let circuit = Circuit(kind:.north), line = RacingLine(circuit:circuit)
        for kind in VehicleKind.allCases {
            let profileDirectory = directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
            defer { try? FileManager.default.removeItem(at:profileDirectory) }
            let seed = makeReviewGame(frame:frame,dataDirectory:profileDirectory)
            seed.shutdown()
            let profileURL = profileDirectory.appendingPathComponent("practice.json")
            var profile = try JSONDecoder().decode(SavedPractice.self,from:Data(contentsOf:profileURL))
            profile.vehicleKind = kind.rawValue
            profile.circuitKind = circuit.kind.rawValue
            let key = LapRecord.key(vehicle:kind,circuit:circuit.kind)
            var analysis = PracticeAnalysis()
            for pace in [0.91,0.77] {
                var car = Vehicle(), session = RaceSession(), command = DrivingInput()
                car.kind = kind
                car.reset(at:circuit.start)
                session.resetLap(at:circuit.start.distance)
                let dt = 1.0/240
                var location = circuit.nearest(to:car.position)
                for step in 0..<(240*360) {
                    if step.isMultiple(of:4) {
                        command = ComputerDriver.input(for:car,at:location,circuit:circuit,line:line,pace:pace)
                    }
                    car.step(dt,input:command,assists:DrivingAssists(),roadDistance:location.distance,
                             roadWidth:circuit.width,roadLateral:location.lateral,roadProgress:location.progress,
                             kerbsEnabled:circuit.hasKerb(at:location.progress),roadContacts:circuit.wheelContacts(at:car.contactPoints))
                    location = circuit.nearest(to:car.position)
                    _ = session.step(dt,vehicle:car,location:location,trackLength:circuit.length,trackWidth:circuit.width,input:command)
                    if session.completedLaps >= 2, let lap = session.analysedLap {
                        analysis.append(lap)
                        break
                    }
                }
            }
            guard analysis.history.count == 2, let latest = analysis.latest, let fastest = analysis.fastest,
                  latest.summary.time > fastest.summary.time else { fatalError("Missing physical practice comparison") }
            let release = (1..<LapInputs.intervals).filter { index in
                let sample = latest.inputs[index]
                return (0.05...0.85).contains(sample.brake) && sample.brake < latest.inputs[index-1].brake
            }.max { a,b in
                abs(latest.inputs[a].handwheelDegrees ?? 0) < abs(latest.inputs[b].handwheelDegrees ?? 0)
            }
            guard let cursor = release else { fatalError("Missing trail-brake observation") }
            profile.analysis = [key:analysis]
            try JSONEncoder().encode(profile).write(to:profileURL,options:.atomic)
            let game = makeReviewGame(frame:frame,dataDirectory:profileDirectory)
            let window = NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView = game.hud
            game.action("analysis")
            game.hud.displayIfNeeded()
            func capture() -> NSBitmapImageRep {
                let image = NSImage(size:frame.size)
                image.lockFocusFlipped(true)
                game.hud.draw(game.hud.bounds)
                image.unlockFocus()
                return NSBitmapImageRep(data:image.tiffRepresentation!)!
            }
            _ = capture()
            for _ in 0..<abs(cursor-400)/8 {
                game.action(cursor < 400 ? "menuLeft" : "menuRight")
            }
            game.action("analysisZoom")
            for _ in 0...LapInputs.intervals {
                guard let marker = game.hud.analysisMarker, marker != cursor else { break }
                game.action(marker < cursor ? "menuRight" : "menuLeft")
            }
            let sample = latest.inputs[cursor]
            check(game.hud.analysisMarker == cursor && (sample.linePressure ?? 0) > 0 && abs(sample.handwheelDegrees ?? 0) > 1,
                  "Native practice analysis inspects measured brake pressure and handwheel travel for "+kind.label)
            let output = directory.appendingPathComponent("corner-"+String(kind.rawValue)+".jpg")
            try capture().representation(using:.jpeg,properties:[.compressionFactor:0.9])!.write(to:output)
            print(String(format:"%@ %.3fs / %.3fs, %.1fm, pedal %.1f%%, pressure %.1f%%, handwheel %.1f°",
                         kind.label,latest.summary.time,fastest.summary.time,Double(cursor)*circuit.length/Double(LapInputs.intervals),
                         sample.brake*100,(sample.linePressure ?? 0)*100,sample.handwheelDegrees ?? 0))
            game.shutdown()
        }
        if failures > 0 { exit(1) }
    }

    static func reviewTwoCarSave() throws {
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/roster-save/" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("practice.json")
        let fresh = makeReviewGame(frame:frame,dataDirectory:directory)
        check(fresh.vehicle.kind == .porsche && VehicleKind.allCases.map(\.rawValue) == [2,5],
              "A new profile opens on the 911 and has precisely two stable vehicle IDs")
        fresh.shutdown()
        var profile = try JSONDecoder().decode(SavedPractice.self,from:Data(contentsOf:path))
        profile.vehicleKind = 4
        let retiredKey = "timing9-4-0"
        let older = reference(speed:24), current = reference(speed:20)
        let archiveKey = LapRecord.key(vehicle:.porsche,circuit:.north,legacyPorscheMass:true)
        let activeKey = LapRecord.key(vehicle:.porsche,circuit:.north)
        var oldAnalysis = PracticeAnalysis()
        oldAnalysis.append(older.analysedLap!)
        profile.circuitKind = CircuitKind.north.rawValue
        profile.records = [retiredKey:older.record!,archiveKey:older.record!,activeKey:current.record!]
        profile.analysis = [retiredKey:PracticeAnalysis(),archiveKey:oldAnalysis]
        profile.vehicleSettings?["4"] = VehicleSettings(tyres:TyreSetup(compound:.soft,coldPressure:1.8),
                                                        assists:DrivingAssists())
        let oldRound = CupSeries.club.rounds[0]
        let record = RaceRecord(id:UUID(),date:Date(),vehicle:.porsche,circuit:oldRound.circuit,wet:false,
                                configuration:oldRound.configuration,completedLaps:2,place:1,totalTime:90,
                                bestLap:41,penaltySeconds:0,assisted:false,cup:CupEntry(series:.club,roundIndex:0))
        let encoder = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with:encoder.encode(profile)) as! [String:Any]
        var historic = try JSONSerialization.jsonObject(with:encoder.encode(record)) as! [String:Any]
        historic["vehicle"] = 4
        json["raceRecords"] = [historic]
        json["cups"] = ["club":["records":[historic],"bestPoints":10]]
        try JSONSerialization.data(withJSONObject:json).write(to:path,options:.atomic)

        let game = makeReviewGame(frame:frame,dataDirectory:directory)
        check(game.vehicle.kind == .porsche && game.practiceReadNotice == nil &&
              game.raceRecords.first?.recordedVehicleLabel == "已退役车型",
              "A retired selection opens on the 911 and its old race keeps its own identity")
        check(game.session.best == current.best && game.session.bestGhost.count == current.record?.ghost.count &&
              game.practiceAnalysis.history.isEmpty,"The current 911 selects only its own practice record, ghost and comparison")
        game.action("raceHistory")
        game.action("historyBests")
        check(game.hasLegacyPorscheBests && game.bestPracticeLap(at:.north)?.time == current.best,
              "Both generations of 911 records open on the current specification")
        game.action("bestsPorscheSpecification")
        check(game.bestsShowsLegacyPorsche && game.bestPracticeLap(at:.north)?.time == older.best && game.session.best == current.best,
              "Viewing the legacy 911 time leaves the current practice reference intact")
        game.action("bestsWet")
        check(!game.hasLegacyPorscheBests && !game.bestsShowsLegacyPorsche && game.bestPracticeLap(at:.north) == nil,
              "Changing road condition clears the archived record filter")
        game.action("menuBack")
        game.action("vehiclePrevious")
        check(game.vehicle.kind == .centenario,"Previous wraps from the 911 to the Centenario")
        game.action("vehicleNext")
        check(game.vehicle.kind == .porsche,"Next wraps from the Centenario to the 911")
        game.action("openShowcase")
        game.action("showcaseNext")
        check(game.showcase?.kind == .centenario,"Showroom cycling loads the Centenario authored model")
        game.action("showcasePrevious")
        check(game.showcase?.kind == .porsche,"Showroom cycling restores the 911 authored model")
        game.action("closeShowcase")
        game.action("vehicleNext")
        game.shutdown()
        let saved = try JSONDecoder().decode(SavedPractice.self,from:Data(contentsOf:path))
        check(saved.vehicleKind == 5 && saved.raceRecords?.first?.$vehicle == 4 &&
              saved.cups?["club"]?.records.first?.$vehicle == 4,
              "An active Lamborghini and a historic entry and cup keep distinct IDs after saving")
        check(saved.records?[retiredKey]?.time == profile.records?[retiredKey]?.time &&
              saved.analysis?[retiredKey] != nil && saved.vehicleSettings?["4"] != nil,
              "Saving the two-car profile preserves retired lap, analysis and setup keys")
        check(saved.records?[archiveKey]?.time == older.best && saved.records?[activeKey]?.time == current.best &&
              saved.analysis?[archiveKey]?.latest?.inputs.count == older.analysedLap?.inputs.count,
              "Rewriting the profile preserves both 911 generations and their archived input data")
        var archivedOnly = saved
        archivedOnly.vehicleKind = VehicleKind.porsche.rawValue
        archivedOnly.records?.removeValue(forKey:activeKey)
        let archivedFolder = directory.appendingPathComponent("archived",isDirectory:true)
        try FileManager.default.createDirectory(at:archivedFolder,withIntermediateDirectories:true)
        try encoder.encode(archivedOnly).write(to:archivedFolder.appendingPathComponent("practice.json"))
        let oldGame = makeReviewGame(frame:frame,dataDirectory:archivedFolder)
        check(oldGame.vehicle.kind == .porsche && oldGame.session.best == nil && oldGame.session.bestGhost.isEmpty &&
              oldGame.practiceAnalysis.history.isEmpty,"A pre-calibration profile starts a new 911 timing sheet and ghost")
        oldGame.shutdown()
        let reopened = makeReviewGame(frame:frame,dataDirectory:directory)
        check(reopened.vehicle.kind == .centenario && reopened.raceRecords.first?.id == record.id,
              "A second launch restores the selected Lamborghini and original historic result")
        reopened.shutdown()
        if failures > 0 { exit(1) }
    }

    static func reviewSaveRecovery(skipController: Bool) throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/save-recovery-review",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let primary = root.appendingPathComponent("practice.json")
        let recovery = root.appendingPathComponent("practice-recovery.json")
        let damaged = root.appendingPathComponent("practice-unreadable.json")
        let first = makeReviewGame(frame:frame,dataDirectory:root)
        first.action("viewCabin")
        first.action("raceSetup")
        first.action("raceOption:laps:5")
        first.action("closeRaceSetup")
        if !skipController {
            first.action("controllerReview")
            for _ in 0..<3 { first.action("hapticRoute") }
            first.action("menuBack")
        }
        first.shutdown()
        let knownGood = try Data(contentsOf:primary)

        let second = makeReviewGame(frame:frame,dataDirectory:root)
        check(second.drivingView == .cockpit && second.raceConfiguration.laps == 5 &&
              (skipController || second.input.hapticRoute == .all) && second.practiceReadNotice == nil,
              "Healthy startup loads the primary profile and its saved settings")
        second.action("viewChase")
        second.shutdown()
        let backedUp = try Data(contentsOf:recovery)
        check(backedUp == knownGood,"The previous verified profile is preserved once per session")

        let torn = Data("{\"version\":10,\"records\":".utf8)
        try torn.write(to:primary,options:.atomic)
        let restored = makeReviewGame(frame:frame,dataDirectory:root)
        let before = try Data(contentsOf:primary)
        check(restored.drivingView == .cockpit && restored.raceConfiguration.laps == 5 &&
              (skipController || restored.input.hapticRoute == .all) && restored.practiceReadNotice != nil && before == torn,
              "An unreadable primary restores the previous profile without an immediate overwrite")
        restored.action("mute")
        restored.shutdown()
        let after = try JSONDecoder().decode(SavedPractice.self,from:Data(contentsOf:primary))
        let heldDamage = try Data(contentsOf:damaged), heldBackup = try Data(contentsOf:recovery)
        check(after.muted && after.raceConfiguration?.laps == 5 && heldDamage == torn && heldBackup == knownGood,
              "A successful write retains the damaged source and the last known good profile")

        let orphan = root.appendingPathComponent("no-backup",isDirectory:true)
        try FileManager.default.createDirectory(at:orphan,withIntermediateDirectories:true)
        try torn.write(to:orphan.appendingPathComponent("practice.json"),options:.atomic)
        let rescued = makeReviewGame(frame:frame,dataDirectory:orphan)
        check(rescued.practiceReadNotice != nil,"An unreadable profile is reported even without a backup")
        rescued.shutdown()
        let raw = try Data(contentsOf:orphan.appendingPathComponent("practice-unreadable.json"))
        check(raw == torn,"A first run without a usable backup still retains the original bytes")
        if failures > 0 { exit(1) }
    }

    static func reviewMenus(skipController: Bool) throws {
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/menu-review")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
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
        game.action("car:"+String(VehicleKind.porsche.rawValue))
        check(game.vehicle.kind == .porsche && game.garageSelection == nil,"Garage selects a vehicle without cycling other cars")
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
        if !skipController {
            game.action("controllerReview")
            try capture("04-calibration")
            let routes = game.hud.visibleActionFrames.contains { $0.1 == "hapticRoute" }
            game.action("hapticRoute")
            check(routes && game.input.hapticRoute == .handles,
                  "Controller calibration offers a reachable alternate haptic route")
            try capture("04b-calibration-route")
            game.action("menuBack")
            check(game.settingsPage == .controller && !game.showingControllerReview,
                  "Calibration returns to its original settings tab")
        }
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
        let expectedSeatRise: Float = game.vehicle.kind == .porsche ? 0.005 : 0.0042
        let actualSeatRise = game.world.camera.simdPosition.y-lowSeat
        check(game.world.camera.camera?.fieldOfView == 64 && abs(actualSeatRise-expectedSeatRise) < 0.001 &&
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
              game.graphicsQuality == .performance && game.vehicle.kind == .porsche,
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

        let reload = makeReviewGame(frame:frame,dataDirectory:data)
        defer { reload.shutdown() }
        check(reload.vehicle.kind == .porsche && reload.circuit.kind == .ridge &&
              reload.graphicsQuality == .performance && reload.sceneView.antialiasingMode == .none &&
              reload.renderingRate == .hz60 && reload.sceneView.preferredFramesPerSecond == 60 &&
              reload.world.cockpitFOV == 64 && reload.world.seatHeight == 1.02 &&
              reload.drivingView == savedView && !reload.ghostEnabled && reload.compactHUD &&
              reload.assists.brakeCurve == .deep &&
              reload.sound.masterVolume == 0.9 && reload.sound.motorVolume == 0.9 && reload.sound.effectsVolume == 0.9,
              "Display, assists and three independent volume settings survive a relaunch")
        let blocked = data.appendingPathComponent("settings-file-instead-of-folder")
        try Data([0]).write(to:blocked)
        let failedSave = makeReviewGame(frame:frame,dataDirectory:blocked)
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

    static func reviewViewport(hidden: Bool) throws {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let data = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/viewport-review",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:data,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:900,height:664)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
        let window = NSWindow(contentRect:frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        let content = NSView(frame:frame)
        content.addSubview(game.sceneView)
        content.addSubview(game.hud)
        window.contentView = content
        if !hidden { window.orderFrontRegardless() }
        defer { window.orderOut(nil) }
        game.action("settings")
        game.action("settings:display")
        game.action("renderingRate")
        game.action("menuBack")
        check(game.renderingRate == .hz60,"Graphics settings switch to the paced viewport")
        game.action("selectVehicle")
        game.action("car:"+String(VehicleKind.porsche.rawValue))
        game.action("openShowcase")
        game.action("showcaseView:side")
        RunLoop.main.run(until:Date(timeIntervalSinceNow:1))
        let options: [SCNHitTestOption:Any] = [.searchMode:SCNHitTestSearchMode.closest.rawValue,
                                             .ignoreHiddenNodes:true,.backFaceCulling:false]
        func selectAtScreenPoint() -> Bool {
            guard let gallery = game.showcase else { return false }
            let bounds = game.sceneView.bounds
            for x in stride(from:bounds.width*0.27,to:bounds.width*0.75,by:18) {
                for y in stride(from:bounds.height*0.32,to:bounds.height*0.65,by:18) {
                    let point = CGPoint(x:x,y:y)
                    guard let hit = game.sceneView.sceneHitTest(point,options:options).first,
                          let panel = gallery.panel(containing:hit.node) else { continue }
                    game.pickShowcasePanel(at:game.sceneView.convert(point,to:nil))
                    return gallery.openPanels.contains(panel)
                }
            }
            return false
        }
        check(selectAtScreenPoint(),"The parked 60 FPS viewport still selects an authored part using its screen position")
        let initial = game.sceneView.snapshot()
        window.setContentSize(NSSize(width:1050,height:730))
        game.viewportChanged()
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.5))
        let resized = game.sceneView.snapshot()
        let bitmap = resized.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        let backingSize = game.sceneView.convertToBacking(game.sceneView.bounds).size
        print("Captured pixels \(bitmap?.pixelsWide ?? 0) × \(bitmap?.pixelsHigh ?? 0) · backing \(Int(backingSize.width.rounded())) × \(Int(backingSize.height.rounded()))")
        check(initial.tiffRepresentation != nil && resized.tiffRepresentation != nil && resized.size.width > initial.size.width &&
              abs(resized.size.width/resized.size.height-1050.0/730) < 0.02,
              "Captured views retain their camera and follow window resize at 60 FPS")
        check(bitmap?.pixelsWide == Int(backingSize.width.rounded()) && bitmap?.pixelsHigh == Int(backingSize.height.rounded()),
              "A 60 FPS capture matches window backing pixels without scaling twice")
        game.action("closeShowcase")
        game.action("settings")
        game.action("settings:display")
        game.action("renderingRate")
        game.action("menuBack")
        check(game.renderingRate == .hz120 && game.sceneView.scene === game.world.scene && game.sceneView.pointOfView === game.world.camera,
              "Returning to the native high-refresh viewport restores the same scene and camera")
        game.shutdown()
        if failures > 0 { exit(1) }
    }

    static func measurePerformance(seconds: Double,wet: Bool,fps60: Bool,quality: GraphicsQuality,
                                   circuit: CircuitKind,vehicle: VehicleKind) throws {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        let clock = ProcessInfo.processInfo
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        defer { try? FileManager.default.removeItem(at:data) }
        let frame = NSRect(x:0,y:0,width:1440,height:900)
        let game = makeReviewGame(frame:frame,dataDirectory:data)
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
        let presentations = FrameMeasurements()
        game.sceneView.onDrawablePresented = { presentations.record($0) }
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
        _ = presentations.take()
        ticks.removeAll(keepingCapacity:true)
        let start = clock.systemUptime
        let initialDistance = game.vehicle.distanceTravelled
        RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds))
        let elapsed = clock.systemUptime - start
        let times = measurements.take()
        let presented = presentations.take().filter { $0 >= start && $0 <= start+elapsed }.sorted()
        if fps60 {
            let intervals = zip(presented.dropFirst(),presented).map { ($0-$1)*1000 }
            print("Metal drawable presentations: "+FrameMeasurements.describe(intervals,elapsed:elapsed,frames:presented.count))
            let rate = Double(presented.count)/elapsed
            check((50...61).contains(rate),"On-screen Metal drawable cadence stays within the 60 FPS setting")
        }
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
        world.selectVehicle(.porsche)
        var player = Vehicle(); player.kind = .porsche; player.reset(at:circuit.start)
        if wet { player.service(setup:TyreSetup(compound:.wet)) }
        var traffic = ComputerTraffic()
        traffic.reset(count:3,kind:.porsche,circuit:circuit,from:circuit.start.distance)
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

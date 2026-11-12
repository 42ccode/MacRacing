import AppKit
import simd

/// Compile into a dedicated scratch .app with bundled Assets. Generated practice
/// data lives beside that scratch app, never beside the actual release bundle.
@main struct TrainingReview {
    static var failures=0
    static func check(_ valid:Bool,_ title:String) {print("\(valid ? "PASS" : "FAIL")  \(title)");if !valid {failures += 1}}
    static func tick(_ session:inout RaceSession,progress:Double,speed:Double,dt:Double=0.1,off:Bool=false) {
        var car=Vehicle();car.position=SIMD2(progress,0);car.velocity=SIMD2(speed,0)
        _ = session.step(dt,vehicle:car,location:TrackLocation(point:car.position,tangent:SIMD2(1,0),progress:progress,lateral:0,distance:off ? 20 : 0,segment:0),trackLength:1200,trackWidth:12)
    }
    static func reference(speed:Double) -> RaceSession {
        var session=RaceSession();session.resetLap(at:0)
        for i in 1...1000 {tick(&session,progress:(Double(i)*speed*0.1).truncatingRemainder(dividingBy:1200),speed:speed);if session.completedLaps>0 {break}}
        return session
    }
    static func main() throws {
        _ = NSApplication.shared
        guard Bundle.main.bundleIdentifier=="studio.apexlab.trainingreview" else {fatalError("Use a dedicated scratch review bundle")}
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/training-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let game=RacingGame(frame:NSRect(x:0,y:0,width:1100,height:718))
        game.hasStarted=true;game.isPaused=true
        game.vehicle.kind = .ferrari;game.world.selectVehicle(.ferrari)
        while game.circuit.kind != .north {game.action("trackNext")}
        let base=reference(speed:20), other=reference(speed:24)
        game.session=base
        game.action("vehicleNext")
        check(game.vehicle.kind == .porsche && game.session.best != base.best,"Switching car does not reuse another car's best")
        game.session=other
        game.action("trackNext")
        check(game.session.best==nil,"New track does not reuse the old track's reference")
        for _ in 0..<3 {game.action("trackNext")}
        check(abs((game.session.best ?? 0)-50)<0.001,"Returning to track restores its own personal best")
        game.action("vehiclePrevious")
        check(abs((game.session.best ?? 0)-60)<0.001,"Returning to car restores its own personal best")
        let reload=RacingGame(frame:game.hud.frame)
        check(reload.vehicle.kind == .ferrari && reload.circuit.kind == .north && abs((reload.session.best ?? 0)-60)<0.001,"Relaunch restores selected vehicle, circuit and record")
        check(reload.session.bestSectors.count==3 && !reload.session.bestTrace.isEmpty && !reload.session.bestGhost.isEmpty,"Relaunch restores sectors, distance reference and ghost together")
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
        let dataFolder=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("APEX Lab Data")
        let settings=dataFolder.appendingPathComponent("practice.json")
        var legacy=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! [String:Any]
        legacy["version"]=8;legacy.removeValue(forKey:"records");legacy["automatic"]=false;legacy["absLevel"]=2
        try JSONSerialization.data(withJSONObject:legacy).write(to:settings,options:.atomic)
        let migrated=RacingGame(frame:game.hud.frame)
        check(!migrated.assists.automatic && migrated.assists.absLevel==2 && migrated.session.best==nil,"Legacy migration keeps driving preferences without inventing a distance reference")
        migrated.action("mute")
        let backup=try JSONSerialization.jsonObject(with:Data(contentsOf:dataFolder.appendingPathComponent("practice-before-1.6.json"))) as! [String:Any]
        let updated=try JSONSerialization.jsonObject(with:Data(contentsOf:settings)) as! [String:Any]
        check(backup["version"] as? Int==8 && updated["version"] as? Int==9,"First save preserves the legacy practice file before writing the new schema")
        print("Rendered five timing states and two window sizes")
        if failures>0 {exit(1)}
    }
}

import AppKit

/// Run from a scratch .app with Assets in Contents/Resources, not the release
/// bundle. Supplies deterministic inputs to the actual HUD, without a controller.
@main struct PedalUIReview {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/pedal-ui-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let game=RacingGame(frame:NSRect(x:0,y:0,width:1100,height:718))
        game.hasStarted=true;game.isPaused=false;game.drivingView = .cockpit
        game.vehicle.gear=3;game.vehicle.velocity=game.vehicle.forward*(100/3.6)
        let window=NSWindow(contentRect:game.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=game.hud
        func capture(_ name:String,rect:NSRect) throws {
            guard let bitmap=game.hud.bitmapImageRepForCachingDisplay(in:rect) else { fatalError("No HUD bitmap") }
            game.hud.cacheDisplay(in:rect,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        }
        let cases:[(String,Double,Double)] = [("released",0,0),("braking",0,0.65),("throttle",1,0),("overlap",0.31,0.72),("full",1,1),("small",0.01,0.02)]
        for (name,throttle,brake) in cases {
            game.drivingInput=DrivingInput(throttle:throttle,brake:brake)
            // Assistance must not replace what the driver is actually pressing.
            game.vehicle.absActive=true;game.vehicle.absRelease=0.8
            game.vehicle.tcActive=true;game.vehicle.tcReduction=0.7
            game.hud.needsDisplay=true;game.hud.displayIfNeeded()
            try capture(name,rect:NSRect(x:18,y:506,width:238,height:194))
            if name=="overlap" {try capture("minimum-window",rect:game.hud.bounds)}
        }
        game.hud.frame=NSRect(x:0,y:0,width:1440,height:900)
        game.hud.needsDisplay=true;game.hud.displayIfNeeded()
        try capture("large-window",rect:game.hud.bounds)
        print("Rendered six input states and two HUD sizes")
    }
}

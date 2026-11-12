import AppKit

/// Run from a scratch .app with Assets in Contents/Resources, not the release
/// bundle. Supplies deterministic inputs to the actual HUD, without a controller.
@main struct PedalUIReview {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/pedal-ui-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let game=RacingGame(frame:NSRect(x:0,y:0,width:1100,height:718))
        game.hasStarted=true;game.isPaused=false;game.drivingView = .chase
        game.vehicle.gear=3;game.vehicle.velocity=game.vehicle.forward*(100/3.6)
        let window=NSWindow(contentRect:game.hud.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=game.hud
        func capture(_ name:String,rect:NSRect) throws {
            guard let bitmap=game.hud.bitmapImageRepForCachingDisplay(in:rect) else { fatalError("No HUD bitmap") }
            game.hud.cacheDisplay(in:rect,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        }
        for frame in 0..<300 {
            let t=Double(frame)/60
            let throttle=t<2.1 ? 1.0 : (t>4.6 ? (t-4.6)*1.2 : max(0,sin(t*38))*0.23)
            let brake=t<2 ? 0 : (t<2.5 ? (t-2)*2 : (t<3.5 ? 0.93+0.07*sin(t*38) : max(0,1-(t-3.5)/0.9)))
            game.inputHistory.update(input:DrivingInput(throttle:throttle,brake:brake),absActive:t>2.5 && t<3.5,dt:1/60,active:true)
        }
        let cases:[(String,Double,Double)] = [("released",0,0),("braking",0,0.65),("throttle",1,0),("overlap",0.31,0.72),("full",1,1),("small",0.01,0.02)]
        for (name,throttle,brake) in cases {
            game.drivingInput=DrivingInput(throttle:throttle,brake:brake)
            // Assistance must not replace what the driver is actually pressing.
            game.vehicle.absActive=true;game.vehicle.absRelease=0.8
            game.vehicle.tcActive=true;game.vehicle.tcReduction=0.7
            game.hud.needsDisplay=true;game.hud.displayIfNeeded()
            try capture(name,rect:NSRect(x:18,y:618,width:414,height:82))
            if name=="overlap" {try capture("minimum-window",rect:game.hud.bounds)}
        }
        game.vehicle.gear=1;game.vehicle.velocity=game.vehicle.forward*(62/3.6)
        game.drivingInput=DrivingInput(throttle:0.45,brake:0,steering:0.3)
        game.hud.needsDisplay=true;game.hud.displayIfNeeded()
        try capture("reference-layout",rect:NSRect(x:18,y:618,width:414,height:82))
        for steering in [-1.0,0,1] {
            game.drivingInput.steering=steering
            game.hud.needsDisplay=true;game.hud.displayIfNeeded()
            try capture("steer-\(Int(steering))",rect:NSRect(x:18,y:618,width:414,height:82))
        }
        game.hud.frame=NSRect(x:0,y:0,width:1440,height:900)
        game.hud.needsDisplay=true;game.hud.displayIfNeeded()
        try capture("large-window",rect:game.hud.bounds)
        print("Rendered six input states, reference layout, three steering positions and two HUD sizes")
    }
}

import AppKit
import SceneKit
import Metal
@main struct RenderReview {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out = base.appendingPathComponent(".build/vehicle-review")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let circuit = Circuit()
        let world = RacingWorld(circuit:circuit,assetsDirectory:base.appendingPathComponent("Assets"))
        let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
        renderer.scene = world.scene; renderer.pointOfView = world.camera
        var car = Vehicle()
        for kind in VehicleKind.allCases {
          world.selectVehicle(kind); car.kind = kind
          for mode in DrivingView.allCases {
            let label = "\(kind.rawValue)-\(mode.rawValue)"
            car.reset(at:circuit.sample(at:70)); world.resetCamera()
            world.update(vehicle:car,input:DrivingInput(),dt:0.1,cockpit:mode.isInterior,ghost:nil,view:mode)
            let start = ProcessInfo.processInfo.systemUptime
            let image = renderer.snapshot(atTime:0,with:NSSize(width:1600,height:900),antialiasingMode:.multisampling4X)
            let data = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try data.write(to:out.appendingPathComponent(label+".png"))
            let jpeg = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.jpeg,properties:[.compressionFactor:0.90])!
            try jpeg.write(to:out.appendingPathComponent(label+".jpg"))
            print(label, "render seconds",ProcessInfo.processInfo.systemUptime-start)
          }
        }
    }
}

import AppKit
import SceneKit
import Metal

/// Diagnostic close-ups at several wheel phases, using the actual runtime mesh.
@main struct WheelReview {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let assets = CommandLine.arguments.count > 1 ? URL(fileURLWithPath:CommandLine.arguments[1]) : base.appendingPathComponent("Assets")
        let out = CommandLine.arguments.count > 2 ? URL(fileURLWithPath:CommandLine.arguments[2]) : base.appendingPathComponent(".build/wheel-fix/render")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let circuit = Circuit(), world = RacingWorld(circuit:Circuit(),assetsDirectory:assets)
        world.selectVehicle(.porsche)
        let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
        renderer.scene = world.scene; renderer.pointOfView = world.camera
        for frame in 0..<4 {
            var car = Vehicle(); car.kind = .porsche; car.reset(at:circuit.sample(at:70))
            car.steeringAngle = frame < 2 ? 0.25 : -0.25
            for i in 0..<4 { car.wheels[i].rotation = Double(frame) * .pi / 2 }
            world.update(vehicle:car,input:DrivingInput(),dt:0,cockpit:false,ghost:nil,view:.chase)
            world.camera.position = world.car.convertPosition(SCNVector3(2.8,0.85,3.5),to:nil)
            world.camera.look(at:world.car.convertPosition(SCNVector3(0.5,0.45,1.0),to:nil))
            let image = renderer.snapshot(atTime:0,with:NSSize(width:1200,height:800),antialiasingMode:.multisampling4X)
            let jpeg = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.jpeg,properties:[.compressionFactor:0.92])!
            try jpeg.write(to:out.appendingPathComponent("wheel-\(frame).jpg"))
        }
        print("Rendered four steering / roll phases")
    }
}

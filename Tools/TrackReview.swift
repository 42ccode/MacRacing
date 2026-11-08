import AppKit
import SceneKit
import Metal
@main struct TrackReview {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let output = base.appendingPathComponent(".build/track-review")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for kind in CircuitKind.allCases {
            let circuit = Circuit(kind:kind)
            let world = RacingWorld(circuit:circuit,assetsDirectory:base.appendingPathComponent("Assets"))
            // Layout inspection from 800 m: move fog beyond the overhead camera.
            // This diagnostic view is not a selectable driving camera.
            world.scene.fogStartDistance = 2000; world.scene.fogEndDistance = 3000
            var car = Vehicle(); car.reset(at:circuit.start)
            world.update(vehicle:car,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
            let xs = circuit.samples.map { $0.point.x }, zs = circuit.samples.map { $0.point.y }
            let x = (xs.min()!+xs.max()!)/2, z = (zs.min()!+zs.max()!)/2
            world.camera.position = SCNVector3(x,800,z)
            world.camera.look(at:SCNVector3(x,0,z),up:SCNVector3(0,0,-1),localFront:SCNVector3(0,0,-1))
            world.camera.camera!.usesOrthographicProjection = true
            world.camera.camera!.orthographicScale = max((xs.max()!-xs.min()!)/1.6,zs.max()!-zs.min()!)*0.63
            let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
            renderer.scene = world.scene; renderer.pointOfView = world.camera
            let frame = renderer.snapshot(atTime:0,with:NSSize(width:1600,height:1000),antialiasingMode:.multisampling4X)
            let data = NSBitmapImageRep(data:frame.tiffRepresentation!)!.representation(using:.jpeg,properties:[.compressionFactor:0.9])!
            try data.write(to:output.appendingPathComponent("track-\(kind.rawValue).jpg"))
            print(kind.name,Int(circuit.length))
        }
    }
}

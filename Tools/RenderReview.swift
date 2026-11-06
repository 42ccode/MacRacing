import AppKit
import SceneKit
import Metal
@main struct RenderReview {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out = base.appendingPathComponent("Docs/Review-0.3")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let circuit = Circuit()
        let world = RacingWorld(circuit:circuit,assetsDirectory:base.appendingPathComponent("Assets"))
        let renderer = SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
        renderer.scene = world.scene; renderer.pointOfView = world.camera
        var car = Vehicle()
        for (label, distance, cockpit) in [("01-cockpit-start",8.0,true),("02-cockpit-corner",235.0,true),("03-cockpit-backstraight",840.0,true),("04-exterior",70.0,false)] {
            car.reset(at:circuit.sample(at:distance)); world.resetCamera()
            world.update(vehicle:car,input:DrivingInput(),dt:0.1,cockpit:cockpit,ghost:nil)
            if cockpit {
                let from = world.camera.position
                let to = vector(car.position+car.forward*4,y:world.seatHeight-0.15)
                let hits = world.scene.rootNode.hitTestWithSegment(from:from,to:to,options:[SCNHitTestOption.searchMode.rawValue:SCNHitTestSearchMode.all.rawValue,SCNHitTestOption.ignoreHiddenNodes.rawValue:true])
                print("center ray",hits.map{ "\($0.node.parent?.name ?? "?") / \($0.node.name ?? "mesh") d=\($0.worldCoordinates)" })
            }
            let start = ProcessInfo.processInfo.systemUptime
            let image = renderer.snapshot(atTime:0,with:NSSize(width:1600,height:900),antialiasingMode:.multisampling4X)
            let data = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try data.write(to:out.appendingPathComponent(label+".png"))
            print(label, "render seconds",ProcessInfo.processInfo.systemUptime-start)
        }
    }
}

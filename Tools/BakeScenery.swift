import AppKit
import SceneKit
import Metal

// Offline impostor authoring: real licensed 3D geometry rendered to four views.
// No scenery is downloaded or generated at runtime.
@main struct BakeScenery {
    static func main() throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = base.appendingPathComponent("Assets/Vegetation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for name in ["tree_small_02", "shrub_01"] {
            let model = try GLTFAsset(url: base.appendingPathComponent(".build/SourceAssets/\(name)/\(name).gltf")).makeScene()
            let (bmin, bmax) = model.boundingBox
            print(name, "bounds", bmin, bmax)
            let height = bmax.y - bmin.y
            let width = max(bmax.x - bmin.x, bmax.z - bmin.z)
            model.position = SCNVector3(-(bmin.x + bmax.x)/2, -bmin.y, -(bmin.z + bmax.z)/2)
            let scene = SCNScene()
            scene.background.contents = NSColor.clear
            scene.lightingEnvironment.contents = base.appendingPathComponent("Assets/Environment/Daylight/kloofendal_48d_partly_cloudy_4k.hdr")
            scene.lightingEnvironment.intensity = 0.7
            scene.rootNode.addChildNode(model)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional
            sun.light!.intensity = 1000; sun.light!.color = NSColor.white
            sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
            scene.rootNode.addChildNode(sun)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.usesOrthographicProjection = true
            let extent = max(height, width) * 1.12
            camera.camera!.orthographicScale = Double(extent / 2)
            camera.camera!.zNear = 0.1; camera.camera!.zFar = 100
            camera.camera!.wantsHDR = true; camera.camera!.wantsExposureAdaptation = false
            camera.camera!.exposureOffset = -0.2
            scene.rootNode.addChildNode(camera)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = scene; renderer.pointOfView = camera
            for i in 0..<4 {
                let a = Double(i) * .pi / 2
                camera.position = SCNVector3(sin(a)*30, Double(height)*0.5, cos(a)*30)
                camera.look(at: SCNVector3(0,height*0.5,0), up: SCNVector3(0,1,0), localFront: SCNVector3(0,0,-1))
                let image = renderer.snapshot(atTime: 0, with: NSSize(width: 1536,height:1536), antialiasingMode: .multisampling4X)
                let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                let filename = "\(name)-\(i).png"
                try png.write(to: output.appendingPathComponent(filename))
                manifest.append(["file":filename,"extent_m":extent,"height_m":height,"source":name])
                print("baked",filename,png.count)
            }
        }
        try JSONSerialization.data(withJSONObject: manifest,options:.prettyPrinted).write(to: output.appendingPathComponent("impostors.json"))
    }
}

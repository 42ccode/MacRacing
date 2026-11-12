import AppKit
import SceneKit
import Metal

/// Unretouched native renders of the 1.5 cockpit, contact patches and circuit.
@main struct DetailReview {
    static func main() throws {
        _ = NSApplication.shared
        let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=base.appendingPathComponent(".build/update-1.5/render")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let circuit=Circuit(), world=RacingWorld(circuit:Circuit(),assetsDirectory:base.appendingPathComponent("Assets"))
        let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
        renderer.scene=world.scene;renderer.pointOfView=world.camera
        func capture(_ name:String) throws {
            let image=renderer.snapshot(atTime:0,with:NSSize(width:1600,height:900),antialiasingMode:.multisampling4X)
            let data=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.jpeg,properties:[.compressionFactor:0.92])!
            try data.write(to:out.appendingPathComponent(name+".jpg"));print("Rendered",name)
        }
        for kind in VehicleKind.allCases {
            world.selectVehicle(kind)
            var car=Vehicle();car.kind=kind;car.reset(at:circuit.sample(at:70))
            for _ in 0..<240 {car.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)}
            world.update(vehicle:car,input:DrivingInput(),dt:0.1,cockpit:true,ghost:nil,view:.cockpit)
            try capture("car-\(kind.rawValue)-cockpit")
            world.update(vehicle:car,input:DrivingInput(),dt:0.1,cockpit:false,ghost:nil,view:.chase)
            world.camera.position=world.car.convertPosition(SCNVector3(3.5,1.25,4.8),to:nil)
            world.camera.look(at:world.car.convertPosition(SCNVector3(0,0.6,0),to:nil),up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
            try capture("car-\(kind.rawValue)-exterior")
        }
        world.car.isHidden=true
        let stand=circuit.sample(at:120)
        world.camera.position=vector(stand.point+stand.right*20-stand.tangent*20,y:7)
        world.camera.look(at:vector(stand.point+stand.right*34,y:1.4),up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
        try capture("track-stand")
        let d=circuit.cornerDistances.first ?? 200, kerb=circuit.sample(at:d)
        world.camera.position=vector(kerb.point+kerb.right*4-kerb.tangent*5,y:0.4)
        world.camera.look(at:vector(kerb.point+kerb.right*6.4,y:0.04),up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
        try capture("track-kerb")
    }
}

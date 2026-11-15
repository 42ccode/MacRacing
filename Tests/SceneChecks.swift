import AppKit
import SceneKit
import simd

@main
struct SceneChecks {
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS  \(message)") }
        else { print("FAIL  \(message)"); failures += 1 }
    }
    // SceneKit's picking API can return no hits before a GPU renderer prepares
    // the scene. Intersect the actual imported triangles in a renderer-free test.
    static func occluder(_ root:SCNNode, from:SCNVector3, to:SCNVector3, ignoring: SCNNode? = nil) -> String? {
        let nearClip = 0.06 / simd_distance(SIMD3(Float(from.x),Float(from.y),Float(from.z)),
                                             SIMD3(Float(to.x),Float(to.y),Float(to.z)))
        func visit(_ node:SCNNode) -> String? {
            if node.isHidden || node === ignoring { return nil }
            if let g=node.geometry, let source=g.sources(for:.vertex).first, source.bytesPerComponent==4 {
                let a=node.simdConvertPosition(SIMD3(Float(from.x),Float(from.y),Float(from.z)),from:root)
                let b=node.simdConvertPosition(SIMD3(Float(to.x),Float(to.y),Float(to.z)),from:root)
                let d=b-a
                // SceneKit's parametric shapes expose a unit mesh on some OS
                // versions. Use their actual metre-sized bounds before the mesh.
                let bounds = g.boundingBox
                let lo = SIMD3<Float>(Float(bounds.min.x),Float(bounds.min.y),Float(bounds.min.z))
                let hi = SIMD3<Float>(Float(bounds.max.x),Float(bounds.max.y),Float(bounds.max.z))
                var near = nearClip, far:Float=1
                for k in 0..<3 {
                    if abs(d[k])<1e-8 {if a[k]<lo[k] || a[k]>hi[k] {far = -1};continue}
                    let x=(lo[k]-a[k])/d[k],y=(hi[k]-a[k])/d[k]
                    near=max(near,min(x,y)); far=min(far,max(x,y))
                }
                let inBounds = near<=far
                if inBounds && (g is SCNPlane || g is SCNBox) {return node.name ?? "fixture"}
                for (elementIndex,el) in g.elements.enumerated() where inBounds && (el.primitiveType == .triangles || el.primitiveType == .triangleStrip) {
                    let m = g.materials.isEmpty ? nil : g.materials[elementIndex % g.materials.count]
                    var detail = ""
                    let hit = source.data.withUnsafeBytes { (verts:UnsafeRawBufferPointer) in
                        el.data.withUnsafeBytes { (indices:UnsafeRawBufferPointer) in
                            func v(_ slot:Int) -> SIMD3<Float> {
                                let offset=slot*el.bytesPerIndex
                                let i:Int
                                switch el.bytesPerIndex {
                                case 1: i=Int(indices[offset])
                                case 2: i=Int(indices.loadUnaligned(fromByteOffset:offset,as:UInt16.self))
                                default: i=Int(indices.loadUnaligned(fromByteOffset:offset,as:UInt32.self))
                                }
                                let p=source.dataOffset+i*source.dataStride
                                return SIMD3(verts.loadUnaligned(fromByteOffset:p,as:Float.self),verts.loadUnaligned(fromByteOffset:p+4,as:Float.self),verts.loadUnaligned(fromByteOffset:p+8,as:Float.self))
                            }
                            for f in 0..<el.primitiveCount {
                                let i = el.primitiveType == .triangles ? 3*f : f
                                let p=v(i), e1=v(i+1)-p, e2=v(i+2)-p
                                let h=simd_cross(d,e2), det=simd_dot(e1,h)
                                if abs(det)<1e-9 {continue}
                                if m?.isDoubleSided == false && ((m?.cullMode == .back && det < 0) || (m?.cullMode == .front && det > 0)) {continue}
                                let t=a-p, u=simd_dot(t,h)/det
                                if u<0 || u>1 {continue}
                                let q=simd_cross(t,e1), w=simd_dot(d,q)/det
                                if w<0 || u+w>1 {continue}
                                let distance=simd_dot(e2,q)/det
                                if distance>nearClip && distance<0.998 { detail = String(format:" %.3fm",distance*simd_length(d)); return true }
                            }
                            return false
                        }
                    }
                    if hit {return (node.name ?? node.parent?.name ?? "mesh")+detail}
                }
            }
            for child in node.childNodes { if let hit=visit(child) {return hit} }
            return nil
        }
        return visit(root)
    }

    static func mirrorVisibility(_ mirror: SCNNode, in world: RacingWorld) -> (visible: Int, tested: Int, blockedBy: [String]) {
        guard let geometry = mirror.geometry, let vertices = geometry.sources(for:.vertex).first,
              let element = geometry.elements.first, element.primitiveCount > 0 else { return (0,0,[]) }
        let eye = world.car.simdConvertPosition(world.camera.simdWorldPosition,from:nil)
        let field = Float(world.camera.camera!.fieldOfView)*Float.pi/180
        let halfHeight = tan(field/2)
        let halfWidth = halfHeight*16/9
        var visible = 0
        var tested = 0
        var blockedBy = Set<String>()
        let stride = max(1,element.primitiveCount/17)
        element.data.withUnsafeBytes { bytes in
            vertices.data.withUnsafeBytes { points in
                for i in Swift.stride(from:0,to:element.primitiveCount,by:stride) {
                    var centre = SIMD3<Float>.zero
                    for corner in 0..<3 {
                        let offset = (i*3+corner)*element.bytesPerIndex
                        let index = Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self))
                        let p = vertices.dataOffset+index*vertices.dataStride
                        centre += SIMD3(points.loadUnaligned(fromByteOffset:p,as:Float.self),
                                        points.loadUnaligned(fromByteOffset:p+4,as:Float.self),
                                        points.loadUnaligned(fromByteOffset:p+8,as:Float.self))/3
                    }
                    tested += 1
                    let local = mirror.simdConvertPosition(centre,to:world.camera)
                    guard local.z < -0.08, abs(local.x/local.z)<halfWidth, abs(local.y/local.z)<halfHeight else {
                        blockedBy.insert("outside frame"); continue
                    }
                    let target = mirror.simdConvertPosition(centre,to:world.car)
                    if let blocker = occluder(world.car,from:SCNVector3(eye.x,eye.y,eye.z),
                                               to:SCNVector3(target.x,target.y,target.z),ignoring:mirror) {
                        blockedBy.insert(blocker.components(separatedBy:" ").first ?? blocker)
                    } else { visible += 1 }
                }
            }
        }
        return (visible,tested,blockedBy.sorted())
    }
    // Inspect referenced vertices, not accessor bounds: the Porsche source shares
    // an axle buffer between left/right meshes. Unreferenced points are not drawn.
    static func wheelVertices(_ root: SCNNode) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        root.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry, let source = geometry.sources(for:.vertex).first,
                  source.bytesPerComponent == 4 else { return }
            var used = Set<Int>()
            for element in geometry.elements {
                element.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    for offset in stride(from:0,to:bytes.count,by:element.bytesPerIndex) {
                        switch element.bytesPerIndex {
                        case 1: used.insert(Int(bytes[offset]))
                        case 2: used.insert(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self)))
                        case 4: used.insert(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))
                        default: break
                        }
                    }
                }
            }
            source.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for index in used.sorted() {
                    let p = source.dataOffset + index * source.dataStride
                    let v = SIMD3<Float>(bytes.loadUnaligned(fromByteOffset:p,as:Float.self),
                        bytes.loadUnaligned(fromByteOffset:p+4,as:Float.self),bytes.loadUnaligned(fromByteOffset:p+8,as:Float.self))
                    result.append(node.simdConvertPosition(v,to:root))
                }
            }
        }
        return result
    }
    static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let gltf = try GLTFAsset(url: assets.appendingPathComponent("CarConcept/CarConcept.glb"))
        let model = try gltf.makeScene()
        let front = model.childNode(withName: "WheelFrontL", recursively: true)!
        let expected = SIMD3<Float>(0.9754932, 0.383759, 1.4856806)
        check(simd_distance(front.simdWorldPosition, expected) < 0.001,
              "GLB fractional matrices retain wheel translation and coordinate conversion")
        let column = model.childNode(withName: "InteriorSteeringCylinder", recursively: true)!
        check(simd_distance(column.simdWorldPosition, SIMD3(0.0009215, 0.5512652, 1.1625408)) < 0.001,
              "Cockpit steering column retains its authored transform")
        let circuit = Circuit()
        let world = RacingWorld(circuit: circuit, assetsDirectory: assets)
        let keyLight = world.scene.rootNode.childNode(withName:"Sunlight",recursively:false)?.light
        world.applyGraphicsQuality(.performance)
        check(keyLight?.shadowMapSize.width == 1024 && keyLight?.shadowCascadeCount == 1 &&
              world.camera.camera?.screenSpaceAmbientOcclusionIntensity == 0,
              "Performance preset reduces scene shading work in addition to antialiasing")
        world.applyGraphicsQuality(.balanced)
        check(keyLight?.shadowMapSize.width == 2048 && keyLight?.shadowCascadeCount == 2 &&
              abs((world.camera.camera?.screenSpaceAmbientOcclusionIntensity ?? 0)-0.55)<0.001,
              "Balanced preset keeps intermediate shadow and ambient detail")
        world.applyGraphicsQuality(.quality)
        check(keyLight?.shadowMapSize.width == 4096 && keyLight?.shadowCascadeCount == 3 &&
              world.camera.camera?.screenSpaceAmbientOcclusionIntensity == 1,
              "Quality preset restores the original lighting settings")
        var marking = Vehicle()
        marking.reset(at:circuit.sample(at:30))
        marking.velocity = marking.forward*18
        marking.wheels[0].slipRatio = -0.88
        marking.wheels[0].normalLoad = 3000
        for _ in 0..<20 {
            world.updateTyreMarks(vehicle:marking,dt:1/120)
            marking.position += marking.velocity/120
        }
        let markNode = world.scene.rootNode.childNode(withName:"TyreMarks",recursively:false)
        let triangles = markNode?.geometry?.elements.first?.primitiveCount ?? 0
        check(triangles > 4 && triangles < 40,"A locking loaded tyre adds short connected marks to the asphalt")
        world.clearTyreMarks()
        marking.wheels[0].normalLoad = 0
        for _ in 0..<20 {
            world.updateTyreMarks(vehicle:marking,dt:1/120)
            marking.position += marking.velocity/120
        }
        check(markNode?.geometry == nil,"Reset clears skid marks and an unloaded wheel leaves none")
        var vehicle = Vehicle()
        vehicle.reset(at: circuit.start)
        let overlap = GhostFrame(time:0,x:vehicle.position.x,z:vehicle.position.y,heading:vehicle.heading)
        let ahead = vehicle.position+vehicle.forward*4
        let separated = GhostFrame(time:0,x:ahead.x,z:ahead.y,heading:vehicle.heading)
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:overlap)
        let invisibleOverlap = world.ghostCar.isHidden
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:separated)
        check(invisibleOverlap && !world.ghostCar.isHidden && (0.40...0.56).contains(world.ghostCar.opacity),
              "Ghost fades inside the player's car and returns smoothly with separation")
        for index in 0..<200 {
            vehicle.heading = Double(index) * 0.08
            vehicle.position += vehicle.forward * 0.2
            world.update(vehicle: vehicle, input: DrivingInput(), dt: 1.0 / 60, cockpit: false, ghost: nil)
        }
        check(simd_dot(world.camera.simdWorldUp, SIMD3<Float>(0, 1, 0)) > 0.90,
              "Chase camera keeps a level horizon after multiple full rotations")
        world.update(vehicle: vehicle, input: DrivingInput(), dt: 1.0 / 60, cockpit: true, ghost: nil)
        let cameraForward = world.camera.simdWorldFront
        let desiredForward = SIMD3<Float>(Float(vehicle.forward.x), 0, Float(vehicle.forward.y))
        check(simd_dot(cameraForward, desiredForward) > 0.99, "Cockpit camera faces the vehicle's forward direction")
        let levelGaze = world.camera.simdWorldFront.y
        var pitching = vehicle
        pitching.pitch = -0.065
        world.update(vehicle:pitching,input:DrivingInput(brake:0.8),dt:1/120,cockpit:true,ghost:nil)
        let firstGaze = world.camera.simdWorldFront.y
        for _ in 0..<60 {
            world.update(vehicle:pitching,input:DrivingInput(brake:0.8),dt:1/120,cockpit:true,ghost:nil)
        }
        let settledGaze = world.camera.simdWorldFront.y
        check(firstGaze < levelGaze && firstGaze > settledGaze && (0.013...0.023).contains(levelGaze-settledGaze),
              "Cockpit gaze follows brake dive smoothly on flat asphalt")
        let rearCamera = world.mirrorCamera
        check(simd_dot(rearCamera.simdWorldFront, desiredForward) < -0.99 && rearCamera.simdWorldUp.y > 0.99,
              "Mirror faces rearward with a level horizon after vehicle rotation")
        var carMeshCount = 0
        var visibleInMirror = 0
        world.car.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            carMeshCount += 1
            if (node.categoryBitMask & rearCamera.camera!.categoryBitMask) != 0 { visibleInMirror += 1 }
        }
        check(carMeshCount > 0 && visibleInMirror == 0, "Mirror excludes every player vehicle mesh")
        let driverRight = SIMD3<Float>(-Float(vehicle.modelX.x), 0, -Float(vehicle.modelX.y))
        for side in [-1.0, 1.0] {
            world.sideLook = side
            for _ in 0..<18 {
                world.update(vehicle: vehicle, input: DrivingInput(), dt: 1/60, cockpit: true, ghost: nil)
            }
            check(simd_dot(world.camera.simdWorldFront, driverRight) * Float(side) > 0.60,
                  "Cockpit glance points toward the requested driver side: \(side)")
        }
        world.sideLook = 0
        for _ in 0..<18 {
            world.update(vehicle: vehicle, input: DrivingInput(), dt: 1/60, cockpit: true, ghost: nil)
        }
        check(abs(simd_dot(world.camera.simdWorldFront, driverRight)) < 0.01, "Cockpit glance returns to centre after release")

        check(world.frontWheels.count == 2 && world.rollingWheels.count == 4,
              "All four imported wheels are attached to animation pivots")
        let steering = world.car.childNode(withName: "InteriorSteeringCylinder", recursively: true)!
        check(abs(steering.simdWorldRight.y) < 0.001,
              "Authored steering-wheel pose is neutralized when steering input is zero")
        vehicle.reset(at: circuit.start)
        for height in [1.00,1.05,1.10] {
            world.seatHeight = height
            world.update(vehicle: vehicle,input: DrivingInput(),dt:1/60,cockpit:true,ghost:nil)
            let eye = world.car.convertPosition(world.camera.position,from:nil)
            let blockers = [-0.55,0,0.55].compactMap { x in
                occluder(world.car, from:eye,to:SCNVector3(x,height-0.09,3))
            }
            check(blockers.isEmpty,"Windscreen sight lines clear at eye height \(height)m: \(blockers)")
        }
        let eye = world.car.convertPosition(world.camera.position,from:nil)
        let testRay = occluder(world.car,from:eye,to:SCNVector3(0,0.62,1.64))
        check(testRay != nil,"Cabin visibility check detects a ray aimed at the dashboard: \(testRay ?? "none")")
        world.resetCamera()
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        let chase = world.car.convertPosition(world.camera.position,from:nil)
        check(chase.z < -5.5 && chase.y > 2 && chase.y < 4,"Switching from cabin immediately places camera behind and above the whole car")
        let seat = world.car.childNode(withName:"InteriorSeatsColor1",recursively:true)!
        check(!seat.isHidden,"Cockpit-only geometry masking is cleared in exterior view")
        for cockpit in [true,false] {
            for inputSign in [-1.0,1.0] {
                vehicle.reset(at:circuit.start)
                for _ in 0..<220 { vehicle.step(1.0/120,input:DrivingInput(throttle:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
                world.resetCamera()
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:cockpit,ghost:nil)
                let screenRight = world.camera.simdWorldRight
                let origin = vehicle.position
                let input = DrivingInput(throttle:0.5,steering:inputSign*0.65)
                for _ in 0..<100 { vehicle.step(1.0/120,input:input,assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
                let delta = vehicle.position-origin
                let lateral = Double(screenRight.x)*delta.x + Double(screenRight.z)*delta.y
                check(inputSign*lateral > 0.15,"Camera-relative turn in \(cockpit ? "cockpit" : "chase"), input \(inputSign), displacement \(String(format:"%.2f",lateral)) m")
                var neutral = vehicle; neutral.steeringAngle = 0
                world.update(vehicle:neutral,input:input,dt:0,cockpit:cockpit,ghost:nil)
                let top = steering.simdConvertVector(SIMD3<Float>(0,1,0),from:nil)
                let neutralWheel = world.frontWheels[0].simdConvertVector(SIMD3<Float>(0,0,1),to:nil)
                world.update(vehicle:vehicle,input:input,dt:0,cockpit:cockpit,ghost:nil)
                let turnedWheel = world.frontWheels[0].simdConvertVector(SIMD3<Float>(0,0,1),to:nil)
                check(Double(simd_dot(turnedWheel-neutralWheel,screenRight))*inputSign>0 && Double(simd_dot(steering.simdConvertVector(top,to:nil)-SIMD3<Float>(0,1,0),screenRight))*inputSign>0,"Road wheels and cockpit steering rim agree with driver input")
            }
        }
        vehicle.reset(at:circuit.start)
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        let hoodMesh = world.body.childNode(withName:"BodyHood",recursively:true)!.childNodes.first { $0.geometry != nil }!
        let originalHood = hoodMesh.geometry!.sources(for:.vertex)[0].data
        vehicle.impact(normalSpeed:22,outwardNormal:vehicle.forward)
        vehicle.damage.rear = 0.7
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        check(hoodMesh.geometry!.sources(for:.vertex)[0].data != originalHood,
              "Nose impact visibly deforms exterior body geometry")
        check(world.body.childNode(withName:"ClubRearWing",recursively:true) == nil &&
              world.frontWheels.contains { $0.scale.y < 0.9 },
              "The concept uses its authored body and punctured wheels lose radius")
        vehicle.service(setup:TyreSetup())
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
        check(hoodMesh.geometry!.sources(for:.vertex)[0].data == originalHood && world.frontWheels.allSatisfy { $0.scale.y == 1 },
              "Repair restores original body geometry and wheel shape")
        for kind in VehicleKind.allCases {
            world.selectVehicle(kind); vehicle.kind = kind; vehicle.reset(at:circuit.start)
            check(world.rollingWheels.count == 4 && world.frontWheels.count == 2,
                  "Vehicle switch rebuilds exactly four wheels: \(kind.label)")
            check(world.rollingWheels.enumerated().allSatisfy { i, wheel in
                let p = wheel.parent!.simdPosition
                let x = (i % 2 == 0 ? -1.0 : 1.0) * vehicle.trackWidth/2
                let z = i < 2 ? kind.frontAxle : -(vehicle.wheelbase-kind.frontAxle)
                return abs(Double(p.x)-x)<0.025 && abs(Double(p.z)-z)<0.025
            }, "Visible wheel centres align with physical contact locations: \(kind.label)")
            for (index, wheel) in world.rollingWheels.enumerated() {
                let points = wheelVertices(wheel)
                var widest:Float = 0, axleError:Float = 0
                for frame in 0..<48 {
                    vehicle.steeringAngle = 0.35 * sin(Double(frame)*0.4)
                    for i in 0..<4 { vehicle.wheels[i].rotation = Double(frame)*0.37 }
                    world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
                    let axle = SIMD3<Float>(Float(cos(vehicle.wheelSteer(index))),0,Float(-sin(vehicle.wheelSteer(index))))
                    let visible = points.map { wheel.simdConvertPosition($0,to:world.car) }
                    let axial = visible.map { simd_dot($0,axle) }
                    widest = max(widest,(axial.max() ?? 0)-(axial.min() ?? 0))
                    axleError = max(axleError,simd_distance(simd_normalize(wheel.simdConvertVector(SIMD3(1,0,0),to:world.car)),axle))
                }
                check(!points.isEmpty && widest < 0.48 && axleError < 0.001,
                      "Actual wheel mesh rolls on its axle during repeated left/right changes: \(kind.label) wheel \(index), axial width \(String(format:"%.3f",widest))m")
                if [.bmw,.centenario].contains(kind) {
                    let caliper = world.car.childNode(withName:"BrakeCaliper\(index)",recursively:true)
                    let before = caliper?.simdWorldTransform
                    vehicle.wheels[index].rotation += .pi/2
                    world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
                    let unchanged = caliper.map { node in
                        (0..<4).allSatisfy { simd_distance(node.simdWorldTransform[$0],before![$0])<0.0001 }
                    } ?? false
                    check(unchanged,"Brake caliper stays fixed while the rim rotates: \(kind.label) wheel \(index)")
                }
            }
            if kind == .centenario {
                let original = world.body.childNode(withName:"OriginalBody",recursively:true)!
                let trim = ["Object_31","Object_35","Object_42","Object_55","Object_69","Object_92"]
                check(trim.allSatisfy { original.childNode(withName:$0,recursively:false)?.childNodes.first?.geometry != nil },
                      "Centenario uses the authored dashboard, trim, seats, door and shell meshes")
            }
            if kind == .mazda || kind == .bmw {
                check(world.body.childNode(withName:"AuthoredSteeringWheel",recursively:true)?.childNodes.first?.geometry != nil,
                      "The replacement retains its original steering wheel geometry: \(kind.label)")
                let trim = kind == .mazda ? "Cube.001_Material.001_0" : "interior_1"
                check(world.body.childNode(withName:trim,recursively:true)?.childNodes.first?.geometry != nil,
                      "The replacement retains the original cabin trim: \(kind.label)")
            }
            if [.mazda,.ferrari,.porsche,.lotus,.honda].contains(kind) {
                check(world.hasMirror(.centre),"The authored cabin mirror displays the central rear feed: \(kind.label)")
            }
            if kind == .porsche {
                let interior = world.body.childNode(withName:"Object_16",recursively:true)
                check(interior?.childNodes.first?.geometry != nil &&
                      world.car.childNode(withName:"AuthoredSteeringWheel",recursively:true) != nil,
                      "The 992 Carrera 4S uses its original cabin and steering wheel geometry")
            }
            check(["LiveInstrumentDisplay","CentenarioTelemetry","AnalogGauge0"].allSatisfy {
                world.body.childNode(withName:$0,recursively:true) == nil
            }, "No procedural instrument geometry inside the car: \(kind.label)")
            vehicle.reset(at:circuit.start)
            var locations: [SIMD3<Float>] = []
            for mode in DrivingView.allCases {
                world.resetCamera()
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:mode.isInterior,ghost:nil,view:mode)
                let p = world.car.convertPosition(world.camera.position,from:nil)
                locations.append(SIMD3(Float(p.x),Float(p.y),Float(p.z)))
                let right = world.camera.simdWorldRight
                check(p.x.isFinite && p.y > 0.3 && simd_dot(right,SIMD3<Float>(Float(-vehicle.modelX.x),0,Float(-vehicle.modelX.y))) > 0.95,
                      "Camera remains level and driver-right aligned: \(kind.label) / \(mode.label)")
                if mode.isInterior || mode == .bonnet || mode == .bumper {
                    let roadSight = kind == .centenario && mode.isInterior ? p.y-0.13 : p.y-0.05
                    let blocked = occluder(world.car,from:p,to:SCNVector3(p.x,roadSight,4))
                    check(blocked == nil,"Driving sight line clear: \(kind.label) / \(mode.label): \(blocked ?? "clear")")
                }
            }
            check(locations.enumerated().allSatisfy { i,p in locations.enumerated().allSatisfy { j,q in i == j || simd_distance(p,q)>0.2 } },
                  "All available viewpoints are distinct: \(kind.label)")
            let mirrorView = DrivingView.cockpit
            world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:mirrorView.isInterior,ghost:nil,view:mirrorView)
            let leftMirror = world.camera(for:.left)
            let rightMirror = world.camera(for:.right)
            let leftLocal = world.car.simdConvertPosition(leftMirror.simdWorldPosition,from:nil)
            let rightLocal = world.car.simdConvertPosition(rightMirror.simdWorldPosition,from:nil)
            check(world.hasMirror(.left) && world.hasMirror(.right) && leftLocal.x > 0.65 && rightLocal.x < -0.65 &&
                  simd_dot(leftMirror.simdWorldFront,rightMirror.simdWorldFront)<0.94 &&
                  world.car.simdConvertVector(leftMirror.simdWorldFront,from:nil).z < -0.9 &&
                  world.car.simdConvertVector(rightMirror.simdWorldFront,from:nil).z < -0.9,
                  "Source mirror faces have independent rear-facing cameras: \(kind.label)")
            do {
                for (mirror,glance) in [(VehicleMirror.left,-0.85),(.centre,0.42),(.right,0.95)] {
                    guard let surface = world.car.childNode(withName:"VehicleMirror-\(mirror)",recursively:true) else { continue }
                    for height in [1.0,1.05,1.10] {
                        world.seatHeight = height
                        world.sideLook = glance
                        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                        let visibility = mirrorVisibility(surface,in:world)
                        check(visibility.tested>0 && visibility.visible*2>=visibility.tested,
                              "Mirror at seat height \(height), \(kind.label) \(mirror): \(visibility.visible)/\(visibility.tested), \(visibility.blockedBy)")
                    }
                }
                world.sideLook = 0
                world.seatHeight = 1.10
            }
            world.updateTraffic([vehicle])
            let opponent = world.scene.rootNode.childNode(withName:"ComputerCar1",recursively:false)
            var opponentSharesLiveMirror = false
            opponent?.enumerateChildNodes { node, _ in
                if node.geometry?.firstMaterial?.name == "LiveMirror" { opponentSharesLiveMirror = true }
            }
            check(opponent != nil && !opponentSharesLiveMirror,"Opponent mirror surfaces retain their own materials: \(kind.label)")
            if kind != .concept {
                check(world.ghostCar.childNodes.allSatisfy { simd_length($0.simdPosition) < 0.001 && simd_dot($0.simdOrientation.vector,SIMD4<Float>(0,0,0,1)) > 0.999 },
                      "Switched vehicle ghost has no stale player transform: \(kind.label)")
                guard let wheel = world.car.childNode(withName:"Steering",recursively:true) else { continue }
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                let neutral = wheel.simdConvertVector(SIMD3<Float>(0,1,0),to:nil)
                vehicle.steeringAngle = -0.15
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                let turned = wheel.simdConvertVector(SIMD3<Float>(0,1,0),to:nil)
                check(simd_dot(turned-neutral,world.camera.simdWorldRight)>0,"New steering wheel turns right with driver-right input: \(kind.label)")
            }
        }
        if failures > 0 { exit(1) }
        print("\nAll asset and camera checks passed.")
    }
}

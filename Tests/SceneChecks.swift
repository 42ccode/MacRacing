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
    static func occluder(_ root:SCNNode, from:SCNVector3, to:SCNVector3,
                         ignoring: SCNNode? = nil, nearDistance: Float = 0.06) -> String? {
        let nearClip = nearDistance / simd_distance(SIMD3(Float(from.x),Float(from.y),Float(from.z)),
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

    static func mirrorVisibility(_ mirror: SCNNode, in world: RacingWorld,
                                 aspect: Float = 16.0/9.0) -> (visible: Int, tested: Int, blockedBy: [String]) {
        guard let geometry = mirror.geometry, let vertices = geometry.sources(for:.vertex).first,
              let element = geometry.elements.first, element.primitiveCount > 0 else { return (0,0,[]) }
        let eye = world.car.simdConvertPosition(world.camera.simdWorldPosition,from:nil)
        let field = Float(world.camera.camera!.fieldOfView)*Float.pi/180
        let halfHeight = tan(field/2)
        let halfWidth = halfHeight*aspect
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

    static func checkPorscheSteeringAxis(_ world: RacingWorld, vehicle: Vehicle) {
        guard let wheel = world.car.childNode(withName:"Steering",recursively:true) else {
            check(false,"911 retains its authored steering wheel rig")
            return
        }
        let rim = wheelVertices(wheel).filter { simd_length(SIMD2($0.x/0.173,$0.y/0.133)) > 0.98 }
        let tilt = Float(32.5 * Double.pi/180)
        let shaft = SIMD3<Float>(0,sin(tilt),-cos(tilt))
        let hub = SIMD3<Float>(0.00022,-0.00577,-0.00368)
        var sample = vehicle
        sample.steeringAngle = 0
        func show(_ pose: Vehicle) {
            world.update(vehicle:pose,input:DrivingInput(),dt:0,cockpit:true,ghost:nil,view:.cockpit)
        }
        show(sample)
        let neutral = wheel.simdTransform
        let neutralRim = rim.map { wheel.simdConvertPosition($0,to:world.body) }
        let neutralHub = wheel.simdConvertPosition(hub,to:world.body)
        var maxAxialTravel: Float = 0, maxHubTravel: Float = 0
        for angle in [-0.52,-0.35,-0.21,-0.09,0.09,0.21,0.35,0.52] {
            sample.steeringAngle = angle
            show(sample)
            for (point,reference) in zip(rim,neutralRim) {
                let moved = wheel.simdConvertPosition(point,to:world.body)-reference
                maxAxialTravel = max(maxAxialTravel,abs(simd_dot(moved,shaft)))
            }
            maxHubTravel = max(maxHubTravel,simd_distance(wheel.simdConvertPosition(hub,to:world.body),neutralHub))
        }
        let liveTurn = wheel.simdTransform
        check(rim.count > 100 && liveTurn != neutral && maxAxialTravel < 0.0003 && maxHubTravel < 0.0001,
              "911 spins its original rim around the inclined shaft without a false tilt or hub orbit")
        var replay = Vehicle()
        replay.applyReplayPose(sample.renderSample,hasElevation:false,braking:false,spray:.zero)
        show(replay)
        let matchesLive = wheel.simdTransform == liveTurn
        sample.steeringAngle = 0
        show(sample)
        check(matchesLive && wheel.simdTransform == neutral &&
              simd_distance(wheel.simdPosition,SIMD3<Float>(0.387547,0.737664,0.472303)) < 0.0001,
              "911 replay and live steering share the same rig, and returning to centre restores the authored transform")
    }
    static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try checkVertexAccessorSlicing()
        try checkCabinMaterials(assets)
        let gltf = try GLTFAsset(url: assets.appendingPathComponent("Vehicles/Centenario.glb"))
        let model = try gltf.makeScene()
        var sourceCount = 0
        var sourcesFitTheirAccessors = true
        model.enumerateChildNodes { node,_ in
            for source in node.geometry?.sources ?? [] where source.vectorCount > 0 {
                sourceCount += 1
                let length = (source.vectorCount-1)*source.dataStride+source.componentsPerVector*source.bytesPerComponent
                sourcesFitTheirAccessors = sourcesFitTheirAccessors &&
                    source.dataOffset == 0 && source.data.count == length
            }
        }
        check(sourceCount > 100 && sourcesFitTheirAccessors,
              "Every Centenario vertex stream is backed only by its own accessor bytes")
        let front = model.childNode(withName: "WheelFL", recursively: true)!
        let expected = SIMD3<Float>(0.848,0.3626,1.345875)
        check(simd_distance(front.simdWorldPosition, expected) < 0.001,
              "GLB fractional matrices retain wheel translation and coordinate conversion")
        let column = model.childNode(withName: "Steering", recursively: true)!
        check(simd_distance(column.simdWorldPosition, SIMD3(0.356,0.7433,0.263375)) < 0.001,
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
        func replayCar(_ track: Circuit,at progress: Double,lane: Double = 0) -> Vehicle {
            var vehicle = Vehicle()
            let station = track.sample(at:progress)
            vehicle.reset(at:TrackSample(point:station.point+station.right*lane,tangent:station.tangent,
                                         distance:station.distance))
            vehicle.velocity = station.tangent*40
            return vehicle
        }
        let originalCamera = world.camera.simdTransform
        let replayCamera = world.tracksideReplayCamera(for:replayCar(circuit,at:85),dt:0,reset:true)
        let firstMount = replayCamera.simdPosition
        let originalAim = replayCamera.simdOrientation
        let tracked = world.tracksideReplayCamera(for:replayCar(circuit,at:91),dt:0.10)
        check(replayCamera !== world.camera && tracked === replayCamera && tracked.simdPosition == firstMount &&
              simd_length(tracked.simdOrientation.vector-originalAim.vector) > 0.02 &&
              world.camera.simdTransform == originalCamera,
              "Trackside replay pans from a fixed place while the separate driving camera stays in its original pose")
        let held = replayCamera.simdTransform
        let seek = replayCar(circuit,at:800)
        _ = world.tracksideReplayCamera(for:seek,dt:0)
        let frozen = replayCamera.simdTransform == held
        _ = world.tracksideReplayCamera(for:seek,dt:0.04)
        let rejectsSkippedPose = replayCamera.simdTransform == held
        _ = world.tracksideReplayCamera(for:seek,dt:0,reset:true)
        check(frozen && rejectsSkippedPose && simd_distance(firstMount,replayCamera.simdPosition) > 50,
              "Paused and skipped frames hold the exact replay pose until a seek explicitly resets the camera")
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:136),dt:0,reset:true)
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:143),dt:0.10)
        let heldThroughGate = firstMount == replayCamera.simdPosition
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:146),dt:0.07)
        let secondMount = replayCamera.simdPosition
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:136),dt:0.10)
        check(heldThroughGate && secondMount != firstMount && replayCamera.simdPosition == secondMount,
              "Replay shot gates have a physical hold distance that prevents cut jitter")
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:circuit.length-2),dt:0,reset:true)
        let closingMount = replayCamera.simdPosition
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:2),dt:0.1)
        let heldAcrossStart = replayCamera.simdPosition == closingMount
        _ = world.tracksideReplayCamera(for:replayCar(circuit,at:8),dt:0.1)
        check(heldAcrossStart && replayCamera.simdPosition == firstMount,
              "A replay crossing the start line transitions smoothly from the final station to the first")
        let wetWorld = RacingWorld(circuit:Circuit(kind:.valley,condition:.wet),assetsDirectory:assets)
        let sky = wetWorld.scene.background.contents as? URL
        var samplesWaterFilm = false
        wetWorld.scene.rootNode.enumerateChildNodes { node,_ in
            guard let geometry = node.geometry, !geometry.sources(for:.color).isEmpty else { return }
            samplesWaterFilm = samplesWaterFilm || geometry.materials.contains {
                $0.shaderModifiers?[.geometry]?.contains("out.waterFilm") == true &&
                $0.shaderModifiers?[.surface]?.contains("in.waterFilm") == true
            }
        }
        check(sky?.lastPathComponent == "kloofendal_overcast_puresky_2k.hdr" &&
              wetWorld.scene.fogStartDistance < world.scene.fogStartDistance && samplesWaterFilm,
              "Wet track uses the attributed overcast sky and keeps the water-depth inputs alongside batched scenery")
        for kind in CircuitKind.allCases {
            autoreleasepool {
                let course = Circuit(kind:kind)
                let scene: SCNScene
                switch kind {
                case .north: scene = world.scene
                case .valley: scene = wetWorld.scene
                default:
                    scene = SCNScene()
                    _ = TrackEnvironment(scene:scene,circuit:course,assets:assets).build()
                }
                let fixtures = scene.rootNode.childNode(withName:"CornerLandmarks",recursively:false)?.childNodes ?? []
                let layout = kind.landmarks
                let namesAreDistinct = Set(layout.map(\.name)).count == 3
                let stayBehindFence = zip(fixtures,layout).allSatisfy { node,spec in
                    let bounds = node.boundingBox
                    let footprint = [bounds.min.x,bounds.max.x].flatMap { x in
                        [bounds.min.z,bounds.max.z].map { z in
                            node.convertPosition(SCNVector3(x,0,z),to:nil)
                        }
                    }
                    let outside = footprint.allSatisfy {
                        course.nearest(to:SIMD2(Double($0.x),Double($0.z))).distance > 18.0
                    }
                    let approach = course.sample(at:spec.corner-120).point
                    let placed = node.simdWorldPosition
                    let toApproach = simd_normalize(approach-SIMD2(Double(placed.x),Double(placed.z)))
                    let front = node.simdWorldFront
                    let facingApproach = simd_dot(toApproach,SIMD2(-Double(front.x),-Double(front.z))) > 0.999
                    return node.name == spec.name && node.geometry != nil && node.physicsBody == nil && outside &&
                        facingApproach && spec.station < spec.corner && course.cornerDistances.contains(spec.corner)
                }
                check(fixtures.count == 3 && namesAreDistinct && stayBehindFence,
                      "Three static, separately culled landmarks face their own safe braking approaches: \(kind.label)")
            }
        }
        let wetCircuit = Circuit(kind:.valley,condition:.wet)
        let wetRoad = wetWorld.scene.rootNode.childNode(withName:"WetDrivingSurface",recursively:false)!
        let originalGeometry = wetRoad.geometry!
        let wetMaterial = originalGeometry.firstMaterial!
        let rows = Int(ceil(wetCircuit.length/3))
        let progress = Int(265/wetCircuit.length*Double(rows))
        let index = progress*13+4
        func film(_ geometry: SCNGeometry) -> SIMD2<Float> {
            let source = geometry.sources(for:.color).first!
            let offset = source.dataOffset+source.dataStride*index
            return source.data.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) in
                SIMD2(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),
                      bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self))
            }
        }
        func blend() -> Float { (wetMaterial.value(forKey:"dryingBlend") as? NSNumber)?.floatValue ?? -1 }
        var worn = TrackDrying(circuit:wetCircuit)
        worn.advance(4)
        for station in stride(from:248.0,through:282,by:0.7) {
            worn.displace(at:station,lateral:-2,travelled:1.85,speed:37,load:3200,treadWidth:0.23)
        }
        let wetFilm = film(originalGeometry).x
        wetWorld.displayTrackDrying(worn,transitioning:true)
        let blendedGeometry = wetRoad.geometry!
        let fromTo = film(blendedGeometry)
        check(abs(fromTo.x-wetFilm) < 1e-6 && fromTo.y < fromTo.x-0.08 && blend() == 0 &&
              blendedGeometry.sources(for:.vertex).first?.data == originalGeometry.sources(for:.vertex).first?.data,
              "A live drying refresh carries the visible and target film on the same road geometry")
        wetWorld.advanceTrackDryingDisplay(0.225)
        check(abs(blend()-0.5) < 1e-6 && wetRoad.geometry === blendedGeometry,
              "Halfway through the drying fade the material mixes both films without reallocating the mesh")
        var rebound = worn
        rebound.advance(2)
        wetWorld.displayTrackDrying(rebound,transitioning:true)
        let retargeted = wetRoad.geometry!
        check(abs(film(retargeted).x-(fromTo.x+fromTo.y)/2) < 1e-6 && blend() == 0,
              "A new drying target during the fade starts from the visible film")
        wetWorld.advanceTrackDryingDisplay(0.45)
        check(blend() == 1 && wetRoad.geometry === retargeted,
              "Drying reaches the exact target at 0.45 seconds without a second geometry swap")
        wetWorld.displayTrackDrying(worn)
        let exact = film(wetRoad.geometry!)
        let seekIsExact = exact.x == exact.y && abs(exact.y-fromTo.y) < 1e-6 && blend() == 1
        wetWorld.displayTrackDrying(nil)
        check(seekIsExact && wetRoad.geometry === originalGeometry,
              "A hard drying seek selects one exact film and reset restores the original wet road")
        let packPlayer = replayCar(wetCircuit,at:98,lane:-1.7)
        let nearbyRivals = [(104.0,1.6),(111.0,-1.8),(119.0,0.5)].map {
            replayCar(wetCircuit,at:$0.0,lane:$0.1)
        }
        let wetCamera = wetWorld.tracksideReplayCamera(for:packPlayer,dt:0,reset:true)
        let wetMount = wetCamera.simdPosition
        let soloFov = wetCamera.camera?.fieldOfView ?? 0
        _ = wetWorld.tracksideReplayCamera(for:packPlayer,dt:0,reset:true,opponents:nearbyRivals)
        let groupFov = wetCamera.camera?.fieldOfView ?? 0
        _ = wetWorld.tracksideReplayCamera(for:packPlayer,dt:0,reset:true,
                                           opponents:[replayCar(wetCircuit,at:188)])
        let distantFov = wetCamera.camera?.fieldOfView ?? 0
        check(groupFov > soloFov+5 && groupFov <= 57 && abs(distantFov-soloFov) < 0.01 &&
              wetCamera.simdPosition == wetMount,
              "The wet replay widens a fixed view for nearby rivals and ignores a distant car")
        wetWorld.applyGraphicsQuality(.performance)
        check(wetCamera.camera?.screenSpaceAmbientOcclusionIntensity == 0,
              "The separate trackside camera follows the race graphics quality")
        wetWorld.applyGraphicsQuality(.quality)
        func sprayCar(at progress: Double,speed: Double,water: [Double]) -> Vehicle {
            var vehicle = Vehicle()
            vehicle.kind = .porsche
            vehicle.reset(at:wetCircuit.sample(at:progress))
            vehicle.velocity = vehicle.forward*speed
            for index in vehicle.wheels.indices { vehicle.wheels[index].angularVelocity = speed/vehicle.wheelRadius }
            var patches = wetCircuit.wheelContacts(at:vehicle.contactPoints)
            for index in patches.indices { patches[index].waterDepth = water[index] }
            vehicle.step(1/240,input:DrivingInput(),assists:DrivingAssists(),
                         roadDistance:0,roadWidth:wetCircuit.width,roadContacts:patches)
            return vehicle
        }
        let splitSpray = sprayCar(at:230,speed:33,water:[0.95,0,0,0.9])
        let contacts = splitSpray.contactPoints
        let patches = contacts.indices.map {
            TyreSpraySample(vehicle:splitSpray,index:$0,contact:contacts[$0],elevation:splitSpray.roadElevation)
        }
        let heading = SIMD3(Float(splitSpray.forward.x),0,Float(splitSpray.forward.y))
        let frontAhead = simd_dot(patches[0].velocity,heading)
        let rearBack = simd_dot(patches[3].velocity,heading)
        let spansBothAxles = simd_dot(patches[0].position-patches[3].position,heading) > Float(splitSpray.wheelbase)
        check(patches[0].strength > 0.65 && patches[1].strength == 0 && patches[2].strength == 0 &&
              patches[3].strength > 0.65 && frontAhead > 0 && rearBack < 0 && spansBothAxles,
              "Split spray originates on the wet wheel patches, with forward bow wash and rearward wake")
        let reversingSpray = sprayCar(at:230,speed:-14,water:[0.95,0,0.95,0])
        let reversePoint = reversingSpray.contactPoints
        let reverseFront = TyreSpraySample(vehicle:reversingSpray,index:0,contact:reversePoint[0],elevation:reversingSpray.roadElevation)
        let reverseRear = TyreSpraySample(vehicle:reversingSpray,index:2,contact:reversePoint[2],elevation:reversingSpray.roadElevation)
        check(simd_dot(reverseFront.velocity,-heading) < 0 && simd_dot(reverseRear.velocity,-heading) > 0,
              "The leading spray moves to the rear axle when the car reverses")
        let wetPack = [235.0,249,270].map { sprayCar(at:$0,speed:40,water:[1.05,1.05,1.05,1.05]) }
        let sprayNodes = wetWorld.scene.rootNode.childNode(withName:"TyreSpray",recursively:false)
        wetWorld.updateSpray(player:splitSpray,opponents:wetPack,cockpit:true,active:false)
        check(sprayNodes?.childNodes.isEmpty == true,"Inactive wet sessions allocate no particle systems")
        wetWorld.updateSpray(player:splitSpray,opponents:wetPack,cockpit:true,active:true)
        let closeSystems = sprayNodes?.childNodes.compactMap { $0.particleSystems?.first } ?? []
        let closeRate = closeSystems.count > 2 ? closeSystems[2].birthRate : 0
        check(closeSystems.count == 8 && closeSystems.allSatisfy { (0...92).contains($0.birthRate) } &&
              (closeSystems.first?.birthRate ?? 0) > 20,
              "A front-only wheel gives visible spray within the two-systems-per-car density limit")
        wetWorld.updateSpray(player:splitSpray,opponents:wetPack,cockpit:false,active:true)
        check(closeRate > 0 && closeSystems.count > 2 && closeSystems[2].birthRate > closeRate*1.25,
              "Close rivals use lighter spray in driving-seat views")
        wetWorld.updateSpray(player:splitSpray,opponents:wetPack,cockpit:true,active:false)
        world.updateSpray(player:splitSpray,opponents:wetPack,cockpit:true,active:true)
        check(closeSystems.allSatisfy { $0.birthRate == 0 } &&
              world.scene.rootNode.childNode(withName:"TyreSpray",recursively:false) == nil,
              "Pausing stops spray births and dry circuits retain an allocation-free path")
        let startLenses = world.scene.rootNode.childNode(withName:"RaceStartLenses",recursively:false)?.childNodes ?? []
        let repeaterLenses = world.scene.rootNode.childNode(withName:"RaceStartRepeater",recursively:false)?.childNodes ?? []
        let wetLenses = wetWorld.scene.rootNode.childNode(withName:"RaceStartLenses",recursively:false)?.childNodes ?? []
        func illuminated(_ lenses: [SCNNode]) -> Int {
            lenses.filter { node in
                guard let color = node.geometry?.firstMaterial?.diffuse.contents as? NSColor,
                      let rgb = color.usingColorSpace(.deviceRGB) else { return false }
                return rgb.redComponent > 0.85
            }.count
        }
        let furthestGridMark = circuit.gridSlot(0,frontMark:true).distance
        let lensPoint = startLenses.first?.worldPosition ?? SCNVector3Zero
        let signalLocation = circuit.nearest(to:SIMD2(Double(lensPoint.x),Double(lensPoint.z)))
        let roadside = repeaterLenses.first?.worldPosition ?? SCNVector3Zero
        let roadsideLocation = circuit.nearest(to:SIMD2(Double(roadside.x),Double(roadside.z)))
        check(startLenses.count == 3 && signalLocation.progress > furthestGridMark+10 && abs(signalLocation.lateral) < 1 &&
              repeaterLenses.count == 3 && roadsideLocation.progress > PitLane.exit && roadsideLocation.lateral < -(circuit.width/2+1),
              "The start gantry and the low repeater are beyond the grid and clear of the pit lane")
        check([3,2,1,0].map { countdown in
            world.setStartLights(countdown:countdown)
            return illuminated(startLenses)+illuminated(repeaterLenses)
        } == [2,4,6,0] && illuminated(wetLenses) == 0,
              "Both start signals light in sync through the countdown and go dark at launch")
        world.setStartLights(countdown:1)
        world.setStartLights(countdown:nil)
        check(illuminated(startLenses+repeaterLenses) == 0,"Leaving a countdown clears the signals for practice")
        let lessonCircuit = Circuit(kind:.valley,condition:.wet)
        let graded = lessonCircuit.samples.first {
            abs(lessonCircuit.roadProfile(at:$0.distance).crossfall) > 0.035 &&
                abs(lessonCircuit.roadProfile(at:$0.distance).height) > 1
        }!
        let zones = graded.distance...(graded.distance+26)
        let lesson = [LessonTrackMarker(progress:graded.distance-10,kind:.brake),
                      LessonTrackMarker(progress:graded.distance+26,kind:.finish)]
        wetWorld.setLessonMarkers(lesson,stopZone:zones)
        let lessonRoot = wetWorld.scene.rootNode.childNode(withName:"LessonTrackMarkers",recursively:false)
        let stopPatch = lessonRoot?.childNode(withName:"LessonStopArea",recursively:false)
        let paint = stopPatch?.geometry?.firstMaterial
        let courseEdge = lessonCircuit.width/2-0.7
        let actual = stopPatch?.geometry?.sources(for:.vertex).first
        let startOfPaint = [-courseEdge,courseEdge].map { lateral -> SIMD3<Float> in
            let point = graded.point+graded.right*lateral
            let height = lessonCircuit.roadProfile(at:graded.distance,lateral:lateral).height+0.044
            return SIMD3(Float(point.x),Float(height),Float(point.y))
        }
        let followsBank = actual.map { source in
            source.data.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) in
                startOfPaint.indices.allSatisfy { i in
                    let offset = source.dataOffset+i*source.dataStride
                    let p = SIMD3(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),
                                  bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self),
                                  bytes.loadUnaligned(fromByteOffset:offset+8,as:Float.self))
                    return simd_distance(p,startOfPaint[i]) < 0.001
                }
            }
        }
        check(followsBank == true && paint?.readsFromDepthBuffer == true && paint?.writesToDepthBuffer == false &&
              lessonRoot?.childNodes.count == 7,
              "Lesson cones and translucent markings use the banked road height and preserve depth")
        let firstNodes = lessonRoot?.childNodes.map(ObjectIdentifier.init)
        wetWorld.setLessonMarkers(lesson,stopZone:zones)
        check(lessonRoot?.childNodes.map(ObjectIdentifier.init) == firstNodes,
              "Repeated presentation reuses exactly the same lesson marker geometry")
        wetWorld.setLessonMarkers([])
        check(lessonRoot?.childNodes.isEmpty == true,"Leaving lessons removes all coaching gates and markings")
        for mirror in [VehicleMirror.left,.right] {
            let order = VehicleMirror.refreshOrder(focused:mirror)
            check(order.first == mirror && order.filter({ $0 == mirror }).count == 3 && Set(order).count == 3,
                  "Looking at the \(mirror) mirror prioritizes its next frame while preserving the other feeds")
        }
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
        vehicle.kind = .centenario
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
        let steering = world.car.childNode(withName: "Steering", recursively: true)!
        check(abs(steering.simdWorldRight.y) < 0.001,
              "Authored steering-wheel pose is neutralized when steering input is zero")
        world.resetCamera()
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        let chase = world.car.convertPosition(world.camera.position,from:nil)
        check(chase.z < -5.5 && chase.y > 2 && chase.y < 4,"Switching from cabin immediately places camera behind and above the whole car")
        let seat = world.car.childNode(withName:"Object_55",recursively:true)!
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
                // A physical rim can rotate past 180 degrees. Measure its
                // initial direction close to centre, before the top passes below.
                var slight = vehicle
                slight.steeringAngle = clamp(vehicle.steeringAngle,-0.08,0.08)
                world.update(vehicle:slight,input:input,dt:0,cockpit:cockpit,ghost:nil)
                let rimMotion = steering.simdConvertVector(top,to:nil)-SIMD3<Float>(0,1,0)
                check(Double(simd_dot(turnedWheel-neutralWheel,screenRight))*inputSign>0 &&
                      Double(simd_dot(rimMotion,screenRight))*inputSign>0,
                      "Road wheels and initial cockpit steering rim motion agree with driver input")
            }
        }
        vehicle.reset(at:circuit.start)
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        let hoodMesh = world.body.childNode(withName:"Object_92",recursively:true)!.childNodes.first { $0.geometry != nil }!
        let originalHood = hoodMesh.geometry!.sources(for:.vertex)[0].data
        vehicle.impact(normalSpeed:22,outwardNormal:vehicle.forward)
        vehicle.damage.rear = 0.7
        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil)
        check(hoodMesh.geometry!.sources(for:.vertex)[0].data != originalHood,
              "Nose impact visibly deforms exterior body geometry")
        check(world.frontWheels.contains { $0.scale.y < 0.9 },
              "Punctured wheels lose radius")
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
                if kind == .centenario {
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
            if kind == .porsche {
                check(world.hasMirror(.centre),"The authored cabin mirror displays the central rear feed: \(kind.label)")
            }
            if kind == .porsche {
                let interior = world.body.childNode(withName:"Object_16",recursively:true)
                check(interior?.childNodes.first?.geometry != nil &&
                      world.car.childNode(withName:"AuthoredSteeringWheel",recursively:true) != nil,
                      "The 992 Carrera 4S uses its original cabin and steering wheel geometry")
                checkPorscheSteeringAxis(world,vehicle:vehicle)
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
            if kind == .porsche {
                let ridge = Circuit(kind:.ridge)
                let cabin = RacingWorld(circuit:ridge,assetsDirectory:assets,vehicleKind:kind)
                var banked = vehicle
                banked.reset(at:ridge.sample(at:721.587))
                banked.pitch = 0.0089
                banked.roll = 0.0834
                banked.heave = -0.004 + banked.pitch*kind.centreOfGravityOffset
                cabin.seatHeight = 1.0
                cabin.sideLook = 1
                for field: CGFloat in [42,62,84] {
                    cabin.cockpitFOV = field
                    cabin.update(vehicle:banked,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                    let eye = cabin.car.simdConvertPosition(cabin.camera.simdWorldPosition,from:nil)
                    let ray = SIMD3<Float>(-0.029,-0.022,-0.06)
                    let target = cabin.camera.simdConvertPosition(ray,to:cabin.car)
                    let near = Float(cabin.camera.camera!.zNear)
                    let start = simd_length(ray)*near/abs(ray.z)
                    let surface = occluder(cabin.car,from:SCNVector3(eye),to:SCNVector3(target),nearDistance:start)
                    check(near == 0.015 && surface?.hasPrefix("Object_16") == true,
                          "911 cockpit keeps the authored dashboard inside the \(field)° viewing frustum under roll: \(surface ?? "clipped")")
                }
                cabin.update(vehicle:banked,input:DrivingInput(),dt:0,cockpit:false,ghost:nil,view:.chase)
                check(cabin.camera.camera?.zNear == 0.06,"911 chase camera restores the standard near clipping distance")
                cabin.update(vehicle:banked,input:DrivingInput(),dt:0,cockpit:true,ghost:nil,view:.dashboard)
                check(cabin.camera.camera?.zNear == 0.06,"911 forward dashboard camera keeps the standard near clipping distance")
            }
            check(locations.enumerated().allSatisfy { i,p in locations.enumerated().allSatisfy { j,q in i == j || simd_distance(p,q)>0.2 } },
                  "All available viewpoints are distinct: \(kind.label)")
            let previousSeatHeight = world.seatHeight
            var unobstructed = true
            let forwardRays = [(0.0,0.0),(-9,3),(0,3),(9,3),(-9,6),(0,6),(9,6)]
            for height in [1.0,1.10] { for pitch in [-0.03,0.0,0.03] {
                world.seatHeight = height
                vehicle.reset(at:circuit.start)
                vehicle.pitch = pitch
                world.resetCamera()
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                let eye = world.car.convertPosition(world.camera.worldPosition,from:nil)
                unobstructed = unobstructed && forwardRays.allSatisfy { yaw,elevation in
                    let angle = yaw * .pi/180
                    let target = SCNVector3(eye.x+sin(angle)*40,eye.y+tan(elevation * .pi/180)*40,eye.z+cos(angle)*40)
                    return occluder(world.car,from:eye,to:target) == nil
                }
            } }
            check(unobstructed,"Forward sight clears roof and dashboard across seat travel during small pitch changes: \(kind.label)")
            for grid in [0,3] { for height in [1.0,1.10] {
                world.seatHeight = height
                vehicle.reset(at:circuit.gridSlot(grid))
                world.resetCamera()
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                let eye = world.car.convertPosition(world.camera.worldPosition,from:nil)
                let viewLimit = tan((world.camera.camera!.fieldOfView/2) * .pi/180)
                check([startLenses,repeaterLenses].contains { lenses in
                    lenses.count == 3 && lenses.allSatisfy { lens in
                        let projected = world.camera.convertPosition(lens.worldPosition,from:nil)
                        let withinView = projected.z < -0.06 &&
                            abs(projected.y/projected.z) < viewLimit && abs(projected.x/projected.z) < viewLimit*16/9
                        let target = world.car.convertPosition(lens.worldPosition,from:nil)
                        return withinView && occluder(world.car,from:eye,to:target) == nil
                    }
                }, "A full start-light set is visible from grid slot \(grid+1) at seat height \(height): \(kind.label)")
            } }
            world.seatHeight = previousSeatHeight
            vehicle.reset(at:circuit.start)
            let mirrorView = DrivingView.cockpit
            world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:mirrorView.isInterior,ghost:nil,view:mirrorView)
            if kind == .porsche {
                let liner = world.car.childNode(withName:GLTFAsset.porscheWindshieldLinerName,recursively:true)
                let hiddenInCockpit = liner?.isHidden == true
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:false,ghost:nil,view:.chase)
                check(hiddenInCockpit && liner?.isHidden == false && liner?.geometry?.elements.first?.primitiveCount == 3296,
                      "911 uses the clean sightline in the cockpit and preserves the exterior windshield liner")
                world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil,view:.cockpit)
            }
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
                let previousFOV = world.cockpitFOV
                if let surface = world.car.childNode(withName:"VehicleMirror-left",recursively:true) {
                    world.sideLook = -1
                    world.cockpitFOV = 42
                    for height in [1.0,1.05,1.10] {
                        world.seatHeight = height
                        world.resetCamera()
                        world.update(vehicle:vehicle,input:DrivingInput(),dt:0,cockpit:true,ghost:nil)
                        let coverage = mirrorVisibility(surface,in:world,aspect:900.0/664.0)
                        check(coverage.tested > 0 && coverage.visible*10 >= coverage.tested*9,
                              "Narrow cockpit frames driver's mirror at seat height \(height): \(kind.label) \(coverage.visible)/\(coverage.tested) \(coverage.blockedBy)")
                    }
                } else { check(false,"Original driver's mirror is available for the narrow cockpit: \(kind.label)") }
                world.cockpitFOV = previousFOV
                world.sideLook = 0
                world.seatHeight = 1.10
            }
            world.updateTraffic(Array(repeating:vehicle,count:RacingWorld.rivalPaintColors.count))
            let opponent = world.scene.rootNode.childNode(withName:"ComputerCar1",recursively:false)
            if let wheel = opponent?.childNode(withName:"TrafficSteer0",recursively:false) {
                var damaged = vehicle
                damaged.wheels[0].punctured = true
                damaged.damage.suspension[0] = 0.75
                world.updateTraffic([damaged,vehicle,vehicle])
                let punctureScale = wheel.scale.y
                let damagedUp = wheel.simdOrientation.act(SIMD3<Float>(0,1,0))
                world.updateTraffic([vehicle,vehicle,vehicle])
                check(abs(punctureScale-0.84) < 1e-5 && abs(damagedUp.x) > 0.07 &&
                      abs(wheel.scale.y-1) < 1e-5 && abs(wheel.simdOrientation.act(SIMD3<Float>(0,1,0)).x) < 1e-5,
                      "A rival displays a puncture and bent suspension, then restores the repaired wheel: \(kind.label)")
            } else { check(false,"Rival front wheel is available for damage presentation: \(kind.label)") }
            var opponentSharesLiveMirror = false
            opponent?.enumerateChildNodes { node, _ in
                if node.geometry?.firstMaterial?.name == "LiveMirror" { opponentSharesLiveMirror = true }
            }
            check(opponent != nil && !opponentSharesLiveMirror,"Opponent mirror surfaces retain their own materials: \(kind.label)")
            func rivalPaint(in root: SCNNode?) -> [SCNMaterial] {
                var tinted: [SCNMaterial] = []
                root?.enumerateChildNodes { node,_ in
                    tinted += (node.geometry?.materials ?? []).filter { $0.name == "RivalPaint" }
                }
                return tinted
            }
            var texturedRivalShaders = Set<String>()
            let colorsMatch = RacingWorld.rivalPaintColors.enumerated().allSatisfy { index,color in
                let root = world.scene.rootNode.childNode(withName:"ComputerCar\(index+1)",recursively:false)
                let painted = rivalPaint(in:root)
                guard !painted.isEmpty else { return false }
                if kind == .porsche {
                    let modifiers = painted.compactMap { $0.shaderModifiers?[.surface] }
                    guard let shader = modifiers.first, modifiers.count == painted.count,
                          painted.allSatisfy({ !($0.diffuse.contents is NSColor) && $0.diffuse.contents != nil }) else { return false }
                    return texturedRivalShaders.insert(shader).inserted
                }
                return painted.allSatisfy { ($0.diffuse.contents as? NSColor) == NSColor(rgb:color) }
            }
            check(colorsMatch && rivalPaint(in:world.car).isEmpty,
                  "The three rivals have stable distinct paint while the player's paint stays authored: \(kind.label)")
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
        try checkShowcase(assets)
        if failures > 0 { exit(1) }
        print("\nAll asset and camera checks passed.")
    }

    static func checkVertexAccessorSlicing() throws {
        let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/gltf-accessor-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let values: [Float] = [
            100,101,102,103,
            99,1,2,3,0,1,0,88,
            99,4,5,6,1,0,0,88,
            99,7,8,9,0,0,1,88,
            104,105
        ]
        var buffer = values.withUnsafeBufferPointer { Data(buffer:$0) }
        let indexOffset = buffer.count
        let indices: [UInt16] = [0,1,2]
        buffer.append(indices.withUnsafeBufferPointer { Data(buffer:$0) })
        try buffer.write(to:folder.appendingPathComponent("interleaved.bin"))
        let asset = folder.appendingPathComponent("interleaved.gltf")
        func writeFixture(positionCount: Int) throws {
            let json: [String:Any] = [
                "asset":["version":"2.0"],
                "buffers":[["uri":"interleaved.bin","byteLength":buffer.count]],
                "bufferViews":[["buffer":0,"byteOffset":16,"byteLength":96,"byteStride":32],
                               ["buffer":0,"byteOffset":indexOffset,"byteLength":6]],
                "accessors":[["bufferView":0,"byteOffset":4,"componentType":5126,"count":positionCount,"type":"VEC3"],
                             ["bufferView":0,"byteOffset":16,"componentType":5126,"count":3,"type":"VEC3"],
                             ["bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"]],
                "meshes":[["primitives":[["attributes":["POSITION":0,"NORMAL":1],"indices":2]]]],
                "nodes":[["mesh":0]],"scenes":[["nodes":[0]]],"scene":0
            ]
            try JSONSerialization.data(withJSONObject:json).write(to:asset)
        }
        try writeFixture(positionCount:3)
        let model = try GLTFAsset(url:asset).makeScene(identifyPrimitives:true)
        let geometry = model.childNode(withName:"0.0",recursively:true)!.geometry!
        let position = geometry.sources(for:.vertex).first!
        let normal = geometry.sources(for:.normal).first!
        func vector(_ source: SCNGeometrySource,index: Int) -> SIMD3<Float> {
            let offset = source.dataOffset+index*source.dataStride
            return source.data.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) in
                SIMD3(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self),
                      bytes.loadUnaligned(fromByteOffset:offset+4,as:Float.self),
                      bytes.loadUnaligned(fromByteOffset:offset+8,as:Float.self))
            }
        }
        check([position,normal].allSatisfy { $0.dataOffset == 0 && $0.dataStride == 32 && $0.data.count == 76 } &&
              vector(position,index:0) == SIMD3(1,2,3) && vector(position,index:2) == SIMD3(7,8,9) &&
              vector(normal,index:0) == SIMD3(0,1,0) && vector(normal,index:2) == SIMD3(0,0,1) &&
              geometry.elements.first?.primitiveCount == 1,
              "Sliced vertex streams preserve interleaving, both offsets and the original triangle")
        try writeFixture(positionCount:4)
        do {
            _ = try GLTFAsset(url:asset).makeScene()
            check(false,"A vertex accessor cannot read past its declared buffer view")
        } catch GLTFError.invalid(let reason) {
            check(reason == "Vertex accessor exceeds its buffer view",
                  "A vertex accessor cannot read past its declared buffer view")
        }
    }

    static func checkCabinMaterials(_ assets: URL) throws {
        let cases: [(VehicleKind,String,String)] = [(.porsche,"18.0","3.0"),(.centenario,"52.0","69.0")]
        for (kind,dashID,exteriorID) in cases {
            let url = assets.appendingPathComponent("Vehicles/\(kind.assetName).glb")
            let model = try GLTFAsset(url:url).makeScene(identifyPrimitives:true)
            let dash = model.childNode(withName:dashID,recursively:true)?.geometry
            let exterior = model.childNode(withName:exteriorID,recursively:true)?.geometry
            let stock = dash?.firstMaterial
            let stockMetalness = stock?.metalness.contents as? NSNumber
            let stockTexture = stock?.diffuse.contents as? NSImage
            let stockIndices = dash?.elements.first?.data
            let sharesInteriorMaterial = stock != nil && stock === exterior?.firstMaterial
            let badge = model.childNode(withName:kind == .porsche ? "AuthoredSteeringWheel" : "57.0",recursively:true)
                .flatMap { $0.geometry ?? $0.childNodes.first?.geometry }
            let badgeMaterial = badge?.firstMaterial
            GLTFAsset.applyCabinMaterials(to:model,kind:kind)
            let cabin = dash?.firstMaterial
            let preservesTexture = stockTexture != nil && cabin?.diffuse.contents as? NSImage === stockTexture
            check(sharesInteriorMaterial && cabin != nil && cabin !== stock &&
                  (cabin?.metalness.contents as? NSNumber)?.doubleValue == 0 &&
                  (cabin?.roughness.contents as? NSNumber)?.doubleValue == (kind == .porsche ? 0.76 : 0.57) &&
                  exterior?.firstMaterial === stock && stock?.metalness.contents as? NSNumber == stockMetalness &&
                  dash?.elements.first?.data == stockIndices && preservesTexture && badge?.firstMaterial === badgeMaterial,
                  "Dielectric cabin keeps original geometry, texture, exterior material and steering badge: \(kind.label)")
        }
    }

    static func checkShowcase(_ assets: URL) throws {
        let gallery = try VehicleShowcase(kind:.centenario,assetRoot:assets)
        for kind in VehicleKind.allCases {
            try gallery.select(kind)
            let base = try GLTFAsset(url:assets.appendingPathComponent("Vehicles/\(kind.assetName).glb")).makeScene(identifyPrimitives:true)
            func triangleCount(_ root: SCNNode) -> Int {
                var count = 0
                root.enumerateChildNodes { node, _ in
                    if node.name?.first?.isNumber == true || node.name == GLTFAsset.porscheWindshieldLinerName {
                        count += node.geometry?.elements.first?.primitiveCount ?? 0
                    }
                }
                return count
            }
            check(triangleCount(base) == triangleCount(gallery.scene.rootNode),
                  "Showcase partitions keep every authored triangle: \(kind.label)")
            if kind == .porsche {
                let door = gallery.scene.rootNode.childNode(withName:"showcase-left",recursively:true)
                let vertices = door?.childNodes.reduce(0) { total,node in
                    total + (node.geometry?.sources(for:.vertex).first?.vectorCount ?? 0)
                } ?? 0
                check((1...10_000).contains(vertices),
                      "Detached door uses a compact vertex buffer as well as the original faces: \(kind.label)")
            }
            if kind == .porsche {
                let liner = gallery.scene.rootNode.childNode(withName:GLTFAsset.porscheWindshieldLinerName,recursively:true)
                let visibleFromOutside = liner?.isHidden == false
                gallery.setView(.cabin)
                let visibleFromCabin = liner?.isHidden == false
                gallery.setView(.front)
                check(visibleFromOutside && !visibleFromCabin && liner?.isHidden == false,
                      "911 gallery keeps its exterior glazing and clears the cabin inspection view")
            } else {
                var windows: [SCNNode] = []
                gallery.scene.rootNode.enumerateChildNodes { node,_ in
                    if node.geometry?.firstMaterial?.name == "material_31" { windows.append(node) }
                }
                let visibleOutside = windows.count >= 3 && windows.allSatisfy { !$0.isHidden }
                gallery.setView(.cabin)
                let clearsCabin = windows.allSatisfy(\.isHidden)
                gallery.setView(.front)
                check(visibleOutside && clearsCabin && windows.allSatisfy { !$0.isHidden },
                      "Centenario retains its original windshield and side glass around a clear cabin inspection view")
            }
            check(gallery.supports(.head) && gallery.supports(.tail) && gallery.supports(.front) &&
                  gallery.openPanels.isEmpty && gallery.activeLamps.isEmpty && !gallery.cabinLightOn,
                  "Showcase loads with closed panels and independent lights: \(kind.label)")
            let doors = [ShowcasePanel.left,.right]
            check(doors.allSatisfy { gallery.supports($0) } &&
                  !gallery.supports(.rearLeft) && !gallery.supports(.rearRight) &&
                  gallery.supports(.rear) == (kind == .centenario),
                  "Vehicle panel controls follow the authored geometry: \(kind.label)")
            func surface(_ id: String,on panel: ShowcasePanel) -> SCNNode? {
                let hinge = gallery.scene.rootNode.childNode(withName:"showcase-"+panel.rawValue,recursively:true)
                return hinge?.childNodes.first { $0.name == id }
            }
            for (index,door) in doors.enumerated() {
                let mirror = kind == .porsche ? "24.0" : (index == 0 ? "70.0" : "78.0")
                let lining = kind == .porsche ? "26.0" : (index == 0 ? "72.0" : "80.0")
                check(surface(mirror,on:door)?.geometry != nil && surface(lining,on:door)?.geometry != nil,
                      "Authored mirror glass and cabin trim move with the \(door.rawValue) door: \(kind.label)")
            }
            let available = ShowcasePanel.allCases.filter { gallery.supports($0) }
            gallery.toggleAllPanels()
            check(gallery.allPanelsOpen && gallery.openPanels == Set(available),
                  "Showcase toggles all supported panels together: \(kind.label)")
            for _ in 0..<55 { gallery.update(1/60) }
            for panel in available {
                let hinge = gallery.scene.rootNode.childNode(withName:"showcase-"+panel.rawValue,recursively:true)
                let panelSurface = hinge?.childNodes.first(where: { $0.geometry != nil })
                check((hinge?.simdOrientation.angle ?? 0) > 0.4 &&
                      panelSurface.map { gallery.panel(containing:$0) == panel } == true,
                      "Showcase opens \(panel.rawValue) on its hinge: \(kind.label)")
            }
            gallery.toggleAllPanels()
            gallery.toggle(.head as VehicleShowcase.Lamp)
            gallery.toggle(.tail)
            gallery.toggleCabinLight()
            for _ in 0..<55 { gallery.update(1/60) }
            check(gallery.openPanels.isEmpty && gallery.activeLamps == [.head,.tail] && gallery.cabinLightOn &&
                  available.allSatisfy { panel in
                      let hinge = gallery.scene.rootNode.childNode(withName:"showcase-"+panel.rawValue,recursively:true)
                      return (hinge?.simdOrientation.angle ?? 1) < 0.001
                  }, "Showcase closes through reverse travel while lamps stay on: \(kind.label)")
            gallery.setView(.cabin)
            let seat = gallery.camera.simdPosition
            let field = gallery.camera.camera?.fieldOfView
            let before = gallery.camera.simdWorldFront
            gallery.zoom(6)
            gallery.moveCamera(SIMD3(0.7,-0.1,0),dt:0.08)
            check(gallery.camera.simdPosition == seat && gallery.camera.camera?.fieldOfView != field &&
                  gallery.camera.simdWorldFront.x < before.x,
                  "Seat inspection keeps eye position and zoom during rotation: \(kind.label)")
        }
    }
}

import AppKit
import SceneKit
import simd

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(calibratedRed: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}

func vector(_ point: SIMD2<Double>, y: Double = 0) -> SCNVector3 {
    SCNVector3(Float(point.x), Float(y), Float(point.y))
}

func material(_ color: NSColor, metal: CGFloat = 0, roughness: CGFloat = 0.8) -> SCNMaterial {
    let result = SCNMaterial()
    result.diffuse.contents = color
    result.lightingModel = .physicallyBased
    result.metalness.contents = metal
    result.roughness.contents = roughness
    return result
}

struct SeededRandom {
    var state: UInt64 = 0xABCDEF0123456789
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}

final class RacingWorld {
    let scene = SCNScene()
    let camera = SCNNode()
    let car = SCNNode()
    let ghostCar = SCNNode()
    let body = SCNNode()
    let steeringWheel = SCNNode()
    private let sunlight = SCNNode()
    var frontWheels: [SCNNode] = []
    var rollingWheels: [SCNNode] = []
    private struct DamageMesh {
        let node: SCNNode
        let original: SCNGeometry
        let vertices: [SIMD3<Float>]
        let toBody: simd_float4x4
    }
    private var damageMeshes: [DamageMesh] = []
    private var renderedDamage = SIMD2<Double>.zero
    private var brakeLights: [SCNMaterial] = []
    private var cameraPosition = SIMD3<Float>.zero
    private var cameraReady = false
    private var chaseYaw = 0.0
    private var wheelPivots: [SCNNode] = []
    private var wheelBaseHeights: [CGFloat] = []
    private var importedSteering: SCNNode?
    private var steeringBase = matrix_identity_float4x4
    private let assetsDirectory: URL
    private var glassNodes: [SCNNode] = []
    private var seatNodes: [SCNNode] = []
    private let instrumentMaterial = SCNMaterial()
    private var instrumentClock = 1.0
    var cockpitFOV: CGFloat = 62
    var seatHeight: Double = 1.00
    var exteriorLook = 0.0

    private func assetURL(_ path: String) -> URL? {
        let url = assetsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private let circuit: Circuit
    init(circuit: Circuit, assetsDirectory: URL? = nil) {
        self.circuit = circuit
        self.assetsDirectory = assetsDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("Assets")
        if let sky = assetURL("Environment/Daylight/kloofendal_48d_partly_cloudy_4k.hdr") {
            scene.background.contents = sky
            scene.lightingEnvironment.contents = sky
        }
        scene.fogColor = NSColor(rgb: 0xB6C3CE)
        scene.fogStartDistance = 380
        scene.fogEndDistance = 1700
        scene.lightingEnvironment.intensity = 0.65

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColor(rgb: 0xD7E4ED)
        ambient.light!.intensity = 18
        scene.rootNode.addChildNode(ambient)
        let sun = sunlight
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.color = NSColor(rgb: 0xFFF9F0)
        sun.light!.intensity = 1050
        sun.light!.castsShadow = true
        sun.light!.shadowMode = .deferred
        sun.light!.shadowColor = NSColor.black.withAlphaComponent(0.62)
        sun.light!.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light!.shadowSampleCount = 8
        sun.light!.shadowBias = 0.03
        sun.light!.orthographicScale = 55
        sun.light!.maximumShadowDistance = 100
        sun.light!.shadowCascadeCount = 3
        sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
        scene.rootNode.addChildNode(sun)

        TrackEnvironment(scene: scene, circuit: circuit, assets: self.assetsDirectory).build()
        buildCar()

        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 62
        camera.camera!.zNear = 0.06
        camera.camera!.zFar = 1500
        camera.camera!.wantsHDR = true
        camera.camera!.wantsExposureAdaptation = false
        camera.camera!.exposureOffset = -0.25
        camera.camera!.whitePoint = 1.0
        camera.camera!.saturation = 0.88
        camera.camera!.screenSpaceAmbientOcclusionIntensity = 1.0
        camera.camera!.screenSpaceAmbientOcclusionRadius = 0.28
        camera.camera!.screenSpaceAmbientOcclusionBias = 0.025
        camera.camera!.screenSpaceAmbientOcclusionDepthThreshold = 0.7
        camera.camera!.bloomIntensity = 0
        camera.camera!.bloomThreshold = 1.3
        scene.rootNode.addChildNode(camera)
    }

    private func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, at position: SCNVector3,
                     material: SCNMaterial, parent: SCNNode? = nil, chamfer: CGFloat = 0) -> SCNNode {
        let shape = SCNBox(width: width, height: height, length: length, chamferRadius: chamfer)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.position = position
        (parent ?? scene.rootNode).addChildNode(node)
        return node
    }

    private func buildCar() {
        car.addChildNode(body)
        scene.rootNode.addChildNode(car)
        guard let url = assetURL("CarConcept/CarConcept.glb"),
              let asset = try? GLTFAsset(url: url), let model = try? asset.makeScene() else {
            fatalError("The bundled Car Concept model could not be loaded. Rebuild with ./build.sh.")
        }
        body.addChildNode(model)
        // Functional, matte cockpit; preserve the authored upholstery normal map,
        // but replace the red display-car trim with charcoal and neutral aluminium.
        model.enumerateChildNodes { node, _ in
            for m in node.geometry?.materials ?? [] {
                switch m.name ?? "" {
                case "Interior 3 Carmine":
                    m.diffuse.contents = NSColor(rgb: 0x181B1D)
                    m.metalness.contents = 0; m.roughness.contents = 0.94
                    m.clearCoat.contents = 0; m.normal.intensity = 0.18
                case "Interior 1", "Interior 2", "Dashboard", "Panel Sides":
                    m.roughness.contents = 0.88; m.clearCoat.contents = 0
                    m.normal.intensity = 0.22
                case "Paint 1 Carmine":
                    m.diffuse.contents = NSColor(rgb: 0x566875)
                    m.metalness.contents = 0.52; m.roughness.contents = 0.30
                case "Paint 2 Carmine":
                    m.diffuse.contents = NSColor(rgb: 0x32383B)
                    m.roughness.contents = 0.5
                default: break
                }
            }
        }
        let top = model.childNodes[0]
        // Asset labels use +X for L; physics wheel order is world -X, +X.
        let wheelNames = ["WheelFrontR", "WheelFrontL", "WheelRearR", "WheelRearL"]
        for (index, name) in wheelNames.enumerated() {
            guard let mesh = top.childNode(withName: name, recursively: true) else { continue }
            var transform = top.simdTransform * mesh.simdTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            transform.columns.3 = SIMD4(0, 0, 0, 1)
            // This showcase model was authored with its front wheels turned 30 degrees.
            if index < 2 { transform = simd_float4x4(simd_quatf(angle: .pi / 6, axis: SIMD3(0, 1, 0))) * transform }
            mesh.removeFromParentNode()
            mesh.simdTransform = transform
            let steeringPivot = SCNNode()
            steeringPivot.simdPosition = position
            let rollingPivot = SCNNode()
            rollingPivot.addChildNode(mesh)
            steeringPivot.addChildNode(rollingPivot)
            car.addChildNode(steeringPivot)
            if index < 2 { frontWheels.append(steeringPivot) }
            wheelPivots.append(steeringPivot)
            wheelBaseHeights.append(CGFloat(position.y))
            rollingWheels.append(rollingPivot)
        }
        importedSteering = top.childNode(withName: "InteriorSteeringCylinder", recursively: true)
        steeringBase = (importedSteering?.simdTransform ?? matrix_identity_float4x4)
            * simd_float4x4(simd_quatf(angle: .pi / 12, axis: SIMD3(0, 1, 0)))
        body.enumerateChildNodes { node, _ in
            if ["InteriorSeatsColor1", "InteriorSeatsColor2", "InteriorSeatsFrame1", "InteriorSeatsFrame2"].contains(node.name ?? "") {
                self.seatNodes.append(node)
            }
            for m in node.geometry?.materials ?? [] {
                if m.name == "Brakelight" { self.brakeLights.append(m) }
                if m.name == "Glass" { self.glassNodes.append(node) }
            }
        }
        // The source model's screen is a static demonstration texture.
        top.childNode(withName: "InteriorSteeringDash", recursively: true)?.isHidden = true
        let bezel = material(NSColor(rgb: 0x101719), roughness: 0.6)
        _ = box(0.34, 0.14, 0.025, at: SCNVector3(0, 0.83, 1.055), material: bezel, parent: body, chamfer: 0.012)
        let display = SCNPlane(width: 0.32, height: 0.12)
        instrumentMaterial.lightingModel = .constant
        display.materials = [instrumentMaterial]
        let displayNode = SCNNode(geometry: display)
        displayNode.name = "LiveInstrumentDisplay"
        displayNode.position = SCNVector3(0, 0.83, 1.039)
        displayNode.eulerAngles.y = .pi
        body.addChildNode(displayNode)
        buildRearWing()
        let deformable: Set<String> = ["BodyHood", "BodyHoodTopgrill", "BodyPanelsColor2",
            "BodyRearPanelsColor1", "BodyHeadlights", "BodyTaillightsPanels", "BodyTaillights"]
        model.enumerateChildNodes { node, _ in
            guard deformable.contains(node.parent?.name ?? ""), let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  source.usesFloatComponents, source.bytesPerComponent == 4 else { return }
            let vertices = source.data.withUnsafeBytes { data in
                (0..<source.vectorCount).map { i -> SIMD3<Float> in
                    let offset = source.dataOffset + i * source.dataStride
                    return SIMD3(data.loadUnaligned(fromByteOffset:offset,as:Float.self),
                                 data.loadUnaligned(fromByteOffset:offset+4,as:Float.self),
                                 data.loadUnaligned(fromByteOffset:offset+8,as:Float.self))
                }
            }
            self.damageMeshes.append(DamageMesh(node:node, original:geometry, vertices:vertices,
                toBody:self.body.simdWorldTransform.inverse * node.simdWorldTransform))
        }
        let ghostPaint = material(NSColor(rgb: 0xB7D2D9))
        ghostPaint.transparency = 0.16
        ghostPaint.writesToDepthBuffer = false
        let ghostMesh = model.clone()
        ghostMesh.enumerateChildNodes { node, _ in
            if let geometry = node.geometry?.copy() as? SCNGeometry {
                geometry.materials = [ghostPaint]
                node.geometry = geometry
            }
        }
        ghostCar.addChildNode(ghostMesh)
        ghostCar.isHidden = true
        scene.rootNode.addChildNode(ghostCar)
    }

    private func updateDamage(_ damage: VehicleDamage) {
        let current = SIMD2(damage.front, damage.rear)
        guard simd_distance(current, renderedDamage) > 0.005 || (current == .zero && renderedDamage != .zero) else { return }
        renderedDamage = current
        for mesh in damageMeshes {
            if current == .zero { mesh.node.geometry = mesh.original; continue }
            let inverse = mesh.toBody.inverse
            let vertices = mesh.vertices.map { v -> SCNVector3 in
                var p = mesh.toBody * SIMD4(v.x, v.y, v.z, 1)
                let front = Float(damage.front) * min(1, max(0, (p.z - 0.9) / 1.3))
                let rear = Float(damage.rear) * min(1, max(0, (-p.z - 0.8) / 1.2))
                p.z += -front * 0.32 + rear * 0.27
                p.y += (front + rear) * (0.045 + 0.025 * sin(p.x * 17))
                let local = inverse * p
                return SCNVector3(local.x, local.y, local.z)
            }
            // A bounded visual approximation; original topology, UVs and material
            // remain intact. Physics damage is independent of this exterior mesh.
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices:vertices)] +
                mesh.original.sources.filter { $0.semantic != .vertex }, elements:mesh.original.elements)
            geometry.materials = mesh.original.materials
            mesh.node.geometry = geometry
        }
    }

    func resetCamera() { cameraReady = false }

    private func buildRearWing() {
        // Inverted airfoil section, twin brackets fixed to the rear deck.
        let composite = material(NSColor(rgb:0x23292C),metal:0.15,roughness:0.48)
        let brackets = material(NSColor(rgb:0x4B5053),metal:0.7,roughness:0.46)
        let wing = SCNNode(); wing.name = "ClubRearWing"; body.addChildNode(wing)
        for x: CGFloat in [-0.48,0.48] {
            _ = box(0.11,0.035,0.25,at:SCNVector3(x,0.64,-1.79),material:brackets,parent:wing, chamfer:0.012)
            let leg = box(0.025,0.42,0.13,at:SCNVector3(x,0.82,-1.84),material:brackets,parent:wing,chamfer:0.012)
            leg.eulerAngles.x = -0.26
        }
        let section = NSBezierPath()
        section.move(to:NSPoint(x:0,y:0)); section.curve(to:NSPoint(x:0.31,y:0.035),
            controlPoint1:NSPoint(x:0.025,y:-0.028),controlPoint2:NSPoint(x:0.18,y:0.008))
        section.curve(to:NSPoint(x:0,y:0),controlPoint1:NSPoint(x:0.17,y:0.047),controlPoint2:NSPoint(x:-0.008,y:0.011)); section.close()
        let foil = SCNShape(path:section,extrusionDepth:1.89); foil.materials = [composite]
        let blade = SCNNode(geometry:foil); blade.eulerAngles.y = .pi/2
        blade.position = SCNVector3(0,1.015,-1.78); wing.addChildNode(blade)
        for x: CGFloat in [-0.945,0.945] {
            _ = box(0.011,0.14,0.33,at:SCNVector3(x,1.02,-1.935),material:composite,parent:wing,chamfer:0.009)
        }
    }

    private func updateInstrument(_ vehicle: Vehicle) {
        let image = NSImage(size: NSSize(width: 512, height: 192))
        image.lockFocus()
        NSColor(rgb: 0x091114).setFill()
        NSRect(x: 0, y: 0, width: 512, height: 192).fill()
        let lime = NSColor(rgb: 0xE6E9D5)
        for bar in 0..<25 {
            let light = bar > 20 ? NSColor(rgb: 0xE85A42) : (bar > 15 ? NSColor(rgb: 0xDFB64C) : NSColor(rgb: 0x58A678))
            (Double(bar) / 25 < vehicle.rpm / 7400 ? light : NSColor(rgb: 0x202B29)).setFill()
            NSRect(x: 18 + bar * 19, y: 163, width: 14, height: 10).fill()
        }
        (String(format: "%03d", Int(vehicle.speedKPH)) as NSString).draw(at: NSPoint(x: 23, y: 24), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 106, weight: .medium), .foregroundColor: NSColor.white
        ])
        ("\(vehicle.gear)" as NSString).draw(at: NSPoint(x: 369, y: 29), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 95, weight: .bold), .foregroundColor: lime
        ])
        ("KM/H                                  GEAR" as NSString).draw(at: NSPoint(x: 27, y: 13), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor(rgb: 0x8B9EA4)
        ])
        image.unlockFocus()
        instrumentMaterial.diffuse.contents = image
    }

    func update(vehicle: Vehicle, input: DrivingInput, dt: Double, cockpit: Bool, ghost: GhostFrame?) {
        updateDamage(vehicle.damage)
        car.position = vector(vehicle.position)
        sunlight.position = vector(vehicle.position, y: 60)
        // The renderer has no glTF transmission path. Clear the cabin glazing in
        // the interior view instead of applying an opaque reflection over the road.
        glassNodes.forEach { $0.isHidden = cockpit }
        seatNodes.forEach { $0.isHidden = cockpit }
        instrumentClock += dt
        if instrumentClock > 0.08 { instrumentClock = 0; updateInstrument(vehicle) }
        car.eulerAngles.y = CGFloat(vehicle.heading)
        body.position.y = CGFloat(vehicle.heave)
        body.eulerAngles.z = CGFloat(vehicle.roll)
        body.eulerAngles.x = CGFloat(-vehicle.pitch)
        for (index, pivot) in wheelPivots.enumerated() {
            pivot.eulerAngles.y = CGFloat(vehicle.wheelSteer(index))
            pivot.eulerAngles.z = CGFloat(vehicle.damage.suspension[index] * (index % 2 == 0 ? 0.16 : -0.16))
            pivot.scale.y = CGFloat(vehicle.wheels[index].radiusScale)
        }
        if let wing = body.childNode(withName: "ClubRearWing", recursively: false) {
            wing.eulerAngles.z = CGFloat(vehicle.damage.rear * 0.18)
            wing.eulerAngles.x = CGFloat(vehicle.damage.rear * 0.12)
            wing.position.y = CGFloat(-vehicle.damage.rear * 0.12)
        }
        for (index, wheel) in rollingWheels.enumerated() {
            wheel.eulerAngles.x = CGFloat(vehicle.wheels[index].rotation)
            wheelPivots[index].position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
        }
        importedSteering?.simdTransform = steeringBase * simd_float4x4(simd_quatf(angle: Float(vehicle.steeringAngle * 9), axis: SIMD3(0, 1, 0)))
        brakeLights.forEach { $0.emission.contents = NSColor(rgb: input.brake > 0.05 ? 0xFF3328 : 0x2A0504) }
        let f = vehicle.forward
        let desired: SIMD3<Float>
        let target: SCNVector3
        if cockpit {
            let p = vehicle.position + f * 0.38
            desired = SIMD3(Float(p.x), Float(seatHeight + vehicle.heave), Float(p.y))
            target = vector(vehicle.position + f * 80, y: seatHeight + vehicle.heave - 3.0)
            camera.camera!.fieldOfView = cockpitFOV
        } else {
            // Smooth heading only: translational lag used to make the vehicle
            // shrink away from the camera at speed or jump towards it on braking.
            let targetYaw = vehicle.heading + exteriorLook * 1.65
            let yawError = atan2(sin(targetYaw-chaseYaw),cos(targetYaw-chaseYaw))
            chaseYaw = cameraReady ? chaseYaw + yawError*(1-exp(-dt*8)) : targetYaw
            let behind = SIMD2(sin(chaseYaw),cos(chaseYaw))
            var p = vehicle.position - behind * 7.6
            let loc = circuit.nearest(to:p)
            if loc.distance > 15 { p = loc.point + simd_normalize(p-loc.point)*15 }
            let height = 2.55 + max(0,7.6-simd_distance(p,vehicle.position))*0.48
            desired = SIMD3(Float(p.x),Float(height),Float(p.y))
            target = vector(vehicle.position + f * (3.4-abs(exteriorLook)*2.5), y: 0.85)
            camera.camera!.fieldOfView = 58
        }
        cameraPosition = desired
        cameraReady = true
        camera.simdPosition = cameraPosition
        camera.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if let ghost {
            ghostCar.isHidden = false
            ghostCar.position = SCNVector3(Float(ghost.x), 0, Float(ghost.z))
            ghostCar.eulerAngles.y = CGFloat(ghost.heading)
        } else { ghostCar.isHidden = true }
    }
}

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

enum DrivingView: Int, CaseIterable, Codable {
    case cockpit, dashboard, bonnet, bumper, chase, chaseFar
    var label: String { ["驾驶舱", "仪表台", "引擎盖", "保险杠", "近距跟车", "远距跟车"][rawValue] }
    var isInterior: Bool { self == .cockpit || self == .dashboard }
    var isChase: Bool { self == .chase || self == .chaseFar }
    func next(_ delta: Int = 1) -> DrivingView { DrivingView(rawValue:(rawValue + delta + Self.allCases.count) % Self.allCases.count)! }
}

final class RacingWorld {
    let scene = SCNScene()
    let camera = SCNNode()
    let mirrorCamera = SCNNode()
    private static let hiddenFromMirror = 1 << 1
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
    private struct OpponentVisual {
        let root: SCNNode
        let body: SCNNode?
        let steer: [SCNNode]
        let roll: [SCNNode]
    }
    private var opponentTemplate: SCNNode?
    private var opponentVisuals: [OpponentVisual] = []
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
    var sideLook = 0.0
    private(set) var vehicleKind = VehicleKind.concept
    private var gaugeNeedles: [SCNNode] = []
    private var contactShadows: [SCNNode] = []
    private var steeringAxis = SIMD3<Float>(0,1,0)

    private func assetURL(_ path: String) -> URL? {
        let url = assetsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private let circuit: Circuit
    let racingLine: RacingLine
    private let racingLineNode = SCNNode()
    private var lineClock = 1.0
    var showRacingLine = true {
        didSet {racingLineNode.isHidden = !showRacingLine;lineClock=1}
    }
    init(circuit: Circuit, assetsDirectory: URL? = nil) {
        self.circuit = circuit
        self.racingLine = RacingLine(circuit:circuit)
        self.assetsDirectory = assetsDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("Assets")
        if let sky = assetURL("Environment/Daylight/kloofendal_48d_partly_cloudy_4k.hdr") {
            scene.background.contents = sky
            scene.lightingEnvironment.contents = sky
        }
        scene.fogColor = NSColor(rgb: 0xB6C3CE)
        scene.fogStartDistance = 380
        scene.fogEndDistance = 1700
        scene.lightingEnvironment.intensity = 0.85

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColor(rgb: 0xD7E4ED)
        ambient.light!.intensity = 28
        scene.rootNode.addChildNode(ambient)
        let sun = sunlight
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.color = NSColor(rgb: 0xFFF9F0)
        sun.light!.intensity = 900
        sun.light!.castsShadow = true
        sun.light!.shadowMode = .deferred
        sun.light!.shadowColor = NSColor.black.withAlphaComponent(0.50)
        sun.light!.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light!.shadowSampleCount = 8
        sun.light!.shadowBias = 0.03
        sun.light!.orthographicScale = 55
        sun.light!.maximumShadowDistance = 100
        sun.light!.shadowCascadeCount = 3
        sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
        scene.rootNode.addChildNode(sun)

        TrackEnvironment(scene: scene, circuit: circuit, assets: self.assetsDirectory).build()
        buildCar(); buildContactShadows(); prepareOpponentTemplate()
        racingLineNode.name="PracticeRacingLine";scene.rootNode.addChildNode(racingLineNode)
        racingLineNode.categoryBitMask = Self.hiddenFromMirror

        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 62
        camera.camera!.zNear = 0.06
        camera.camera!.zFar = 1500
        camera.camera!.wantsHDR = true
        camera.camera!.wantsExposureAdaptation = false
        camera.camera!.exposureOffset = -0.25
        camera.camera!.whitePoint = 1.0
        camera.camera!.saturation = 0.96
        camera.camera!.screenSpaceAmbientOcclusionIntensity = 1.0
        camera.camera!.screenSpaceAmbientOcclusionRadius = 0.28
        camera.camera!.screenSpaceAmbientOcclusionBias = 0.025
        camera.camera!.screenSpaceAmbientOcclusionDepthThreshold = 0.7
        camera.camera!.bloomIntensity = 0
        camera.camera!.bloomThreshold = 1.3
        scene.rootNode.addChildNode(camera)

        let rearView = SCNCamera()
        rearView.fieldOfView = 25
        rearView.zNear = 0.14
        rearView.zFar = 440
        rearView.categoryBitMask = ~Self.hiddenFromMirror
        mirrorCamera.camera = rearView
        scene.rootNode.addChildNode(mirrorCamera)
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

    func selectVehicle(_ kind: VehicleKind) {
        guard kind != vehicleKind else { return }
        car.childNodes.forEach { $0.removeFromParentNode() }
        body.childNodes.forEach { $0.removeFromParentNode() }
        ghostCar.childNodes.forEach { $0.removeFromParentNode() }
        body.transform = SCNMatrix4Identity
        frontWheels = []; rollingWheels = []; wheelPivots = []; wheelBaseHeights = []
        damageMeshes = []; glassNodes = []; seatNodes = []; brakeLights = []
        gaugeNeedles = []; contactShadows = []
        importedSteering = nil; renderedDamage = .zero; steeringAxis = SIMD3(0,1,0)
        instrumentClock = 1; vehicleKind = kind
        buildCar(); buildContactShadows(); prepareOpponentTemplate(); resetCamera()
    }

    private func prepareOpponentTemplate() {
        opponentVisuals.forEach { $0.root.removeFromParentNode() }
        opponentVisuals.removeAll()
        body.name = "TrafficBody"
        for index in wheelPivots.indices {
            wheelPivots[index].name = "TrafficSteer\(index)"
            rollingWheels[index].name = "TrafficRoll\(index)"
        }
        let template = car.clone()
        template.transform = SCNMatrix4Identity
        template.childNode(withName: "LiveInstrumentDisplay", recursively: true)?.removeFromParentNode()
        template.categoryBitMask = 1
        template.enumerateChildNodes { node, _ in node.categoryBitMask = 1 }
        opponentTemplate = template
        for root in [car, ghostCar] {
            root.categoryBitMask = Self.hiddenFromMirror
            root.enumerateChildNodes { node, _ in node.categoryBitMask = Self.hiddenFromMirror }
        }
    }

    func updateTraffic(_ vehicles: [Vehicle]) {
        while opponentVisuals.count > vehicles.count {
            opponentVisuals.removeLast().root.removeFromParentNode()
        }
        guard let template = opponentTemplate else { return }
        let paintColors: [UInt32] = [0x2966A1, 0xDB8E27, 0x438269]
        let paintNames = ["Body_Color", "paint", "Paint 1 Carmine"]
        let lightNames = ["Brakelight", "Taillight_Glass"]
        while opponentVisuals.count < vehicles.count {
            let index = opponentVisuals.count
            let root = template.clone()
            root.name = "ComputerCar\(index+1)"
            root.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry,
                      geometry.materials.contains(where: { paintNames.contains($0.name ?? "") || lightNames.contains($0.name ?? "") }),
                      let copy = geometry.copy() as? SCNGeometry else { return }
                copy.materials = geometry.materials.map { original in
                    let name = original.name ?? ""
                    guard (paintNames.contains(name) || lightNames.contains(name)),
                          let material = original.copy() as? SCNMaterial else { return original }
                    if paintNames.contains(name) {material.diffuse.contents = NSColor(rgb: paintColors[index % paintColors.count])}
                    else {material.emission.contents = NSColor(rgb: 0x2A0504)}
                    return material
                }
                node.geometry = copy
            }
            scene.rootNode.addChildNode(root)
            let steer = wheelPivots.indices.compactMap { root.childNode(withName: "TrafficSteer\($0)", recursively: false) }
            let roll = wheelPivots.indices.compactMap { root.childNode(withName: "TrafficRoll\($0)", recursively: true) }
            opponentVisuals.append(OpponentVisual(root: root, body: root.childNode(withName: "TrafficBody", recursively: false), steer: steer, roll: roll))
        }
        for (visual, vehicle) in zip(opponentVisuals, vehicles) {
            visual.root.position = vector(vehicle.position)
            visual.root.eulerAngles.y = CGFloat(vehicle.heading)
            visual.body?.position.y = CGFloat(vehicle.heave)
            visual.body?.eulerAngles.x = CGFloat(-vehicle.pitch)
            visual.body?.eulerAngles.z = CGFloat(vehicle.roll)
            for index in visual.steer.indices {
                visual.steer[index].eulerAngles.y = CGFloat(vehicle.wheelSteer(index))
                visual.steer[index].position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
            }
            for index in visual.roll.indices {
                visual.roll[index].simdOrientation = simd_quatf(angle: Float(vehicle.wheels[index].rotation), axis: SIMD3(1,0,0))
            }
        }
    }

    private func buildCar() {
        if vehicleKind != .concept { buildProductionCar(); return }
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
                    m.metalness.contents = 0.30; m.roughness.contents = 0.28
                    m.normal.intensity = 0.12; m.clearCoat.contents = 0.85; m.clearCoatRoughness.contents = 0.14
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

    private func buildProductionCar() {
        car.addChildNode(body); scene.rootNode.addChildNode(car)
        let file = vehicleKind.assetName
        guard let url = assetURL("Vehicles/\(file).glb"), let asset = try? GLTFAsset(url:url),
              let model = try? asset.makeScene() else { fatalError("Missing bundled vehicle: \(file)") }
        body.addChildNode(model)
        let paint = ([1: 0x951B16, 2: 0x66777E, 3: 0xB4B7BD, 4: 0x244E69] as [Int: UInt32])[vehicleKind.rawValue]
        model.enumerateChildNodes { node, _ in
            for m in node.geometry?.materials ?? [] {
                if self.vehicleKind == .centenario {
                    if m.name == "material_31" { self.glassNodes.append(node) }
                    if m.name == "LIGT_RED" { self.brakeLights.append(m) }
                    continue
                }
                switch m.name ?? "" {
                case "Body_Color", "paint":
                    if let paint { m.diffuse.contents = NSColor(rgb: paint) }
                    m.multiply.contents = NSColor.white
                    m.metalness.contents = 0.12; m.roughness.contents = 0.32
                    m.clearCoat.contents = 0.55; m.clearCoatRoughness.contents = 0.18
                case "Tires", "rubber":
                    m.diffuse.contents = NSColor(rgb:0x1A1B1C); m.metalness.contents = 0
                    m.roughness.contents = 0.96
                case "Glass_Gray", "window":
                    m.diffuse.contents = NSColor(rgb:0x243137); m.metalness.contents = 0.0
                    m.roughness.contents = 0.16; m.transparency = 0.45
                    m.clearCoat.contents = 0.12; m.clearCoatRoughness.contents = 0.15
                    m.transparencyMode = .aOne; m.writesToDepthBuffer = false
                    self.glassNodes.append(node)
                case "InteriorBlocker": self.glassNodes.append(node)
                case "RLA_miata_seats": self.seatNodes.append(node)
                case "RLA_miata_alcantara":
                    m.diffuse.contents = NSColor(rgb:0x27292A)
                    m.metalness.contents = 0; m.roughness.contents = 0.94
                    m.normal.intensity = 0.25
                case "Leather_red", "Leather", "Interior_dark", "Interior_light", "Carpet", "Carbon_Fiber", "plastic_gray":
                    m.diffuse.contents = NSColor(rgb:0x202225); m.metalness.contents = 0
                    m.roughness.contents = 0.85
                case "silver", "metal_chrome", "metal_gray":
                    m.diffuse.contents = NSColor(rgb:0x9B9C9D); m.metalness.contents = 0.85
                    m.roughness.contents = 0.28
                case "Taillight_Glass":
                    m.diffuse.contents = NSColor(rgb:0x750D08); m.metalness.contents = 0
                    m.roughness.contents = 0.25; self.brakeLights.append(m)
                case "full_black":
                    m.metalness.contents = 0; m.roughness.contents = 0.95
                    // The exterior-only Porsche includes opaque cabin filler.
                    if self.vehicleKind == .porsche { self.seatNodes.append(node) }
                default: break
                }
            }
        }
        for (index,name) in ["WheelFR","WheelFL","WheelRR","WheelRL"].enumerated() {
            guard let mesh = model.childNode(withName:name,recursively:true) else { continue }
            let position = mesh.simdPosition
            mesh.removeFromParentNode(); mesh.simdPosition = .zero
            let pivot = SCNNode(); pivot.simdPosition = position
            let roll = SCNNode(); roll.addChildNode(mesh); pivot.addChildNode(roll); car.addChildNode(pivot)
            if vehicleKind == .porsche || vehicleKind == .bmw || vehicleKind == .mazda || vehicleKind == .centenario {
                // Calipers belong to the upright: steer with the wheel,
                // but never spin with the tyre/rim and brake disc.
                var calipers: [SCNNode] = []
                mesh.enumerateChildNodes { node, _ in
                    if (vehicleKind == .porsche && node.geometry?.materials.contains(where: { $0.name == "Material.001" }) == true) ||
                        (node.geometry != nil && (node.parent?.name == "BrakeCaliperMesh" ||
                            (vehicleKind == .centenario && ["Object_7","Object_18"].contains(node.parent?.name ?? "")))) { calipers.append(node) }
                }
                for node in calipers {
                    let local = simd_inverse(pivot.simdWorldTransform) * node.simdWorldTransform
                    node.removeFromParentNode(); pivot.addChildNode(node); node.simdTransform = local
                    node.name = "BrakeCaliper\(index)"
                }
            }
            wheelPivots.append(pivot); rollingWheels.append(roll); wheelBaseHeights.append(CGFloat(position.y))
            if index < 2 { frontWheels.append(pivot) }
        }
        importedSteering = model.childNode(withName:"Steering",recursively:true)
        steeringAxis = vehicleKind == .centenario ? simd_normalize(SIMD3(0,0.31,-0.95)) : SIMD3(0,0,-1)
        if vehicleKind.hasSimpleCabin { buildSimpleCabin() }
        steeringBase = importedSteering?.simdTransform ?? matrix_identity_float4x4
        if vehicleKind != .centenario {
            // Functional display sits on the dashboard; the exterior model stays intact.
            let display = SCNPlane(width:0.19,height:0.07)
            instrumentMaterial.lightingModel = .constant; display.materials = [instrumentMaterial]
            let instrument = SCNNode(geometry:display); instrument.name = "LiveInstrumentDisplay"
            switch vehicleKind {
            case .ferrari: instrument.position = SCNVector3(0.345,0.84,0.69)
            case .mazda:
                instrument.position = SCNVector3(0.345,0.815,0.380)
                let housing = box(0.205,0.082,0.025,at:SCNVector3(0.345,0.815,0.394),
                                  material:material(NSColor(rgb:0x202326)),parent:body,chamfer:0.003)
                housing.name = "InstrumentHousing"
            default: instrument.position = SCNVector3(-0.25,0.73,0.65)
            }
            instrument.eulerAngles.y = .pi; body.addChildNode(instrument)
        }
        model.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry,
                  geometry.materials.contains(where: {
                    let name = $0.name ?? ""
                    if self.vehicleKind == .centenario {
                        return ["Object_64","Object_76","Object_92","Object_93","Object_95"].contains(node.parent?.name ?? "")
                    }
                    return ["Body_Color","paint"].contains(name)
                  }),
                  let source = geometry.sources(for:.vertex).first, source.bytesPerComponent == 4 else { return }
            let vertices = source.data.withUnsafeBytes { data in
                (0..<source.vectorCount).map { i -> SIMD3<Float> in
                    let o = source.dataOffset+i*source.dataStride
                    return SIMD3(data.loadUnaligned(fromByteOffset:o,as:Float.self),data.loadUnaligned(fromByteOffset:o+4,as:Float.self),data.loadUnaligned(fromByteOffset:o+8,as:Float.self))
                }
            }
            self.damageMeshes.append(DamageMesh(node:node,original:geometry,vertices:vertices,toBody:self.body.simdWorldTransform.inverse*node.simdWorldTransform))
        }
        let silhouette = car.clone(), ghostPaint = material(NSColor(rgb:0xB7D2D9))
        ghostPaint.transparency = 0.16; ghostPaint.writesToDepthBuffer = false
        silhouette.enumerateChildNodes { node,_ in
            if let g = node.geometry?.copy() as? SCNGeometry { g.materials = [ghostPaint]; node.geometry = g }
        }
        silhouette.transform = SCNMatrix4Identity
        ghostCar.addChildNode(silhouette); ghostCar.isHidden = true; scene.rootNode.addChildNode(ghostCar)
    }

    private func buildSimpleCabin() {
        let trim = material(NSColor(rgb:0x141719),roughness:0.94)
        _ = box(1.35,0.14,0.31,at:SCNVector3(0,0.73,0.83),material:trim,parent:body,chamfer:0.04)
        _ = box(1.48,0.08,1.8,at:SCNVector3(0,0.28,-0.05),material:trim,parent:body)
        _ = box(1.48,0.44,0.18,at:SCNVector3(0,0.49,0.84),material:trim,parent:body,chamfer:0.02)
        for x: CGFloat in [-0.72,0.72] {
            _ = box(0.12,0.46,1.7,at:SCNVector3(x,0.51,-0.05),material:trim,parent:body,chamfer:0.025)
        }
        let rim = SCNTorus(ringRadius:0.16,pipeRadius:0.016)
        rim.ringSegmentCount = 64; rim.pipeSegmentCount = 12; rim.materials = [trim]
        let wheel = SCNNode(); wheel.name = "Steering"
        wheel.position = SCNVector3(0.345,0.77,0.48)
        let ring = SCNNode(geometry:rim); ring.eulerAngles.x = .pi/2; wheel.addChildNode(ring)
        let spoke = material(NSColor(rgb:0x4B5052),metal:0.65,roughness:0.38)
        _ = box(0.29,0.025,0.02,at:SCNVector3(0,0,0),material:spoke,parent:wheel,chamfer:0.008)
        _ = box(0.035,0.14,0.02,at:SCNVector3(0,-0.06,0),material:spoke,parent:wheel,chamfer:0.008)
        _ = box(0.08,0.065,0.035,at:SCNVector3(0,0,-0.008),material:trim,parent:wheel,chamfer:0.016)
        body.addChildNode(wheel); importedSteering = wheel
        // Five recessed instruments in the generic Porsche cockpit.
        let bezel=material(NSColor(rgb:0x41474A),metal:0.7,roughness:0.4)
        let dial=material(NSColor(rgb:0x070A0B),roughness:0.9)
        let markings=material(NSColor(rgb:0xC8D1D3),roughness:0.8)
        let needlePaint=material(NSColor(rgb:0xCF5E36),roughness:0.75)
        for i in 0..<5 {
            let r:CGFloat=i==2 ? 0.065 : 0.052
            let gauge=SCNNode();gauge.name="AnalogGauge\(i)";gauge.position=SCNVector3(0.345+CGFloat(i-2)*0.118,0.84,0.79);body.addChildNode(gauge)
            let face=SCNCylinder(radius:r,height:0.014);face.radialSegmentCount=48;face.materials=[dial]
            let plate=SCNNode(geometry:face);plate.eulerAngles.x = .pi/2;gauge.addChildNode(plate)
            let ring=SCNTorus(ringRadius:r,pipeRadius:0.003);ring.materials=[bezel]
            let edge=SCNNode(geometry:ring);edge.eulerAngles.x = .pi/2;edge.position.z = -0.009;gauge.addChildNode(edge)
            for tick in 0..<11 {
                let angle=CGFloat(-2.35+Double(tick)*0.47),mark=SCNNode()
                mark.position=SCNVector3(sin(angle)*r*0.8,cos(angle)*r*0.8,-0.012)
                mark.eulerAngles.z = -angle;gauge.addChildNode(mark)
                _ = box(0.002,0.008,0.002,at:SCNVector3Zero,material:markings,parent:mark)
            }
            let pivot=SCNNode();gauge.addChildNode(pivot);gaugeNeedles.append(pivot)
            _ = box(0.003,r*0.68,0.002,at:SCNVector3(0,r*0.30,-0.016),material:needlePaint,parent:pivot)
        }
    }

    private func buildContactShadows() {
        let image=NSImage(size:NSSize(width:128,height:128));image.lockFocus()
        NSColor.clear.setFill();NSRect(x:0,y:0,width:128,height:128).fill()
        let gradient=NSGradient(colorsAndLocations:(NSColor.black.withAlphaComponent(0.42),0),(NSColor.black.withAlphaComponent(0.15),0.55),(NSColor.clear,1))
        gradient?.draw(in:NSRect(x:0,y:0,width:128,height:128),relativeCenterPosition:.zero);image.unlockFocus()
        let shadow=SCNMaterial();shadow.lightingModel = .constant;shadow.diffuse.contents=image
        shadow.isDoubleSided=true;shadow.writesToDepthBuffer=false
        for pivot in wheelPivots {
            let plane=SCNPlane(width:0.50,height:0.72);plane.materials=[shadow]
            let node=SCNNode(geometry:plane);node.name="TyreContactShadow";node.eulerAngles.x = -.pi/2
            node.position=SCNVector3(pivot.position.x,0.031,pivot.position.z);car.addChildNode(node);contactShadows.append(node)
        }
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

    func resetCamera() { cameraReady = false; lineClock = 1 }

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

    private func updateRacingLine(_ vehicle:Vehicle,dt:Double) {
        guard showRacingLine else {return}
        lineClock += dt
        guard lineClock>=0.1 else {return}
        lineClock=0
        let location=circuit.nearest(to:vehicle.position)
        let progress=location.progress
        let backwards=simd_dot(vehicle.velocity,circuit.sample(at:progress).tangent)<(-1)
        racingLineNode.isHidden=backwards || circuit.pitLane.contains(location)
        guard !racingLineNode.isHidden else {return}
        var vertices:[SCNVector3]=[]
        var groups=[[Int32](),[Int32](),[Int32]()]
        // World-anchored dashes: no sliding texture or screen-space floating line.
        let base=floor(progress/racingLine.spacing)*racingLine.spacing
        for step in -2..<55 {
            let d=base+Double(step)*racingLine.spacing
            let a=racingLine.sample(at:d), b=racingLine.sample(at:d+racingLine.spacing*0.66)
            let direction=simd_normalize(b.position-a.position), side=SIMD2(direction.y,-direction.x)*0.23
            let index=Int32(vertices.count)
            vertices += [vector(a.position-side,y:0.045),vector(a.position+side,y:0.045),
                         vector(b.position-side,y:0.045),vector(b.position+side,y:0.045)]
            let cue=racingLine.cue(at:d,speed:vehicle.speed)
            let group=cue == .brake ? 2 : (cue == .lift ? 1 : 0)
            groups[group] += [index,index+2,index+1,index+1,index+2,index+3]
        }
        let materials=[0x77B66F,0xE3BD58,0xD95750].map { rgb -> SCNMaterial in
            let m=SCNMaterial();m.lightingModel = .constant
            m.diffuse.contents=NSColor(rgb:UInt32(rgb),alpha:0.60);m.isDoubleSided=true
            m.writesToDepthBuffer=false;m.readsFromDepthBuffer=true
            return m
        }
        let active = groups.indices.filter { !groups[$0].isEmpty }
        let elements=active.map {SCNGeometryElement(indices:groups[$0],primitiveType:.triangles)}
        let mesh=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:elements)
        mesh.materials=active.map { materials[$0] };racingLineNode.geometry=mesh;racingLineNode.castsShadow=false
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
        (vehicle.gearLabel as NSString).draw(at: NSPoint(x: 369, y: 29), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 95, weight: .bold), .foregroundColor: lime
        ])
        ("KM/H                                  GEAR" as NSString).draw(at: NSPoint(x: 27, y: 13), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor(rgb: 0x8B9EA4)
        ])
        image.unlockFocus()
        instrumentMaterial.diffuse.contents = image
    }

    func update(vehicle: Vehicle, input: DrivingInput, dt: Double, cockpit: Bool, ghost: GhostFrame?, view: DrivingView? = nil) {
        let mode = view ?? (cockpit ? .cockpit : .chase)
        updateRacingLine(vehicle,dt:dt)
        updateDamage(vehicle.damage)
        car.position = vector(vehicle.position)
        sunlight.position = vector(vehicle.position, y: 60)
        // The renderer has no glTF transmission path. Clear the cabin glazing in
        // the interior view instead of applying an opaque reflection over the road.
        glassNodes.forEach { $0.isHidden = mode.isInterior }
        seatNodes.forEach { $0.isHidden = mode.isInterior }
        importedSteering?.isHidden = mode == .dashboard
        instrumentClock += dt
        if instrumentClock > 0.08 && vehicleKind != .centenario { instrumentClock = 0; updateInstrument(vehicle) }
        car.eulerAngles.y = CGFloat(vehicle.heading)
        body.position.y = CGFloat(vehicle.heave)
        body.eulerAngles.z = CGFloat(vehicle.roll)
        body.eulerAngles.x = CGFloat(-vehicle.pitch)
        for (index, pivot) in wheelPivots.enumerated() {
            let steer = simd_quatf(angle:Float(vehicle.wheelSteer(index)),axis:SIMD3(0,1,0))
            let camber = simd_quatf(angle:Float(vehicle.damage.suspension[index] * (index % 2 == 0 ? 0.16 : -0.16)),axis:SIMD3(0,0,1))
            pivot.simdOrientation = steer * camber
            pivot.scale.y = CGFloat(vehicle.wheels[index].radiusScale)
        }
        if let wing = body.childNode(withName: "ClubRearWing", recursively: false) {
            wing.eulerAngles.z = CGFloat(vehicle.damage.rear * 0.18)
            wing.eulerAngles.x = CGFloat(vehicle.damage.rear * 0.12)
            wing.position.y = CGFloat(-vehicle.damage.rear * 0.12)
        }
        for (index, wheel) in rollingWheels.enumerated() {
            wheel.simdOrientation = simd_quatf(angle:Float(vehicle.wheels[index].rotation),axis:SIMD3(1,0,0))
            wheelPivots[index].position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
        }
        for (i,node) in contactShadows.enumerated() {
            node.position.y = 0.031+CGFloat(max(0,vehicle.wheels[i].surfaceHeight))
            node.opacity = CGFloat(clamp(vehicle.wheels[i].normalLoad/3000,0,1))
        }
        let gauges=[vehicle.coolantTemperature/140,vehicle.speedKPH/300,vehicle.rpm/8000,
                    (vehicle.wheels.map(\.brakeTemperature).max() ?? 40)/900,vehicle.powerFactor]
        for (i,needle) in gaugeNeedles.enumerated() { needle.eulerAngles.z = CGFloat(2.35-clamp(gauges[i],0,1)*4.7) }
        importedSteering?.simdTransform = steeringBase * simd_float4x4(simd_quatf(angle: Float(vehicle.steeringAngle * 9), axis: steeringAxis))
        brakeLights.forEach { $0.emission.contents = NSColor(rgb: input.brake > 0.05 ? 0xFF3328 : 0x2A0504) }
        let f = vehicle.forward
        let mirrorHeight = 1.36 + vehicle.heave
        mirrorCamera.position = vector(vehicle.position, y: mirrorHeight)
        mirrorCamera.look(at: vector(vehicle.position - f * 60, y: mirrorHeight - 1.9),
                          up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        let desired: SIMD3<Float>
        let target: SCNVector3
        if mode.isInterior || mode == .bonnet || mode == .bumper {
            let side = vehicleKind == .concept ? 0.0 : 0.345
            var longitudinal = 0.38, lateral = side, height = seatHeight
            if vehicleKind != .concept { longitudinal = -0.12 }
            if mode == .dashboard { longitudinal += 0.42; height = vehicleKind == .ferrari ? 0.96 : 1.04 }
            if mode == .cockpit && vehicleKind == .mazda {
                longitudinal = -0.24
                height = seatHeight - 0.06
            }
            if vehicleKind == .centenario && mode.isInterior {
                lateral = 0.355
                height = seatHeight - 0.065
                longitudinal = mode == .cockpit ? -0.15 : 0.20
            }
            if mode == .bonnet { longitudinal = 1.25; lateral = 0; height = 1.10 }
            if mode == .bumper { longitudinal = 2.6; lateral = 0; height = 0.42 }
            let p = vehicle.position + f * longitudinal + vehicle.modelX * lateral
            desired = SIMD3(Float(p.x), Float(height + vehicle.heave), Float(p.y))
            let glance = mode.isInterior ? sideLook * 0.73 : 0
            let direction = f * cos(glance) - vehicle.modelX * sin(glance)
            target = vector(p + direction * 80, y: height + vehicle.heave - (mode == .bumper ? 0.5 : 2.0))
            camera.camera!.fieldOfView = mode.isInterior ? cockpitFOV : 65
        } else {
            let targetYaw = vehicle.heading + sideLook * 1.65
            let yawError = atan2(sin(targetYaw-chaseYaw),cos(targetYaw-chaseYaw))
            chaseYaw = cameraReady ? chaseYaw + yawError*(1-exp(-dt*8)) : targetYaw
            let behind = SIMD2(sin(chaseYaw),cos(chaseYaw))
            let distance = mode == .chaseFar ? 10.5 : 6.4
            var p = vehicle.position - behind * distance
            let loc = circuit.nearest(to:p)
            if loc.distance > 15 { p = loc.point + simd_normalize(p-loc.point)*15 }
            let height = (mode == .chaseFar ? 3.5 : 2.15) + max(0,distance-simd_distance(p,vehicle.position))*0.48
            desired = SIMD3(Float(p.x),Float(height),Float(p.y))
            target = vector(vehicle.position + f * (3.4-abs(sideLook)*2.5), y: 0.75)
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

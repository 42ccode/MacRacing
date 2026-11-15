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

enum VehicleMirror: CaseIterable {
    case centre, left, right

    var size: (width: Int, height: Int) { self == .centre ? (360,96) : (180,100) }
}

enum GraphicsQuality: Int, CaseIterable {
    case performance, balanced, quality

    var title: String {
        switch self {
        case .performance: return "性能"
        case .balanced: return "均衡"
        case .quality: return "画质"
        }
    }
}

final class RacingWorld {
    let scene = SCNScene()
    let camera = SCNNode()
    let mirrorCamera = SCNNode()
    private let leftMirrorCamera = SCNNode()
    private let rightMirrorCamera = SCNNode()
    private struct MirrorSurface {
        let material: SCNMaterial
        let original: SCNMaterial
        let centre: SIMD3<Float>
    }
    private var mirrorSurfaces: [VehicleMirror:MirrorSurface] = [:]
    private static let hiddenFromMirror = 1 << 1
    let car = SCNNode()
    let ghostCar = SCNNode()
    let body = SCNNode()
    let steeringWheel = SCNNode()
    private let sunlight = SCNNode()
    private var appliedGraphicsQuality = GraphicsQuality.quality
    private let cabinFill = SCNNode()
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
    private var brakeLampOn: Bool?
    private var presentedView: DrivingView?
    private var cameraPosition = SIMD3<Float>.zero
    private var cameraReady = false
    private var chaseYaw = 0.0
    private var gazePitch = 0.0
    private struct OpponentVisual {
        let root: SCNNode
        let body: SCNNode?
        let steer: [SCNNode]
        let roll: [SCNNode]
        let brakeLights: [SCNMaterial]
        var brakeLampOn: Bool?
    }
    private var opponentTemplate: SCNNode?
    private var opponentVisuals: [OpponentVisual] = []
    private let sprayRoot = SCNNode()
    private struct SprayEmitter {
        let node: SCNNode
        let system: SCNParticleSystem
        var birthRate = 0.0
        var category = 1
    }
    private var sprayEmitters: [SprayEmitter] = []
    private let tyreMarkNode = SCNNode()
    private var tyreMarkClock = 0.0
    private var tyreMarkDirty = false
    private var previousMarkPoints: [SIMD2<Double>?] = Array(repeating:nil,count:4)
    private var tyreMarks: [TyreMark] = []
    private struct TyreMark {
        let start: SIMD2<Double>
        let end: SIMD2<Double>
    }
    private var wheelPivots: [SCNNode] = []
    private var wheelBaseHeights: [CGFloat] = []
    private var importedSteering: SCNNode?
    private var steeringBase = matrix_identity_float4x4
    private let assetsDirectory: URL
    private var glassNodes: [SCNNode] = []
    private var seatNodes: [SCNNode] = []
    private var glanceAngle = 0.0
    var cockpitFOV: CGFloat = 62
    var seatHeight: Double = 1.00
    var sideLook = 0.0
    private(set) var vehicleKind = VehicleKind.concept
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
        if circuit.condition == .wet {
            scene.lightingEnvironment.intensity = 0.65
            scene.fogStartDistance = 180
            scene.fogEndDistance = 1050
        }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColor(rgb: 0xD7E4ED)
        ambient.light!.intensity = 28
        scene.rootNode.addChildNode(ambient)
        cabinFill.light = SCNLight()
        cabinFill.light?.type = .ambient
        cabinFill.light?.color = NSColor(rgb: 0xD1DCE3)
        cabinFill.light?.intensity = 0
        cabinFill.light?.categoryBitMask = Self.hiddenFromMirror
        scene.rootNode.addChildNode(cabinFill)
        let sun = sunlight
        sun.name = "Sunlight"
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.color = NSColor(rgb: 0xFFF9F0)
        sun.light!.intensity = circuit.condition == .wet ? 570 : 900
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
        if circuit.condition == .wet {
            sprayRoot.name = "TyreSpray"
            scene.rootNode.addChildNode(sprayRoot)
        }

        TrackEnvironment(scene: scene, circuit: circuit, assets: self.assetsDirectory).build()
        buildCar(); bindMirrors(); buildContactShadows(); prepareOpponentTemplate()
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

        for mirror in VehicleMirror.allCases {
            let node = camera(for:mirror)
            let rearView = SCNCamera()
            rearView.fieldOfView = mirror == .centre ? 58 : 34
            rearView.projectionDirection = .horizontal
            rearView.zNear = 0.18
            rearView.zFar = mirror == .centre ? 440 : 170
            rearView.categoryBitMask = ~Self.hiddenFromMirror
            node.camera = rearView
            scene.rootNode.addChildNode(node)
        }
    }

    func applyGraphicsQuality(_ quality: GraphicsQuality) {
        guard quality != appliedGraphicsQuality,let sun = sunlight.light,let view = camera.camera else { return }
        appliedGraphicsQuality = quality
        switch quality {
        case .performance:
            sun.shadowMapSize = CGSize(width:1024,height:1024)
            sun.shadowCascadeCount = 1
            sun.maximumShadowDistance = 65
            sun.shadowSampleCount = 2
            view.screenSpaceAmbientOcclusionIntensity = 0
        case .balanced:
            sun.shadowMapSize = CGSize(width:2048,height:2048)
            sun.shadowCascadeCount = 2
            sun.maximumShadowDistance = 82
            sun.shadowSampleCount = 4
            view.screenSpaceAmbientOcclusionIntensity = 0.55
        case .quality:
            sun.shadowMapSize = CGSize(width:4096,height:4096)
            sun.shadowCascadeCount = 3
            sun.maximumShadowDistance = 100
            sun.shadowSampleCount = 8
            view.screenSpaceAmbientOcclusionIntensity = 1
        }
    }

    func selectVehicle(_ kind: VehicleKind) {
        guard kind != vehicleKind else { return }
        car.childNodes.forEach { $0.removeFromParentNode() }
        body.childNodes.forEach { $0.removeFromParentNode() }
        ghostCar.childNodes.forEach { $0.removeFromParentNode() }
        body.transform = SCNMatrix4Identity
        frontWheels = []; rollingWheels = []; wheelPivots = []; wheelBaseHeights = []
        damageMeshes = []; glassNodes = []; seatNodes = []; brakeLights = []; mirrorSurfaces = [:]
        brakeLampOn = nil
        presentedView = nil
        contactShadows = []
        importedSteering = nil; renderedDamage = .zero; steeringAxis = SIMD3(0,1,0)
        vehicleKind = kind
        buildCar(); bindMirrors(); buildContactShadows(); prepareOpponentTemplate(); resetCamera()
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
        template.categoryBitMask = 1
        template.enumerateChildNodes { node, _ in
            node.categoryBitMask = 1
            guard let surface = self.mirrorSurfaces.values.first(where: { $0.material === node.geometry?.firstMaterial }),
                  let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.firstMaterial = surface.original
            node.geometry = geometry
        }
        opponentTemplate = template
        for root in [car, ghostCar] {
            root.categoryBitMask = Self.hiddenFromMirror
            root.enumerateChildNodes { node, _ in node.categoryBitMask = Self.hiddenFromMirror }
        }
    }

    func camera(for mirror: VehicleMirror) -> SCNNode {
        switch mirror {
        case .centre: return mirrorCamera
        case .left: return leftMirrorCamera
        case .right: return rightMirrorCamera
        }
    }

    func hasMirror(_ mirror: VehicleMirror) -> Bool { mirrorSurfaces[mirror] != nil }
    func mirrorHasImage(_ mirror: VehicleMirror) -> Bool {
        guard let contents = mirrorSurfaces[mirror]?.material.diffuse.contents else { return false }
        return !(contents is NSColor)
    }

    func setMirrorImage(_ image: CGImage?, for mirror: VehicleMirror) {
        guard let surface = mirrorSurfaces[mirror] else { return }
        surface.material.diffuse.contents = image as Any? ?? NSColor(rgb:0x46505A)
    }

    private func bindMirrors() {
        var meshes: [SCNNode] = []
        body.enumerateChildNodes { node, _ in if node.geometry != nil { meshes.append(node) } }
        for node in meshes {
            guard let geometry = node.geometry, let original = geometry.firstMaterial else { continue }
            let name = node.parent?.name ?? ""
            let material = original.name ?? ""
            let region: (SIMD3<Float>) -> Bool
            switch (vehicleKind,name,material) {
            case (.concept,_, "Mirror"), (_,_, "AuthoredMirrorGlass"), (.bmw,_, "mirror"),
                 (.centenario,"Object_65","material_30"), (.centenario,"Object_77","material_30"):
                region = { _ in true }
            case (.ferrari,"chrome","metal_chrome"):
                region = { p in
                    (abs(p.x) > 0.943 && (0.804...0.919).contains(p.y) && (0.548...0.636).contains(p.z)) ||
                    (abs(p.x) < 0.13 && (1.061...1.122).contains(p.y) && (0.438...0.475).contains(p.z))
                }
            default: continue
            }
            bindMirrorFaces(on:node,geometry:geometry,original:original,region:region)
        }
    }

    private func bindMirrorFaces(on node: SCNNode,geometry: SCNGeometry,original: SCNMaterial,
                                 region: (SIMD3<Float>) -> Bool) {
        guard let source = geometry.sources(for:.vertex).first, source.bytesPerComponent == 4,
              let element = geometry.elements.first, element.primitiveType == .triangles else { return }
        let points = source.data.withUnsafeBytes { bytes in
            (0..<source.vectorCount).map { i -> SIMD3<Float> in
                let p = source.dataOffset+i*source.dataStride
                let xyz = SIMD3(bytes.loadUnaligned(fromByteOffset:p,as:Float.self),
                                bytes.loadUnaligned(fromByteOffset:p+4,as:Float.self),
                                bytes.loadUnaligned(fromByteOffset:p+8,as:Float.self))
                return node.simdConvertPosition(xyz,to:body)
            }
        }
        let indices = element.data.withUnsafeBytes { bytes in
            (0..<element.primitiveCount*3).map { index -> UInt32 in
                let p = index*element.bytesPerIndex
                switch element.bytesPerIndex {
                case 1: return UInt32(bytes[p])
                case 2: return UInt32(bytes.loadUnaligned(fromByteOffset:p,as:UInt16.self))
                default: return bytes.loadUnaligned(fromByteOffset:p,as:UInt32.self)
                }
            }
        }
        var remaining: [UInt32] = []
        var surfaces: [VehicleMirror:[UInt32]] = [:]
        for offset in stride(from:0,to:indices.count,by:3) {
            let triangle = indices[offset..<(offset+3)]
            let a = points[Int(indices[offset])]
            let b = points[Int(indices[offset+1])]
            let c = points[Int(indices[offset+2])]
            let normal = simd_cross(b-a,c-a)
            let exposed = vehicleKind != .bmw || normal.z < -0.30*simd_length(normal)
            if exposed && triangle.allSatisfy({ region(points[Int($0)]) }) {
                let x = points[Int(indices[offset])].x
                let mirror: VehicleMirror = abs(x) < 0.35 ? .centre : (x > 0 ? .left : .right)
                surfaces[mirror,default:[]].append(contentsOf:triangle)
            } else {
                remaining.append(contentsOf:triangle)
            }
        }
        guard !surfaces.isEmpty else { return }
        let originalSources = [.vertex,.normal,.tangent,.texcoord].flatMap { geometry.sources(for:$0) }
        node.geometry = remaining.isEmpty ? nil : SCNGeometry(sources:originalSources,
            elements:[SCNGeometryElement(indices:remaining,primitiveType:.triangles)])
        node.geometry?.firstMaterial = original
        for (mirror,faces) in surfaces {
            let vertices = Set(faces).map { points[Int($0)] }
            let low = vertices.reduce(SIMD3<Float>(repeating:.infinity),simd_min)
            let high = vertices.reduce(SIMD3<Float>(repeating:-.infinity),simd_max)
            let texcoords = points.map { point in
                CGPoint(x:CGFloat((point.x-low.x)/max(0.001,high.x-low.x)),
                        y:CGFloat((high.y-point.y)/max(0.001,high.y-low.y)))
            }
            let glass = SCNGeometry(sources:[source,SCNGeometrySource(textureCoordinates:texcoords)],
                                   elements:[SCNGeometryElement(indices:faces,primitiveType:.triangles)])
            let existing = mirrorSurfaces[mirror]
            let material = existing?.material ?? SCNMaterial()
            material.name = "LiveMirror"
            material.lightingModel = .constant
            material.isDoubleSided = original.isDoubleSided
            glass.firstMaterial = material
            let face = SCNNode(geometry:glass)
            face.name = "VehicleMirror-\(mirror)"
            face.castsShadow = false
            node.addChildNode(face)
            mirrorSurfaces[mirror] = MirrorSurface(material:material,original:original,centre:(low+high)/2)
            setMirrorImage(nil,for:mirror)
        }
    }

    func updateTraffic(_ vehicles: [Vehicle]) {
        while opponentVisuals.count > vehicles.count {
            opponentVisuals.removeLast().root.removeFromParentNode()
        }
        guard let template = opponentTemplate else { return }
        let paintColors: [UInt32] = [0x2966A1, 0xDB8E27, 0x438269]
        let paintNames = ["Body_Color", "paint", "Paint 1 Carmine"]
        let lightNames = ["Brakelight", "Taillight_Glass", "LIGT_RED", "SourcedBrakeLamp"]
        while opponentVisuals.count < vehicles.count {
            let index = opponentVisuals.count
            let root = template.clone()
            var opponentBrakeLights: [SCNMaterial] = []
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
                    else {
                        material.emission.contents = NSColor(rgb: 0x2A0504)
                        opponentBrakeLights.append(material)
                    }
                    return material
                }
                node.geometry = copy
            }
            scene.rootNode.addChildNode(root)
            let steer = wheelPivots.indices.compactMap { root.childNode(withName: "TrafficSteer\($0)", recursively: false) }
            let roll = wheelPivots.indices.compactMap { root.childNode(withName: "TrafficRoll\($0)", recursively: true) }
            opponentVisuals.append(OpponentVisual(root:root,body:root.childNode(withName:"TrafficBody",recursively:false),
                                                  steer:steer,roll:roll,brakeLights:opponentBrakeLights))
        }
        for index in vehicles.indices {
            let visual = opponentVisuals[index], vehicle = vehicles[index]
            visual.root.position = vector(vehicle.position,y:roadElevation(of:vehicle))
            visual.root.eulerAngles.y = CGFloat(vehicle.heading)
            visual.body?.position.y = CGFloat(vehicle.heave)
            visual.body?.eulerAngles.x = CGFloat(-vehicle.pitch)
            visual.body?.eulerAngles.z = CGFloat(vehicle.roll)
            let braking = vehicle.brakeLightsActive
            if braking != visual.brakeLampOn {
                opponentVisuals[index].brakeLampOn = braking
                let brakeColor = Self.brakeColor(braking)
                visual.brakeLights.forEach { $0.emission.contents = brakeColor }
            }
            for index in visual.steer.indices {
                visual.steer[index].eulerAngles.y = CGFloat(vehicle.wheelSteer(index))
                visual.steer[index].position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
            }
            for index in visual.roll.indices {
                visual.roll[index].simdOrientation = simd_quatf(angle: Float(vehicle.wheels[index].rotation), axis: SIMD3(1,0,0))
            }
        }
    }

    private static let brakeOnColor = NSColor(rgb:0xFF3328)
    private static let brakeOffColor = NSColor(rgb:0x2A0504)

    private static func brakeColor(_ active: Bool) -> NSColor {
        active ? brakeOnColor : brakeOffColor
    }

    private static let tyreMarkMaterial: SCNMaterial = {
        let ink = NSColor(rgb:0x18191A,alpha:0.62)
        let texture = NSImage(size:NSSize(width:32,height:8))
        texture.lockFocus()
        NSGradient(colorsAndLocations:(.clear,0),(ink,0.33),(ink,0.67),(.clear,1))?
            .draw(in:NSRect(x:0,y:0,width:32,height:8),angle:0)
        texture.unlockFocus()
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = texture
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }()

    func breakTyreMarkStreaks() {
        previousMarkPoints = Array(repeating:nil,count:4)
    }

    func clearTyreMarks() {
        breakTyreMarkStreaks()
        tyreMarks.removeAll(keepingCapacity:true)
        tyreMarkNode.geometry = nil
        tyreMarkClock = 0
        tyreMarkDirty = false
    }

    func updateTyreMarks(vehicle: Vehicle,dt: Double) {
        guard dt > 0, circuit.condition == .dry else { return }
        let speed = vehicle.speed
        let rollingDirection = vehicle.forwardSpeed < 0 ? -1.0 : 1.0
        func leavesMark(_ tyre: WheelState) -> Bool {
            guard tyre.surface == .asphalt, tyre.normalLoad > 700 else { return false }
            return -tyre.slipRatio*rollingDirection > 0.68 ||
                (abs(tyre.relaxedSlipAngle) > 0.25 && tyre.gripUsage > 0.90)
        }
        if speed > 4 && vehicle.wheels.contains(where:leavesMark) {
            let points = vehicle.contactPoints
            for index in points.indices {
                guard leavesMark(vehicle.wheels[index]) else {
                    previousMarkPoints[index] = nil
                    continue
                }
                let point = points[index]
                if let previous = previousMarkPoints[index] {
                    let gap = simd_distance(previous,point)
                    if gap < 0.26 { continue }
                    if gap < 2.2 &&
                        circuit.nearest(to:previous).distance < circuit.width/2-0.14 &&
                        circuit.nearest(to:point).distance < circuit.width/2-0.14 {
                        tyreMarks.append(TyreMark(start:previous,end:point))
                        tyreMarkDirty = true
                    }
                }
                previousMarkPoints[index] = point
            }
        } else {
            breakTyreMarkStreaks()
        }
        if tyreMarks.count > 400 { tyreMarks.removeFirst(tyreMarks.count-400) }
        guard tyreMarkDirty else { return }
        tyreMarkClock += dt
        guard tyreMarkClock >= 0.10 else { return }
        tyreMarkClock = 0
        tyreMarkDirty = false
        redrawTyreMarks()
    }

    private func redrawTyreMarks() {
        var vertices: [SCNVector3] = []
        var texcoords: [CGPoint] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(tyreMarks.count*4)
        texcoords.reserveCapacity(tyreMarks.count*4)
        indices.reserveCapacity(tyreMarks.count*6)
        for mark in tyreMarks {
            let direction = simd_normalize(mark.end-mark.start)
            let halfWidth = SIMD2(direction.y,-direction.x)*0.105
            let first = UInt32(vertices.count)
            for point in [mark.start-halfWidth,mark.start+halfWidth,mark.end-halfWidth,mark.end+halfWidth] {
                vertices.append(vector(point,y:elevation(at:point)+0.043))
            }
            texcoords.append(contentsOf:[CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:0,y:1),CGPoint(x:1,y:1)])
            indices.append(contentsOf:[first,first+2,first+1,first+1,first+2,first+3])
        }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(textureCoordinates:texcoords)],
                                   elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        geometry.materials = [Self.tyreMarkMaterial]
        tyreMarkNode.geometry = geometry
        if tyreMarkNode.parent == nil {
            tyreMarkNode.name = "TyreMarks"
            tyreMarkNode.renderingOrder = 3
            tyreMarkNode.castsShadow = false
            scene.rootNode.addChildNode(tyreMarkNode)
        }
    }

    func updateSpray(player: Vehicle, opponents: [Vehicle], cockpit: Bool, active: Bool) {
        guard circuit.condition == .wet else { return }
        let vehicles = [player] + opponents
        let count = vehicles.count * 2
        while sprayEmitters.count > count { sprayEmitters.removeLast().node.removeFromParentNode() }
        while sprayEmitters.count < count {
            let node = SCNNode()
            let particles = SCNParticleSystem()
            particles.birthRate = 0
            particles.particleLifeSpan = 0.42
            particles.particleLifeSpanVariation = 0.14
            particles.particleVelocity = 2.3
            particles.particleVelocityVariation = 1.1
            particles.particleSize = 0.28
            particles.particleSizeVariation = 0.12
            particles.emittingDirection = SCNVector3(0,0.33,-1)
            particles.spreadingAngle = 29
            particles.acceleration = SCNVector3(0,-0.7,0)
            particles.blendMode = .alpha
            particles.particleColor = NSColor(rgb:0xCBD5DB,alpha:0.16)
            particles.particleImage = Self.sprayTexture
            particles.isLocal = false
            node.addParticleSystem(particles)
            sprayRoot.addChildNode(node)
            sprayEmitters.append(SprayEmitter(node:node,system:particles))
        }
        for (index, vehicle) in vehicles.enumerated() {
            let distance = simd_distance(player.position,vehicle.position)
            let detail = clamp((140-distance)/72,0,1)
            let visibility = active ? detail*detail*(3-2*detail) : 0
            let forward = vehicle.forward
            let rear = vehicle.position-forward*(vehicle.wheelbase-vehicle.kind.frontAxle+0.18)
            let across = vehicle.modelX*(vehicle.trackWidth/2)
            let height = 0.13+roadElevation(of:vehicle)
            for side in 0..<2 {
                let slot = index*2+side
                let emitter = sprayEmitters[slot]
                let rate = vehicle.wheels[side+2].spray*95*visibility
                if rate > 0.25 {
                    let contact = rear + (side == 0 ? -across : across)
                    emitter.node.position = vector(contact,y:height+vehicle.wheels[side+2].surfaceHeight)
                    emitter.node.eulerAngles.y = CGFloat(vehicle.heading)
                    let category = index == 0 && !cockpit ? Self.hiddenFromMirror : 1
                    if emitter.category != category {
                        sprayEmitters[slot].category = category
                        emitter.node.categoryBitMask = category
                    }
                    if abs(rate-emitter.birthRate) > 0.65 {
                        sprayEmitters[slot].birthRate = rate
                        emitter.system.birthRate = CGFloat(rate)
                    }
                } else if emitter.birthRate != 0 {
                    sprayEmitters[slot].birthRate = 0
                    emitter.system.birthRate = 0
                }
            }
        }
    }

    private static let sprayTexture: NSImage = {
        let size = NSSize(width:32,height:32)
        let image = NSImage(size:size)
        image.lockFocus()
        let gradient = NSGradient(colors:[.white,NSColor.white.withAlphaComponent(0.22),.clear],
                                  atLocations:[0,0.5,0.92],colorSpace:.deviceRGB)
        let centre = NSPoint(x:16,y:16)
        gradient?.draw(fromCenter:centre,radius:0,toCenter:centre,radius:16,options:[])
        image.unlockFocus()
        return image
    }()

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
        let paint = ([1: 0x951B16] as [Int: UInt32])[vehicleKind.rawValue]
        model.enumerateChildNodes { node, _ in
            for m in node.geometry?.materials ?? [] {
                if self.vehicleKind == .centenario {
                    if m.name == "material_31" {
                        m.diffuse.contents = NSColor(rgb:0x26313B)
                        m.transparency = 0.30
                        m.metalness.contents = 0.03
                        m.roughness.contents = 0.12
                        m.clearCoat.contents = 0.24
                        self.glassNodes.append(node)
                    }
                    if m.name == "LIGT_RED" { self.brakeLights.append(m) }
                    continue
                }
                switch m.name ?? "" {
                case "Body_Color", "paint":
                    if let paint { m.diffuse.contents = NSColor(rgb: paint) }
                    m.multiply.contents = NSColor.white
                    m.metalness.contents = 0.05; m.roughness.contents = 0.28
                    m.clearCoat.contents = 0.72; m.clearCoatRoughness.contents = 0.17
                case "Tires", "rubber":
                    m.diffuse.contents = NSColor(rgb:0x1A1B1C); m.metalness.contents = 0
                    m.roughness.contents = 0.96
                case "Glass_Gray", "window", "CockpitWindow":
                    m.diffuse.contents = NSColor(rgb:0x34434D); m.metalness.contents = 0.0
                    m.roughness.contents = 0.16; m.transparency = 0.29
                    m.clearCoat.contents = 0.12; m.clearCoatRoughness.contents = 0.15
                    m.transparencyMode = .aOne; m.writesToDepthBuffer = false
                    self.glassNodes.append(node)
                case "InteriorBlocker": self.glassNodes.append(node)
                case "RLA_miata_alcantara":
                    m.diffuse.contents = NSColor(rgb:0x27292A)
                    m.metalness.contents = 0; m.roughness.contents = 0.94
                    m.normal.intensity = 0.25
                case "Leather_red", "Leather", "Interior_dark", "Interior_light", "Carpet", "Carbon_Fiber", "plastic_gray":
                    if m.name == "Carbon_Fiber" {
                        m.metalness.contents = 0.12; m.roughness.contents = 0.62
                    } else {
                        m.metalness.contents = 0; m.roughness.contents = 0.86
                        if m.name != "Leather_red" {
                            m.diffuse.contents = NSColor(rgb:m.name == "Interior_light" ? 0x3B3C40 : 0x28292D)
                        }
                    }
                case "silver", "metal_chrome", "metal_gray":
                    let brushed = self.vehicleKind == .ferrari && m.name == "metal_gray"
                    m.diffuse.contents = NSColor(rgb:brushed ? 0x5A5D61 : 0x9B9C9D)
                    m.metalness.contents = brushed ? 0.52 : 0.85
                    m.roughness.contents = brushed ? 0.46 : 0.28
                case "SourcedBrakeLamp": self.brakeLights.append(m)
                case "Taillight_Glass":
                    m.diffuse.contents = NSColor(rgb:0x750D08); m.metalness.contents = 0
                    m.roughness.contents = 0.25; self.brakeLights.append(m)
                case "full_black":
                    m.metalness.contents = 0; m.roughness.contents = 0.95
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
            if vehicleKind == .bmw || vehicleKind == .centenario {
                // Calipers belong to the upright: steer with the wheel,
                // but never spin with the tyre/rim and brake disc.
                var calipers: [SCNNode] = []
                mesh.enumerateChildNodes { node, _ in
                    if node.geometry != nil && (node.parent?.name == "BrakeCaliperMesh" ||
                        (vehicleKind == .centenario && ["Object_7","Object_18"].contains(node.parent?.name ?? ""))) {
                        calipers.append(node)
                    }
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
        steeringBase = importedSteering?.simdTransform ?? matrix_identity_float4x4
        model.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry,
                  geometry.materials.contains(where: {
                    let name = $0.name ?? ""
                    if self.vehicleKind == .centenario {
                        return ["Object_64","Object_76","Object_92","Object_93","Object_95"].contains(node.parent?.name ?? "")
                    }
                    return ["Body_Color","paint","AuthoredPaint","CAR.carros","CarPaintWhite"].contains(name) ||
                        (self.vehicleKind == .porsche && node.parent?.name == "Object_8")
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

    /// Front three-quarter presentation camera for the start screen. The car
    /// sits to the right of the controls, leaving the centre of the road clear.
    func frameMenuCar(_ vehicle: Vehicle, aspect: CGFloat) {
        racingLineNode.isHidden = true
        let height = roadElevation(of:vehicle)
        let viewpoint = vehicle.position+vehicle.forward*7.65-vehicle.modelX*5.1
        let towardCar = simd_normalize(vehicle.position-viewpoint)
        let horizontalRight = SIMD2(-towardCar.y,towardCar.x)
        let offset = clamp(2.50+(Double(aspect)-1.35)*0.62,2.46,3.45)
        camera.position = vector(viewpoint,y:height+2.05)
        camera.look(at:vector(vehicle.position-horizontalRight*offset,y:height+1.32),
                    up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
        camera.camera?.fieldOfView = 46
        cameraReady = false
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
            vertices += [a.position-side,a.position+side,b.position-side,b.position+side].map {
                vector($0,y:0.045+elevation(at:$0))
            }
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

    func update(vehicle: Vehicle, input: DrivingInput, dt: Double, cockpit: Bool, ghost: GhostFrame?, view: DrivingView? = nil) {
        let mode = view ?? (cockpit ? .cockpit : .chase)
        let cameraContinuous = cameraReady && presentedView == mode && dt > 0
        updateRacingLine(vehicle,dt:dt)
        updateDamage(vehicle.damage)
        let elevation = roadElevation(of:vehicle)
        car.position = vector(vehicle.position,y:elevation)
        sunlight.position = vector(vehicle.position, y: 60+elevation)
        if presentedView != mode {
            // Interior views clear the opaque glTF glazing from the driver's view.
            glassNodes.forEach { $0.isHidden = mode.isInterior }
            seatNodes.forEach { $0.isHidden = mode.isInterior }
            cabinFill.light?.intensity = mode.isInterior ? 80 : 0
            importedSteering?.isHidden = mode == .dashboard
            presentedView = mode
        }
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
        for (index, wheel) in rollingWheels.enumerated() {
            wheel.simdOrientation = simd_quatf(angle:Float(vehicle.wheels[index].rotation),axis:SIMD3(1,0,0))
            wheelPivots[index].position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
        }
        for (i,node) in contactShadows.enumerated() {
            node.position.y = 0.031+CGFloat(vehicle.wheels[i].surfaceHeight)
            node.opacity = CGFloat(clamp(vehicle.wheels[i].normalLoad/3000,0,1))
        }
        importedSteering?.simdTransform = steeringBase * simd_float4x4(simd_quatf(angle: Float(vehicle.steeringAngle * 9), axis: steeringAxis))
        let braking = vehicle.brakeLightsActive
        if braking != brakeLampOn {
            brakeLampOn = braking
            let brakeColor = Self.brakeColor(braking)
            brakeLights.forEach { $0.emission.contents = brakeColor }
        }
        let f = vehicle.forward
        let mirrorHeight = 1.36 + vehicle.heave + elevation
        mirrorCamera.position = vector(vehicle.position, y: mirrorHeight)
        mirrorCamera.look(at: vector(vehicle.position - f * 60, y: mirrorHeight - 1.9),
                          up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if mode.isInterior {
            for mirror in [VehicleMirror.left,.right] {
                guard let surface = mirrorSurfaces[mirror] else { continue }
                let node = camera(for:mirror)
                let side = mirror == .left ? 1.0 : -1.0
                let mount = vehicleKind == .honda ? SIMD3(Float(side*0.855),0.947,0.638) :
                    surface.centre+SIMD3(Float(side*0.03),0.012,-0.05)
                let origin = body.simdConvertPosition(mount,to:nil)
                let direction = -f+vehicle.modelX*(side*0.24)
                node.simdPosition = origin
                node.look(at:vector(SIMD2(Double(origin.x),Double(origin.z))+direction*55,y:Double(origin.y)-2.6),
                            up:SCNVector3(0,1,0),localFront:SCNVector3(0,0,-1))
            }
        }
        let desired: SIMD3<Float>
        let target: SCNVector3
        if mode.isInterior || mode == .bonnet || mode == .bumper {
            var longitudinal = -0.12, lateral = 0.345, height = seatHeight
            if mode == .cockpit {
                switch vehicleKind {
                case .concept: longitudinal = 0.38; lateral = 0; height = 1+(seatHeight-1)*0.47
                case .ferrari: longitudinal = -0.045; height += 0.015
                case .porsche: longitudinal = -0.11; lateral = 0.375; height = 1.015+(seatHeight-1)*0.55
                case .bmw: longitudinal = 0.05; lateral = 0.39
                case .mazda: longitudinal = -0.24; lateral = 0.376; height -= 0.035
                case .centenario: longitudinal = -0.05; lateral = 0.355; height -= 0.030
                case .lotus: longitudinal = -0.17; lateral = 0.295; height = 1.034+(seatHeight-1)*0.16
                case .honda: longitudinal = -0.01; lateral = 0.33; height += 0.20
                }
            } else if mode == .dashboard {
                if vehicleKind == .concept { longitudinal = 0.80; lateral = 0 }
                else if vehicleKind == .centenario { longitudinal = 0.24; lateral = 0.355 }
                else if vehicleKind == .mazda { longitudinal = 0.20; lateral = 0.376 }
                else if vehicleKind == .bmw { longitudinal = 0.35; lateral = 0.39 }
                else if vehicleKind == .porsche { longitudinal = 0.32; lateral = 0.375 }
                else if vehicleKind == .lotus { longitudinal = 0.26; lateral = 0.295 }
                else if vehicleKind == .honda { longitudinal = 0.44; lateral = 0.33 }
                else { longitudinal = 0.30 }
                height = vehicleKind == .honda ? 1.20 : (vehicleKind == .ferrari || vehicleKind == .lotus ? 0.98 : 1.04)
            }
            if mode == .bonnet { longitudinal = 1.25; lateral = 0; height = 1.10 }
            if mode == .bumper { longitudinal = 2.6; lateral = 0; height = 0.42 }
            let glanceRange = vehicleKind == .honda ? 0.86 : 1.22
            let requestedGlance = mode.isInterior ? sideLook*glanceRange : 0
            glanceAngle = cameraContinuous ? glanceAngle + (requestedGlance-glanceAngle)*(1-exp(-dt*18)) : requestedGlance
            let glance = glanceAngle
            let p = vehicle.position + f*(longitudinal-abs(glance)*0.035) + vehicle.modelX*(lateral-glance*0.052)
            let cameraHeight = elevation + height + vehicle.heave * (mode.isInterior ? 0.55 : 1)
            desired = SIMD3(Float(p.x), Float(cameraHeight), Float(p.y))
            let direction = f * cos(glance) - vehicle.modelX * sin(glance)
            var roadGradient = SIMD2<Double>.zero
            if circuit.hasElevation {
                let local = circuit.nearest(to:vehicle.position)
                let surface = circuit.roadProfile(at:local.progress,lateral:local.lateral)
                roadGradient = local.tangent*surface.grade+SIMD2(local.tangent.y,-local.tangent.x)*surface.crossfall
            }
            let bodyPitch = clamp(vehicle.pitch-simd_dot(roadGradient,f),-0.11,0.11)
            let targetPitch = simd_dot(roadGradient,direction)*0.82+bodyPitch*(mode.isInterior ? 0.29 : 0.56)
            gazePitch = cameraContinuous ? gazePitch+(targetPitch-gazePitch)*(1-exp(-dt*13)) : targetPitch
            let downTilt = mode == .bumper ? 0.5 : (mode.isInterior ? 3.3 : 2)
            target = vector(p+direction*80,y:cameraHeight-downTilt+gazePitch*80)
            camera.camera!.fieldOfView = mode.isInterior ? cockpitFOV : 65
        } else {
            let targetYaw = vehicle.heading + sideLook * 1.65
            let yawError = atan2(sin(targetYaw-chaseYaw),cos(targetYaw-chaseYaw))
            chaseYaw = cameraContinuous ? chaseYaw+yawError*(1-exp(-dt*8)) : targetYaw
            let behind = SIMD2(sin(chaseYaw),cos(chaseYaw))
            let distance = mode == .chaseFar ? 10.5 : 5.8
            var p = vehicle.position - behind * distance
            let loc = circuit.nearest(to:p)
            if loc.distance > 15 { p = loc.point + simd_normalize(p-loc.point)*15 }
            let height = (mode == .chaseFar ? 3.5 : 2.05) + max(0,distance-simd_distance(p,vehicle.position))*0.48 + self.elevation(at:p)
            desired = SIMD3(Float(p.x),Float(height),Float(p.y))
            target = vector(vehicle.position + f * (3.4-abs(sideLook)*2.5), y: 0.75+elevation)
            camera.camera!.fieldOfView = mode == .chaseFar ? 58 : 54
        }
        cameraPosition = desired
        cameraReady = true
        camera.simdPosition = cameraPosition
        camera.look(at: target, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if let ghost {
            let point = SIMD2(ghost.x,ghost.z)
            let separation = simd_distance(point,vehicle.position)
            let reveal = clamp((separation-1.6)/5.0,0,1)
            ghostCar.opacity = CGFloat(reveal*reveal*(3-2*reveal))
            ghostCar.isHidden = reveal < 0.02
            ghostCar.position = vector(point,y:self.elevation(at:point))
            ghostCar.eulerAngles.y = CGFloat(ghost.heading)
        } else { ghostCar.isHidden = true }
    }

    private func elevation(at point: SIMD2<Double>) -> Double {
        circuit.hasElevation ? circuit.roadHeight(at:circuit.nearest(to:point)) : 0
    }

    private func roadElevation(of vehicle: Vehicle) -> Double {
        vehicle.hasRoadElevationSample ? vehicle.roadElevation : elevation(at:vehicle.position)
    }
}

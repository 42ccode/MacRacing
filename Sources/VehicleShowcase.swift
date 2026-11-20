import AppKit
import SceneKit
import simd

enum ShowcasePanel: String, CaseIterable {
    case left, right, rearLeft, rearRight, front, rear

    func title(for vehicle: VehicleKind) -> String {
        switch self {
        case .left: return "左门"
        case .right: return "右门"
        case .rearLeft: return "左后门"
        case .rearRight: return "右后门"
        case .front: return "前备厢盖"
        case .rear: return "后机舱盖"
        }
    }
}

final class VehicleShowcase {
    enum Lamp: String, CaseIterable, Decodable { case head, tail, hazard }
    enum Viewpoint: String, CaseIterable { case front, side, rear, cabin }
    private struct Surface: Decodable {
        let id: String
        let total: Int
        let ranges: [Int]?
        let lamp: Lamp?
        let doubleSided: Bool?
    }
    private struct Hinge: Decodable {
        let pivot: [Float]
        let angle: Float
        let axis: [Float]
        let surfaces: [Surface]
    }
    private struct Profile: Decodable {
        let panels: [String:Hinge]
        let lamps: [String:[Surface]]
    }
    private struct MovingPart {
        let node: SCNNode
        let axis: SIMD3<Float>
        let radians: Float
        var amount: Float = 0

        mutating func advance(toward target: Float, dt: Double) -> Bool {
            if amount == target { return false }
            let step = Float(dt)/0.78
            amount += clamp(target-amount,-step,step)
            let t = amount
            node.simdOrientation = simd_quatf(angle:radians*t*t*(3-2*t),axis:axis)
            return true
        }
    }

    let scene = SCNScene()
    let camera = SCNNode()
    private let model = SCNNode()
    private let ground = SCNNode()
    private(set) var kind: VehicleKind
    private(set) var openPanels = Set<ShowcasePanel>()
    private(set) var activeLamps = Set<Lamp>()
    private(set) var cabinLightOn = false
    private(set) var viewpoint = Viewpoint.front
    private var panels: [ShowcasePanel:MovingPart] = [:]
    private var lamps: [Lamp:[SCNMaterial]] = [:]
    private var cabinGlazing: [SCNNode] = []
    private var beams: [SCNNode] = []
    private var keyLight: SCNLight?
    private var rimLight: SCNLight?
    private var ambientLight: SCNLight?
    private let cabinFill = SCNLight()
    private let profiles: [String:Profile]
    private let assetRoot: URL
    private var yaw = 0.74
    private var pitch = 0.19
    private var distance = 6.3
    private var cabinFOV: CGFloat = 62
    private var flashTime = 0.0
    private var flashOn = false

    init(kind: VehicleKind, assetRoot: URL) throws {
        self.kind = kind
        self.assetRoot = assetRoot
        profiles = try JSONDecoder().decode([String:Profile].self,
            from: Data(contentsOf: assetRoot.appendingPathComponent("Vehicles/Showcase.json")))
        let studio = NSColor(srgbRed:0.090,green:0.108,blue:0.130,alpha:1)
        scene.background.contents = studio
        scene.fogColor = studio
        scene.fogStartDistance = 8
        scene.fogEndDistance = 25
        if let sky = NSImage(contentsOf:assetRoot.appendingPathComponent("Environment/Daylight/kloofendal_48d_partly_cloudy_4k.hdr")) {
            scene.lightingEnvironment.contents = sky
            scene.lightingEnvironment.intensity = 0.30
        }
        let floor = SCNFloor()
        floor.reflectivity = 0.008
        let tile = SCNMaterial()
        tile.lightingModel = .physicallyBased
        tile.diffuse.contents = NSColor(srgbRed:0.182,green:0.207,blue:0.228,alpha:1)
        tile.roughness.contents = 0.46
        tile.metalness.contents = 0.06
        floor.materials = [tile]
        ground.geometry = floor
        ground.castsShadow = false
        scene.rootNode.addChildNode(ground)
        scene.rootNode.addChildNode(model)
        let key = addLight(.directional, at:SIMD3(3.2,5.2,3), aiming:.zero, intensity:730,
                           color:NSColor(srgbRed:1,green:0.94,blue:0.87,alpha:1)).light!
        key.castsShadow = true
        key.shadowMode = .deferred
        key.automaticallyAdjustsShadowProjection = false
        key.orthographicScale = 8
        key.maximumShadowDistance = 15
        key.zNear = 0.1
        key.zFar = 18
        key.shadowBias = 0.035
        key.shadowRadius = 7
        key.shadowSampleCount = 8
        key.shadowMapSize = CGSize(width:2048,height:2048)
        key.shadowColor = NSColor.black.withAlphaComponent(0.62)
        keyLight = key
        rimLight = addLight(.directional,at:SIMD3(-4.5,3,-2),aiming:.zero,intensity:440,
                            color:NSColor(srgbRed:0.73,green:0.85,blue:1,alpha:1)).light
        ambientLight = addLight(.ambient,at:.zero,aiming:SIMD3(0,0,1),intensity:120,color:.white).light
        cabinFill.type = .omni
        cabinFill.color = NSColor(srgbRed:1,green:0.95,blue:0.86,alpha:1)
        cabinFill.intensity = 0
        cabinFill.attenuationStartDistance = 0.1
        cabinFill.attenuationEndDistance = 2.0
        cabinFill.attenuationFalloffExponent = 1
        let dome = SCNNode()
        dome.position = SCNVector3(0,1.08,-0.25)
        dome.light = cabinFill
        scene.rootNode.addChildNode(dome)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 39
        camera.camera?.zNear = 0.028
        camera.camera?.zFar = 70
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        scene.rootNode.addChildNode(camera)
        try select(kind)
    }

    private func addLight(_ type: SCNLight.LightType, at position: SIMD3<Float>, aiming point: SIMD3<Float>,
                          intensity: CGFloat, color: NSColor) -> SCNNode {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = color
        let node = SCNNode()
        node.light = light
        node.simdPosition = position
        if type != .ambient { node.simdLook(at:point,up:SIMD3(0,1,0),localFront:SIMD3(0,0,-1)) }
        scene.rootNode.addChildNode(node)
        return node
    }

    func supports(_ panel: ShowcasePanel) -> Bool { panels[panel] != nil }
    func supports(_ lamp: Lamp) -> Bool { !(lamps[lamp] ?? []).isEmpty }
    var allPanelsOpen: Bool { !panels.isEmpty && openPanels.count == panels.count }

    func panel(containing node: SCNNode) -> ShowcasePanel? {
        var ancestor: SCNNode? = node
        while let current = ancestor, current !== model {
            if let match = panels.first(where:{ $0.value.node === current }) { return match.key }
            ancestor = current.parent
        }
        return nil
    }

    func toggleAllPanels() {
        if allPanelsOpen { openPanels.removeAll() }
        else { openPanels = Set(panels.keys) }
    }

    func select(_ kind: VehicleKind) throws {
        let name = kind.assetName
        guard let profile = profiles[name] else { throw GLTFError.invalid("Missing showcase profile for \(name)") }
        let root = try GLTFAsset(url:assetRoot.appendingPathComponent("Vehicles/\(name).glb")).makeScene(identifyPrimitives:true)
        GLTFAsset.applyCabinMaterials(to:root,kind:kind)
        let windshieldLiner = kind == .porsche ? GLTFAsset.separatePorscheWindshieldLiner(from:root) : nil
        var surfaces: [String:SCNNode] = [:]
        var refinished = Set<ObjectIdentifier>()
        root.enumerateChildNodes { node, _ in
            guard let id = node.name, node.geometry != nil else { return }
            surfaces[id] = node
            guard let material = node.geometry?.firstMaterial, let name = material.name else { return }
            if ["Glass","CockpitWindow","material_31"].contains(name) {
                if name != "Glass" { material.diffuse.contents = NSColor(rgb:0x40505B) }
                material.transparency = 0.22
                material.transparencyMode = .aOne
                material.writesToDepthBuffer = false
                material.metalness.contents = 0
                material.roughness.contents = 0.20
                node.castsShadow = false
                node.renderingOrder = 2
            }
            guard refinished.insert(ObjectIdentifier(material)).inserted else { return }
            if name == "CUIR" {
                material.metalness.contents = 0
                material.roughness.contents = 0.77
                material.clearCoat.contents = 0
            }
        }
        var assignments: [String:[(Surface,SCNNode,Lamp?)]] = [:]
        var nextPanels: [ShowcasePanel:MovingPart] = [:]
        func bind(_ hinge: Hinge, name: String) throws -> MovingPart {
            guard hinge.axis.count == 3, hinge.pivot.count == 3 else { throw GLTFError.invalid("Invalid showcase hinge") }
            let pivot = SCNNode()
            pivot.name = "showcase-"+name
            pivot.simdPosition = SIMD3(hinge.pivot[0],hinge.pivot[1],hinge.pivot[2])
            root.addChildNode(pivot)
            let axis = simd_normalize(SIMD3(hinge.axis[0],hinge.axis[1],hinge.axis[2]))
            for surface in hinge.surfaces { assignments[surface.id,default:[]].append((surface,pivot,surface.lamp)) }
            return MovingPart(node:pivot,axis:axis,radians:hinge.angle * .pi/180)
        }
        for panel in ShowcasePanel.allCases {
            if let hinge = profile.panels[panel.rawValue] { nextPanels[panel] = try bind(hinge,name:panel.rawValue) }
        }
        for lamp in Lamp.allCases {
            for surface in profile.lamps[lamp.rawValue] ?? [] {
                guard let parent = surfaces[surface.id]?.parent else { throw GLTFError.invalid("Missing lamp mesh") }
                assignments[surface.id,default:[]].append((surface,parent,lamp))
            }
        }

        var nextLamps: [Lamp:[SCNMaterial]] = [:]
        for (id, groups) in assignments {
            guard let node = surfaces[id], let source = node.geometry, let element = source.elements.first,
                  element.primitiveType == .triangles else { throw GLTFError.invalid("Missing showcase mesh \(id)") }
            let original = element.data
            let stride = element.bytesPerIndex * 3
            var used = [Bool](repeating:false,count:element.primitiveCount)
            for (surface, parent, lamp) in groups {
                guard surface.total == element.primitiveCount else { throw GLTFError.invalid("Showcase geometry changed: \(id)") }
                let ranges = surface.ranges ?? [0,surface.total]
                guard ranges.count.isMultiple(of:2) else { throw GLTFError.invalid("Invalid showcase ranges") }
                var indices = Data()
                for run in Swift.stride(from:0,to:ranges.count,by:2) {
                    let start = ranges[run], length = ranges[run+1]
                    guard start >= 0, length > 0, length <= used.count, start <= used.count-length else {
                        throw GLTFError.invalid("Invalid showcase face range")
                    }
                    let end = start+length
                    for face in start..<end {
                        guard !used[face] else { throw GLTFError.invalid("Duplicate showcase face") }
                        used[face] = true
                    }
                    indices.append(original.subdata(in:start*stride..<end*stride))
                }
                let child = SCNNode(geometry:try Self.mesh(source,indices,bytesPerIndex:element.bytesPerIndex))
                child.name = id
                child.castsShadow = node.castsShadow
                child.renderingOrder = node.renderingOrder
                child.simdTransform = parent.simdWorldTransform.inverse * node.simdWorldTransform
                parent.addChildNode(child)
                if lamp != nil || surface.doubleSided == true,
                   let material = child.geometry?.firstMaterial?.copy() as? SCNMaterial {
                    if surface.doubleSided == true { material.isDoubleSided = true }
                    child.geometry?.materials = [material]
                    if let channel = lamp {
                        material.emission.contents = NSColor.black
                        nextLamps[channel,default:[]].append(material)
                    }
                }
            }
            var remainder = Data()
            var start = 0
            while start < used.count {
                if used[start] { start += 1; continue }
                var end = start+1
                while end < used.count && !used[end] { end += 1 }
                remainder.append(original.subdata(in:start*stride..<end*stride))
                start = end
            }
            if remainder.isEmpty { node.removeFromParentNode() }
            else { node.geometry = try Self.mesh(source,remainder,bytesPerIndex:element.bytesPerIndex) }
        }
        model.childNodes.forEach { $0.removeFromParentNode() }
        model.addChildNode(root)
        cabinGlazing.removeAll()
        if let windshieldLiner { cabinGlazing.append(windshieldLiner) }
        let cabinWindow = kind == .porsche ? "CockpitWindow" : "material_31"
        root.enumerateChildNodes { node,_ in
            if node.geometry?.firstMaterial?.name == cabinWindow { self.cabinGlazing.append(node) }
        }
        // Align the opening display to the exported rolling radii. The ISR
        // asset's front tyres sit 2.3 cm above its rear contact plane.
        ground.position.y = -0.001
        if kind == .centenario {
            for name in ["WheelFR","WheelFL"] {
                if let wheel = root.childNode(withName:name,recursively:true) {
                    wheel.simdWorldPosition.y -= 0.023
                }
            }
        }
        self.kind = kind
        panels = nextPanels
        lamps = nextLamps
        openPanels.removeAll()
        activeLamps.removeAll()
        flashTime = 0
        flashOn = false
        cabinLightOn = false
        cabinFill.intensity = 0
        for beam in beams { beam.removeFromParentNode() }
        beams.removeAll()
        let headlightPosition: SIMD3<Float> = kind == .porsche ? SIMD3(0.67,0.69,1.86) : SIMD3(0.79,0.55,2.25)
        for side: Float in [-1,1] {
            let lamp = headlightPosition * SIMD3(side,1,1)
            let node = addLight(.spot,at:lamp,aiming:lamp+SIMD3(0,-0.72,4.5),
                                intensity:0,color:NSColor(srgbRed:0.85,green:0.92,blue:1,alpha:1))
            node.light?.spotInnerAngle = 18
            node.light?.spotOuterAngle = 46
            node.light?.attenuationEndDistance = 12
            beams.append(node)
        }
        setView(.front)
    }

    private static func mesh(_ geometry: SCNGeometry, _ data: Data, bytesPerIndex: Int) throws -> SCNGeometry {
        let sources = geometry.sources
        guard let count = sources.first(where:{ $0.semantic == .vertex })?.vectorCount,
              sources.allSatisfy({ $0.vectorCount == count }), [1,2,4].contains(bytesPerIndex) else {
            throw GLTFError.invalid("Invalid showcase vertex layout")
        }

        // Reindex in face order. Reusing the original buffers would leave every
        // detached panel with the vertex storage and bounds of its parent mesh.
        var sourceIndices: [Int] = []
        var lookup = [UInt32](repeating:.max,count:count)
        let compactIndices = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try Swift.stride(from:0,to:bytes.count,by:bytesPerIndex).map { offset -> UInt32 in
                let index: Int
                switch bytesPerIndex {
                case 1: index = Int(bytes[offset])
                case 2: index = Int(UInt16(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self)))
                default: index = Int(UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))
                }
                guard index < count else { throw GLTFError.invalid("Showcase vertex index out of range") }
                if lookup[index] == .max {
                    lookup[index] = UInt32(sourceIndices.count)
                    sourceIndices.append(index)
                }
                return lookup[index]
            }
        }
        let element: SCNGeometryElement
        let compactSources: [SCNGeometrySource]
        let triangles = compactIndices.count/3
        if sourceIndices.count == count {
            compactSources = sources
            element = SCNGeometryElement(data:data,primitiveType:.triangles,primitiveCount:triangles,bytesPerIndex:bytesPerIndex)
        } else {
            compactSources = sources.map { source in
                let vectorSize = source.componentsPerVector * source.bytesPerComponent
                var packed = Data(count:sourceIndices.count*vectorSize)
                source.data.withUnsafeBytes { original in
                    packed.withUnsafeMutableBytes { output in
                        for (outputIndex,sourceIndex) in sourceIndices.enumerated() {
                            let offset = source.dataOffset+source.dataStride*sourceIndex
                            output.baseAddress!.advanced(by:outputIndex*vectorSize)
                                .copyMemory(from:original.baseAddress!.advanced(by:offset),byteCount:vectorSize)
                        }
                    }
                }
                return SCNGeometrySource(data:packed,semantic:source.semantic,vectorCount:sourceIndices.count,
                    usesFloatComponents:source.usesFloatComponents,componentsPerVector:source.componentsPerVector,
                    bytesPerComponent:source.bytesPerComponent,dataOffset:0,dataStride:vectorSize)
            }
            if sourceIndices.count <= Int(UInt16.max)+1 {
                let shorts = compactIndices.map { UInt16($0).littleEndian }
                element = SCNGeometryElement(data:shorts.withUnsafeBytes { Data($0) },primitiveType:.triangles,
                    primitiveCount:triangles,bytesPerIndex:2)
            } else {
                let ints = compactIndices.map(\.littleEndian)
                element = SCNGeometryElement(data:ints.withUnsafeBytes { Data($0) },primitiveType:.triangles,
                    primitiveCount:triangles,bytesPerIndex:4)
            }
        }
        let result = SCNGeometry(sources:compactSources,elements:[element])
        result.materials = geometry.materials
        return result
    }

    func toggle(_ part: ShowcasePanel) {
        guard supports(part) else { return }
        if openPanels.remove(part) == nil { openPanels.insert(part) }
    }

    func toggle(_ lamp: Lamp) {
        guard supports(lamp) else { return }
        if activeLamps.remove(lamp) == nil { activeLamps.insert(lamp) }
        flashTime = 0
        refreshLamps()
    }

    func toggleCabinLight() {
        cabinLightOn.toggle()
        cabinFill.intensity = cabinLightOn ? 7 : 0
    }

    private func refreshLamps() {
        flashOn = activeLamps.contains(.hazard) && flashTime < 0.36
        for channel in Lamp.allCases {
            let on = channel == .hazard ? flashOn : activeLamps.contains(channel)
            let color: NSColor
            switch channel {
            case .head: color = NSColor(srgbRed:0.75,green:0.87,blue:1,alpha:1)
            case .tail: color = NSColor(srgbRed:0.95,green:0.07,blue:0.055,alpha:1)
            case .hazard: color = NSColor(srgbRed:1,green:0.42,blue:0.04,alpha:1)
            }
            for material in lamps[channel] ?? [] { material.emission.contents = on ? color : .black }
        }
        let visible = activeLamps.contains(.head)
        for beam in beams { beam.light?.intensity = visible ? 310 : 0 }
    }

    @discardableResult func update(_ dt: Double) -> Bool {
        var changed = false
        for part in ShowcasePanel.allCases {
            guard var state = panels[part] else { continue }
            let target: Float = openPanels.contains(part) ? 1 : 0
            if state.advance(toward:target,dt:dt) {
                panels[part] = state
                changed = true
            }
        }
        if activeLamps.contains(.hazard) {
            flashTime = (flashTime+dt).truncatingRemainder(dividingBy:0.76)
            if (flashTime < 0.36) != flashOn { refreshLamps(); changed = true }
        }
        return changed
    }

    func setView(_ view: Viewpoint) {
        viewpoint = view
        cabinGlazing.forEach { $0.isHidden = view == .cabin }
        keyLight?.intensity = view == .cabin ? 290 : 730
        rimLight?.intensity = view == .cabin ? 150 : 440
        ambientLight?.intensity = view == .cabin ? 205 : 120
        switch view {
        case .front: yaw = 0.74; pitch = 0.21
        case .side: yaw = .pi/2; pitch = 0.10
        case .rear: yaw = 2.49; pitch = 0.24
        case .cabin: yaw = 0; pitch = -0.12; cabinFOV = 62
        }
        distance = max(5.8,kind.wheelbase*2.27)
        updateCamera()
    }

    func nextView() {
        let views = Viewpoint.allCases
        let index = views.firstIndex(of:viewpoint) ?? 0
        setView(views[(index+1) % views.count])
    }

    @discardableResult func moveCamera(_ axes: SIMD3<Double>, dt: Double) -> Bool {
        guard axes != .zero else { return false }
        if axes.x != 0 || axes.y != 0 {
            let horizontal = viewportDirection * axes.x
            orbit(dx:horizontal*185*dt,dy:axes.y*155*dt)
        }
        if axes.z != 0 { zoom(axes.z*26*dt) }
        return true
    }

    private var viewportDirection: Double { viewpoint == .cabin ? -1 : 1 }

    func orbit(dx: Double, dy: Double) {
        yaw = (yaw+dx*0.009).truncatingRemainder(dividingBy:2 * .pi)
        pitch = clamp(pitch+dy*0.008, viewpoint == .cabin ? -0.68 : 0.045,viewpoint == .cabin ? 0.58 : 1.13)
        updateCamera()
    }

    func zoom(_ scroll: Double) {
        if viewpoint == .cabin {
            cabinFOV = clamp(cabinFOV-CGFloat(scroll)*1.4,42,81)
            camera.camera?.fieldOfView = cabinFOV
        } else {
            distance = clamp(distance*exp(-scroll*0.042),2.6,10)
            updateCamera()
        }
    }

    private func updateCamera() {
        let direction = SIMD3<Float>(Float(sin(yaw)*cos(pitch)),Float(sin(pitch)),Float(cos(yaw)*cos(pitch)))
        if viewpoint == .cabin {
            let seat: SIMD3<Float>
            switch kind {
            case .porsche: seat = SIMD3(0.375,1.015,-0.11)
            case .centenario: seat = SIMD3(0.355,0.97,-0.05)
            }
            camera.camera?.fieldOfView = cabinFOV
            camera.simdPosition = seat
            camera.simdLook(at:seat+direction,up:SIMD3(0,1,0),localFront:SIMD3(0,0,-1))
        } else {
            let look = SIMD3<Float>(0,0.60,0)
            camera.camera?.fieldOfView = 39
            camera.simdPosition = look+direction*Float(distance)
            camera.simdLook(at:look,up:SIMD3(0,1,0),localFront:SIMD3(0,0,-1))
        }
    }
}

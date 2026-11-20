import AppKit
import SceneKit
import simd

enum GLTFError: Error { case invalid(String) }

/// glTF 2.0 reader for the bundled licensed vehicle and scenery assets.
/// Retains original mesh normals, UV channels, materials, hierarchy and transforms.
final class GLTFAsset {
    private let document: [String: Any]
    private let binary: Data
    private let accessors: [[String: Any]]
    private let views: [[String: Any]]
    private var images: [NSImage?] = []
    private var materials: [SCNMaterial] = []

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        func word(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        let jsonData: Data
        var embeddedBuffer: Data?
        if data.count > 28 && word(0) == 0x46546C67 {
            guard word(4) == 2 else { throw GLTFError.invalid("Not a GLB 2 file") }
            let jsonLength = Int(word(12))
            guard 20 + jsonLength + 8 <= data.count else { throw GLTFError.invalid("Truncated GLB") }
            jsonData = data.subdata(in: 20..<(20 + jsonLength))
            let binaryOffset = 20 + jsonLength + 8
            let binaryLength = Int(word(20 + jsonLength))
            guard binaryOffset + binaryLength <= data.count else { throw GLTFError.invalid("Truncated vertex data") }
            embeddedBuffer = data.subdata(in: binaryOffset..<(binaryOffset + binaryLength))
        } else { jsonData = data }
        guard let document = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let accessors = document["accessors"] as? [[String: Any]],
              let views = document["bufferViews"] as? [[String: Any]] else { throw GLTFError.invalid("Missing geometry tables") }
        self.document = document
        self.accessors = accessors
        self.views = views
        if let embeddedBuffer { binary = embeddedBuffer }
        else if let buffers = document["buffers"] as? [[String: Any]], buffers.count == 1,
                let uri = buffers.first?["uri"] as? String {
            binary = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(uri))
        } else { throw GLTFError.invalid("Expected one local geometry buffer") }
        for image in document["images"] as? [[String: Any]] ?? [] {
            if let viewIndex = image["bufferView"] as? Int {
                let view = views[viewIndex]
                let offset = view["byteOffset"] as? Int ?? 0
                let length = view["byteLength"] as! Int
                images.append(NSImage(data: binary.subdata(in: offset..<(offset + length))))
            } else if let uri = image["uri"] as? String {
                images.append(NSImage(contentsOf: url.deletingLastPathComponent().appendingPathComponent(uri)))
            } else { images.append(nil) }
        }
        materials = (document["materials"] as? [[String: Any]] ?? []).map(makeMaterial)
    }

    private func applyTexture(_ info: [String: Any]?, to property: SCNMaterialProperty) -> Bool {
        guard let info, let index = info["index"] as? Int,
              let textures = document["textures"] as? [[String: Any]], index < textures.count,
              let source = textures[index]["source"] as? Int, source < images.count, let image = images[source] else { return false }
        property.contents = image
        property.mappingChannel = info["texCoord"] as? Int ?? 0
        property.wrapS = .repeat
        property.wrapT = .repeat
        property.mipFilter = .linear
        property.maxAnisotropy = 8
        if let extensions = info["extensions"] as? [String: Any],
           let transform = extensions["KHR_texture_transform"] as? [String: Any] {
            let scale = transform["scale"] as? [Double] ?? [1, 1]
            let offset = transform["offset"] as? [Double] ?? [0, 0]
            property.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(CGFloat(scale[0]), CGFloat(scale[1]), 1),
                SCNMatrix4MakeTranslation(CGFloat(offset[0]), CGFloat(offset[1]), 0))
        }
        return true
    }

    private func makeMaterial(_ value: [String: Any]) -> SCNMaterial {
        let result = SCNMaterial()
        result.name = value["name"] as? String
        result.lightingModel = .physicallyBased
        result.isDoubleSided = value["doubleSided"] as? Bool ?? false
        let pbr = value["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        let rgba = pbr["baseColorFactor"] as? [Double] ?? [1, 1, 1, 1]
        // glTF factors are linear. Treating them as sRGB crushes dark materials
        // and gives painted/metal surfaces the wrong response to daylight.
        func srgb(_ v: Double) -> CGFloat { CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) }
        let color = NSColor(srgbRed: srgb(rgba[0]), green: srgb(rgba[1]), blue: srgb(rgba[2]), alpha: CGFloat(rgba[3]))
        if applyTexture(pbr["baseColorTexture"] as? [String: Any], to: result.diffuse) { result.multiply.contents = color }
        else { result.diffuse.contents = color }
        result.metalness.contents = pbr["metallicFactor"] as? Double ?? 1
        result.roughness.contents = pbr["roughnessFactor"] as? Double ?? 1
        if let texture = pbr["metallicRoughnessTexture"] as? [String: Any] {
            _ = applyTexture(texture, to: result.metalness)
            result.metalness.textureComponents = .blue
            _ = applyTexture(texture, to: result.roughness)
            result.roughness.textureComponents = .green
        }
        if let normal = value["normalTexture"] as? [String: Any] {
            _ = applyTexture(normal, to: result.normal)
            result.normal.intensity = normal["scale"] as? CGFloat ?? 1
        }
        if let ao = value["occlusionTexture"] as? [String: Any], (ao["strength"] as? Double ?? 1) > 0 {
            _ = applyTexture(ao, to: result.ambientOcclusion)
            result.ambientOcclusion.textureComponents = .red
            result.ambientOcclusion.intensity = ao["strength"] as? CGFloat ?? 1
        }
        if let emission = value["emissiveFactor"] as? [Double] {
            result.emission.contents = NSColor(calibratedRed: emission[0], green: emission[1], blue: emission[2], alpha: 1)
        }
        _ = applyTexture(value["emissiveTexture"] as? [String: Any], to: result.emission)
        let extensions = value["extensions"] as? [String: Any] ?? [:]
        if let coat = extensions["KHR_materials_clearcoat"] as? [String: Any] {
            result.clearCoat.contents = coat["clearcoatFactor"] as? Double ?? 0
            result.clearCoatRoughness.contents = coat["clearcoatRoughnessFactor"] as? Double ?? 0.08
        }
        if extensions["KHR_materials_transmission"] != nil {
            result.diffuse.contents = NSColor(rgb: 0x39484E)
            result.metalness.contents = 0.08
            result.roughness.contents = 0.03
            result.transparency = 0.20
            result.transparencyMode = .aOne
            result.writesToDepthBuffer = false
        }
        if value["alphaMode"] as? String == "BLEND" { result.transparency = CGFloat(rgba[3]); result.writesToDepthBuffer = false }
        if value["alphaMode"] as? String == "MASK" {
            let cutoff = value["alphaCutoff"] as? Double ?? 0.5
            result.shaderModifiers = [.surface: "#pragma body\nif (_surface.diffuse.a < \(cutoff)) discard_fragment();\n_surface.diffuse.a = 1.0;"]
            result.writesToDepthBuffer = true
        }
        return result
    }

    private func source(_ accessorIndex: Int, semantic: SCNGeometrySource.Semantic) throws -> SCNGeometrySource {
        guard accessors.indices.contains(accessorIndex) else { throw GLTFError.invalid("Missing vertex accessor") }
        let a = accessors[accessorIndex]
        guard let viewIndex = a["bufferView"] as? Int, views.indices.contains(viewIndex),
              a["componentType"] as? Int == 5126, let count = a["count"] as? Int, count >= 0 else {
            throw GLTFError.invalid("Unsupported vertex encoding")
        }
        let view = views[viewIndex]
        let components = ["VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 3
        let vectorSize = components*4
        let stride = view["byteStride"] as? Int ?? vectorSize
        let viewOffset = view["byteOffset"] as? Int ?? 0
        let accessorOffset = a["byteOffset"] as? Int ?? 0
        guard let viewLength = view["byteLength"] as? Int,
              (0...binary.count).contains(viewOffset), (0...(binary.count-viewOffset)).contains(viewLength),
              (0...viewLength).contains(accessorOffset), stride >= vectorSize else {
            throw GLTFError.invalid("Vertex buffer view is out of range")
        }
        let available = viewLength-accessorOffset
        guard count == 0 || (available >= vectorSize && count-1 <= (available-vectorSize)/stride) else {
            throw GLTFError.invalid("Vertex accessor exceeds its buffer view")
        }
        let bytes = count == 0 ? 0 : (count-1)*stride+vectorSize
        let start = viewOffset+accessorOffset
        // SceneKit uploads the source's backing data. Keep only the bytes
        // needed by this accessor, including gaps in interleaved streams.
        return SCNGeometrySource(data:binary.subdata(in:start..<(start+bytes)),semantic:semantic,
            vectorCount:count,usesFloatComponents:true,componentsPerVector:components,bytesPerComponent:4,
            dataOffset:0,dataStride:stride)
    }

    private func geometry(_ primitive: [String: Any]) throws -> SCNGeometry {
        guard let attrs = primitive["attributes"] as? [String: Int], let position = attrs["POSITION"],
              let index = primitive["indices"] as? Int else { throw GLTFError.invalid("Missing mesh indices") }
        var sources = [try source(position, semantic: .vertex)]
        if let normal = attrs["NORMAL"] { sources.append(try source(normal, semantic: .normal)) }
        if let tangent = attrs["TANGENT"] { sources.append(try source(tangent, semantic: .tangent)) }
        if let uv = attrs["TEXCOORD_0"] { sources.append(try source(uv, semantic: .texcoord)) }
        if let uv = attrs["TEXCOORD_1"] { sources.append(try source(uv, semantic: .texcoord)) }
        let accessor = accessors[index]
        let view = views[accessor["bufferView"] as! Int]
        let offset = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let bytes = [5121: 1, 5123: 2, 5125: 4][accessor["componentType"] as! Int] ?? 2
        let count = accessor["count"] as! Int
        let indices = binary.subdata(in: offset..<(offset + count * bytes))
        let element = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: count / 3, bytesPerIndex: bytes)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        if let material = primitive["material"] as? Int { geometry.materials = [materials[material]] }
        return geometry
    }

    func makeScene(identifyPrimitives: Bool = false) throws -> SCNNode {
        let nodes = document["nodes"] as? [[String: Any]] ?? []
        let meshes = document["meshes"] as? [[String: Any]] ?? []
        func node(_ index: Int) throws -> SCNNode {
            let data = nodes[index]
            let result = SCNNode()
            result.name = data["name"] as? String
            if let matrix = (data["matrix"] as? [NSNumber])?.map(\.floatValue), matrix.count == 16 {
                result.simdTransform = simd_float4x4(columns: (
                    SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]), SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
                    SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]), SIMD4(matrix[12], matrix[13], matrix[14], matrix[15])))
            } else {
                if let p = (data["translation"] as? [NSNumber])?.map(\.floatValue) { result.simdPosition = SIMD3(p[0], p[1], p[2]) }
                if let r = (data["rotation"] as? [NSNumber])?.map(\.floatValue) { result.simdOrientation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]) }
                if let s = (data["scale"] as? [NSNumber])?.map(\.floatValue) { result.simdScale = SIMD3(s[0], s[1], s[2]) }
            }
            if let mesh = data["mesh"] as? Int {
                let primitives = meshes[mesh]["primitives"] as? [[String: Any]] ?? []
                for (part, primitive) in primitives.enumerated() {
                    let surface = SCNNode(geometry: try geometry(primitive))
                    if identifyPrimitives { surface.name = "\(index).\(part)" }
                    result.addChildNode(surface)
                }
            }
            for child in data["children"] as? [Int] ?? [] { result.addChildNode(try node(child)) }
            return result
        }
        let root = SCNNode()
        let scenes = document["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = document["scene"] as? Int ?? 0
        for index in scenes[sceneIndex]["nodes"] as? [Int] ?? [] { root.addChildNode(try node(index)) }
        return root
    }

    static func applyCabinMaterials(to model: SCNNode, kind: VehicleKind) {
        model.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry, let original = geometry.firstMaterial,
                  let name = node.parent?.name else { return }
            let roughness: Double
            switch (kind,name) {
            case (.porsche,"Object_16"), (.centenario,"Object_31"):
                roughness = 0.76
            case (.centenario,"Object_42"), (.centenario,"Object_69"), (.centenario,"Object_81"):
                roughness = 0.57
            default:
                return
            }
            // The original maps and UV bindings are shared with exterior panels.
            guard let material = original.copy() as? SCNMaterial else { return }
            material.metalness.contents = 0
            material.roughness.contents = roughness
            material.clearCoat.contents = 0
            geometry.firstMaterial = material
        }
    }

    static let porscheWindshieldLinerName = "PorscheWindshieldLiner"

    /// Object_26 carries an opaque liner almost coincident with the separate
    /// windshield. Keep the source faces available outside the driver's view.
    static func separatePorscheWindshieldLiner(from vehicle: SCNNode) -> SCNNode? {
        guard let parent = vehicle.childNode(withName: "Object_26", recursively: true),
              let body = parent.childNodes.first, let stock = body.geometry,
              let element = stock.elements.first, element.primitiveType == .triangles,
              element.primitiveCount == 38_550 else { return nil }
        let linerFaces = 8_928..<12_224
        let faceSize = element.bytesPerIndex * 3
        let indices = element.data
        let start = linerFaces.lowerBound * faceSize
        let end = linerFaces.upperBound * faceSize
        var remainder = indices.subdata(in: 0..<start)
        remainder.append(indices.subdata(in: end..<indices.count))
        func geometry(_ data: Data) -> SCNGeometry {
            let faces = SCNGeometryElement(data: data, primitiveType: .triangles,
                primitiveCount: data.count / faceSize, bytesPerIndex: element.bytesPerIndex)
            let part = SCNGeometry(sources: stock.sources, elements: [faces])
            part.materials = stock.materials
            return part
        }
        body.geometry = geometry(remainder)
        let liner = SCNNode(geometry: geometry(indices.subdata(in: start..<end)))
        liner.name = porscheWindshieldLinerName
        liner.transform = body.transform
        liner.castsShadow = body.castsShadow
        liner.renderingOrder = body.renderingOrder
        parent.addChildNode(liner)
        return liner
    }
}

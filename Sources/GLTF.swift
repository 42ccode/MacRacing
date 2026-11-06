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
        let a = accessors[accessorIndex]
        guard let viewIndex = a["bufferView"] as? Int, a["componentType"] as? Int == 5126 else { throw GLTFError.invalid("Unsupported vertex encoding") }
        let view = views[viewIndex]
        let components = ["VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 3
        return SCNGeometrySource(data: binary, semantic: semantic, vectorCount: a["count"] as! Int,
            usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4,
            dataOffset: (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0),
            dataStride: view["byteStride"] as? Int ?? components * 4)
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

    func makeScene() throws -> SCNNode {
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
                for primitive in meshes[mesh]["primitives"] as? [[String: Any]] ?? [] {
                    result.addChildNode(SCNNode(geometry: try geometry(primitive)))
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
}

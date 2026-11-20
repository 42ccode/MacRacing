import AppKit
import SceneKit
import simd

/// Authored at real metre scale. Shared textures and batched meshes keep the
/// populated scene affordable; the 2-million-triangle source tree is baked offline.
final class TrackEnvironment {
    let scene: SCNScene
    let circuit: Circuit
    let assets: URL
    private var root = SCNNode()
    private static let pavementLift = 0.025
    private static let vergeEdge = 6.38
    private static let vergeLift = 0.016
    // The wet film is sampled at regular stations. Its road edge, paved
    // verge, striping and graded shoulders must follow the same chords.
    private lazy var wetPavementStations: [TrackSample]? = {
        guard circuit.condition == .wet else { return nil }
        let count = Int(ceil(circuit.length/3))
        return (0..<count).map { circuit.sample(at:Double($0)*circuit.length/Double(count)) }
    }()
    private let dark = material(NSColor(rgb: 0x25282A), roughness: 0.9)
    private let paint = material(NSColor(rgb: 0xCFCDC1), roughness: 0.95)
    init(scene: SCNScene, circuit: Circuit, assets: URL) {
        self.scene = scene; self.circuit = circuit; self.assets = assets
        root.name = "CircuitEnvironment"
        scene.rootNode.addChildNode(root)
    }
    func build() -> [SCNMaterial] {
        ground(); road(); pitLane(); barriers(); pits(); circuitDetails()
        let landmarkClearings = cornerLandmarks()
        let startLenses = startingLights()
        // Posts, rails, garages and paint never move. Submit them by material
        // rather than submitting every small part separately on every frame.
        let fixed = root.flattenedClone()
        root.removeFromParentNode(); root = fixed; scene.rootNode.addChildNode(root)
        vegetation(avoiding:landmarkClearings)
        return startLenses
    }
    private func texture(_ path: String, _ property: SCNMaterialProperty, tile: CGFloat = 1) {
        property.contents = assets.appendingPathComponent(path)
        property.wrapS = .repeat; property.wrapT = .repeat
        property.maxAnisotropy = 16; property.mipFilter = .linear
        property.contentsTransform = SCNMatrix4MakeScale(tile,tile,1)
    }
    private func scanMaterial(_ name: String, tint: UInt32, tile: CGFloat = 1) -> SCNMaterial {
        let m = material(NSColor.white)
        texture("Environment/\(name)_diff_2k.jpg",m.diffuse,tile:tile)
        texture("Environment/\(name)_nor_gl_2k.jpg",m.normal,tile:tile)
        texture("Environment/\(name)_rough_2k.jpg",m.roughness,tile:tile)
        m.multiply.contents = NSColor(rgb:tint)
        m.normal.intensity = 0.35
        return m
    }
    private func trackPaint(_ color: UInt32) -> SCNMaterial {
        let m = material(NSColor(rgb:color),roughness:0.91)
        texture("Environment/asphalt_02_nor_gl_2k.jpg",m.normal)
        m.normal.intensity = 0.18
        m.shaderModifiers = [.surface: """
        #pragma body
        float2 p = _surface.normalTexcoord;
        float grain = sin(p.x*197.0+p.y*151.0)*sin(p.y*263.0-p.x*173.0);
        float wear = smoothstep(0.05,0.72,sin(p.y*19.0+p.x*41.0)*sin(p.y*37.0-p.x*22.0));
        _surface.diffuse.rgb *= 0.93 - 0.12*wear + 0.04*grain;
        """]
        return m
    }

    @discardableResult private func mesh(_ v: [SCNVector3], _ uv: [CGPoint], _ indices: [Int32], _ m: SCNMaterial,
                      normals: [SCNVector3]? = nil, colors: [SIMD4<Float>]? = nil,
                      name: String = "", batch: Bool = true) -> SCNNode {
        let ns = normals ?? v.map { _ in SCNVector3(0,1,0) }
        var sources: [SCNGeometrySource] = [.init(vertices:v),.init(normals:ns),.init(textureCoordinates:uv)]
        if let colors {
            let data = colors.withUnsafeBufferPointer { Data(buffer:$0) }
            sources.append(SCNGeometrySource(data:data,semantic:.color,vectorCount:colors.count,
                usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16))
        }
        let g = SCNGeometry(sources:sources,elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [m]
        let n = SCNNode(geometry:g); n.name = name
        (batch ? root : scene.rootNode).addChildNode(n)
        return n
    }
    @discardableResult private func box(_ w: CGFloat,_ h: CGFloat,_ l: CGFloat,_ p: SCNVector3,
                                        _ m: SCNMaterial, parent: SCNNode? = nil, bevel: CGFloat = 0) -> SCNNode {
        let g = SCNBox(width:w,height:h,length:l,chamferRadius:bevel); g.materials = [m]
        let n = SCNNode(geometry:g); n.position = p; (parent ?? root).addChildNode(n); return n
    }
    private func tube(_ from: SCNVector3,_ to: SCNVector3,_ radius: CGFloat,_ m: SCNMaterial, parent: SCNNode? = nil) {
        let a = SIMD3<Float>(Float(from.x),Float(from.y),Float(from.z)), b = SIMD3<Float>(Float(to.x),Float(to.y),Float(to.z))
        let delta = b-a
        let g = SCNCylinder(radius:radius,height:CGFloat(simd_length(delta))); g.radialSegmentCount = 8; g.materials = [m]
        let n = SCNNode(geometry:g); n.simdPosition = (a+b)*0.5
        n.simdOrientation = simd_quatf(from:SIMD3(0,1,0),to:simd_normalize(delta)); (parent ?? root).addChildNode(n)
    }
    private func label(_ value: String, size: CGFloat, at p: SCNVector3, parent: SCNNode, color: SCNMaterial) {
        let g = SCNText(string:value,extrusionDepth:0.001)
        g.font = NSFont.systemFont(ofSize:32,weight:.semibold); g.flatness = 0.3; g.materials = [color]
        let n = SCNNode(geometry:g); let b = g.boundingBox
        let scale = size / max(0.001,b.max.y-b.min.y)
        n.pivot = SCNMatrix4MakeTranslation((b.min.x+b.max.x)/2,(b.min.y+b.max.y)/2,0)
        n.scale = SCNVector3(scale,scale,scale); n.position = p; parent.addChildNode(n)
    }
    private func terrainHeight(_ p: SIMD2<Double>) -> Double {
        let location = circuit.nearest(to:p), d = location.distance
        let blend = clamp((d-27)/95,0,1)
        let hills = 3 + sin(p.x*0.008+0.8)*5 + cos(p.y*0.012)*3 + sin((p.x+p.y)*0.022)*1.6
        let profile = circuit.roadHeight(at:location)
        let edge = clamp((d-22)/105,0,1)
        return -0.045 + profile*(1-edge*edge*(3-2*edge)) + max(0,hills)*blend*blend
    }

    private func roadVector(_ s: TrackSample, _ lateral: Double, _ base: Double) -> SCNVector3 {
        vector(s.point+s.right*lateral,y:base+circuit.roadProfile(at:s.distance,lateral:lateral).height)
    }

    private func normal(_ s: TrackSample, _ lateral: Double, additional: SIMD2<Double> = .zero) -> SCNVector3 {
        let p = circuit.roadProfile(at:s.distance,lateral:lateral)
        let gradient = s.tangent*p.grade + s.right*p.crossfall + additional
        return SCNVector3(simd_normalize(SIMD3<Float>(Float(-gradient.x),1,Float(-gradient.y))))
    }
    private func ground() {
        let grass = scanMaterial("grass_ground",tint:0xADB59A)
        grass.normal.intensity = 0.12
        grass.shaderModifiers = [.surface: """
        #pragma body
        float2 p = _surface.diffuseTexcoord;
        float n = sin(p.x*0.39+sin(p.y*0.31))*sin(p.y*0.48+p.x*0.13);
        _surface.diffuse.rgb *= 0.94 + 0.12*n;
        _surface.roughness = 0.98;
        """]
        let count = 128, size = 1600.0, step = size/Double(count)
        var heights = [Double](), v = [SCNVector3](), uv = [CGPoint](), ix = [Int32](), ns = [SCNVector3]()
        for z in 0...count { for x in 0...count {
            let p = SIMD2(Double(x)*step-size/2,Double(z)*step-size/2)
            var y = terrainHeight(p)
            if circuit.hasElevation {
                let location = circuit.nearest(to:p)
                // Reserve the full road corridor for the finer shoulder mesh.
                // Drop the coarse terrain far enough that no quad can crest
                // above the asphalt between samples.
                let weight = clamp((39-location.distance)/14,0,1)
                y -= 1.15 * weight
            }
            heights.append(y); v.append(vector(p,y:y)); uv.append(CGPoint(x:p.x/5,y:p.y/5))
        }}
        for z in 0...count { for x in 0...count {
            let dx = heights[z*(count+1)+min(x+1,count)]-heights[z*(count+1)+max(x-1,0)]
            let dz = heights[min(z+1,count)*(count+1)+x]-heights[max(z-1,0)*(count+1)+x]
            let n = simd_normalize(SIMD3<Float>(Float(-dx),Float(2*step),Float(-dz)))
            ns.append(SCNVector3(n.x,n.y,n.z))
            if z<count && x<count { let i = Int32(z*(count+1)+x), s = Int32(count+1); ix += [i,i+s,i+1,i+1,i+s,i+s+1] }
        }}
        mesh(v,uv,ix,grass,normals:ns,name:"ContouredGrassTerrain")
        if circuit.hasElevation {
            // Fine shoulder mesh keeps the coarse terrain from intersecting the bank.
            let stations = wetPavementStations
            for side in [-1.0,1.0] {
                for (a,b) in [(Self.vergeEdge,9.0),(9,13),(13,18),(18,24),(24,34)] {
                    let pavedEdge = a == Self.vergeEdge && stations != nil
                    let nearHeight = pavedEdge ? Self.vergeLift : -0.012
                    let startHeight = side > 0 ? nearHeight : -0.012
                    let endHeight = side < 0 ? nearHeight : -0.012
                    strip(min(a*side,b*side),max(a*side,b*side),startHeight,grass,
                          endHeight:endHeight,stations:stations,name:"GradedShoulder")
                }
            }
        }
    }
    private func strip(_ a: Double,_ b: Double,_ height: Double,_ m: SCNMaterial,
                       filter: ((Int)->Bool)? = nil, offset: ((TrackSample)->Double)? = nil,
                       endHeight: Double? = nil, stations: [TrackSample]? = nil,
                       name: String = "", batch: Bool = true) {
        let samples = stations ?? circuit.samples
        let finalHeight = endHeight ?? height
        let crossfall = (finalHeight-height)/(b-a)
        let hasNormals = circuit.hasElevation || crossfall != 0
        var v = [SCNVector3](), uv = [CGPoint](), ix = [Int32](), ns = [SCNVector3]()
        for i in 0...samples.count {
            let s = samples[i%samples.count], shift = offset?(s) ?? 0
            let d = i == samples.count ? circuit.length : s.distance
            v += [roadVector(s,a+shift,height),roadVector(s,b+shift,finalHeight)]
            if hasNormals {
                let gradient = crossfall == 0 ? .zero : s.right*crossfall
                ns += [normal(s,a+shift,additional:gradient),normal(s,b+shift,additional:gradient)]
            }
            uv += [CGPoint(x:a/3,y:d/3),CGPoint(x:b/3,y:d/3)]
            if i<samples.count && (filter?(i) ?? true) {
                let n = Int32(i*2); ix += [n,n+2,n+1,n+1,n+2,n+3]
            }
        }
        m.isDoubleSided = true
        if !ix.isEmpty { mesh(v,uv,ix,m,normals:hasNormals ? ns : nil,name:name,batch:batch) }
    }
    private func road() {
        let asphalt = scanMaterial("asphalt_track",tint:0xC6C5C1)
        asphalt.normal.intensity = 0.30
        if circuit.condition == .wet {
            asphalt.normal.intensity = 0.18
            asphalt.clearCoat.contents = 0.25
            asphalt.clearCoatRoughness.contents = 0.11
        }
        asphalt.shaderModifiers = [.surface: """
        #pragma body
        float2 p = _surface.diffuseTexcoord * 3.0;
        float variation = sin(p.x*0.37+sin(p.y*0.12))*sin(p.y*0.29);
        float aggregate = sin(p.x*3.3+p.y*1.2)*sin(p.y*4.2-p.x*2.7);
        float centre = 1.35*sin(p.y*0.022)+0.50*sin(p.y*0.053);
        float track = abs(p.x-centre);
        float rubber = 1.0-smoothstep(0.15,0.57,abs(track-0.83));
        float joint = 1.0-smoothstep(0.025,0.10,abs(p.x-2.95-0.04*sin(p.y*0.28)));
        float patch = smoothstep(0.84,0.98,sin(p.y*0.19)*sin(p.y*0.087+1.1))
                    * (1.0-smoothstep(0.34,0.42,abs(p.x+3.64)));
        _surface.diffuse.rgb *= 0.99 + 0.07*variation + 0.04*aggregate - 0.15*rubber - 0.21*joint + 0.17*patch;
        """]
        let stations = wetPavementStations
        if let stations {
            let filmVarying = "#pragma varyings\nfloat waterFilm;\n"
            asphalt.shaderModifiers?[.geometry] = "#pragma arguments\nfloat dryingBlend;\n" + filmVarying + """
            #pragma body
            out.waterFilm = mix(_geometry.color.r,_geometry.color.g,dryingBlend);
            _geometry.color.rgb = float3(1.0);
            """
            asphalt.setValue(NSNumber(value:1.0 as Float),forKey:"dryingBlend")
            if let roadShader = asphalt.shaderModifiers?[.surface] {
                asphalt.shaderModifiers?[.surface] = filmVarying + roadShader + """

                float film = smoothstep(0.0,1.0,in.waterFilm);
                float3 n = normalize(_surface.geometryNormal);
                float headOn = abs(dot(n,normalize(_surface.view)));
                // Approximate low-frequency sky reflection in pooled water.
                // At grazing angles its Fresnel term brightens markedly.
                float sky = 0.0204 + 0.9796*pow(saturate(1.0-headOn),5.0);
                _surface.diffuse.rgb *= 0.89 - 0.18*film;
                _surface.roughness = mix(_surface.roughness,0.10,film*0.92);
                _surface.clearCoat = 0.12 + 0.72*film;
                _surface.clearCoatRoughness = 0.23 - 0.17*film;
                _surface.emission.rgb += sky*film*float3(0.17,0.20,0.24);
                """
            }
            wetRoad(asphalt,stations:stations)
        } else {
            // SceneKit's flattened clone can strip shader modifiers and vertex inputs.
            strip(-6,6,Self.pavementLift,asphalt,name:"DrivingSurface",batch:false)
        }
        let edge = scanMaterial("asphalt_02",tint:0x8D8678)
        let seamHeight = stations == nil ? Self.vergeLift : Self.pavementLift
        strip(-Self.vergeEdge,-6,Self.vergeLift,edge,endHeight:seamHeight,stations:stations)
        strip(6,Self.vergeEdge,seamHeight,edge,endHeight:Self.vergeLift,stations:stations)
        let wornPaint = trackPaint(0xB6B4A9)
        strip(-5.94,-5.80,0.033,wornPaint,stations:stations)
        strip(5.80,5.94,0.033,wornPaint,stations:stations)
        raisedKerbs(red:scanMaterial("asphalt_02",tint:0xA64B40),white:scanMaterial("asphalt_02",tint:0xEEE9DA))
        brakingMarks()
        distanceBoards()
        for slot in 0..<12 {
            let s = circuit.gridSlot(slot, frontMark:true)
            let n = SCNNode(); n.position = vector(s.point); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
            box(2.46,0.004,0.09,SCNVector3(0,0.036,0),wornPaint,parent:n)
            for edge: CGFloat in [-1.19,1.19] {
                box(0.08,0.004,0.52,SCNVector3(edge,0.036,-0.27),wornPaint,parent:n)
            }
        }
        let s = circuit.sample(at:0), n = SCNNode(); n.position = vector(s.point); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
        for row in 0..<2 {
            for column in 0..<32 where (column+row).isMultiple(of:2) {
                box(0.36,0.004,0.24,SCNVector3((CGFloat(column)-15.5)*0.36,0.037,(CGFloat(row)-0.5)*0.24),
                    wornPaint,parent:n)
            }
        }
        let galvanized = material(NSColor(rgb:0x8A9295),metal:0.65,roughness:0.5)
        for x: CGFloat in [-9,9] { tube(SCNVector3(x,0,0),SCNVector3(x,6.1,0),0.14,galvanized,parent:n) }
        box(18.4,0.65,0.8,SCNVector3(0,6,0),galvanized,parent:n)
        box(5.5,0.7,0.04,SCNVector3(0,6,-0.43),dark,parent:n)
        let front = SCNNode(); front.eulerAngles.y = .pi; n.addChildNode(front)
        label(circuit.name,size:0.38,at:SCNVector3(0,5.82,0.46),parent:front,color:paint)
    }

    private func startingLights() -> [SCNMaterial] {
        let sample = circuit.sample(at:circuit.gridSlot(0,frontMark:true).distance+18)
        let beam = material(NSColor(rgb:0x707A7D),metal:0.54,roughness:0.53)
        let housing = material(NSColor(rgb:0x171C1E),roughness:0.78)
        let frame = SCNNode()
        frame.position = roadVector(sample,0,0)
        frame.eulerAngles.y = CGFloat(atan2(sample.tangent.x,sample.tangent.y))
        root.addChildNode(frame)

        // Single support behind the catch fence; the arm clears the full
        // grid and avoids putting a post in the pit lane or the run-off.
        let support: CGFloat = 18.2
        let footY = roadVector(sample,Double(support),-0.5).y-frame.position.y
        box(0.48,5.98-footY,0.68,SCNVector3(support,(5.98+footY)/2,0),beam,parent:frame)
        box(21.7,0.40,0.56,SCNVector3(7.55,5.78,0),beam,parent:frame)
        tube(SCNVector3(support,4.18,0),SCNVector3(15.0,5.69,0),0.075,beam,parent:frame)
        box(2.58,0.72,0.20,SCNVector3(0,5.31,0),housing,parent:frame,bevel:0.06)

        // A lower repeater sits beyond the pit exit. Its shallower sight line
        // clears low windscreens and sun visors when the overhead lamps don't.
        let repeater = circuit.sample(at:PitLane.exit+7)
        let pedestal = SCNNode()
        pedestal.position = roadVector(repeater,-8.4,0)
        pedestal.eulerAngles.y = CGFloat(atan2(repeater.tangent.x,repeater.tangent.y))
        root.addChildNode(pedestal)
        box(0.22,2.75,0.26,SCNVector3(0,1.32,0),beam,parent:pedestal)
        box(0.48,0.14,0.50,SCNVector3(0,0.03,0),beam,parent:pedestal)
        box(2.58,0.81,0.20,SCNVector3(0,2.60,0),housing,parent:pedestal,bevel:0.06)

        func lenses(at frame: SCNNode, height: CGFloat, radius: CGFloat, name: String) -> [SCNMaterial] {
            let signal = SCNNode()
            signal.name = name
            signal.position = frame.position
            signal.eulerAngles.y = frame.eulerAngles.y
            scene.rootNode.addChildNode(signal)
            return (0..<3).map { index in
                // The front of each lens points toward cars on the grid.
                let lens = SCNMaterial()
                lens.lightingModel = .constant
                lens.diffuse.contents = NSColor(rgb:0x412327)
                let geometry = SCNCylinder(radius:radius,height:0.048)
                geometry.radialSegmentCount = 28
                geometry.materials = [lens]
                let node = SCNNode(geometry:geometry)
                node.eulerAngles.x = .pi/2
                node.position = SCNVector3(CGFloat(1-index)*0.72,height,-0.127)
                node.castsShadow = false
                signal.addChildNode(node)
                return lens
            }
        }
        return lenses(at:frame,height:5.31,radius:0.253,name:"RaceStartLenses") +
            lenses(at:pedestal,height:2.60,radius:0.31,name:"RaceStartRepeater")
    }

    private func distanceBoards() {
        let leg = material(NSColor(rgb:0x737A79),metal:0.4,roughness:0.65)
        let back = material(NSColor(rgb:0xAAAFA7),roughness:0.7)
        let distances = [100.0,50.0]
        let faces = distances.map {
            Self.signFace(String(Int($0)),background:0xEBEBDF,foreground:0x202625,aspect:1.56)
        }
        let lane = circuit.pitLane
        for target in circuit.cornerDistances {
            let before = circuit.sample(at:target-12).tangent
            let after = circuit.sample(at:target+12).tangent
            let outside = before.x*after.y-before.y*after.x >= 0 ? 1.0 : -1.0
            for (index,distance) in distances.enumerated() {
                let sample = circuit.sample(at:target-distance)
                let local = lane.localProgress(sample.distance)
                let inPit = (PitLane.entry...PitLane.exit).contains(local)
                // Keep posts off all pavement, including the merge where it
                // widens along the outside edge of the racing surface.
                let offset = inPit && outside < 0 ? min(-8.5,lane.lateral(at:local)-PitLane.halfWidth-1.7) : outside*8.5
                signPanel(sample,offset:offset,width:1.82,height:1.17,centre:1.25,
                          backing:back,post:leg,face:faces[index])
            }
        }
    }

    static func signFace(_ title: String, background: UInt32, foreground: UInt32, aspect: CGFloat) -> SCNMaterial {
        let size = NSSize(width:384,height:(384/aspect).rounded(.up))
        let image = NSImage(size:size)
        image.lockFocus()
        NSColor(rgb:background).setFill()
        NSRect(origin:.zero,size:size).fill()
        let attributes: [NSAttributedString.Key:Any] = [
            .font:NSFont.systemFont(ofSize:size.height*0.70,weight:.heavy),
            .foregroundColor:NSColor(rgb:foreground)
        ]
        let text = NSAttributedString(string:title,attributes:attributes)
        let bounds = text.size()
        text.draw(at:NSPoint(x:(size.width-bounds.width)/2,y:(size.height-bounds.height)/2))
        image.unlockFocus()
        let face = SCNMaterial()
        face.lightingModel = .constant
        face.diffuse.contents = image
        face.diffuse.mipFilter = .linear
        face.diffuse.maxAnisotropy = 8
        return face
    }

    @discardableResult private func signPanel(_ sample: TrackSample, offset: Double, width: CGFloat, height: CGFloat,
                                              centre: CGFloat, backing: SCNMaterial, post: SCNMaterial,
                                              face: SCNMaterial) -> SCNNode {
        let anchor = SCNNode()
        anchor.position = roadVector(sample,offset,0)
        anchor.eulerAngles.y = CGFloat(atan2(sample.tangent.x,sample.tangent.y)+Double.pi)
        root.addChildNode(anchor)
        let panel = SCNPlane(width:width,height:height)
        panel.materials = [face]
        let front = SCNNode(geometry:panel)
        front.position = SCNVector3(0,centre,0.042)
        front.castsShadow = false
        anchor.addChildNode(front)
        box(width+0.05,height+0.05,0.08,SCNVector3(0,centre,0),backing,parent:anchor,bevel:0.016)
        for side in [-1.0,1.0] {
            let x = CGFloat(side)*width*0.30
            tube(SCNVector3(x,-0.12,-0.045),SCNVector3(x,centre+height*0.36,-0.045),0.027,post,parent:anchor)
        }
        return anchor
    }

    private func wetRoad(_ asphalt: SCNMaterial, stations: [TrackSample]) {
        let across = 12, along = stations.count
        var points: [SCNVector3] = [], normals: [SCNVector3] = [], coords: [CGPoint] = []
        var colors: [SIMD4<Float>] = [], indices: [Int32] = []
        for i in 0...along {
            let distance = Double(i)*circuit.length/Double(along)
            let sample = stations[i%along]
            for j in 0...across {
                let lateral = Double(j)-6
                let depth = circuit.waterDepth(at:distance,lateral:lateral)
                let wet = Float(clamp((depth-0.25)/0.80,0,1))
                points.append(roadVector(sample,lateral,Self.pavementLift))
                normals.append(normal(sample,lateral))
                coords.append(CGPoint(x:lateral/3,y:distance/3))
                colors.append(SIMD4(wet,wet,wet,1))
                if i < along && j < across {
                    let a = Int32(i*(across+1)+j), b = a+Int32(across+1)
                    indices += [a,b,a+1,a+1,b,b+1]
                }
            }
        }
        asphalt.isDoubleSided = true
        mesh(points,coords,indices,asphalt,normals:normals,colors:colors,name:"WetDrivingSurface",batch:false)
    }
    private func brakingMarks() {
        let width = 32, height = 128
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:width*4,bitsPerPixel:32)!
        let pixels = bitmap.bitmapData!
        for y in 0..<height {
            let t = Double(y)/Double(height-1)
            let fade = min(1,t*6,(1-t)*9)
            for x in 0..<width {
                let across = abs(Double(x)/Double(width-1)*2-1)
                let feather = max(0,1-across*across)
                let mottling = 0.79 + 0.21*sin(t*48+Double(x)*0.2)
                let index = (y*width+x)*4
                pixels[index] = 0; pixels[index+1] = 0; pixels[index+2] = 0
                pixels[index+3] = UInt8(60*fade*feather*mottling)
            }
        }
        let image = NSImage(size:NSSize(width:width,height:height))
        image.addRepresentation(bitmap)
        let rubber = SCNMaterial()
        rubber.lightingModel = .constant
        rubber.diffuse.contents = image
        rubber.diffuse.mipFilter = .linear
        rubber.writesToDepthBuffer = false
        rubber.isDoubleSided = true
        var vertices:[SCNVector3]=[], uv:[CGPoint]=[], indices:[Int32]=[]
        let steps = 34
        for target in circuit.cornerDistances {
            for lane in [-0.84,0.84] {
                let base = Int32(vertices.count)
                for i in 0...steps {
                    let t = Double(i)/Double(steps)
                    let progress = target-46+34*t
                    let sample = circuit.sample(at:progress)
                    let offset = lane + 0.22*sin(progress*0.085)
                    let halfWidth = 0.13 + 0.045*sin(t * .pi)
                    vertices += [roadVector(sample,offset-halfWidth,0.034),
                                 roadVector(sample,offset+halfWidth,0.034)]
                    uv += [CGPoint(x:0,y:t),CGPoint(x:1,y:t)]
                    if i<steps {
                        let n = base+Int32(i*2)
                        indices += [n,n+2,n+1,n+1,n+2,n+3]
                    }
                }
            }
        }
        if !indices.isEmpty { mesh(vertices,uv,indices,rubber,name:"BrakingRubber").castsShadow = false }
    }

    private func raisedKerbs(red: SCNMaterial, white: SCNMaterial) {
        let edges = [0.0,0.12/0.85,0.70/0.85,1.0]
        let count = Int(ceil(circuit.length/0.25))
        for side in [-1.0,1.0] { for stripe in 0...1 {
            var vertices:[SCNVector3]=[],uv:[CGPoint]=[],normals:[SCNVector3]=[],indices:[Int32]=[]
            for i in 0..<count {
                let d=Double(i)*circuit.length/Double(count), next=Double(i+1)*circuit.length/Double(count)
                guard Int(d/2.5)%2==stripe, circuit.kerb(at:(d+next)/2,side:side).scale > 0.001 else { continue }
                let start=Int32(vertices.count)
                for distance in [d,next] {
                    let sample=circuit.sample(at:distance)
                    let profile=circuit.kerb(at:distance,side:side)
                    // Differentiate the same tapered shape at a fixed lateral
                    // distance so the ramp and bank shade like the driven surface.
                    let before=circuit.kerb(at:distance-0.01,side:side)
                    let after=circuit.kerb(at:distance+0.01,side:side)
                    for fraction in edges {
                        let edge=fraction*profile.width
                        let h=profile.elevation(progress:distance,distanceFromEdge:edge)
                        vertices.append(roadVector(sample,side*(6+edge),Self.pavementLift+h))
                        uv.append(CGPoint(x:edge/3,y:distance/3))
                        let across=(profile.elevation(progress:distance,distanceFromEdge:edge+0.001)-profile.elevation(progress:distance,distanceFromEdge:edge-0.001))/0.002
                        let along=(after.elevation(progress:distance+0.01,distanceFromEdge:edge)-before.elevation(progress:distance-0.01,distanceFromEdge:edge))/0.02
                        let gradient=sample.right*side*across+sample.tangent*along
                        normals.append(normal(sample,side*(6+edge),additional:gradient))
                    }
                }
                for j in 0..<3 {
                    let a=start+Int32(j), b=a+4
                    indices += side>0 ? [a,b,a+1,a+1,b,b+1] : [a,a+1,b,a+1,b+1,b]
                }
            }
            let paint=stripe==0 ? red : white; paint.isDoubleSided=true
            if !indices.isEmpty { mesh(vertices,uv,indices,paint,normals:normals,name:"ProfiledKerbs") }
        }}
    }

    private func circuitDetails() {
        let steel=material(NSColor(rgb:0x727A7D),metal:0.65,roughness:0.6)
        let concrete=material(NSColor(rgb:0xA7AAA4),roughness:0.94)
        let seat=material(NSColor(rgb:0x344853),roughness:0.82)
        // Furniture stays outside the physical barrier and away from nearby bends.
        let sample=circuit.sample(at:120), centre=sample.point+sample.right*34
        let corners=[SIMD2(-12.0,-7),SIMD2(12.0,-7),SIMD2(-12.0,7),SIMD2(12.0,7)]
        if corners.allSatisfy({ circuit.nearest(to:centre+sample.right*$0.x+sample.tangent*$0.y).distance>17 }) {
            let stand=SCNNode(); stand.name="SpectatorStand";stand.position=vector(centre,y:circuit.hasElevation ? terrainHeight(centre) : 0);stand.eulerAngles.y=CGFloat(atan2(sample.tangent.x,sample.tangent.y));root.addChildNode(stand)
            for row in 0..<6 {
                let x=CGFloat(row)*1.1-3, h=CGFloat(row)*0.42+0.3
                box(1.1,h,20,SCNVector3(x,h/2,0),concrete,parent:stand)
                for place in 0..<28 {
                    box(0.45,0.10,0.52,SCNVector3(x,h+0.22,CGFloat(place)*0.67-9),seat,parent:stand,bevel:0.025)
                    box(0.10,0.38,0.52,SCNVector3(x+0.2,h+0.43,CGFloat(place)*0.67-9),seat,parent:stand,bevel:0.025)
                }
            }
            for z:CGFloat in [-10,10] {
                tube(SCNVector3(-3.5,1.25,z),SCNVector3(3,3.7,z),0.045,steel,parent:stand)
                for row in 0..<6 {
                    let x=CGFloat(row)*1.1-3, h=CGFloat(row)*0.42+0.3
                    tube(SCNVector3(x,h,z),SCNVector3(x,1.25+(x+3.5)*2.45/6.5,z),0.035,steel,parent:stand)
                }
            }
        }
        for distance in stride(from:0.0,to:circuit.length,by:60) {
            let s=circuit.sample(at:distance)
            for side in [-1.0,1.0] {
                let point=s.point+s.right*(17.3*side)
                guard circuit.nearest(to:point).distance>16.8 else {continue}
                let n=SCNNode();n.position=roadVector(s,17.3*side,0);n.eulerAngles.y=CGFloat(atan2(s.tangent.x,s.tangent.y));root.addChildNode(n)
                box(0.12,0.8,0.12,SCNVector3(0,0.4,0),paint,parent:n)
                box(0.13,0.13,0.025,SCNVector3(0,0.67,-0.07),side>0 ? seat : dark,parent:n)
            }
        }
        // Pit-lane service objects behind the barrier, never invisible obstacles.
        for distance in [12.0,45,78] {
            let s=circuit.sample(at:distance), p=s.point+s.right*(-19)
            guard circuit.nearest(to:p).distance>17 else {continue}
            let n=SCNNode();n.position=vector(p);root.addChildNode(n)
            for i in 0..<3 {
                let tyre=SCNTorus(ringRadius:0.24,pipeRadius:0.085);tyre.ringSegmentCount=24;tyre.pipeSegmentCount=8;tyre.materials=[dark]
                let ring=SCNNode(geometry:tyre);ring.position=SCNVector3(0,CGFloat(i)*0.16+0.09,0);n.addChildNode(ring)
            }
        }
    }

    static func landmarkFootprint(_ form: CornerLandmark.Form) -> SIMD2<Double> {
        switch form {
        case .marshalPost: return SIMD2(2.4,2.1)
        case .wall: return SIMD2(4.0,1.35)
        case .lightRig: return SIMD2(3.15,1.5)
        case .observationDeck: return SIMD2(3.1,2.1)
        case .shelter: return SIMD2(3.2,2.1)
        case .mast: return SIMD2(2.4,1.8)
        }
    }

    private func cornerLandmarks() -> [SIMD2<Double>] {
        let landmarks = SCNNode()
        landmarks.name = "CornerLandmarks"
        scene.rootNode.addChildNode(landmarks)
        let cement = scanMaterial("concrete_wall_006",tint:0xA3A399,tile:1.4)
        let steel = material(NSColor(rgb:0x666E70),metal:0.42,roughness:0.58)
        let roof = material(NSColor(rgb:0xD7D7CB),metal:0.16,roughness:0.68)
        let window = material(NSColor(rgb:0x26323A),metal:0.25,roughness:0.4)
        var clearings: [SIMD2<Double>] = []
        for landmark in circuit.kind.landmarks {
            let station = circuit.sample(at:landmark.station)
            let centre = station.point+station.right*landmark.offset
            let approach = circuit.sample(at:landmark.corner-120)
            let facing = simd_normalize(approach.point-centre)
            let across = SIMD2(facing.y,-facing.x)
            let half = Self.landmarkFootprint(landmark.form)
            let clear = [-1.0,0,1].allSatisfy { x in
                [-1.0,0,1].allSatisfy { z in
                    let point = centre+across*(half.x*x)+facing*(half.y*z)
                    return circuit.nearest(to:point).distance > 18.1
                }
            }
            guard clear else { continue }

            let anchor = SCNNode()
            anchor.name = landmark.name
            anchor.position = vector(centre,y:terrainHeight(centre))
            anchor.eulerAngles.y = CGFloat(atan2(facing.x,facing.y))
            let accent = material(NSColor(rgb:landmark.accent),roughness:0.65)
            func part(_ width: CGFloat,_ height: CGFloat,_ depth: CGFloat,_ x: CGFloat,_ y: CGFloat,_ z: CGFloat,
                      _ finish: SCNMaterial,bevel: CGFloat = 0) {
                box(width,height,depth,SCNVector3(x,y,z),finish,parent:anchor,bevel:bevel)
            }
            func member(_ a: SCNVector3,_ b: SCNVector3,_ radius: CGFloat,_ finish: SCNMaterial) {
                tube(a,b,radius,finish,parent:anchor)
            }
            func plate(width: CGFloat,height: CGFloat,y: CGFloat,z: CGFloat) {
                part(width+0.13,height+0.11,0.10,0,y,z,window,bevel:0.025)
                let plaque = SCNPlane(width:width,height:height)
                plaque.materials = [Self.signFace(landmark.name,background:0x23303B,foreground:0xF2EEDF,aspect:width/height)]
                let surface = SCNNode(geometry:plaque)
                surface.castsShadow = false
                surface.position = SCNVector3(0,y,z+0.054)
                anchor.addChildNode(surface)
            }

            switch landmark.form {
            case .marshalPost:
                part(4.12,1.22,3.46,0,-0.43,0,cement,bevel:0.08)
                part(3.72,2.65,3.18,0,1.51,0,accent,bevel:0.06)
                part(3.48,0.76,0.035,0,2.37,1.601,window)
                part(0.035,0.76,2.0,-1.881,2.37,0,window)
                part(0.05,0.82,0.052,0,2.37,1.626,roof)
                part(0.06,1.91,0.96,1.874,1.19,-0.38,window,bevel:0.02)
                part(0.047,0.047,0.14,1.924,1.17,-0.13,roof)
                part(4.63,0.21,3.99,0,2.91,0.07,roof,bevel:0.045)
                part(3.77,0.34,0.16,0,3.16,1.49,accent)
                plate(width:3.38,height:0.64,y:3.49,z:1.62)
            case .wall:
                part(7.75,1.13,2.44,0,-0.39,0,cement,bevel:0.09)
                part(7.35,1.62,1.53,0,0.99,-0.12,cement,bevel:0.08)
                part(5.40,1.06,1.38,0.21,2.23,-0.20,cement,bevel:0.08)
                for x: CGFloat in [-2.35,0,2.35] {
                    part(0.24,2.52,0.40,x,1.38,0.66,cement,bevel:0.04)
                }
                part(5.61,0.19,1.60,0.21,2.80,-0.08,accent)
                part(3.49,0.50,0.49,0,2.99,0,accent,bevel:0.05)
                plate(width:3.40,height:0.62,y:3.25,z:0.31)
            case .lightRig:
                for x: CGFloat in [-2.64,2.64] {
                    part(0.83,1.18,2.24,x,-0.38,0,cement,bevel:0.06)
                    member(SCNVector3(x,0,0),SCNVector3(x,6.32,0),0.124,steel)
                    part(0.32,0.47,0.33,x,5.59,0,accent)
                    for shift: CGFloat in [-0.17,0.17] {
                        part(0.30,0.27,0.25,x+shift,6.23,0.15,window,bevel:0.025)
                        part(0.25,0.23,0.03,x+shift,6.23,0.282,roof,bevel:0.02)
                    }
                }
                member(SCNVector3(-2.64,5.79,0),SCNVector3(2.64,5.79,0),0.064,steel)
                part(5.50,0.21,0.31,0,3.74,0,accent)
                plate(width:3.75,height:0.64,y:3.74,z:0.19)
            case .observationDeck:
                part(5.03,1.13,3.31,0,-0.40,0,cement,bevel:0.08)
                for x: CGFloat in [-2.04,2.04] {
                    for z: CGFloat in [-1.21,1.21] { part(0.17,3.65,0.17,x,1.83,z,steel) }
                    member(SCNVector3(x,0.17,-1.20),SCNVector3(x,3.51,1.20),0.048,steel)
                    member(SCNVector3(x,3.68,-1.38),SCNVector3(x,4.50,-1.38),0.051,steel)
                    member(SCNVector3(x,3.68,1.38),SCNVector3(x,4.50,1.38),0.051,steel)
                    member(SCNVector3(x,4.50,-1.38),SCNVector3(x,4.50,1.38),0.050,steel)
                }
                part(5.21,0.27,3.19,0,3.63,0,accent)
                member(SCNVector3(-2.04,4.50,1.38),SCNVector3(2.04,4.50,1.38),0.05,steel)
                member(SCNVector3(-2.04,4.50,-1.38),SCNVector3(0.88,4.50,-1.38),0.05,steel)
                for x: CGFloat in [0.91,1.52] {
                    member(SCNVector3(x,0.11,-1.92),SCNVector3(x,4.1,-1.43),0.041,steel)
                }
                for level in 1...10 {
                    let y = CGFloat(level)*0.34
                    let z = -1.92+(y-0.11)*0.123
                    member(SCNVector3(0.91,y,z),SCNVector3(1.52,y,z),0.028,steel)
                }
                part(1.26,0.10,0.95,0.82,4.48,-0.41,roof,bevel:0.04)
                part(0.13,0.85,0.13,0.82,4.06,-0.41,steel)
                plate(width:4.08,height:0.72,y:3.63,z:1.66)
            case .shelter:
                part(5.74,1.10,3.68,0,-0.43,0,cement,bevel:0.08)
                for x: CGFloat in [-2.37,2.37] {
                    part(0.23,3.50,0.31,x,1.76,1.25,accent)
                    part(0.23,2.98,0.31,x,1.54,-1.25,accent)
                    member(SCNVector3(x,2.99,-1.25),SCNVector3(x,3.50,1.25),0.071,steel)
                }
                let canopy = box(6.16,0.20,4.06,SCNVector3(0,3.28,0),roof,parent:anchor,bevel:0.04)
                canopy.eulerAngles.x = -0.19
                part(4.60,1.98,0.19,0,1.21,-1.26,accent,bevel:0.03)
                part(2.26,0.14,0.48,0,0.66,-0.92,steel,bevel:0.04)
                part(5.08,0.19,0.26,0,3.46,1.30,accent)
                plate(width:4.02,height:0.67,y:3.46,z:1.46)
            case .mast:
                part(3.35,1.19,3.27,0,-0.41,0,cement,bevel:0.09)
                for x: CGFloat in [-1,1] {
                    for z: CGFloat in [-1,1] {
                        member(SCNVector3(x*1.11,0,z*1.05),SCNVector3(x*0.27,7.65,z*0.27),0.058,steel)
                    }
                    member(SCNVector3(x*1.10,0,1.04),SCNVector3(x*0.81,2.71,-0.79),0.045,steel)
                    member(SCNVector3(x*0.81,2.71,-0.79),SCNVector3(x*0.53,5.18,0.53),0.045,steel)
                    member(SCNVector3(x*0.53,5.18,0.53),SCNVector3(x*0.27,7.65,-0.27),0.043,steel)
                }
                for (y,width,finish) in [(2.71,1.81,roof),(5.18,1.22,accent),(7.37,0.73,roof)] {
                    part(width,0.17,width,0,y,0,finish)
                }
                member(SCNVector3(0,7.31,0),SCNVector3(0,8.56,0),0.051,steel)
                member(SCNVector3(-1.49,8.21,0),SCNVector3(1.49,8.21,0),0.040,steel)
                part(0.88,0.19,0.17,0.64,8.22,0,accent,bevel:0.027)
                plate(width:3.28,height:0.65,y:3.59,z:1.18)
                member(SCNVector3(-1.65,3.59,1.12),SCNVector3(1.65,3.59,1.12),0.052,steel)
            }
            // Each footprint can be culled independently around the lap.
            landmarks.addChildNode(anchor.flattenedClone())
            clearings.append(centre)
        }
        return clearings
    }

    private func barriers() {
        let metal = material(NSColor(rgb:0xA2A4A1),metal:0.48,roughness:0.64)
        texture("Environment/metal_plate_diff_2k.jpg",metal.diffuse)
        texture("Environment/metal_plate_rough_2k.jpg",metal.roughness)
        metal.roughness.intensity = 0.75
        metal.multiply.contents = NSColor(rgb:0xE3E7E4)
        let rib = Circuit.guardRailCorrugation
        let profile: [(Double,Double)] = [(0.29,rib),(0.35,-rib),(0.43,rib),(0.50,-rib),(0.58,rib)]
        for side in [-1.0,1.0] {
            var v = [SCNVector3](),uv = [CGPoint](),ix = [Int32](),normals = [SCNVector3]()
            for i in 0...circuit.samples.count {
                let s = circuit.samples[i%circuit.samples.count]
                let verticesPerSample = (profile.count-1)*2
                for j in 0..<(profile.count-1) {
                    let lower = profile[j], upper = profile[j+1]
                    let slope = Float((upper.1-lower.1)/(upper.0-lower.0))
                    let normal = simd_normalize(SIMD3<Float>(-Float(s.right.x*side),slope,-Float(s.right.y*side)))
                    for (height, offset) in [lower,upper] {
                        v.append(roadVector(s,(Circuit.guardRailOffset+offset)*side,height))
                        uv.append(CGPoint(x:s.distance/4,y:height*2))
                        normals.append(SCNVector3(normal))
                    }
                    if i<circuit.samples.count {
                        let k = Int32(i*verticesPerSample+j*2), next = k+Int32(verticesPerSample)
                        ix += [k,next,k+1,k+1,next,next+1]
                    }
                }
            }
            metal.isDoubleSided = true; mesh(v,uv,ix,metal,normals:normals,name:"CorrugatedArmco")
        }
        // Mip-filtered alpha retains fine wires without a hard distance cutoff.
        let chain = SCNMaterial(); chain.lightingModel = .constant
        chain.diffuse.contents = wireTexture(); chain.isDoubleSided = true
        chain.diffuse.wrapS = .repeat; chain.diffuse.wrapT = .repeat
        chain.diffuse.mipFilter = .linear
        chain.diffuse.maxAnisotropy = 8
        chain.writesToDepthBuffer = false
        let steel = material(NSColor(rgb:0x626765),metal:0.6,roughness:0.65)
        var v = [SCNVector3](), uv = [CGPoint](), ix = [Int32](), ns = [SCNVector3]()
        for i in stride(from:0,to:circuit.samples.count,by:3) {
            let s = circuit.samples[i], next = circuit.samples[(i+3)%circuit.samples.count]
            for side in [-1.0,1.0] {
                let a = s.point+s.right*17*side, b = next.point+next.right*17*side
                tube(roadVector(s,17*side,0),roadVector(s,17*side,3),0.033,steel)
                tube(roadVector(s,15.95*side,0),roadVector(s,15.95*side,0.72),0.04,steel)
                let k = Int32(v.count); v += [roadVector(s,17*side,0.2),roadVector(next,17*side,0.2),roadVector(s,17*side,2.8),roadVector(next,17*side,2.8)]
                let u = simd_distance(a,b)/0.28
                uv += [CGPoint(x:0,y:0),CGPoint(x:u,y:0),CGPoint(x:0,y:9.3),CGPoint(x:u,y:9.3)]
                ix += [k,k+2,k+1,k+1,k+2,k+3]
                ns += Array(repeating:SCNVector3(Float(s.right.x),0,Float(s.right.y)),count:4)
                tube(roadVector(s,17*side,2.8),roadVector(next,17*side,2.8),0.016,steel)
            }
        }
        mesh(v,uv,ix,chain,normals:ns,name:"CatchFencing").castsShadow = false
    }
    private func wireTexture() -> NSImage {
        let image = NSImage(size:NSSize(width:128,height:128)); image.lockFocus()
        NSColor.clear.setFill(); NSRect(x:0,y:0,width:128,height:128).fill()
        let path = NSBezierPath(); path.lineWidth = 2.0
        path.move(to:.init(x:0,y:0)); path.line(to:.init(x:128,y:128))
        path.move(to:.init(x:0,y:128)); path.line(to:.init(x:128,y:0))
        NSColor(rgb:0x626C6D,alpha:0.75).setStroke(); path.stroke(); image.unlockFocus(); return image
    }
    private func pitLane() {
        let lane = circuit.pitLane
        let asphalt = scanMaterial("asphalt_track",tint:0xA7ADB0)
        if circuit.condition == .wet {
            asphalt.multiply.contents = NSColor(rgb:0x858F97)
            asphalt.roughness.contents = 0.36
            asphalt.clearCoat.contents = 0.26
            asphalt.clearCoatRoughness.contents = 0.20
        }
        let blue = trackPaint(0x508393)
        let yellow = trackPaint(0xC8AA57)
        func ribbon(from start:Double,to end:Double,left:Double,right:Double,height:Double,
                    material:SCNMaterial,name:String) {
            let steps = max(1,Int(ceil((end-start)/2)))
            var vertices:[SCNVector3]=[], uv:[CGPoint]=[], indices:[Int32]=[]
            for i in 0...steps {
                let distance = start+(end-start)*Double(i)/Double(steps), sample = circuit.sample(at:distance)
                let offset = lane.lateral(at:distance)
                vertices += [vector(sample.point+sample.right*(offset+left),y:height),
                             vector(sample.point+sample.right*(offset+right),y:height)]
                uv += [CGPoint(x:0,y:distance/3),CGPoint(x:(right-left)/3,y:distance/3)]
                if i<steps {let n=Int32(i*2);indices += [n,n+2,n+1,n+1,n+2,n+3]}
            }
            material.isDoubleSided=true
            mesh(vertices,uv,indices,material,name:name)
        }
        ribbon(from:PitLane.entry,to:PitLane.exit,left:-PitLane.halfWidth,right:PitLane.halfWidth,height:0.029,material:asphalt,name:"PitLaneAsphalt")
        for edge in [-PitLane.halfWidth+0.10,PitLane.halfWidth-0.10] {
            ribbon(from:PitLane.entry,to:PitLane.exit,left:edge-0.043,right:edge+0.043,height:0.036,material:blue,name:"PitLaneEdge")
        }
        for gate in [PitLane.limitEntry,PitLane.limitExit] {
            ribbon(from:gate-0.14,to:gate+0.14,left:-2.05,right:2.05,height:0.037,material:paint,name:"PitSpeedGate")
        }
        let bay = PitLane.boxProgress
        for side in [-1.15,1.15] {
            ribbon(from:bay-3.3,to:bay+3.3,left:side-0.06,right:side+0.06,height:0.039,material:yellow,name:"PitBoxLine")
        }
        for end in [bay-3.3,bay+3.3] {
            ribbon(from:end-0.06,to:end+0.06,left:-1.15,right:1.15,height:0.039,material:yellow,name:"PitBoxEnd")
        }
        let arrows = [PitLane.entry+23,PitLane.entry+36,PitLane.limitEntry+7,
                      PitLane.limitExit+13,PitLane.limitExit+30]
        let arrowCorners: [(Double,Double)] = [(-0.15,-1.30),(0.15,-1.30),(-0.15,0.25),(0.15,0.25),
                                             (-0.52,0.25),(0.52,0.25),(0,1.26)]
        var arrowVertices: [SCNVector3] = [], arrowUV: [CGPoint] = [], arrowIndices: [Int32] = []
        for distance in arrows {
            let base = Int32(arrowVertices.count)
            for (side,along) in arrowCorners {
                let sample = circuit.sample(at:distance+along)
                arrowVertices.append(roadVector(sample,lane.lateral(at:distance+along)+side,0.041))
                arrowUV.append(CGPoint(x:side/3,y:along/3))
            }
            arrowIndices += [base,base+2,base+1,base+1,base+2,base+3,base+4,base+6,base+5]
        }
        mesh(arrowVertices,arrowUV,arrowIndices,trackPaint(0xDCDBD0),name:"PitDirectionArrows").castsShadow = false

        let backing = material(NSColor(rgb:0x293B42),roughness:0.82)
        let speedRim = material(NSColor(rgb:0xA73833),roughness:0.65)
        let speedFace = material(NSColor(rgb:0xECE8D9),roughness:0.7)
        let speedInk = material(NSColor(rgb:0x222A2A))
        for finish in [speedRim,speedFace,speedInk] { finish.lightingModel = .constant }
        let approach = circuit.sample(at:PitLane.entry-17)
        signPanel(approach,offset:-8.4,width:2.28,height:0.90,centre:1.41,backing:backing,post:backing,
                  face:Self.signFace("PIT →",background:0xE8E9DF,foreground:0x253136,aspect:2.53))
        for (distance,title) in [(PitLane.entry+5,"PIT IN"),(PitLane.limitEntry,"60"),(bay,"BOX"),(PitLane.limitExit,"PIT OUT")] {
            let sample = circuit.sample(at:distance)
            let position = sample.point + sample.right * (lane.lateral(at:distance)-3.0)
            let sign = SCNNode(); sign.position=vector(position);sign.eulerAngles.y=CGFloat(atan2(sample.tangent.x,sample.tangent.y));root.addChildNode(sign)
            tube(SCNVector3(0,0,0),SCNVector3(0,1.19,0),0.035,backing,parent:sign)
            let face = SCNNode(); face.eulerAngles.y = .pi; sign.addChildNode(face)
            if title == "60" {
                let rim = SCNCylinder(radius:0.38,height:0.045)
                rim.materials = [speedRim]
                let disc = SCNNode(geometry:rim)
                disc.position = SCNVector3(0,1.22,0); disc.eulerAngles.x = .pi/2
                face.addChildNode(disc)
                let centre = SCNCylinder(radius:0.302,height:0.014)
                centre.materials = [speedFace]
                let insert = SCNNode(geometry:centre)
                insert.position = SCNVector3(0,1.22,0.029); insert.eulerAngles.x = .pi/2
                face.addChildNode(insert)
                label(title,size:0.27,at:SCNVector3(0,1.22,0.039),parent:face,color:speedInk)
            } else {
                box(1.43,0.55,0.07,SCNVector3(0,1.22,0),backing,parent:face,bevel:0.03)
                label(title,size:0.23,at:SCNVector3(0,1.22,0.046),parent:face,color:paint)
            }
        }
    }

    private func pits() {
        let concrete = material(NSColor.white,roughness:0.9)
        texture("Environment/concrete_wall_006_diff_2k.jpg",concrete.diffuse)
        texture("Environment/concrete_wall_006_nor_gl_2k.jpg",concrete.normal)
        concrete.normal.intensity = 0.25
        let wall = material(NSColor(rgb:0x888A85),roughness:0.9)
        let shutter = material(NSColor(rgb:0x5E6465),metal:0.3,roughness:0.65)
        let glass = material(NSColor(rgb:0x253238),metal:0.55,roughness:0.18)
        let sign = material(NSColor(rgb:0x2C3E4A),roughness:0.8)
        let apron = scanMaterial("asphalt_02",tint:0xBEB8AB)
        let trim = scanMaterial("metal_plate",tint:0xADB0AE)
        let canopy = material(NSColor(rgb:0x3F4A4D),metal:0.30,roughness:0.62)
        let lightHousing = material(NSColor(rgb:0xDDD8BC),roughness:0.64)
        strip(-35,-16.7,-0.018,apron,filter:{ (0...99).contains(self.circuit.samples[$0].distance) },name:"GarageApron")
        for i in 0..<10 {
            let s = circuit.sample(at:Double(i)*9+5)
            let n = SCNNode(); n.position = vector(s.point+s.right*(-28)); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
            box(12,4.6,8.9,SCNVector3(0,2.3,0),concrete,parent:n)
            box(12.6,0.22,9.1,SCNVector3(0,4.7,0),trim,parent:n,bevel:0.025)
            box(2.7,0.15,8.92,SCNVector3(7.08,3.67,0),canopy,parent:n,bevel:0.02)
            box(0.10,0.30,8.92,SCNVector3(8.44,3.62,0),trim,parent:n)
            for z: CGFloat in [-3.78,3.78] {
                box(2.65,0.13,0.12,SCNVector3(7.10,3.54,z),canopy,parent:n)
                box(0.20,0.18,0.18,SCNVector3(6.17,0.10,z),trim,parent:n)
            }
            box(0.12,0.06,2.6,SCNVector3(7.06,3.56,0),lightHousing,parent:n)
            box(0.08,3.2,6.8,SCNVector3(6.05,1.62,0),shutter,parent:n)
            for rib in 0..<20 { box(0.026,0.022,6.8,SCNVector3(6.098,CGFloat(rib)*0.15+0.12,0),shutter,parent:n) }
            box(0.11,0.14,6.8,SCNVector3(6.13,3.22,0),trim,parent:n)
            box(0.1,0.58,6.8,SCNVector3(6.08,4.1,0),glass,parent:n)
            for z: CGFloat in [-2.2,0,2.2] { box(0.14,0.62,0.05,SCNVector3(6.15,4.1,z),wall,parent:n) }
            for z: CGFloat in [-3.7,3.7] { tube(SCNVector3(6.22,0,z),SCNVector3(6.22,4.58,z),0.06,shutter,parent:n) }
            let board = box(0.09,0.55,1.0,SCNVector3(8.51,3.61,0),sign,parent:n)
            let facing = SCNNode(); facing.eulerAngles.y = .pi/2; board.addChildNode(facing)
            label(String(format:"%02d",i+1),size:0.34,at:SCNVector3(0,0,0.06),parent:facing,color:paint)
        }
        // Control tower, windows, service stairs and roof guard rails.
        let s = circuit.sample(at:-25), n = SCNNode(); n.position = vector(s.point+s.right*(-30)); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
        box(9,8,10,SCNVector3(0,4,0),concrete,parent:n)
        box(9.5,0.25,10.5,SCNVector3(0,8.15,0),wall,parent:n)
        box(0.05,2.0,9.3,SCNVector3(4.55,6.7,0),glass,parent:n)
        for z in stride(from:-4.5,through:4.5,by:1.5) { box(0.12,2.1,0.06,SCNVector3(4.6,6.7,z),wall,parent:n) }
        tube(SCNVector3(0,8.2,0),SCNVector3(0,12,0),0.04,shutter,parent:n)
    }
    private func vegetation(avoiding landmarkClearings: [SIMD2<Double>]) {
        var random = SeededRandom()
        random.state &+= UInt64(circuit.kind.rawValue)*7919
        let variants = (0..<4).map { i -> SCNMaterial in
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = assets.appendingPathComponent("Vegetation/tree_small_02-\(i).png")
            m.isDoubleSided = true; m.diffuse.mipFilter = .linear
            m.shaderModifiers = [.surface:"#pragma body\nif (_surface.diffuse.a < 0.40) discard_fragment();\n_surface.diffuse.a = 1.0;"]
            return m
        }
        let shrubs = (0..<4).map { i -> SCNMaterial in
            let m = variants[i].copy() as! SCNMaterial
            m.diffuse.contents = assets.appendingPathComponent("Vegetation/shrub_01-\(i).png")
            return m
        }
        var used = [SIMD2<Double>]()
        for index in 0..<2400 {
            let extent = circuit.kind == .grand ? 1200.0 : 850.0
            let p = SIMD2((random.next()-0.5)*extent,(random.next()-0.5)*extent)
            let location = circuit.nearest(to:p)
            guard location.distance>25 && location.distance<220 else { continue }
            // Leave the pit buildings clear; irregular clumps and varied silhouettes.
            guard !(p.y < -165 && p.x > -160 && p.x < 80) else { continue }
            guard !used.contains(where:{simd_distance_squared($0,p)<36}) else { continue }
            used.append(p)
            let height = 6+random.next()*9
            if !landmarkClearings.contains(where:{simd_distance_squared($0,p)<121}) {
                let plane = SCNPlane(width:CGFloat(height),height:CGFloat(height))
                plane.materials = [variants[index%4]]
                let tree = SCNNode(geometry:plane); tree.name = "TreeImpostor"
                tree.position = vector(p,y:terrainHeight(p)+height*0.47)
                let facing = SCNBillboardConstraint(); facing.freeAxes = .Y; tree.constraints = [facing]
                tree.castsShadow = false; root.addChildNode(tree)
            }
            if index%5==0 {
                let bushHeight = 1.4+random.next()*1.2
                let p2 = p+SIMD2(3,2)
                guard !landmarkClearings.contains(where:{simd_distance_squared($0,p2)<30}) else { continue }
                let bush = SCNNode(geometry:SCNPlane(width:CGFloat(bushHeight*1.5),height:CGFloat(bushHeight)))
                bush.geometry!.materials = [shrubs[(index+1)%4]]
                bush.position = vector(p2,y:terrainHeight(p2)+bushHeight*0.45)
                let f = SCNBillboardConstraint(); f.freeAxes = .Y; bush.constraints = [f]; bush.castsShadow = false
                root.addChildNode(bush)
            }
        }
    }
}

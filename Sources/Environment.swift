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
    private let dark = material(NSColor(rgb: 0x25282A), roughness: 0.9)
    private let paint = material(NSColor(rgb: 0xCFCDC1), roughness: 0.95)
    init(scene: SCNScene, circuit: Circuit, assets: URL) {
        self.scene = scene; self.circuit = circuit; self.assets = assets
        root.name = "CircuitEnvironment"
        scene.rootNode.addChildNode(root)
    }
    func build() {
        ground(); road(); barriers(); pits(); circuitDetails()
        // Posts, rails, garages and paint never move. Submit them by material
        // rather than submitting every small part separately on every frame.
        let fixed = root.flattenedClone()
        root.removeFromParentNode(); root = fixed; scene.rootNode.addChildNode(root)
        vegetation()
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
    @discardableResult private func mesh(_ v: [SCNVector3], _ uv: [CGPoint], _ indices: [Int32], _ m: SCNMaterial,
                      normals: [SCNVector3]? = nil, name: String = "") -> SCNNode {
        let ns = normals ?? v.map { _ in SCNVector3(0,1,0) }
        let g = SCNGeometry(sources: [.init(vertices:v),.init(normals:ns),.init(textureCoordinates:uv)],
                            elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [m]
        let n = SCNNode(geometry:g); n.name = name; root.addChildNode(n); return n
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
        let d = circuit.nearest(to:p).distance
        let blend = clamp((d-27)/95,0,1)
        let hills = 3 + sin(p.x*0.008+0.8)*5 + cos(p.y*0.012)*3 + sin((p.x+p.y)*0.022)*1.6
        return -0.045 + max(0,hills)*blend*blend
    }
    private func ground() {
        let grass = scanMaterial("grass_ground",tint:0xACB09C)
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
            let y = terrainHeight(p); heights.append(y); v.append(vector(p,y:y)); uv.append(CGPoint(x:p.x/5,y:p.y/5))
        }}
        for z in 0...count { for x in 0...count {
            let dx = heights[z*(count+1)+min(x+1,count)]-heights[z*(count+1)+max(x-1,0)]
            let dz = heights[min(z+1,count)*(count+1)+x]-heights[max(z-1,0)*(count+1)+x]
            let n = simd_normalize(SIMD3<Float>(Float(-dx),Float(2*step),Float(-dz)))
            ns.append(SCNVector3(n.x,n.y,n.z))
            if z<count && x<count { let i = Int32(z*(count+1)+x), s = Int32(count+1); ix += [i,i+s,i+1,i+1,i+s,i+s+1] }
        }}
        mesh(v,uv,ix,grass,normals:ns,name:"ContouredGrassTerrain")
    }
    private func strip(_ a: Double,_ b: Double,_ height: Double,_ m: SCNMaterial,
                       filter: ((Int)->Bool)? = nil, offset: ((TrackSample)->Double)? = nil, name: String = "") {
        var v = [SCNVector3](), uv = [CGPoint](), ix = [Int32]()
        for i in 0...circuit.samples.count {
            let s = circuit.samples[i%circuit.samples.count], shift = offset?(s) ?? 0
            let d = i == circuit.samples.count ? circuit.length : s.distance
            v += [vector(s.point+s.right*(a+shift),y:height),vector(s.point+s.right*(b+shift),y:height)]
            uv += [CGPoint(x:a/3,y:d/3),CGPoint(x:b/3,y:d/3)]
            if i<circuit.samples.count && (filter?(i) ?? true) {
                let n = Int32(i*2); ix += [n,n+2,n+1,n+1,n+2,n+3]
            }
        }
        m.isDoubleSided = true
        if !ix.isEmpty { mesh(v,uv,ix,m,name:name) }
    }
    private func road() {
        let asphalt = scanMaterial("asphalt_track",tint:0xB4B5B6)
        asphalt.normal.intensity = 0.22
        asphalt.shaderModifiers = [.surface: """
        #pragma body
        float2 p = _surface.diffuseTexcoord;
        float variation = sin(p.x*0.21 + sin(p.y*0.15))*sin(p.y*0.12);
        float offset = 0.54*sin(p.y*0.065)+0.24*sin(p.y*0.17);
        float groove = 1.0-smoothstep(0.25,0.93,abs(p.x-offset));
        _surface.diffuse.rgb *= 0.96+variation*0.07-groove*0.12;
        _surface.roughness = 0.92;
        """]
        strip(-6,6,0.025,asphalt,name:"DrivingSurface")
        let edge = scanMaterial("asphalt_02",tint:0x807D70)
        strip(-6.35,-6,0.016,edge); strip(6,6.35,0.016,edge)
        let wornPaint = scanMaterial("asphalt_02",tint:0xEFEBDB)
        wornPaint.diffuse.intensity = 1.4
        strip(-5.88,-5.75,0.033,wornPaint); strip(5.75,5.88,0.033,wornPaint)
        raisedKerbs(red:scanMaterial("asphalt_02",tint:0x9B3C34),white:wornPaint)
        let rubber = material(NSColor(rgb:0x272624),roughness:0.96)
        rubber.transparency = 0.08; rubber.writesToDepthBuffer = false
        // Short braking streaks, grid boxes and a measured start line.
        for target in circuit.cornerDistances {
            for lane in [-0.9,0.9] {
                strip(lane-0.10,lane+0.10,0.038,rubber,filter: { let d = self.circuit.samples[$0].distance; return d>target-65 && d<target-15 })
            }
            for distance in [100.0,50.0] {
                let s = circuit.sample(at:target-distance)
                let n = SCNNode(); n.position = vector(s.point+s.right*9.4); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)+Double.pi); root.addChildNode(n)
                box(1.1,1.25,0.07,SCNVector3(0,1.25,0),paint,parent:n)
                tube(SCNVector3(-0.36,0,0),SCNVector3(-0.36,1.8,0),0.025,dark,parent:n)
                tube(SCNVector3(0.36,0,0),SCNVector3(0.36,1.8,0),0.025,dark,parent:n)
                label(String(Int(distance)),size:0.48,at:SCNVector3(0,1.25,0.04),parent:n,color:dark)
            }
        }
        for distance in stride(from:30.0,to:110,by:12) {
            let s = circuit.sample(at:distance)
            for side in [-1.0,1.0] {
                let n = SCNNode(); n.position = vector(s.point+s.right*3*side); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
                box(2.3,0.004,0.10,SCNVector3(0,0.04,0),wornPaint,parent:n)
                box(0.10,0.004,1.5,SCNVector3(-1.1,0.04,-0.7),wornPaint,parent:n)
            }
        }
        let s = circuit.sample(at:0), n = SCNNode(); n.position = vector(s.point); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
        box(11.5,0.004,0.3,SCNVector3(0,0.04,0),wornPaint,parent:n)
        let galvanized = material(NSColor(rgb:0x8A9295),metal:0.65,roughness:0.5)
        for x: CGFloat in [-9,9] { tube(SCNVector3(x,0,0),SCNVector3(x,6.1,0),0.14,galvanized,parent:n) }
        box(18.4,0.65,0.8,SCNVector3(0,6,0),galvanized,parent:n)
        box(5.5,0.7,0.04,SCNVector3(0,6,-0.43),dark,parent:n)
        let front = SCNNode(); front.eulerAngles.y = .pi; n.addChildNode(front)
        label(circuit.name,size:0.38,at:SCNVector3(0,5.82,0.46),parent:front,color:paint)
        for i in 0..<5 { box(0.26,0.48,0.18,SCNVector3(CGFloat(i-2)*0.34,5.35,0),dark,parent:n,bevel:0.05) }
    }
    private func raisedKerbs(red: SCNMaterial, white: SCNMaterial) {
        let edges = [0.0,0.12,0.70,0.85]
        let count = Int(ceil(circuit.length/0.25))
        for side in [-1.0,1.0] { for stripe in 0...1 {
            var vertices:[SCNVector3]=[],uv:[CGPoint]=[],normals:[SCNVector3]=[],indices:[Int32]=[]
            for i in 0..<count {
                let d=Double(i)*circuit.length/Double(count), next=Double(i+1)*circuit.length/Double(count)
                guard circuit.hasKerb(at:(d+next)/2),Int(d/2.5)%2==stripe else { continue }
                let start=Int32(vertices.count)
                for distance in [d,next] {
                    let sample=circuit.sample(at:distance)
                    for edge in edges {
                        let h=kerbElevation(progress:distance,distanceFromEdge:edge)
                        vertices.append(vector(sample.point+sample.right*side*(6+edge),y:0.025+h))
                        uv.append(CGPoint(x:edge/3,y:distance/3))
                        let across=(kerbElevation(progress:distance,distanceFromEdge:edge+0.001)-kerbElevation(progress:distance,distanceFromEdge:edge-0.001))/0.002
                        let along=(kerbElevation(progress:distance+0.001,distanceFromEdge:edge)-kerbElevation(progress:distance-0.001,distanceFromEdge:edge))/0.002
                        let gradient=sample.right*side*across+sample.tangent*along
                        let n=simd_normalize(SIMD3<Float>(Float(-gradient.x),1,Float(-gradient.y)))
                        normals.append(SCNVector3(n))
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
            let stand=SCNNode(); stand.name="SpectatorStand";stand.position=vector(centre);stand.eulerAngles.y=CGFloat(atan2(sample.tangent.x,sample.tangent.y));root.addChildNode(stand)
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
                let n=SCNNode();n.position=vector(point);n.eulerAngles.y=CGFloat(atan2(s.tangent.x,s.tangent.y));root.addChildNode(n)
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

    private func barriers() {
        let metal = material(NSColor(rgb:0xA2A4A1),metal:0.7,roughness:0.64)
        texture("Environment/metal_plate_diff_2k.jpg",metal.diffuse)
        metal.multiply.contents = NSColor(rgb:0xC4C9C7)
        let profile: [(Double,Double)] = [(0.29,0.08),(0.35,-0.08),(0.43,0.08),(0.50,-0.08),(0.58,0.08)]
        for side in [-1.0,1.0] {
            var v = [SCNVector3](),uv = [CGPoint](),ix = [Int32](),normals = [SCNVector3]()
            for i in 0...circuit.samples.count {
                let s = circuit.samples[i%circuit.samples.count]
                for (h,dx) in profile {
                    v.append(vector(s.point+s.right*(15.8+dx)*side,y:h))
                    uv.append(CGPoint(x:s.distance/4,y:h*2))
                    normals.append(SCNVector3(-Float(s.right.x*side),0,-Float(s.right.y*side)))
                }
                if i<circuit.samples.count { for j in 0..<4 { let k=Int32(i*5+j); ix += [k,k+5,k+1,k+1,k+5,k+6] } }
            }
            metal.isDoubleSided = true; mesh(v,uv,ix,metal,normals:normals,name:"CorrugatedArmco")
        }
        // Catch-fence uses a cutout wire mesh, not large solid panels.
        let chain = SCNMaterial(); chain.lightingModel = .physicallyBased
        chain.diffuse.contents = wireTexture(); chain.isDoubleSided = true
        chain.roughness.contents = 0.8; chain.diffuse.wrapS = .repeat; chain.diffuse.wrapT = .repeat
        chain.shaderModifiers = [.surface:"#pragma body\nif (_surface.diffuse.a < 0.35) discard_fragment();\n_surface.diffuse.a = 1.0;"]
        let steel = material(NSColor(rgb:0x626765),metal:0.6,roughness:0.65)
        var v = [SCNVector3](), uv = [CGPoint](), ix = [Int32](), ns = [SCNVector3]()
        for i in stride(from:0,to:circuit.samples.count,by:3) {
            let s = circuit.samples[i], next = circuit.samples[(i+3)%circuit.samples.count]
            for side in [-1.0,1.0] {
                let a = s.point+s.right*17*side, b = next.point+next.right*17*side
                tube(vector(a),vector(a,y:3.0),0.033,steel)
                tube(vector(s.point+s.right*15.95*side),vector(s.point+s.right*15.95*side,y:0.72),0.04,steel)
                let k = Int32(v.count); v += [vector(a,y:0.2),vector(b,y:0.2),vector(a,y:2.8),vector(b,y:2.8)]
                let u = simd_distance(a,b)/0.28
                uv += [CGPoint(x:0,y:0),CGPoint(x:u,y:0),CGPoint(x:0,y:9.3),CGPoint(x:u,y:9.3)]
                ix += [k,k+2,k+1,k+1,k+2,k+3]
                ns += Array(repeating:SCNVector3(Float(s.right.x),0,Float(s.right.y)),count:4)
                tube(vector(a,y:2.8),vector(b,y:2.8),0.016,steel)
            }
        }
        mesh(v,uv,ix,chain,normals:ns,name:"CatchFencing")
    }
    private func wireTexture() -> NSImage {
        let image = NSImage(size:NSSize(width:128,height:128)); image.lockFocus()
        NSColor.clear.setFill(); NSRect(x:0,y:0,width:128,height:128).fill()
        let path = NSBezierPath(); path.lineWidth = 2.0
        path.move(to:.init(x:0,y:0)); path.line(to:.init(x:128,y:128))
        path.move(to:.init(x:0,y:128)); path.line(to:.init(x:128,y:0))
        NSColor(rgb:0x707672).setStroke(); path.stroke(); image.unlockFocus(); return image
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
        let apron = scanMaterial("asphalt_02",tint:0xAAA8A1)
        for i in 0..<10 {
            let s = circuit.sample(at:Double(i)*9+5)
            let n = SCNNode(); n.position = vector(s.point+s.right*(-28)); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
            box(17,0.025,9,SCNVector3(4,-0.015,0),apron,parent:n)
            box(12,4.6,8.9,SCNVector3(0,2.3,0),concrete,parent:n)
            box(12.6,0.22,9.1,SCNVector3(0,4.7,0),wall,parent:n)
            box(0.08,3.2,6.8,SCNVector3(6.05,1.62,0),shutter,parent:n)
            for rib in 0..<20 { box(0.025,0.022,6.8,SCNVector3(6.10,CGFloat(rib)*0.15+0.12,0),wall,parent:n) }
            box(0.1,0.58,6.8,SCNVector3(6.08,4.1,0),glass,parent:n)
            for z: CGFloat in [-2.2,0,2.2] { box(0.14,0.62,0.05,SCNVector3(6.15,4.1,z),wall,parent:n) }
            for z: CGFloat in [-3.7,3.7] { tube(SCNVector3(6.22,0,z),SCNVector3(6.22,4.58,z),0.06,shutter,parent:n) }
            let board = box(0.09,0.55,1.0,SCNVector3(6.22,3.55,0),sign,parent:n)
            let facing = SCNNode(); facing.eulerAngles.y = .pi/2; board.addChildNode(facing)
            label(String(format:"%02d",i+1),size:0.34,at:SCNVector3(0,-0.19,0.06),parent:facing,color:paint)
        }
        // Control tower, windows, service stairs and roof guard rails.
        let s = circuit.sample(at:-25), n = SCNNode(); n.position = vector(s.point+s.right*(-30)); n.eulerAngles.y = CGFloat(atan2(s.tangent.x,s.tangent.y)); root.addChildNode(n)
        box(9,8,10,SCNVector3(0,4,0),concrete,parent:n)
        box(9.5,0.25,10.5,SCNVector3(0,8.15,0),wall,parent:n)
        box(0.05,2.0,9.3,SCNVector3(4.55,6.7,0),glass,parent:n)
        for z in stride(from:-4.5,through:4.5,by:1.5) { box(0.12,2.1,0.06,SCNVector3(4.6,6.7,z),wall,parent:n) }
        tube(SCNVector3(0,8.2,0),SCNVector3(0,12,0),0.04,shutter,parent:n)
    }
    private func vegetation() {
        var random = SeededRandom()
        random.state &+= UInt64(circuit.kind.rawValue)*7919
        let variants = (0..<4).map { i -> SCNMaterial in
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = assets.appendingPathComponent("Vegetation/tree_small_02-\(i).png")
            m.isDoubleSided = true; m.diffuse.mipFilter = .linear
            m.shaderModifiers = [.surface:"#pragma body\nif (_surface.diffuse.a < 0.40) discard_fragment();\n_surface.diffuse.a = 1.0;"]
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
            let plane = SCNPlane(width:CGFloat(height),height:CGFloat(height))
            plane.materials = [variants[index%4]]
            let tree = SCNNode(geometry:plane); tree.name = "TreeImpostor"
            tree.position = vector(p,y:terrainHeight(p)+height*0.47)
            let facing = SCNBillboardConstraint(); facing.freeAxes = .Y; tree.constraints = [facing]
            tree.castsShadow = false; root.addChildNode(tree)
            if index%5==0 {
                let bushHeight = 3+random.next()*2
                let bush = SCNNode(geometry:SCNPlane(width:CGFloat(bushHeight*1.5),height:CGFloat(bushHeight)))
                bush.geometry!.materials = [variants[(index+1)%4]]
                let p2 = p+SIMD2(3,2)
                bush.position = vector(p2,y:terrainHeight(p2)+bushHeight*0.45)
                let f = SCNBillboardConstraint(); f.freeAxes = .Y; bush.constraints = [f]; bush.castsShadow = false
                root.addChildNode(bush)
            }
        }
    }
}

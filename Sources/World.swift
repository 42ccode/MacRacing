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

    static func refreshOrder(focused: Self?) -> [Self] {
        switch focused {
        case .left: return [.left,.centre,.left,.right,.left,.centre]
        case .right: return [.right,.centre,.right,.left,.right,.centre]
        default: return [.centre,.left,.centre,.right]
        }
    }
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

struct LessonTrackMarker: Equatable {
    enum Kind { case brake, turn, accelerate, finish }
    let progress: Double
    let kind: Kind
}

struct TyreSpraySample {
    let position: SIMD3<Float>
    let velocity: SIMD3<Float>
    let strength: Double

    init(vehicle: Vehicle,index: Int,contact: SIMD2<Double>,elevation: Double) {
        let wheel = vehicle.wheels[index]
        let angle = vehicle.heading + vehicle.wheelSteer(index)
        let forward = SIMD2(sin(angle),cos(angle))
        let outside = SIMD2(forward.y,-forward.x) * (index.isMultiple(of:2) ? -1.0 : 1.0)
        let arm = contact-vehicle.centreOfGravityPosition
        let motion = vehicle.velocity+vehicle.yawRate*SIMD2(arm.y,-arm.x)
        let along = simd_dot(motion,forward)
        let direction = along < 0 ? -1.0 : 1.0
        let speed = min(55,abs(along))
        let tread = min(speed,wheel.rollingContactSpeed)
        let drift = clamp(simd_dot(motion,outside)*0.13,-2,2)
        let leading = along < 0 ? index >= 2 : index < 2
        strength = clamp(wheel.spray,0,1)*(leading ? 0.92 : 1)
        // The leading axle pushes a low bow wave aside. The trailing
        // tyre throws water higher and away from the direction of travel.
        let throwAlong = leading ? 0.80+0.062*speed+0.027*tread : -0.69-0.049*speed-0.046*tread
        let throwOutside = 0.64+0.047*speed+0.51*strength+drift
        let horizontal = forward*(direction*throwAlong)+outside*throwOutside
        let lift = leading ? 0.49+0.013*speed+0.32*strength : 0.81+0.019*speed+0.45*strength
        let patch = contact+outside*0.045+forward*(leading ? 0.055*direction : -0.07*direction)
        position = SIMD3(Float(patch.x),Float(elevation+wheel.surfaceHeight+0.095),Float(patch.y))
        velocity = SIMD3(Float(horizontal.x),Float(lift),Float(horizontal.y))
    }
}

// Birth callbacks run on the rendering thread. Read one coherent copy of the
// two patch samples per batch and leave the SceneKit particle buffers owned by it.
private final class TyreSprayBirth {
    private struct Patches {
        let front: TyreSpraySample
        let rear: TyreSpraySample
        let origin: SIMD3<Float>
        let frontShare: Double
    }
    private let lock = NSLock()
    private var patches: Patches?
    private var seed: UInt64

    init(index: Int) { seed = 0xD97B0475C2193951 &+ UInt64(index)*7829 }

    func update(front: TyreSpraySample,rear: TyreSpraySample,origin: SIMD3<Float>,frontShare: Double) {
        lock.lock()
        patches = Patches(front:front,rear:rear,origin:origin,frontShare:frontShare)
        lock.unlock()
    }

    func emit(_ data: UnsafeMutablePointer<UnsafeMutableRawPointer>,_ stride: UnsafeMutablePointer<Int>,count: Int) {
        lock.lock()
        let patches = self.patches
        var scatter = SeededRandom(state:seed)
        seed &+= 0x9E3779B97F4A7C15
        lock.unlock()
        guard let patches else { return }
        for index in 0..<count {
            let patch = scatter.next() < patches.frontShare ? patches.front : patches.rear
            let offset = patch.position-patches.origin
            let p = data[0].advanced(by:stride[0]*index).assumingMemoryBound(to:Float.self)
            p[0] += offset.x+Float((scatter.next()-0.5)*0.17)
            p[1] += offset.y+Float(scatter.next()*0.044)
            p[2] += offset.z+Float((scatter.next()-0.5)*0.20)
            let speed = Float(0.70+scatter.next()*0.62)
            let v = data[1].advanced(by:stride[1]*index).assumingMemoryBound(to:Float.self)
            v[0] = patch.velocity.x*speed+Float(scatter.next()-0.5)*1.2
            v[1] = patch.velocity.y*Float(0.67+scatter.next()*0.67)
            v[2] = patch.velocity.z*speed+Float(scatter.next()-0.5)*1.1
        }
    }
}

final class RacingWorld {
    static let rivalPaintColors: [UInt32] = [0x4692C6,0xDF9F39,0x488E6B]
    let scene = SCNScene()
    let camera = SCNNode()
    private let tracksideCamera = SCNNode()
    private struct ReplayMount {
        let start: Double
        let eye: SIMD3<Float>
        let frameHeight: Double
    }
    private lazy var replayMounts = Self.replayCoverage(for:circuit.kind).map { spec -> ReplayMount in
        let sample = circuit.sample(at:spec.station)
        let bank = circuit.roadProfile(at:sample.distance,lateral:spec.offset).height
        let point = sample.point+sample.right*spec.offset
        let eye = SIMD3(Float(point.x),Float(bank+spec.height),Float(point.y))
        return ReplayMount(start:spec.start,eye:eye,frameHeight:spec.frameHeight)
    }
    private var replayMountIndex: Int?
    private var replayAim = SIMD3<Float>.zero
    private var replayPreviousPosition = SIMD2<Double>.zero
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
        let birth: TyreSprayBirth
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
    private var glanceAngle = 0.0
    var cockpitFOV: CGFloat = 62
    var seatHeight: Double = 1.00
    var sideLook = 0.0
    private(set) var vehicleKind: VehicleKind
    private var contactShadows: [SCNNode] = []
    private var steeringAxis = SIMD3<Float>(0,1,0)
    private var steeringCentre = SIMD3<Float>.zero

    private func assetURL(_ path: String) -> URL? {
        let url = assetsDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private let circuit: Circuit
    private var originalWetRoad: SCNGeometry?
    private var initialWaterDepths: [Double] = []
    private var displayedWetColors: [SIMD4<Float>] = []
    private var dryingDisplayProgress = 1.0
    private static let dryingDisplayDuration = 0.45
    let racingLine: RacingLine
    private let racingLineNode = SCNNode()
    private let lessonMarkersNode = SCNNode()
    private var lessonMarkers: [LessonTrackMarker] = []
    private var lessonStopZone: ClosedRange<Double>?
    private var startLenses: [SCNMaterial] = []
    private var illuminatedStartLenses = 0
    private var lineClock = 1.0
    private var lineDashes: [Int:[SCNVector3]] = [:]
    private var lineWindowStart: Int?
    private var lineWindowCues: [Int] = []
    private lazy var lineMaterials: [SCNMaterial] = [0x77B66F,0xE3BD58,0xD95750].map { rgb in
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(rgb:UInt32(rgb),alpha:0.60)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        return material
    }
    var showRacingLine = true {
        didSet {racingLineNode.isHidden = !showRacingLine;lineClock=1}
    }
    init(circuit: Circuit, assetsDirectory: URL? = nil, vehicleKind: VehicleKind = .centenario) {
        self.circuit = circuit
        self.vehicleKind = vehicleKind
        self.racingLine = RacingLine(circuit:circuit)
        self.assetsDirectory = assetsDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("Assets")
        let daylight = "Environment/Daylight/kloofendal_48d_partly_cloudy_4k.hdr"
        let overcast = "Environment/Overcast/kloofendal_overcast_puresky_2k.hdr"
        let skyPath = circuit.condition == .wet ? overcast : daylight
        if let sky = assetURL(skyPath) ?? assetURL(daylight) {
            scene.background.contents = sky
            scene.lightingEnvironment.contents = sky
        }
        scene.fogColor = NSColor(rgb: 0xB6C3CE)
        scene.fogStartDistance = 380
        scene.fogEndDistance = 1700
        scene.lightingEnvironment.intensity = 0.85
        if circuit.condition == .wet {
            scene.lightingEnvironment.intensity = 0.82
            scene.fogColor = NSColor(rgb:0xA5AEB5)
            scene.fogStartDistance = 155
            scene.fogEndDistance = 910
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
        sun.light!.intensity = circuit.condition == .wet ? 230 : 900
        sun.light!.castsShadow = true
        sun.light!.shadowMode = .deferred
        sun.light!.shadowColor = NSColor.black.withAlphaComponent(circuit.condition == .wet ? 0.27 : 0.50)
        sun.light!.shadowMapSize = CGSize(width: 4096, height: 4096)
        sun.light!.shadowSampleCount = 8
        if circuit.condition == .wet { sun.light!.shadowRadius = 5 }
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

        startLenses = TrackEnvironment(scene:scene,circuit:circuit,assets:self.assetsDirectory).build()
        rebuildCarVisuals()
        racingLineNode.name="PracticeRacingLine";scene.rootNode.addChildNode(racingLineNode)
        racingLineNode.categoryBitMask = Self.hiddenFromMirror
        lessonMarkersNode.name = "LessonTrackMarkers"
        scene.rootNode.addChildNode(lessonMarkersNode)

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
        tracksideCamera.name = "TracksideReplayCamera"
        if let replayLens = camera.camera?.copy() as? SCNCamera {
            replayLens.zNear = 0.28
            replayLens.zFar = 1250
            replayLens.projectionDirection = .vertical
            tracksideCamera.camera = replayLens
        }
        scene.rootNode.addChildNode(tracksideCamera)

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
        tracksideCamera.camera?.screenSpaceAmbientOcclusionIntensity = view.screenSpaceAmbientOcclusionIntensity
    }

    private struct ReplayCoverage {
        let start: Double
        let station: Double
        let offset: Double
        let height: Double
        let frameHeight: Double

        init(_ start: Double,_ station: Double,_ offset: Double,_ height: Double,_ frameHeight: Double) {
            self.start = start
            self.station = station
            self.offset = offset
            self.height = height
            self.frameHeight = frameHeight
        }
    }

    /// Cut gate, fixed mount station, lateral offset, height and framed
    /// vertical extent in metres. Each layout has its own coverage set.
    private static func replayCoverage(for kind: CircuitKind) -> [ReplayCoverage] {
        switch kind {
        case .north:
            // Main straight, double bend, back section and final approach.
            return [
                .init(0,99,18.9,5.9,13), .init(138,232,-10.8,2.45,10),
                .init(270,345,-13.7,3.4,10.4), .init(409,502,18.7,5.7,13),
                .init(534,582,10.5,2.3,9.5), .init(648,719,-10.5,3.4,11),
                .init(782,854,18.7,5.9,13.5), .init(920,976,10.6,2.6,9.6),
                .init(1038,1124,-19.0,6.6,13), .init(1180,1280,10.5,2.7,10.6),
                .init(1324,1393,-12.8,3.3,11)
            ]
        case .sprint:
            return [
                .init(0,102,18.8,5.7,13), .init(140,230,-11.4,2.6,11),
                .init(287,364,-10.5,2.2,9.8), .init(418,488,10.6,4.55,11.5),
                .init(534,586,-11,3.15,10), .init(663,758,18.8,5.6,15),
                .init(812,901,-11.8,2.8,11), .init(953,1046,-18.9,6.3,12.2),
                .init(1095,1163,-12.5,5.05,10.6)
            ]
        case .technical:
            // Shorter coverage around the two tightest hairpins.
            return [
                .init(0,102,18.7,5.7,13.4), .init(145,243,-12.1,3.0,11),
                .init(293,375,-11.1,2.3,9.8), .init(425,530,10.4,2.8,9.5),
                .init(564,657,-13.2,3.2,11), .init(697,791,-18.8,5.7,13.8),
                .init(840,935,18.8,5.8,13.5), .init(994,1067,-11.8,3.0,11.8),
                .init(1107,1192,12.6,3.5,10.0), .init(1235,1318,-10.5,3.4,11.4),
                .init(1371,1448,-12.2,5.3,10.6), .init(1501,1557,18.8,5.5,13)
            ]
        case .grand:
            return [
                .init(0,106,19.1,6.1,14), .init(155,266,18.6,5.9,13.7),
                .init(319,422,-11.7,2.7,10.4), .init(465,551,18.8,5.5,14.0),
                .init(605,694,-12.0,3.0,10.5), .init(749,835,-18.8,5.8,14),
                .init(900,1000,18.8,6.0,13.5), .init(1050,1152,-11.0,3.3,10.5),
                .init(1200,1272,11,2.8,10.2), .init(1328,1415,-12.3,6.0,11.5),
                .init(1472,1571,18.8,6.0,14), .init(1624,1719,-10.4,2.7,11),
                .init(1767,1859,-18.8,5.6,14), .init(1920,2019,-12.0,2.7,10.3),
                .init(2071,2168,18.8,5.9,13), .init(2226,2267,10.8,3.4,10.8)
            ]
        case .ridge:
            // Elevated mounts for the crest, descent and lower high-speed bowl.
            return [
                .init(0,104,19,6.0,14.2), .init(157,273,-11.6,2.9,10.8),
                .init(329,431,18.9,6.7,14), .init(477,562,-11.8,3.5,10.6),
                .init(626,718,-18.9,6.8,14.8), .init(774,861,18.9,7.4,13.5),
                .init(920,1015,-12.0,4.9,11.7), .init(1069,1168,18.7,7.4,14.0),
                .init(1218,1307,-19,6.4,14.5), .init(1371,1471,-11.7,3.6,10.7),
                .init(1528,1618,18.7,6.0,13.9), .init(1672,1768,-12.4,3.1,10.2),
                .init(1822,1929,18.9,5.9,14.3), .init(1985,2088,-19.1,5.8,12.4),
                .init(2139,2234,-11.5,5.5,10.4), .init(2292,2358,11.3,3.1,11.0)
            ]
        case .valley:
            return [
                .init(0,104,19,6.0,14), .init(145,248,-12.0,2.7,10.5),
                .init(288,365,-11.6,3.0,11), .init(422,502,-18.8,7.1,15),
                .init(548,622,12.0,3.6,10.5), .init(665,728,18.8,6.9,13.5),
                .init(790,866,-11.1,2.7,10.5), .init(911,972,-13,2.8,11.0),
                .init(1034,1131,18.9,7.0,14), .init(1186,1280,-12.0,3.3,10.5),
                .init(1337,1422,-18.8,5.7,13), .init(1479,1553,11.2,3.4,11),
                .init(1608,1695,-10.8,3.45,11.5), .init(1747,1795,18.9,5.7,13)
            ]
        }
    }

    /// Fixed pads and a panning lens exist only for replay. The caller
    /// explicitly resets after seeking so a frozen pose can't switch shots.
    func tracksideReplayCamera(for vehicle: Vehicle,dt: Double,reset: Bool = false,opponents: [Vehicle] = []) -> SCNNode {
        let position = vehicle.position
        guard position.x.isFinite,position.y.isFinite else { return tracksideCamera }
        let previous = replayMountIndex
        if !reset, previous != nil {
            guard dt.isFinite,dt > 0,
                  simd_distance(position,replayPreviousPosition) < max(22,vehicle.speed*min(dt,0.10)*2+9) else {
                return tracksideCamera
            }
        }
        let location = circuit.nearest(to:position)
        let progress = location.progress == circuit.length ? 0 : location.progress
        let selected = replayMounts.lastIndex { $0.start <= progress } ?? 0
        let index: Int
        if !reset, let previous, selected != previous {
            let start = replayMounts[previous].start
            let end = previous+1 < replayMounts.count ? replayMounts[previous+1].start : circuit.length
            let fromStart = progress >= start ? progress-start : progress-start+circuit.length
            let margin = clamp(vehicle.speed*0.14,5,10)
            index = fromStart <= end-start+margin || fromStart >= circuit.length-margin ? previous : selected
        } else {
            index = selected
        }
        let mount = replayMounts[index]
        let cut = reset || previous != index
        if cut { tracksideCamera.simdPosition = mount.eye }
        replayMountIndex = index
        replayPreviousPosition = position

        let carHeight = roadElevation(of:vehicle)+0.75+vehicle.modelHeave*0.45
        let subject = SIMD3(Float(position.x),Float(carHeight),Float(position.y))
        let framing = replayFraming(mount:mount,subject:subject,vehicle:vehicle,progress:progress,opponents:opponents)
        let step = clamp(dt.isFinite ? dt : 0,0,0.12)
        replayAim = cut ? framing.target : replayAim+(framing.target-replayAim)*Float(1-exp(-step*15))
        // Keep the world up vector stable even if an off-track car passes
        // directly below one of the lower mounts.
        let horizontal = simd_distance(SIMD2(replayAim.x,replayAim.z),SIMD2(mount.eye.x,mount.eye.z))
        let aim = horizontal > 0.65 ? replayAim : replayAim+SIMD3(Float(location.tangent.x),0,Float(location.tangent.y))
        tracksideCamera.simdLook(at:aim,up:SIMD3(0,1,0),localFront:SIMD3(0,0,-1))
        if let lens = tracksideCamera.camera {
            let fov = CGFloat(framing.fieldOfView)
            let slew = fov > lens.fieldOfView ? 13.0 : 8.0
            lens.fieldOfView = cut ? fov : lens.fieldOfView+(fov-lens.fieldOfView)*CGFloat(1-exp(-step*slew))
        }
        return tracksideCamera
    }

    private func replayFraming(mount: ReplayMount,subject: SIMD3<Float>,vehicle: Vehicle,progress: Double,
                               opponents: [Vehicle]) -> (target: SIMD3<Float>,fieldOfView: Double) {
        let offset = subject-mount.eye
        let distance = max(1,Double(simd_length(offset)))
        let shotField = 2*atan(mount.frameHeight/(2*distance))
        let planar = SIMD2(Double(offset.x),Double(offset.z))
        let depth = simd_length(planar)
        let lead = vehicle.velocity*min(0.16,0.28*mount.frameHeight/max(vehicle.speed,1))
        guard depth > 0.65,!opponents.isEmpty else {
            return (subject+SIMD3(Float(lead.x),0,Float(lead.y)),clamp(shotField*180 / .pi,8,57))
        }

        let along = planar/depth
        let across = SIMD2(along.y,-along.x)
        let pad = atan(3.1/depth)
        var low = -pad
        var high = pad
        var group = 0.0
        for rival in opponents {
            let separation = simd_distance(rival.position,vehicle.position)
            guard separation < 30 else { continue }
            let rivalProgress = circuit.nearest(to:rival.position).progress
            let gap = abs(rivalProgress-progress)
            let arc = min(gap,circuit.length-gap)
            let blend = clamp(min((30-separation)/8,(34-arc)/10),0,1)
            let weight = blend*blend*(3-2*blend)
            guard weight > 0 else { continue }
            let away = rival.position-SIMD2(Double(mount.eye.x),Double(mount.eye.z))
            let bearing = atan2(simd_dot(away,across),simd_dot(away,along))
            guard abs(bearing) < 1.2 else { continue }
            let margin = atan(3.1/max(1,simd_length(away)))
            low = min(low,-pad+(bearing-margin+pad)*weight)
            high = max(high,pad+(bearing+margin-pad)*weight)
            group = max(group,weight)
        }
        let pan = (high+low)*0.5
        let shift = across*(tan(pan)*depth)+lead*(1-0.82*group)
        // The 1.32 aspect keeps the pack safely framed in the minimum-size game window.
        let packField = min(1.15,(high-low)*0.5+0.045*group)
        let field = group > 0 ? max(shotField,2*atan(tan(packField)/1.32)) : shotField
        return (subject+SIMD3(Float(shift.x),0,Float(shift.y)),clamp(field*180 / .pi,8,57))
    }

    func setStartLights(countdown: Int?) {
        let illuminated = countdown.map { (1...3).contains($0) ? 4-$0 : 0 } ?? 0
        guard illuminated != illuminatedStartLenses else { return }
        illuminatedStartLenses = illuminated
        for (index,lens) in startLenses.enumerated() {
            lens.diffuse.contents = NSColor(rgb:index % 3 < illuminated ? 0xFF352D : 0x412327)
        }
    }

    func displayTrackDrying(_ condition: TrackDrying?, transitioning: Bool = false) {
        guard circuit.condition == .wet,
              let road = scene.rootNode.childNode(withName:"WetDrivingSurface",recursively:false) else { return }
        guard let condition, condition.elapsed > 0 else {
            if let originalWetRoad, road.geometry !== originalWetRoad { road.geometry = originalWetRoad }
            displayedWetColors.removeAll(keepingCapacity:true)
            dryingDisplayProgress = 1
            updateDryingDisplayWeight()
            return
        }
        let across = Int(circuit.width)+1
        let along = Int(ceil(circuit.length/3))
        if originalWetRoad == nil {
            originalWetRoad = road.geometry
            initialWaterDepths = (0...along).flatMap { row in
                let progress = Double(row)*circuit.length/Double(along)
                return (0..<across).map { column in
                    circuit.waterDepth(at:progress,lateral:Double(column)-circuit.width/2)
                }
            }
        }
        guard let originalWetRoad else { return }
        let weight = dryingDisplayWeight
        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(initialWaterDepths.count)
        var needsTransition = false
        for (index,initial) in initialWaterDepths.enumerated() {
            let progress = Double(index/across)*circuit.length/Double(along)
            let lateral = Double(index%across)-circuit.width/2
            let wet = Float(clamp((condition.depth(from:initial,at:progress,lateral:lateral)-0.25)/0.80,0,1))
            var previous = wet
            if transitioning {
                if displayedWetColors.isEmpty {
                    previous = Float(clamp((initial-0.25)/0.80,0,1))
                } else {
                    let displayed = displayedWetColors[index]
                    previous = displayed.x+(displayed.y-displayed.x)*weight
                }
                needsTransition = needsTransition || previous != wet
            }
            colors.append(SIMD4(previous,wet,wet,1))
        }
        let data = colors.withUnsafeBufferPointer { Data(buffer:$0) }
        let color = SCNGeometrySource(data:data,semantic:.color,vectorCount:colors.count,
            usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let geometry = SCNGeometry(sources:originalWetRoad.sources.filter { $0.semantic != .color }+[color],
                                   elements:originalWetRoad.elements)
        geometry.materials = originalWetRoad.materials
        displayedWetColors = colors
        dryingDisplayProgress = needsTransition ? 0 : 1
        updateDryingDisplayWeight()
        road.geometry = geometry
    }

    func advanceTrackDryingDisplay(_ dt: Double) {
        guard dryingDisplayProgress < 1, dt.isFinite, dt > 0 else { return }
        dryingDisplayProgress = min(1,dryingDisplayProgress+dt/Self.dryingDisplayDuration)
        updateDryingDisplayWeight()
    }

    private var dryingDisplayWeight: Float {
        let t = Float(dryingDisplayProgress)
        return t*t*(3-2*t)
    }

    private func updateDryingDisplayWeight() {
        originalWetRoad?.firstMaterial?.setValue(NSNumber(value:dryingDisplayWeight),forKey:"dryingBlend")
    }

    func setLessonMarkers(_ markers: [LessonTrackMarker], stopZone: ClosedRange<Double>? = nil) {
        guard markers != lessonMarkers || stopZone != lessonStopZone else { return }
        lessonMarkers = markers
        lessonStopZone = stopZone
        lessonMarkersNode.childNodes.forEach { $0.removeFromParentNode() }
        let edge = circuit.width/2-0.7
        let stopsAtEnd = stopZone.map {
            $0.lowerBound.isFinite && $0.upperBound.isFinite &&
                $0.upperBound > $0.lowerBound && $0.upperBound-$0.lowerBound <= circuit.length
        } ?? false
        if stopsAtEnd, let zone = stopZone {
            paintLessonSurface([(zone,-edge...edge)],color:0xEAB957,alpha:0.26,height:0.044,name:"LessonStopArea")
            let edgeLines = [(zone,(-edge)...(-edge+0.12)),(zone,(edge-0.12)...edge)]
            let caps = [zone.lowerBound,zone.upperBound].map { (($0-0.09)...($0+0.09),-edge...edge) }
            paintLessonSurface(edgeLines+caps,color:0xF7D772,alpha:0.86,height:0.050,name:"LessonStopBoundary")
        }
        for marker in markers where marker.progress.isFinite {
            placeLessonCones(marker)
            if marker.kind == .finish {
                let rows: [ClosedRange<Double>] = [
                    (marker.progress-0.32)...marker.progress,marker.progress...(marker.progress+0.32)
                ]
                let tile = edge/7
                let checks = rows.enumerated().flatMap { row,progress in
                    (0..<14).compactMap { column -> (ClosedRange<Double>,ClosedRange<Double>)? in
                        guard (row+column).isMultiple(of:2) else { return nil }
                        let left = -edge+Double(column)*tile
                        return (progress,left...(left+tile))
                    }
                }
                paintLessonSurface(checks,color:0xEAF3F0,alpha:0.86,height:0.050,name:"LessonFinishStripe")
            }
        }
    }

    private func placeLessonCones(_ marker: LessonTrackMarker) {
        let palette: (word: String,color: UInt32)
        switch marker.kind {
        case .brake: palette = ("BRAKE",0xFF805B)
        case .turn: palette = ("TURN",0xF0BF59)
        case .accelerate: palette = ("POWER",0x69CCA7)
        case .finish: palette = ("FINISH",0xEAF3F0)
        }
        let station = circuit.sample(at:marker.progress)
        let pit = circuit.pitLane
        let local = pit.localProgress(station.distance)
        let stakes = material(NSColor(rgb:0x283436),roughness:0.84)
        let coneColor = material(NSColor(rgb:palette.color),roughness:0.68)
        let stripe = material(NSColor(rgb:0xF2F4ED),roughness:0.7)
        let face = TrackEnvironment.signFace(palette.word,background:palette.color,foreground:0x192221,aspect:2.5)
        for side in [-1.0,1.0] {
            let kerb = circuit.kerb(at:station.distance,side:side)
            let margin = max(1.2,kerb.width+0.36)
            var lateral = (circuit.width/2+margin)*side
            if side < 0 && (PitLane.entry...PitLane.exit).contains(local) {
                lateral = min(lateral,pit.lateral(at:local)-PitLane.halfWidth-0.9)
            }
            let height = circuit.roadProfile(at:station.distance,lateral:lateral).height
            let fixture = SCNNode()
            fixture.name = "LessonGate-\(marker.kind)"
            fixture.position = vector(station.point+station.right*lateral,y:height)
            fixture.eulerAngles.y = CGFloat(atan2(station.tangent.x,station.tangent.y)+Double.pi)
            lessonMarkersNode.addChildNode(fixture)
            func add(_ geometry: SCNGeometry,_ material: SCNMaterial,y: CGFloat,z: CGFloat = 0) {
                geometry.materials = [material]
                let node = SCNNode(geometry:geometry)
                node.position = SCNVector3(0,y,z)
                node.castsShadow = false
                fixture.addChildNode(node)
            }
            add(SCNBox(width:0.51,height:0.05,length:0.51,chamferRadius:0.018),stakes,y:0.03)
            for (base,top,segment,centre,material) in [
                (0.20,0.14,0.20,0.15,coneColor),(0.14,0.108,0.12,0.31,stripe),
                (0.108,0.042,0.22,0.48,coneColor)
            ] {
                let cone = SCNCone(topRadius:CGFloat(top),bottomRadius:CGFloat(base),height:CGFloat(segment))
                cone.radialSegmentCount = 14
                add(cone,material,y:CGFloat(centre))
            }
            add(SCNBox(width:0.038,height:0.47,length:0.05,chamferRadius:0),stakes,y:0.70)
            add(SCNBox(width:1.27,height:0.53,length:0.046,chamferRadius:0.018),stakes,y:0.89)
            add(SCNPlane(width:1.23,height:0.49),face,y:0.89,z:0.024)
        }
    }

    private func paintLessonSurface(_ ribbons: [(ClosedRange<Double>,ClosedRange<Double>)], color: UInt32,
                                    alpha: CGFloat, height: Double, name: String) {
        var vertices: [SCNVector3] = []
        var triangles: [Int32] = []
        for (progress,sides) in ribbons {
            let length = progress.upperBound-progress.lowerBound
            let sections = max(1,Int(ceil(length/2.5)))
            for index in 0...sections {
                let sample = circuit.sample(at:progress.lowerBound+length*Double(index)/Double(sections))
                let first = Int32(vertices.count)
                for lateral in [sides.lowerBound,sides.upperBound] {
                    let y = circuit.roadProfile(at:sample.distance,lateral:lateral).height+height
                    vertices.append(vector(sample.point+sample.right*lateral,y:y))
                }
                if index < sections {
                    triangles += [first,first+2,first+1,first+1,first+2,first+3]
                }
            }
        }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],
                                   elements:[SCNGeometryElement(indices:triangles,primitiveType:.triangles)])
        let paint = SCNMaterial()
        paint.lightingModel = .constant
        paint.diffuse.contents = NSColor(rgb:color,alpha:alpha)
        paint.isDoubleSided = true
        paint.readsFromDepthBuffer = true
        paint.writesToDepthBuffer = false
        geometry.materials = [paint]
        let mark = SCNNode(geometry:geometry)
        mark.name = name
        mark.castsShadow = false
        mark.categoryBitMask = Self.hiddenFromMirror
        mark.renderingOrder = 4
        lessonMarkersNode.addChildNode(mark)
    }

    func selectVehicle(_ kind: VehicleKind) {
        guard kind != vehicleKind else { return }
        car.childNodes.forEach { $0.removeFromParentNode() }
        body.childNodes.forEach { $0.removeFromParentNode() }
        ghostCar.childNodes.forEach { $0.removeFromParentNode() }
        body.transform = SCNMatrix4Identity
        frontWheels = []; rollingWheels = []; wheelPivots = []; wheelBaseHeights = []
        damageMeshes = []; glassNodes = []; brakeLights = []; mirrorSurfaces = [:]
        brakeLampOn = nil
        presentedView = nil
        contactShadows = []
        importedSteering = nil; renderedDamage = .zero
        vehicleKind = kind
        rebuildCarVisuals()
        resetCamera()
    }

    private func rebuildCarVisuals() {
        buildCar()
        bindMirrors()
        buildContactShadows()
        prepareOpponentTemplate()
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
            switch (vehicleKind,name,material) {
            case (.porsche,_,"AuthoredMirrorGlass"),
                 (.centenario,"Object_65","material_30"), (.centenario,"Object_77","material_30"):
                bindMirrorFaces(on:node,geometry:geometry,original:original)
            default:
                continue
            }
        }
    }

    private func bindMirrorFaces(on node: SCNNode,geometry: SCNGeometry,original: SCNMaterial) {
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
        var surfaces: [VehicleMirror:[UInt32]] = [:]
        for offset in stride(from:0,to:indices.count,by:3) {
            let triangle = indices[offset..<(offset+3)]
            let x = points[Int(indices[offset])].x
            let mirror: VehicleMirror = abs(x) < 0.35 ? .centre : (x > 0 ? .left : .right)
            surfaces[mirror,default:[]].append(contentsOf:triangle)
        }
        guard !surfaces.isEmpty else { return }
        node.geometry = nil
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

    private func isRivalPaint(_ name: String, on node: SCNNode) -> Bool {
        switch vehicleKind {
        case .porsche: return node.parent?.name == "Object_8"
        case .centenario: return name == "Material" && node.parent?.name == "Object_95"
        }
    }

    private static let rivalBrakeNames: Set<String> = ["LIGT_RED","SourcedBrakeLamp"]

    private func setRivalPaint(_ material: SCNMaterial, color: UInt32) {
        material.name = "RivalPaint"
        guard vehicleKind == .porsche else {
            material.diffuse.contents = NSColor(rgb:color)
            return
        }
        // The 911's licensed atlas shares paint, glass, crest and trim. Only
        // replace the dark paint swatch on the authored outer body primitive.
        func linear(_ component: UInt32) -> Double {
            let value = Double(component)/255
            return value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
        }
        let red = linear((color >> 16) & 255), green = linear((color >> 8) & 255), blue = linear(color & 255)
        let swatch = "float3(\(linear(38)),\(linear(37)),\(linear(45)))"
        material.shaderModifiers = [.surface:"""
        #pragma body
        float d = length(_surface.diffuse.rgb - \(swatch));
        float mask = 1.0 - smoothstep(0.004,0.012,d);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb,float3(\(red),\(green),\(blue)),mask);
        """]
    }

    func updateTraffic(_ vehicles: [Vehicle]) {
        while opponentVisuals.count > vehicles.count {
            opponentVisuals.removeLast().root.removeFromParentNode()
        }
        guard let template = opponentTemplate else { return }
        let paintColors = Self.rivalPaintColors
        while opponentVisuals.count < vehicles.count {
            let index = opponentVisuals.count
            let root = template.clone()
            var opponentBrakeLights: [SCNMaterial] = []
            var paintCopies: [ObjectIdentifier:SCNMaterial] = [:]
            var lightCopies: [ObjectIdentifier:SCNMaterial] = [:]
            root.name = "ComputerCar\(index+1)"
            root.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry,
                      geometry.materials.contains(where: {
                          self.isRivalPaint($0.name ?? "",on:node) || Self.rivalBrakeNames.contains($0.name ?? "")
                      }),
                      let copy = geometry.copy() as? SCNGeometry else { return }
                copy.materials = geometry.materials.map { original in
                    let name = original.name ?? ""
                    let source = ObjectIdentifier(original)
                    if self.isRivalPaint(name,on:node) {
                        if let paint = paintCopies[source] { return paint }
                        guard let material = original.copy() as? SCNMaterial else { return original }
                        self.setRivalPaint(material,color:paintColors[index % paintColors.count])
                        paintCopies[source] = material
                        return material
                    }
                    if Self.rivalBrakeNames.contains(name) {
                        if let lamp = lightCopies[source] { return lamp }
                        guard let material = original.copy() as? SCNMaterial else { return original }
                        material.emission.contents = NSColor(rgb: 0x2A0504)
                        opponentBrakeLights.append(material)
                        lightCopies[source] = material
                        return material
                    }
                    return original
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
            visual.body?.position.y = CGFloat(vehicle.modelHeave)
            visual.body?.eulerAngles.x = CGFloat(-vehicle.pitch)
            visual.body?.eulerAngles.z = CGFloat(vehicle.roll)
            let braking = vehicle.brakeLightsActive
            if braking != visual.brakeLampOn {
                opponentVisuals[index].brakeLampOn = braking
                let brakeColor = Self.brakeColor(braking)
                visual.brakeLights.forEach { $0.emission.contents = brakeColor }
            }
            updateWheelPose(vehicle,pivots:visual.steer,rolling:visual.roll)
        }
    }

    private func updateWheelPose(_ vehicle: Vehicle,pivots: [SCNNode],rolling: [SCNNode]) {
        for (index,pivot) in pivots.enumerated() {
            let steer = simd_quatf(angle:Float(vehicle.wheelSteer(index)),axis:SIMD3(0,1,0))
            let camber = simd_quatf(angle:Float(vehicle.damage.suspension[index] * (index % 2 == 0 ? 0.16 : -0.16)),axis:SIMD3(0,0,1))
            pivot.simdOrientation = steer * camber
            pivot.scale.y = CGFloat(vehicle.wheels[index].radiusScale)
            pivot.position.y = wheelBaseHeights[index] + CGFloat(vehicle.wheels[index].surfaceHeight)
        }
        for (index,wheel) in rolling.enumerated() {
            wheel.simdOrientation = simd_quatf(angle:Float(vehicle.wheels[index].rotation),axis:SIMD3(1,0,0))
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
        guard active else {
            for index in sprayEmitters.indices where sprayEmitters[index].birthRate > 0 {
                sprayEmitters[index].birthRate = 0
                sprayEmitters[index].system.birthRate = 0
            }
            return
        }
        let vehicles = [player] + opponents
        let count = vehicles.count * 2
        while sprayEmitters.count > count { sprayEmitters.removeLast().node.removeFromParentNode() }
        while sprayEmitters.count < count {
            let node = SCNNode()
            let birth = TyreSprayBirth(index:sprayEmitters.count)
            let particles = SCNParticleSystem()
            particles.birthRate = 0
            particles.particleLifeSpan = 0.43
            particles.particleLifeSpanVariation = 0.15
            particles.particleSize = 0.29
            particles.particleSizeVariation = 0.13
            particles.acceleration = SCNVector3(0,-3.1,0)
            particles.dampingFactor = 0.26
            particles.stretchFactor = 0.045
            particles.blendMode = .alpha
            particles.particleColor = NSColor(rgb:0xD5DFE4,alpha:0.19)
            particles.particleImage = Self.sprayTexture
            particles.isLocal = false
            particles.handle(.birth,forProperties:[.position,.velocity]) { data,stride,_,count in
                birth.emit(data,stride,count:count)
            }
            node.addParticleSystem(particles)
            sprayRoot.addChildNode(node)
            sprayEmitters.append(SprayEmitter(node:node,system:particles,birth:birth))
        }
        for (index, vehicle) in vehicles.enumerated() {
            let distance = simd_distance(player.position,vehicle.position)
            let detail = clamp((125-distance)/70,0,1)
            let near = clamp((distance-4)/12,0,1)
            let readable = cockpit && index > 0 ? 0.65+0.35*near*near*(3-2*near) : 1
            let visibility = detail*detail*(3-2*detail)*readable
            let contacts = vehicle.contactPoints
            let elevation = roadElevation(of:vehicle)
            for side in 0..<2 {
                let slot = index*2+side
                let emitter = sprayEmitters[slot]
                let front = TyreSpraySample(vehicle:vehicle,index:side,contact:contacts[side],elevation:elevation)
                let rear = TyreSpraySample(vehicle:vehicle,index:side+2,contact:contacts[side+2],elevation:elevation)
                let strength = front.strength+rear.strength
                let rate = min(92,strength*52)*visibility
                if rate > 0.25 {
                    let share = front.strength/strength
                    let origin = rear.position+(front.position-rear.position)*Float(share)
                    emitter.node.simdPosition = origin
                    emitter.birth.update(front:front,rear:rear,origin:origin,frontShare:share)
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
        car.addChildNode(body); scene.rootNode.addChildNode(car)
        let file = vehicleKind.assetName
        guard let url = assetURL("Vehicles/\(file).glb"), let asset = try? GLTFAsset(url:url),
              let model = try? asset.makeScene() else { fatalError("Missing bundled vehicle: \(file)") }
        GLTFAsset.applyCabinMaterials(to:model,kind:vehicleKind)
        body.addChildNode(model)
        if vehicleKind == .porsche, let liner = GLTFAsset.separatePorscheWindshieldLiner(from:model) {
            glassNodes.append(liner)
        }
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
                case "CockpitWindow":
                    m.diffuse.contents = NSColor(rgb:0x34434D)
                    m.metalness.contents = 0
                    m.roughness.contents = 0.16
                    m.transparency = 0.29
                    m.clearCoat.contents = 0.12
                    m.clearCoatRoughness.contents = 0.15
                    m.transparencyMode = .aOne
                    m.writesToDepthBuffer = false
                    self.glassNodes.append(node)
                case "SourcedBrakeLamp": self.brakeLights.append(m)
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
            if vehicleKind == .centenario {
                // Calipers belong to the upright: steer with the wheel,
                // but never spin with the tyre/rim and brake disc.
                var calipers: [SCNNode] = []
                mesh.enumerateChildNodes { node, _ in
                    if node.geometry != nil && (node.parent?.name == "BrakeCaliperMesh" ||
                        ["Object_7","Object_18"].contains(node.parent?.name ?? "")) {
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
        switch vehicleKind {
        case .porsche:
            // Axis and centre measured from the original rim in Steering-local metres.
            steeringAxis = simd_normalize(SIMD3(0,0.5373,-0.8434))
            steeringCentre = SIMD3(0.00022,-0.00577,-0.00368)
        case .centenario:
            steeringAxis = simd_normalize(SIMD3(0,0.31,-0.95))
            steeringCentre = .zero
        }
        steeringBase = importedSteering?.simdTransform ?? matrix_identity_float4x4
        model.enumerateChildNodes { node, _ in
            let name = node.parent?.name ?? ""
            let deforms = self.vehicleKind == .centenario ?
                ["Object_64","Object_76","Object_92","Object_93","Object_95"].contains(name) : name == "Object_8"
            guard deforms, let geometry = node.geometry, !geometry.materials.isEmpty,
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
        let spacing = racingLine.spacing
        let windowStart = Int(floor(progress/spacing))
        let base = Double(windowStart)*spacing
        let cues = (-2..<55).map { step in
            let cue = racingLine.cue(at:base+Double(step)*spacing,speed:vehicle.speed)
            return cue == .brake ? 2 : (cue == .lift ? 1 : 0)
        }
        guard windowStart != lineWindowStart || cues != lineWindowCues else { return }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(cues.count*4)
        var groups = [[Int32](),[Int32](),[Int32]()]
        // Each station's dash follows the same road shape each time it enters the window.
        for (offset,group) in cues.enumerated() {
            let step = offset-2
            let station = windowStart+step
            let dash: [SCNVector3]
            if let cached = lineDashes[station] {
                dash = cached
            } else {
                let distance = base+Double(step)*spacing
                let a = racingLine.sample(at:distance), b = racingLine.sample(at:distance+spacing*0.66)
                let direction = simd_normalize(b.position-a.position)
                let side = SIMD2(direction.y,-direction.x)*0.23
                dash = [a.position-side,a.position+side,b.position-side,b.position+side].map {
                    vector($0,y:0.045+elevation(at:$0))
                }
                lineDashes[station] = dash
            }
            let index = Int32(vertices.count)
            vertices += dash
            groups[group] += [index,index+2,index+1,index+1,index+2,index+3]
        }
        let active = groups.indices.filter { !groups[$0].isEmpty }
        let elements = active.map { SCNGeometryElement(indices:groups[$0],primitiveType:.triangles) }
        let mesh = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:elements)
        mesh.materials = active.map { lineMaterials[$0] }
        racingLineNode.geometry = mesh
        racingLineNode.castsShadow = false
        lineWindowStart = windowStart
        lineWindowCues = cues
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
            cabinFill.light?.intensity = mode.isInterior ? 80 : 0
            importedSteering?.isHidden = mode == .dashboard
            // The Carrera dashboard passes within 6 cm of the lowest seat
            // during right glances under roll. Keep the visible skin intact.
            camera.camera?.zNear = mode == .cockpit && vehicleKind == .porsche ? 0.015 : 0.06
            presentedView = mode
        }
        car.eulerAngles.y = CGFloat(vehicle.heading)
        body.position.y = CGFloat(vehicle.modelHeave)
        body.eulerAngles.z = CGFloat(vehicle.roll)
        body.eulerAngles.x = CGFloat(-vehicle.pitch)
        updateWheelPose(vehicle,pivots:wheelPivots,rolling:rollingWheels)
        for (i,node) in contactShadows.enumerated() {
            node.position.y = 0.031+CGFloat(vehicle.wheels[i].surfaceHeight)
            node.opacity = CGFloat(clamp(vehicle.wheels[i].normalLoad/3000,0,1))
        }
        if let importedSteering {
            let rotation = simd_quatf(angle:Float(vehicle.handwheelAngle),axis:steeringAxis)
            var pose = simd_float4x4(rotation)
            let compensation = steeringCentre-rotation.act(steeringCentre)
            pose.columns.3 = SIMD4(compensation.x,compensation.y,compensation.z,1)
            importedSteering.simdTransform = steeringBase*pose
        }
        let braking = vehicle.brakeLightsActive
        if braking != brakeLampOn {
            brakeLampOn = braking
            let brakeColor = Self.brakeColor(braking)
            brakeLights.forEach { $0.emission.contents = brakeColor }
        }
        let f = vehicle.forward
        let centreMount = mirrorSurfaces[.centre]?.centre ?? SIMD3(0,1.36,0)
        frameMirror(mirrorCamera,at:centreMount,looking:SIMD3(0,-0.032,-1))
        if mode.isInterior {
            for mirror in [VehicleMirror.left,.right] {
                guard let surface = mirrorSurfaces[mirror] else { continue }
                let node = camera(for:mirror)
                let side = mirror == .left ? 1.0 : -1.0
                let mount = surface.centre+SIMD3(Float(side*0.03),0.012,-0.05)
                frameMirror(node,at:mount,looking:SIMD3(Float(side*0.24),-0.047,-1))
            }
        }
        let desired: SIMD3<Float>
        let target: SCNVector3
        if mode.isInterior || mode == .bonnet || mode == .bumper {
            var longitudinal = -0.12, lateral = 0.345, height = seatHeight
            if mode == .cockpit {
                // The saved seat setting expresses position within the car's
                // range, with less rise where the authored roof sits lower.
                let travel = seatHeight-1
                switch vehicleKind {
                case .porsche: longitudinal = -0.11; lateral = 0.375; height = 1.015+travel*0.25
                case .centenario: longitudinal = -0.05; lateral = 0.355; height = 0.970+travel*0.21
                }
            } else if mode == .dashboard {
                switch vehicleKind {
                case .porsche: longitudinal = 0.32; lateral = 0.375
                case .centenario: longitudinal = 0.24; lateral = 0.355
                }
                height = 1.04
            }
            if mode == .bonnet { longitudinal = 1.25; lateral = 0; height = 1.10 }
            if mode == .bumper { longitudinal = 2.6; lateral = 0; height = 0.42 }
            let fullGlance = 1.22
            var requestedGlance = mode.isInterior ? sideLook*fullGlance : 0
            if mode == .cockpit && sideLook < 0 && cockpitFOV < 62, let mirror = mirrorSurfaces[.left] {
                // A narrow lens can turn past the driver's mirror. Ease the
                // end of the glance toward its authored bearing, with room to look outside.
                let bearing = atan2(abs(Double(mirror.centre.x)-lateral),Double(mirror.centre.z)-longitudinal)
                let narrow = clamp((62-Double(cockpitFOV))/20,0,1)
                let reduction = max(0,fullGlance-bearing-0.20)*narrow
                let overrun = -requestedGlance-(fullGlance-2*reduction)
                if reduction > 0 && overrun > 0 {
                    requestedGlance += overrun*overrun/(4*reduction)
                }
            }
            glanceAngle = cameraContinuous ? glanceAngle + (requestedGlance-glanceAngle)*(1-exp(-dt*18)) : requestedGlance
            let glance = glanceAngle
            let p = vehicle.position + f*(longitudinal-abs(glance)*0.035) + vehicle.modelX*(lateral-glance*0.052)
            let cameraHeight = elevation + height + vehicle.modelHeave * (mode.isInterior ? 0.55 : 1)
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

    private func frameMirror(_ node: SCNNode, at mount: SIMD3<Float>, looking direction: SIMD3<Float>) {
        let origin = body.simdConvertPosition(mount,to:nil)
        let axis = body.simdConvertVector(direction,to:nil)
        let up = body.simdConvertVector(SIMD3(0,1,0),to:nil)
        node.simdPosition = origin
        node.simdLook(at:origin+axis,up:up,localFront:SIMD3(0,0,-1))
    }

    private func elevation(at point: SIMD2<Double>) -> Double {
        circuit.hasElevation ? circuit.roadHeight(at:circuit.nearest(to:point)) : 0
    }

    private func roadElevation(of vehicle: Vehicle) -> Double {
        vehicle.hasRoadElevationSample ? vehicle.roadElevation : elevation(at:vehicle.position)
    }
}

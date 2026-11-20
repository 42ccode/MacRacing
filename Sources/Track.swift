import Foundation
import simd

func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

struct TrackSample {
    let point: SIMD2<Double>
    let tangent: SIMD2<Double>
    let distance: Double
    var right: SIMD2<Double> { SIMD2(tangent.y, -tangent.x) }
}

struct TrackLocation {
    let point: SIMD2<Double>
    let tangent: SIMD2<Double>
    let progress: Double
    let lateral: Double
    let distance: Double
    let segment: Int
}

enum CircuitKind: Int, CaseIterable, Codable {
    case north, sprint, technical, grand, ridge, valley
    var name: String { ["NORTH LOOP", "CLUB SPRINT", "TECHNICAL PARK", "GRAND CIRCUIT", "RIDGE RING", "VALLEY CIRCUIT"][rawValue] }
    var label: String { ["北环赛道", "俱乐部短环", "技术公园", "大奖赛长环", "高原高速环", "河谷环线"][rawValue] }
    var detail: String { ["均衡弯道 · 基础练习", "短直道 · 连续中速弯", "发卡与变向 · 制动练习", "长直道 · 高速弯与减速弯", "高低起伏 · 带横坡高速弯", "起伏与连续变向 · 回头弯"][rawValue] }
    var hasElevation: Bool { self == .ridge || self == .valley }
    var controls: [SIMD2<Double>] {
        switch self {
        case .north: return [
            [-100,-165],[35,-165],[150,-165],[210,-105],
            [180,-30],[100,0],[65,55],[135,110],
            [145,175],[55,210],[-5,165],[-35,105],
            [-115,95],[-200,40],[-200,-55],[-175,-165]]
        case .sprint: return [
            [-100,-165],[35,-165],[150,-135],[180,-35],
            [105,50],[110,150],[-15,195],[-150,135],
            [-205,20],[-170,-110]]
        case .technical: return [
            [-100,-165],[40,-165],[185,-130],[220,-30],
            [100,25],[175,125],[100,220],[-40,220],
            [-155,140],[-65,55],[-175,-5],[-220,-110]]
        case .grand: return [
            [-100,-165],[100,-165],[360,-140],[470,0],
            [420,160],[250,235],[90,235],[20,165],
            [-70,165],[-145,240],[-325,180],[-420,20],[-330,-150]]
        case .ridge: return [
            [-260,-220],[0,-220],[255,-220],[420,-132],[455,34],
            [355,145],[212,186],[110,300],[-55,315],[-150,215],
            [-270,200],[-430,120],[-450,-65],[-370,-178]]
        case .valley: return [
            [-120,-180],[10,-180],[170,-180],[240,-127],[244,-42],
            [200,4],[90,9],[53,65],[106,122],[219,132],[242,190],
            [159,250],[18,243],[-101,188],[-159,90],[-215,38],[-221,-82]]
        }
    }
}

struct CornerLandmark {
    enum Form { case marshalPost, wall, lightRig, observationDeck, shelter, mast }

    let corner: Double
    let station: Double
    let offset: Double
    let form: Form
    let name: String
    let accent: UInt32

    init(_ corner: Double,_ station: Double,_ offset: Double,_ form: Form,_ name: String,_ accent: UInt32) {
        self.corner = corner
        self.station = station
        self.offset = offset
        self.form = form
        self.name = name
        self.accent = accent
    }
}

extension CircuitKind {
    // Scenery positions behind the catch fence. The corner and station
    // identify the braking approach and the landmark independently.
    var landmarks: [CornerLandmark] {
        switch self {
        case .north:
            return [
                .init(340,314,23.0,.marshalPost,"PINE POST",0x496E5C),
                .init(570,547,-23.8,.wall,"STONE BANK",0x95754E),
                .init(1380,1356,23.5,.lightRig,"NORTH LIGHTS",0x567587)
            ]
        case .sprint:
            return [
                .init(370,338,23.7,.observationDeck,"CLUB STAND",0x935F49),
                .init(570,514,-23.8,.shelter,"CUTTING",0x667752),
                .init(1180,1165,23.0,.marshalPost,"PADDOCK",0x56748D)
            ]
        case .technical:
            return [
                .init(290,266,23.0,.mast,"SERVICE MAST",0xA46D41),
                .init(540,508,24.5,.wall,"PANEL WALL",0x558185),
                .init(1450,1427,23.2,.lightRig,"EAST RIG",0xA38346)
            ]
        case .grand:
            return [
                .init(660,639,23.8,.observationDeck,"EAST STAND",0xA36A51),
                .init(1260,1212,23.7,.shelter,"CROSSING",0x546F82),
                .init(1850,1826,24.0,.wall,"WEST WALL",0x777A61)
            ]
        case .ridge:
            return [
                .init(890,866,23.0,.mast,"SUMMIT",0xB06553),
                .init(1330,1304,23.7,.wall,"QUARRY",0x927858),
                .init(1950,1924,23.3,.lightRig,"LOWER RIG",0x5E7481)
            ]
        case .valley:
            return [
                .init(330,307,23.0,.marshalPost,"PUMP HOUSE",0x547882),
                .init(720,691,-23.7,.shelter,"MILL SHELTER",0x805E50),
                .init(1370,1348,23.9,.observationDeck,"VALLEY DECK",0x577C62)
            ]
        }
    }
}

struct WheelRoadContact {
    var distance: Double
    var progress: Double
    var kerbsEnabled: Bool
    var surfaceTemperature = 30.0
    var waterDepth = 0.0 // millimetres
    var elevation = 0.0 // metres, excluding the kerb
    var gradient = SIMD2<Double>.zero // vertical rise per horizontal metre, world X/Z
    var kerbScale = 1.0

    var kerb: RoadKerb { RoadKerb(scale:kerbsEnabled ? kerbScale : 0) }
}

struct RoadKerb {
    let scale: Double
    var width: Double { 0.35 + 0.50 * scale }

    func elevation(progress: Double, distanceFromEdge: Double) -> Double {
        guard scale > 0 else { return 0 }
        return scale * kerbElevation(progress:progress, distanceFromEdge:distanceFromEdge * (0.85/width))
    }
}

enum TrackCondition: Int, CaseIterable {
    case dry, wet

    var label: String { self == .dry ? "干地" : "湿地" }
}

/// A wet circuit after rain has stopped. Main-track traffic clears its own paths,
/// while local runoff slowly fills the cleared tread marks from adjacent water.
struct TrackDrying {
    static let interval = 0.05
    private static let lateralCount = 13
    private let length: Double
    private let width: Double
    private let stationCount: Int
    private var cleared: [Float]
    private(set) var elapsed = 0.0

    init(circuit: Circuit) {
        length = circuit.length
        width = circuit.width
        stationCount = Int(ceil(length / 5))
        cleared = [Float](repeating:0,count:stationCount*Self.lateralCount)
    }

    mutating func advance(_ dt: Double) {
        guard dt.isFinite && dt > 0 else { return }
        elapsed += dt
        let runoff = Float(exp(-dt/115))
        for index in cleared.indices { cleared[index] *= runoff }
    }

    mutating func displace(at progress: Double, lateral: Double, travelled: Double,
                           speed: Double, load: Double, treadWidth: Double) {
        let speedShare = clamp((speed-3)/19,0,1)
        let loadShare = clamp(load/2900,0,1.15)
        let treadShare = clamp(treadWidth/0.22,0.65,1.40)
        let swept = travelled * Double(stationCount) / length
        let pass = 0.072*swept*speedShare*loadShare*treadShare
        guard pass.isFinite && pass > 0, let point = cell(at:progress,lateral:lateral) else { return }
        let across = Self.lateralCount
        for (line,share) in [(point.station,1-point.along),(point.nextStation,point.along)] {
            let left = line*across+point.slot
            let contribution = Float(pass*share)
            cleared[left] = min(0.73,cleared[left]+(1-cleared[left])*contribution*Float(1-point.cross))
            cleared[left+1] = min(0.73,cleared[left+1]+(1-cleared[left+1])*contribution*Float(point.cross))
        }
    }

    func depth(from initial: Double, at progress: Double, lateral: Double) -> Double {
        guard elapsed > 0, let point = cell(at:progress,lateral:lateral) else { return initial }
        let start = point.station*Self.lateralCount+point.slot
        let end = point.nextStation*Self.lateralCount+point.slot
        let a = Double(cleared[start])*(1-point.cross)+Double(cleared[start+1])*point.cross
        let b = Double(cleared[end])*(1-point.cross)+Double(cleared[end+1])*point.cross
        let displaced = a+(b-a)*point.along
        // Shallower films evaporate more quickly. Deep pockets remain wet
        // where they are not mechanically cleared.
        let evaporated = elapsed*(0.00016+max(0,0.50-initial)*0.00028)
        return max(0.035,(initial-evaporated)*(1-displaced))
    }

    private func cell(at progress: Double, lateral: Double)
        -> (station: Int,nextStation: Int,along: Double,slot: Int,cross: Double)? {
        let edge = width/2
        guard progress.isFinite, lateral.isFinite, abs(lateral) <= edge else { return nil }
        let lap = progress/length
        let along = (lap-floor(lap))*Double(stationCount)
        let station = min(Int(along),stationCount-1)
        let cross = (lateral+edge)/width*Double(Self.lateralCount-1)
        let slot = min(Int(cross),Self.lateralCount-2)
        return (station,(station+1)%stationCount,along-Double(station),slot,cross-Double(slot))
    }
}

/// A closed, original circuit. World coordinates are metres in the X/Z plane.
final class Circuit {
    private struct Segment {
        let point: SIMD2<Double>
        let delta: SIMD2<Double>
        let tangent: SIMD2<Double>
        let length: Double
        let inverseSquaredLength: Double
        let progress: Double
    }
    private struct ElevationWave {
        let amplitude: Double
        let start: Double
        let peak: Double
        let end: Double

        init(_ amplitude: Double, _ start: Double, _ peak: Double, _ end: Double) {
            self.amplitude = amplitude; self.start = start; self.peak = peak; self.end = end
        }

        func evaluate(_ t: Double) -> SIMD2<Double> {
            guard t > start && t < end else { return .zero }
            let rising = t < peak
            let span = rising ? peak-start : end-peak
            let u = rising ? (t-start)/span : (end-t)/span
            let value = u*u*u*(10+u*(-15+6*u))
            let slope = (rising ? 1 : -1) * 30*u*u*(1-u)*(1-u)/span
            return SIMD2(value,slope)*amplitude
        }
    }
    private static let ridgeGrades = [ElevationWave(21,0.087,0.300,0.510),ElevationWave(-12,0.45,0.66,0.93)]
    private static let ridgeBanks = [ElevationWave(0.062,0.255,0.300,0.357),ElevationWave(0.048,0.515,0.553,0.61),
                                    ElevationWave(-0.045,0.641,0.679,0.718)]
    private static let valleyGrades = [ElevationWave(7.4,0.125,0.305,0.480),ElevationWave(-5.1,0.510,0.661,0.910)]
    private static let valleyBanks = [ElevationWave(0.037,0.232,0.285,0.326),ElevationWave(-0.053,0.340,0.401,0.457),
                                     ElevationWave(0.045,0.488,0.529,0.578)]
    private let segments: [Segment]
    private let nearbySegments: [SIMD2<Int>: [Int]]
    private var kerbStations: [SIMD2<Double>] = [] // negative and positive lateral edges
    private static let bucketSize = 24.0
    static let guardRailOffset = 15.8
    static let guardRailCorrugation = 0.08
    static let guardRailInnerEdge = guardRailOffset - guardRailCorrugation
    let width: Double = 12
    let samples: [TrackSample]
    let length: Double
    let kind: CircuitKind
    let condition: TrackCondition
    var name: String { kind.name }
    var hasElevation: Bool { kind.hasElevation }

    /// Continuous grade and banking profiles for the fictional circuits.
    /// The grid and the full pit entry/exit remain level.
    func roadProfile(at progress: Double, lateral: Double = 0) -> (height: Double, grade: Double, crossfall: Double) {
        guard hasElevation else { return (0,0,0) }
        let lap = progress/length
        let t = lap-floor(lap)
        let gradeWaves = kind == .ridge ? Self.ridgeGrades : Self.valleyGrades
        let bankWaves = kind == .ridge ? Self.ridgeBanks : Self.valleyBanks
        let grade = gradeWaves.reduce(SIMD2<Double>.zero) { $0+$1.evaluate(t) }
        let bank = bankWaves.reduce(SIMD2<Double>.zero) { $0+$1.evaluate(t) }
        let u = clamp((abs(lateral)-7)/14,0,1)
        let blend = 1 - u*u*(3-2*u)
        let blendDerivative = -copysign(6*u*(1-u)/14,lateral)
        let shoulder = lateral*blend
        return (grade.x + bank.x*shoulder,
                (grade.y + bank.y*shoulder)/length,
                bank.x*(blend+lateral*blendDerivative))
    }

    func roadHeight(at location: TrackLocation) -> Double {
        roadProfile(at:location.progress,lateral:location.lateral).height
    }

    func surfaceTemperature(at progress: Double) -> Double {
        // Repeatable dry-session baseline. The profile closes continuously at start/finish.
        let phase = progress / length * (2 * .pi)
        let base = condition == .wet ? 26.0 : 34.0
        return base + 3 * sin(phase - 0.7) + 1.5 * sin(phase * 3)
    }

    func waterDepth(at progress: Double, lateral: Double = 0) -> Double {
        guard condition == .wet else { return 0 }
        let phase = progress / length * (2 * .pi)
        let rill = 1.4*sin(phase*2+0.4)+0.6*sin(phase*5)
        let shallow = 0.24*exp(-pow((lateral-rill)/1.95,2))
        let pocket = 0.69 * pow(max(0,cos(phase*5-1.2)),6) *
            exp(-pow((lateral-3.5*cos(phase*3+0.2))/1.5,2))
        let bank = roadProfile(at:progress).crossfall
        let drainage = clamp(-lateral*bank*0.38,-0.19,0.19)
        return clamp(0.55 + 0.22*sin(phase*3) + 0.15*cos(phase*7) - shallow + pocket + drainage,0.08,1.30)
    }

    func wheelContacts(at points: [SIMD2<Double>], drying: TrackDrying? = nil) -> [WheelRoadContact] {
        points.map { point in
            let contact = nearest(to: point)
            let profile = roadProfile(at:contact.progress,lateral:contact.lateral)
            let right = SIMD2(contact.tangent.y,-contact.tangent.x)
            let gradient = contact.tangent*profile.grade + right*profile.crossfall
            let temperature = surfaceTemperature(at:contact.progress)
            let water = waterDepth(at:contact.progress,lateral:contact.lateral)
            if pitLane.hasAsphalt(at: contact) {
                return WheelRoadContact(distance:0,progress:contact.progress,kerbsEnabled:false,
                                        surfaceTemperature:temperature,waterDepth:water,
                                        elevation:profile.height,gradient:gradient)
            }
            let kerb = kerb(at:contact.progress,side:contact.lateral)
            let film = condition == .wet ? drying?.depth(from:water,at:contact.progress,lateral:contact.lateral) ?? water : water
            return WheelRoadContact(distance:contact.distance,progress:contact.progress,
                                    kerbsEnabled:kerb.scale > 0,surfaceTemperature:temperature,
                                    waterDepth:film,elevation:profile.height,gradient:gradient,kerbScale:kerb.scale)
        }
    }

    init(kind: CircuitKind = .north, condition: TrackCondition = .dry) {
        self.kind = kind
        self.condition = condition
        let controls = kind.controls
        var positions: [SIMD2<Double>] = []
        for index in controls.indices {
            let count = controls.count
            let p0 = controls[(index + count - 1) % count]
            let p1 = controls[index]
            let p2 = controls[(index + 1) % count]
            let p3 = controls[(index + 2) % count]
            for step in 0..<32 {
                let t = Double(step) / 32
                let a = 2 * p1
                let b = (-p0 + p2) * t
                let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                let d = (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t
                positions.append((a + b + c + d) * 0.5)
            }
        }
        var accumulated = 0.0
        var result: [TrackSample] = []
        for index in positions.indices {
            if index > 0 { accumulated += simd_distance(positions[index], positions[index - 1]) }
            let before = positions[(index + positions.count - 1) % positions.count]
            let after = positions[(index + 1) % positions.count]
            result.append(TrackSample(point: positions[index], tangent: simd_normalize(after - before), distance: accumulated))
        }
        samples = result
        length = accumulated + simd_distance(positions.last!, positions.first!)
        segments = result.indices.map { index in
            let sample = result[index]
            let delta = result[(index + 1) % result.count].point - sample.point
            let squaredLength = simd_length_squared(delta)
            return Segment(point:sample.point,delta:delta,tangent:simd_normalize(delta),
                           length:sqrt(squaredLength),inverseSquaredLength:1/max(squaredLength,0.0001),
                           progress:sample.distance)
        }
        let size = Self.bucketSize
        var nearbySegments: [SIMD2<Int>: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let end = segment.point + segment.delta
            let lowerX = min(segment.point.x,end.x), upperX = max(segment.point.x,end.x)
            let lowerY = min(segment.point.y,end.y), upperY = max(segment.point.y,end.y)
            let firstX = Int(floor(lowerX/size))-1, lastX = Int(floor(upperX/size))+1
            let firstY = Int(floor(lowerY/size))-1, lastY = Int(floor(upperY/size))+1
            // Record this segment once in each query cell where it could be
            // within one cell width of the query point.
            for x in firstX...lastX {
                let left = Double(x)*size
                let gapX = max(0,lowerX-(left+size),left-upperX)
                for y in firstY...lastY {
                    let top = Double(y)*size
                    let gapY = max(0,lowerY-(top+size),top-upperY)
                    if gapX*gapX+gapY*gapY <= size*size {
                        nearbySegments[SIMD2(x,y),default:[]].append(index)
                    }
                }
            }
        }
        self.nearbySegments = nearbySegments
        kerbStations = buildKerbStations()
    }

    func nearest(to position: SIMD2<Double>, useSpatialIndex: Bool = true) -> TrackLocation {
        var bestSquared = Double.infinity
        var bestIndex = 0
        var bestFraction = 0.0
        func consider(_ index: Int) {
            let segment = segments[index]
            let offset = position - segment.point
            let t = clamp(simd_dot(offset, segment.delta) * segment.inverseSquaredLength, 0, 1)
            let squaredDistance = simd_length_squared(offset - segment.delta * t)
            if squaredDistance < bestSquared || (squaredDistance == bestSquared && index < bestIndex) {
                bestSquared = squaredDistance
                bestIndex = index
                bestFraction = t
            }
        }
        let size = Self.bucketSize
        if useSpatialIndex && position.x.isFinite && position.y.isFinite &&
            abs(position.x) < 100_000 && abs(position.y) < 100_000 {
            let x = Int(floor(position.x / size))
            let y = Int(floor(position.y / size))
            if let indices = nearbySegments[SIMD2(x,y)] {
                for index in indices { consider(index) }
            }
        }
        // Any segment not in the cell's index is at least one cell width away.
        if bestSquared >= size * size {
            for index in segments.indices { consider(index) }
        }
        let best = segments[bestIndex]
        let closest = best.point + best.delta * bestFraction
        return TrackLocation(point:closest,tangent:best.tangent,progress:best.progress+best.length*bestFraction,
                             lateral:simd_dot(position-closest,SIMD2(best.tangent.y,-best.tangent.x)),
                             distance:sqrt(bestSquared),segment:bestIndex)
    }

    func sample(at distance: Double) -> TrackSample {
        let wrapped = (distance.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].distance <= wrapped { low = mid } else { high = mid - 1 }
        }
        let a = samples[low]
        let b = samples[(low + 1) % samples.count]
        let endDistance = low == samples.count - 1 ? length : b.distance
        let t = (wrapped - a.distance) / max(endDistance - a.distance, 0.0001)
        return TrackSample(point: a.point + (b.point - a.point) * t,
                           tangent: simd_normalize(a.tangent + (b.tangent - a.tangent) * t), distance: wrapped)
    }

    private func buildKerbStations() -> [SIMD2<Double>] {
        let count = Int(ceil(length))
        let spacing = length / Double(count)
        func angle(at progress: Double) -> Double {
            let a = sample(at:progress-9).tangent, b = sample(at:progress+9).tangent
            return atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))
        }
        func smooth(_ value: Double) -> Double {
            let t = clamp(value,0,1)
            return t*t*(3-2*t)
        }
        return (0..<count).map { i in
            let progress = Double(i) * spacing
            let current = angle(at:progress), prior = angle(at:progress-18)
            let inside = smooth((abs(current)-0.075)/0.075)
            let exit = 0.82 * smooth((abs(prior)-0.11)/0.065) * smooth((abs(prior)-abs(current)-0.025)/0.10)
            var edges = SIMD2(current >= 0 ? inside : 0,current < 0 ? inside : 0)
            let outsideIndex = prior >= 0 ? 1 : 0
            edges[outsideIndex] = max(edges[outsideIndex],exit)

            // A flush merge replaces the inside kerb where the pit pavement
            // crosses the track edge. Taper the transition into the verge.
            let local = pitLane.localProgress(progress)
            let pitWeight = smooth(min(local-PitLane.entry+7.5,PitLane.exit+7.5-local)/6)
            let pitClearance = abs(-width/2-0.28-pitLane.lateral(at:local))-PitLane.halfWidth
            edges.x *= 1-pitWeight*(1-smooth(pitClearance/1.25))
            return edges
        }
    }

    func kerb(at progress: Double, side: Double) -> RoadKerb {
        guard progress.isFinite else { return RoadKerb(scale:0) }
        let lap = progress/length
        let station = (lap-floor(lap))*Double(kerbStations.count)
        let index = min(Int(station),kerbStations.count-1)
        let fraction = station-Double(index)
        let axis = side < 0 ? 0 : 1
        let low = kerbStations[index][axis], high = kerbStations[(index+1)%kerbStations.count][axis]
        return RoadKerb(scale:low+(high-low)*fraction)
    }

    func hasKerb(at distance: Double) -> Bool {
        kerb(at:distance,side:-1).scale > 0 || kerb(at:distance,side:1).scale > 0
    }

    var cornerDistances: [Double] {
        let candidates = stride(from:0.0,to:length,by:10).map { d -> (Double,Double) in
            let a = sample(at:d-12).tangent, b = sample(at:d+12).tangent
            return (d,abs(atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))))
        }.filter { $0.1>0.18 }.sorted { $0.1>$1.1 }
        var selected: [Double] = []
        for (distance,_) in candidates {
            if selected.allSatisfy({ let delta=abs($0-distance); return min(delta,length-delta)>160 }) { selected.append(distance) }
        }
        return selected.sorted()
    }

    var start: TrackSample { sample(at: 8) }
    func gridSlot(_ index: Int, frontMark: Bool = false) -> TrackSample {
        // The painted boxes sit just beyond the timing gantry.
        let mark = sample(at: 101 - Double(index) * 7 - (frontMark ? 0 : 1.65))
        let lateral = index.isMultiple(of: 2) ? 2.65 : -2.65
        return TrackSample(point: mark.point + mark.right*lateral, tangent: mark.tangent, distance: mark.distance)
    }
    var pitLane: PitLane { PitLane(trackLength:length) }
}

/// Shared by the contact solver and the visible kerb mesh (metres above asphalt).
func kerbElevation(progress: Double, distanceFromEdge: Double) -> Double {
    let inner = clamp(distanceFromEdge/0.12,0,1)
    let outer = clamp((0.85-distanceFromEdge)/0.15,0,1)
    return (0.030 + 0.012*sin(progress*7))*inner*outer
}

/// Authored-track practice guide: outside / apex / outside offsets with a
/// conservative curvature speed envelope. This is not a lap-time optimizer.
struct RacingLine {
    struct Point {
        let progress: Double
        let position: SIMD2<Double>
        let targetSpeed: Double // m/s
    }
    enum Cue { case accelerate, lift, brake }
    let points: [Point]
    let length: Double
    let spacing: Double

    init(circuit: Circuit) {
        length=circuit.length
        let count=Int(ceil(circuit.length/4))
        let step = circuit.length / Double(count)
        spacing = step
        let samples = (0..<count).map { circuit.sample(at: Double($0) * step) }
        let bends=samples.map { s -> Double in
            let a=circuit.sample(at:s.distance-10).tangent, b=circuit.sample(at:s.distance+10).tangent
            return atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))/20
        }
        func circular(_ value:Double) -> Double {
            var d=value
            if d>circuit.length/2 {d -= circuit.length}
            if d < -circuit.length/2 {d += circuit.length}
            return d
        }
        var corners:[Int]=[]
        for i in bends.indices.sorted(by:{abs(bends[$0])>abs(bends[$1])}) where abs(bends[i])>0.004 {
            if corners.allSatisfy({abs(circular(samples[i].distance-samples[$0].distance))>90}) {corners.append(i)}
        }
        let margin=circuit.width/2-2.2
        var offsets=samples.map { s -> Double in
            var offset=0.0, weight=0.0
            for i in corners {
                let d=circular(s.distance-samples[i].distance)
                guard abs(d)<115 else {continue}
                let influence=exp(-pow(d/85,4))
                let sign=bends[i]>0 ? 1.0 : -1.0
                let curve=2.8*exp(-pow((d+57)/30,2))+2.8*exp(-pow((d-57)/30,2))-4.2*exp(-pow(d/25,2))
                offset += sign*curve*influence;weight += influence
            }
            return clamp(offset/max(1,weight),-margin,margin)
        }
        for _ in 0..<12 {
            let old=offsets
            for i in 0..<count {offsets[i]=old[i]*0.6+(old[(i+count-1)%count]+old[(i+1)%count])*0.2}
        }
        func wetExposure(at progress: Double, offset: Double) -> Double {
            let left = circuit.waterDepth(at:progress,lateral:offset-0.78)
            let right = circuit.waterDepth(at:progress,lateral:offset+0.78)
            return 0.35*min(left,right)+0.65*max(left,right)
        }
        if circuit.condition == .wet {
            let deviations = [-1.25,-0.85,-0.40,0,0.40,0.85,1.25]
            var shifts = samples.indices.map { index -> Double in
                let station = samples[index].distance
                let original = offsets[index]
                var bestShift = 0.0
                var bestCost = wetExposure(at:station,offset:original)
                for deviation in deviations {
                    let candidate = clamp(original+deviation,-margin,margin)
                    let shift = candidate-original
                    let cost = wetExposure(at:station,offset:candidate)+0.073*shift*shift
                    if cost < bestCost {
                        bestCost = cost
                        bestShift = shift
                    }
                }
                return bestShift
            }
            // Spread a correction over several car lengths so one short
            // puddle cannot turn the guide into a last-second lane change.
            for _ in 0..<20 {
                let previous = shifts
                for i in shifts.indices {
                    shifts[i] = 0.5*previous[i]+0.25*(previous[(i+count-1)%count]+previous[(i+1)%count])
                }
            }
            for i in offsets.indices { offsets[i] = clamp(offsets[i]+shifts[i],-margin,margin) }
        }
        let positions=samples.indices.map {samples[$0].point+samples[$0].right*offsets[$0]}
        var speeds=(0..<count).map { i -> Double in
            let a=positions[(i+count-1)%count], b=positions[i], c=positions[(i+1)%count]
            let ab=b-a, bc=c-b, ac=c-a
            let curvature=2*(ab.x*bc.y-ab.y*bc.x)/max(0.001,simd_length(ab)*simd_length(bc)*simd_length(ac))
            let profile = circuit.roadProfile(at:samples[i].distance,lateral:offsets[i])
            let bankSupport = abs(curvature) > 0.0001 ? copysign(1,curvature)*profile.crossfall*9.81 : 0
            let wetScale = circuit.condition == .wet ?
                clamp(0.89 - 0.14*wetExposure(at:samples[i].distance,offset:offsets[i]),0.72,0.89) : 1
            return min(72,sqrt((6.5+bankSupport)/max(abs(curvature),0.0001))) * wetScale
        }
        // Closed-loop passes propagate braking upstream, including past the
        // finish line. Distance uses the offset path, not just centreline spacing.
        for _ in 0..<3 {
            for i in (0..<count).reversed() {
                let j=(i+1)%count, ds=simd_distance(positions[i],positions[j])
                let grade = circuit.roadProfile(at:samples[i].distance,lateral:offsets[i]).grade
                speeds[i]=min(speeds[i],sqrt(speeds[j]*speeds[j]+2*(6+9.81*grade)*ds))
            }
            for i in 0..<count {
                let j=(i+1)%count, ds=simd_distance(positions[i],positions[j])
                let grade = circuit.roadProfile(at:samples[i].distance,lateral:offsets[i]).grade
                speeds[j]=min(speeds[j],sqrt(speeds[i]*speeds[i]+2*(3-9.81*grade)*ds))
            }
        }
        points=samples.indices.map {Point(progress:samples[$0].distance,position:positions[$0],targetSpeed:speeds[$0])}
    }
    func sample(at progress:Double) -> Point {
        let d=(progress.truncatingRemainder(dividingBy:length)+length).truncatingRemainder(dividingBy:length)
        let index=min(points.count-1,Int(d/spacing)), next=(index+1)%points.count
        let t=clamp((d-points[index].progress)/spacing,0,1), a=points[index], b=points[next]
        return Point(progress:d,position:a.position+(b.position-a.position)*t,targetSpeed:a.targetSpeed+(b.targetSpeed-a.targetSpeed)*t)
    }
    func cue(at progress:Double,speed:Double) -> Cue {
        let target=sample(at:progress).targetSpeed
        if speed>target+2 {return .brake}
        if speed>target*0.88 {return .lift}
        return .accelerate
    }
}

/// Offset lane inside the barrier beside the garages. The same coordinates are used
/// for the pavement, wheel contacts, speed zone and service box.
struct PitLane {
    static let entry = -108.0
    static let limitEntry = -55.0
    static let boxProgress = 43.0
    static let limitExit = 104.0
    static let exit = 154.0
    static let halfWidth = 2.2
    static let speedLimit = 60.0 / 3.6
    let trackLength: Double

    func localProgress(_ progress: Double) -> Double {
        let wrapped = progress.truncatingRemainder(dividingBy: trackLength)
        if wrapped > trackLength/2 { return wrapped-trackLength }
        if wrapped < -trackLength/2 { return wrapped+trackLength }
        return wrapped
    }

    func lateral(at progress: Double) -> Double {
        let p = localProgress(progress)
        let fraction = clamp(min((p-Self.entry)/(Self.limitEntry-Self.entry),
                                 (Self.exit-p)/(Self.exit-Self.limitExit)), 0, 1)
        return -4.1 - 6.5 * fraction*fraction*(3-2*fraction)
    }

    func hasAsphalt(at location: TrackLocation) -> Bool {
        let p = localProgress(location.progress)
        return (Self.entry...Self.exit).contains(p) && abs(location.lateral-lateral(at:p)) <= Self.halfWidth
    }

    func contains(_ location: TrackLocation) -> Bool {
        location.lateral < -6.2 && hasAsphalt(at: location)
    }

    func isLimited(_ location: TrackLocation) -> Bool {
        contains(location) && (Self.limitEntry...Self.limitExit).contains(localProgress(location.progress))
    }

    func metresToSpeedLimit(at location: TrackLocation) -> Double? {
        let progress = localProgress(location.progress)
        guard contains(location),progress < Self.limitEntry else { return nil }
        return Self.limitEntry-progress
    }

    func targetSpeed(at location: TrackLocation) -> Double? {
        guard contains(location) else { return nil }
        let progress = localProgress(location.progress)
        guard progress <= Self.limitExit else { return nil }
        let metres = max(0,Self.limitEntry-progress)
        return sqrt(Self.speedLimit*Self.speedLimit+2*2.7*metres)
    }

    func inServiceBox(_ location: TrackLocation) -> Bool {
        abs(localProgress(location.progress)-Self.boxProgress) < 3.2 &&
            abs(location.lateral-lateral(at:Self.boxProgress)) < 1.05
    }

    func serviceSample(on circuit: Circuit) -> TrackSample {
        let sample = circuit.sample(at:Self.boxProgress)
        return TrackSample(point:sample.point+sample.right*lateral(at:Self.boxProgress),
                           tangent:sample.tangent,distance:sample.distance)
    }
}

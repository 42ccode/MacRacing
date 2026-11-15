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
    var detail: String { ["均衡弯道 · 基础练习", "短直道 · 连续中速弯", "发卡与变向 · 制动练习", "长直道 · 高速弯与减速弯", "高低起伏 · 带横坡高速弯", "连续变向 · 回头弯"][rawValue] }
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

struct WheelRoadContact {
    var distance: Double
    var progress: Double
    var kerbsEnabled: Bool
    var surfaceTemperature = 30.0
    var waterDepth = 0.0 // millimetres
    var elevation = 0.0 // metres, excluding the kerb
    var gradient = SIMD2<Double>.zero // vertical rise per horizontal metre, world X/Z
}

enum TrackCondition: Int, CaseIterable {
    case dry, wet

    var label: String { self == .dry ? "干地" : "湿地" }
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
    private let segments: [Segment]
    private let nearbySegments: [SIMD2<Int>: [Int]]
    private static let bucketSize = 24.0
    let width: Double = 12
    let samples: [TrackSample]
    let length: Double
    let kind: CircuitKind
    let condition: TrackCondition
    var name: String { kind.name }
    var hasElevation: Bool { kind == .ridge }

    /// Continuous surveyed-style profile for the fictional Ridge Ring.
    /// The grid and the full pit entry/exit remain level.
    func roadProfile(at progress: Double, lateral: Double = 0) -> (height: Double, grade: Double, crossfall: Double) {
        guard hasElevation else { return (0,0,0) }
        let t = progress / length - floor(progress / length)
        func window(_ start: Double, _ peak: Double, _ end: Double) -> (value: Double, derivative: Double) {
            guard t > start && t < end else { return (0,0) }
            let rising = t < peak
            let span = rising ? peak - start : end - peak
            let u = rising ? (t - start)/span : (end - t)/span
            return (u*u*u*(10+u*(-15+6*u)), (rising ? 1 : -1) * 30*u*u*(1-u)*(1-u)/span)
        }
        let crest = window(0.087,0.300,0.510), hollow = window(0.45,0.66,0.93)
        let outerTurn = window(0.255,0.300,0.357), farTurn = window(0.515,0.553,0.61)
        let switchback = window(0.641,0.679,0.718)
        let bank = 0.062*outerTurn.value + 0.048*farTurn.value - 0.045*switchback.value
        let bankDerivative = 0.062*outerTurn.derivative + 0.048*farTurn.derivative - 0.045*switchback.derivative
        let u = clamp((abs(lateral)-7)/14,0,1)
        let blend = 1 - u*u*(3-2*u)
        let blendDerivative = -copysign(6*u*(1-u)/14,lateral)
        let shoulder = lateral*blend
        return (21*crest.value - 12*hollow.value + bank*shoulder,
                (21*crest.derivative - 12*hollow.derivative + bankDerivative*shoulder)/length,
                bank*(blend+lateral*blendDerivative))
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

    func wheelContacts(at points: [SIMD2<Double>]) -> [WheelRoadContact] {
        points.map { point in
            let contact = nearest(to: point)
            let profile = roadProfile(at:contact.progress,lateral:contact.lateral)
            let right = SIMD2(contact.tangent.y,-contact.tangent.x)
            let gradient = contact.tangent*profile.grade + right*profile.crossfall
            if pitLane.hasAsphalt(at: contact) {
                return WheelRoadContact(distance:0,progress:contact.progress,kerbsEnabled:false,
                                        surfaceTemperature:surfaceTemperature(at:contact.progress),waterDepth:waterDepth(at:contact.progress,lateral:contact.lateral),
                                        elevation:profile.height,gradient:gradient)
            }
            return WheelRoadContact(distance:contact.distance,progress:contact.progress,
                                    kerbsEnabled:hasKerb(at:contact.progress),surfaceTemperature:surfaceTemperature(at:contact.progress),
                                    waterDepth:waterDepth(at:contact.progress,lateral:contact.lateral),elevation:profile.height,gradient:gradient)
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

    func hasKerb(at distance: Double) -> Bool {
        let a = sample(at: distance - 9).tangent
        let b = sample(at: distance + 9).tangent
        return abs(a.x * b.y - a.y * b.x) > 0.085
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
        let positions=samples.indices.map {samples[$0].point+samples[$0].right*offsets[$0]}
        var speeds=(0..<count).map { i -> Double in
            let a=positions[(i+count-1)%count], b=positions[i], c=positions[(i+1)%count]
            let ab=b-a, bc=c-b, ac=c-a
            let curvature=2*(ab.x*bc.y-ab.y*bc.x)/max(0.001,simd_length(ab)*simd_length(bc)*simd_length(ac))
            let profile = circuit.roadProfile(at:samples[i].distance,lateral:offsets[i])
            let bankSupport = abs(curvature) > 0.0001 ? copysign(1,curvature)*profile.crossfall*9.81 : 0
            let wetScale = circuit.condition == .wet ?
                clamp(0.89 - 0.14*circuit.waterDepth(at:samples[i].distance,lateral:offsets[i]),0.72,0.89) : 1
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

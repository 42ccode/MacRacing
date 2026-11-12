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
    case north, sprint, technical, grand
    var name: String { ["NORTH LOOP", "CLUB SPRINT", "TECHNICAL PARK", "GRAND CIRCUIT"][rawValue] }
    var label: String { ["北环赛道", "俱乐部短环", "技术公园", "大奖赛长环"][rawValue] }
    var detail: String { ["均衡弯道 · 基础练习", "短直道 · 连续中速弯", "发卡与变向 · 制动练习", "长直道 · 高速弯与减速弯"][rawValue] }
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
        }
    }
}

/// A closed, original circuit. World coordinates are metres in the X/Z plane.
final class Circuit {
    let width: Double = 12
    let samples: [TrackSample]
    let length: Double
    let kind: CircuitKind
    var name: String { kind.name }

    init(kind: CircuitKind = .north) {
        self.kind = kind
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
    }

    func nearest(to position: SIMD2<Double>) -> TrackLocation {
        var bestSquared = Double.infinity
        var result = TrackLocation(point: .zero, tangent: [1, 0], progress: 0, lateral: 0, distance: 0, segment: 0)
        for index in samples.indices {
            let a = samples[index]
            let b = samples[(index + 1) % samples.count]
            let delta = b.point - a.point
            let squaredLength = simd_length_squared(delta)
            let t = clamp(simd_dot(position - a.point, delta) / max(squaredLength, 0.0001), 0, 1)
            let closest = a.point + delta * t
            let squaredDistance = simd_length_squared(position - closest)
            if squaredDistance < bestSquared {
                bestSquared = squaredDistance
                let tangent = simd_normalize(delta)
                result = TrackLocation(point: closest, tangent: tangent,
                    progress: a.distance + sqrt(squaredLength) * t,
                    lateral: simd_dot(position - closest, SIMD2(tangent.y, -tangent.x)),
                    distance: sqrt(squaredDistance), segment: index)
            }
        }
        return result
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
}

/// Shared by the contact solver and the visible kerb mesh (metres above asphalt).
func kerbElevation(progress: Double, distanceFromEdge: Double) -> Double {
    let inner = clamp(distanceFromEdge/0.12,0,1)
    let outer = clamp((0.85-distanceFromEdge)/0.15,0,1)
    return (0.030 + 0.012*sin(progress*7))*inner*outer
}

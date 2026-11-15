import Foundation
import simd

@main struct RacingLineChecks {
    static func main() {
        var failed = false
        func check(_ result: Bool, _ name: String) {
            print("\(result ? "PASS" : "FAIL")  \(name)")
            failed = failed || !result
        }
        for kind in CircuitKind.allCases {
            let circuit = Circuit(kind: kind)
            let line = RacingLine(circuit: circuit)
            let extent = stride(from: 0.0, to: circuit.length, by: 1).map {
                circuit.nearest(to: line.sample(at: $0).position).distance
            }.max()!
            check(extent < circuit.width/2 - 1.6, "Guide leaves vehicle-width asphalt clearance on \(kind.label)")
            check(extent > 2.2, "Guide uses road width on \(kind.label)")
            check(simd_distance(line.sample(at: -0.01).position, line.sample(at: 0.01).position) < 0.1,
                  "Guide joins across the finish on \(kind.label)")
            check(line.points.indices.allSatisfy { index in
                let a = line.points[index], b = line.points[(index+1) % line.points.count]
                let distance = simd_distance(a.position, b.position)
                let energyDelta = b.targetSpeed*b.targetSpeed - a.targetSpeed*a.targetSpeed
                let lateral = simd_dot(a.position-circuit.sample(at:a.progress).point,circuit.sample(at:a.progress).right)
                let gravity = 9.81*circuit.roadProfile(at:a.progress,lateral:lateral).grade
                return a.targetSpeed.isFinite && a.targetSpeed > 0 &&
                    energyDelta <= 2*(3-gravity)*distance + 0.01 &&
                    energyDelta >= -2*(6+gravity)*distance - 0.01
            }, "Speed envelope respects acceleration and braking around \(kind.label)")
            let projectionsMatch = stride(from:0.0,to:circuit.length,by:17).allSatisfy { progress in
                let sample = circuit.sample(at:progress)
                return [-120.0,-24,-8,0,8,24,120].allSatisfy { offset in
                    let point = sample.point + sample.right * offset
                    let indexed = circuit.nearest(to:point)
                    let exhaustive = circuit.nearest(to:point,useSpatialIndex:false)
                    return indexed.segment == exhaustive.segment && abs(indexed.progress - exhaustive.progress) < 0.000001
                }
            }
            check(projectionsMatch, "Indexed projection agrees with exhaustive search on \(kind.label)")
        }
        let line = RacingLine(circuit: Circuit())
        let wet = Circuit(condition:.wet)
        let wetLine = RacingLine(circuit:wet)
        check(wet.waterDepth(at:15)>0 && abs(wet.waterDepth(at:-0.01)-wet.waterDepth(at:wet.length-0.01))<0.0001 &&
              wetLine.sample(at:100).targetSpeed < line.sample(at:100).targetSpeed &&
              Circuit().waterDepth(at:15)==0,
              "Wet practice has a continuous water profile and a slower reference line")
        let film = (0..<150).flatMap { i -> [Double] in
            let progress = wet.length * Double(i)/150
            return [-5.0,-2.5,0,2.5,5].map { wet.waterDepth(at:progress,lateral:$0) }
        }
        check((film.min() ?? 0) >= 0.08 && (film.max() ?? 0) > 1.0 &&
              (film.max() ?? 0) <= 1.30 &&
              (0..<150).contains { i in
                  let p = wet.length * Double(i)/150
                  return abs(wet.waterDepth(at:p,lateral:-3)-wet.waterDepth(at:p,lateral:3)) > 0.35
              }, "The authored wet profile contains shallow and deep lanes while remaining bounded")
        let corner = line.points.min { $0.targetSpeed < $1.targetSpeed }!
        check(line.cue(at: corner.progress, speed: corner.targetSpeed*0.6) == .accelerate &&
              line.cue(at: corner.progress, speed: corner.targetSpeed) == .lift &&
              line.cue(at: corner.progress, speed: corner.targetSpeed+5) == .brake,
              "Approach speed changes the cue at the same corner")
        if failed { exit(1) }
    }
}

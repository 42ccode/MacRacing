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
                return a.targetSpeed.isFinite && a.targetSpeed > 0 &&
                    energyDelta <= 6*distance + 0.01 && energyDelta >= -12*distance - 0.01
            }, "Speed envelope respects acceleration and braking around \(kind.label)")
        }
        let line = RacingLine(circuit: Circuit())
        let corner = line.points.min { $0.targetSpeed < $1.targetSpeed }!
        check(line.cue(at: corner.progress, speed: corner.targetSpeed*0.6) == .accelerate &&
              line.cue(at: corner.progress, speed: corner.targetSpeed) == .lift &&
              line.cue(at: corner.progress, speed: corner.targetSpeed+5) == .brake,
              "Approach speed changes the cue at the same corner")
        if failed { exit(1) }
    }
}

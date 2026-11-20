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

            let kerbStations = stride(from:0.0,to:circuit.length,by:0.5).map { progress in
                let left = circuit.kerb(at:progress,side:-1), right = circuit.kerb(at:progress,side:1)
                return (progress,left,right)
            }
            check(kerbStations.allSatisfy { (0...1).contains($0.1.scale) && (0...1).contains($0.2.scale) } &&
                  kerbStations.contains { abs($0.1.scale-$0.2.scale) > 0.75 } &&
                  kerbStations.contains { (0.08...0.35).contains($0.1.scale) || (0.08...0.35).contains($0.2.scale) },
                  "Kerbs vary by approached side and taper from a full kerb to the verge on \(kind.label)")
            let seam = [-1.0,1.0].allSatisfy { side in
                abs(circuit.kerb(at:-0.01,side:side).scale - circuit.kerb(at:circuit.length-0.01,side:side).scale) < 0.000001
            }
            let mergesAreFlush = [PitLane.entry+0.05,PitLane.exit-0.05].allSatisfy { progress in
                let sample = circuit.sample(at:progress)
                let wheel = circuit.wheelContacts(at:[sample.point + sample.right * -6.20])[0]
                return wheel.kerb.scale < 0.00001
            }
            check(seam && mergesAreFlush, "Kerbs wrap cleanly and stay clear of the pit merges on \(kind.label)")

            let wetCircuit = Circuit(kind:kind,condition:.wet)
            let wetGuide = RacingLine(circuit:wetCircuit)
            var dryExposure = 0.0, wetExposure = 0.0, shiftChange = 0.0, clearance = 0.0
            var lastShift = 0.0
            for i in 0...wetGuide.points.count {
                let index = i % wetGuide.points.count
                let point = wetGuide.points[index]
                let centre = wetCircuit.sample(at:point.progress)
                let dryOffset = simd_dot(line.points[index].position-centre.point,centre.right)
                let wetOffset = simd_dot(point.position-centre.point,centre.right)
                func water(at offset: Double) -> Double {
                    let left = wetCircuit.waterDepth(at:point.progress,lateral:offset-0.78)
                    let right = wetCircuit.waterDepth(at:point.progress,lateral:offset+0.78)
                    return 0.35*min(left,right)+0.65*max(left,right)
                }
                let shift = wetOffset-dryOffset
                if i > 0 { shiftChange = max(shiftChange,abs(shift-lastShift)) }
                lastShift = shift
                dryExposure += water(at:dryOffset)
                wetExposure += water(at:wetOffset)
                clearance = max(clearance,abs(wetOffset))
            }
            check(wetExposure < 0.98*dryExposure && shiftChange < 0.25 && clearance < circuit.width/2-1.6,
                  "Wet guide reduces tyre exposure to water with smooth corrections and lane clearance on \(kind.label)")
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

        let valley = Circuit(kind:.valley)
        let crest = valley.roadProfile(at:valley.length*0.305)
        let dip = valley.roadProfile(at:valley.length*0.661)
        let offsets = [0.285,0.401,0.529].map { valley.roadProfile(at:valley.length*$0).crossfall }
        let pitFlat = stride(from:PitLane.entry,through:PitLane.exit,by:2).allSatisfy {
            valley.roadProfile(at:$0,lateral:valley.pitLane.lateral(at:$0)).height == 0
        }
        let slopeMatches = stride(from:0.0,to:valley.length,by:1.7).allSatisfy { progress in
            let analytic = valley.roadProfile(at:progress,lateral:4).grade
            let ahead = valley.roadProfile(at:progress+0.01,lateral:4).height
            let behind = valley.roadProfile(at:progress-0.01,lateral:4).height
            return abs(analytic-(ahead-behind)/0.02) < 0.0001 && abs(analytic) < 0.06
        }
        check(pitFlat && slopeMatches && abs(crest.height-7.4) < 0.001 && abs(dip.height+5.1) < 0.001 &&
              offsets[0] > 0.036 && offsets[1] < -0.052 && offsets[2] > 0.044,
              "Valley Circuit has linked grades and opposite camber through the switchbacks, with flat pits")
        let corner = line.points.min { $0.targetSpeed < $1.targetSpeed }!
        check(line.cue(at: corner.progress, speed: corner.targetSpeed*0.6) == .accelerate &&
              line.cue(at: corner.progress, speed: corner.targetSpeed) == .lift &&
              line.cue(at: corner.progress, speed: corner.targetSpeed+5) == .brake,
              "Approach speed changes the cue at the same corner")
        if failed { exit(1) }
    }
}

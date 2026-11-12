import Foundation

struct InputHistory {
    struct Sample {
        let time: Double
        let throttle: Double
        let brake: Double
        let absActive: Bool
    }
    static let duration = 5.0
    private(set) var time = 0.0
    private(set) var samples: [Sample] = []

    mutating func reset() { time=0; samples.removeAll(keepingCapacity:true) }

    mutating func update(input: DrivingInput, absActive: Bool, dt: Double, active: Bool) {
        guard active, dt.isFinite, dt>0 else { return }
        time += min(dt,0.1)
        func valid(_ value: Double) -> Double { value.isFinite ? clamp(value,0,1) : 0 }
        samples.append(Sample(time:time,throttle:valid(input.throttle),brake:valid(input.brake),absActive:absActive))
        let cutoff=time-Self.duration
        // Keep the sample just before the left edge for continuous clipping.
        var remove=0
        while remove+1<samples.count && samples[remove+1].time<cutoff { remove += 1 }
        remove=max(remove,samples.count-602)
        if remove>0 { samples.removeFirst(remove) }
    }
}

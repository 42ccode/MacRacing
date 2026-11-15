import Foundation

struct ControllerCalibration {
    static func steering(_ raw: Double, deadzone: Double) -> Double {
        guard raw.isFinite else { return 0 }
        let deadzone = deadzone.isFinite ? clamp(deadzone,0.02,0.30) : 0.08
        let travel = clamp((abs(raw) - deadzone) / (1 - deadzone),0,1)
        let edge = 0.075
        let eased = travel < edge ? travel * (travel/edge) * (2-travel/edge) : travel
        return copysign(eased,raw)
    }
}

/// Converts on/off pedals to repeatable taps. Gamepad values bypass it.
struct KeyboardPedals {
    private(set) var throttle = 0.0
    private(set) var brake = 0.0

    mutating func update(throttle pressedThrottle: Bool, brake pressedBrake: Bool, dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        let step = min(dt,0.067)
        Self.advance(&throttle,pressed:pressedThrottle && !pressedBrake,step:step,attack:4.6,release:12)
        Self.advance(&brake,pressed:pressedBrake,step:step,attack:7.5,release:19)
    }

    private static func advance(_ value: inout Double,pressed: Bool,step: Double,attack: Double,release: Double) {
        value = pressed ? min(1,value+step*attack) : max(0,value-step*release)
    }
}

/// Advances physics through timestamped input. When a poll is late, keep the
/// previous command for overdue steps and blend over one normal poll interval.
struct DrivingStepClock {
    let step = 1.0/240
    let inputInterval = 1.0/120
    private(set) var remainder = 0.0
    private var previous = DrivingInput()

    mutating func reset() {
        remainder = 0
        previous = DrivingInput()
    }

    mutating func advance(seconds: Double, to input: DrivingInput) -> Batch {
        let elapsed = seconds.isFinite ? clamp(seconds,0,1.0/15) : 0
        let total = remainder+elapsed
        let count = Int((total/step+1e-9).rounded(.down))
        let result = Batch(count:count,step:step,firstEnd:step-remainder,elapsed:elapsed,
                           blendDuration:min(elapsed,inputInterval),before:previous,after:input)
        remainder = max(0,total-Double(count)*step)
        if elapsed > 0 { previous = input }
        return result
    }

    struct Batch {
        let count: Int
        fileprivate let step: Double
        fileprivate let firstEnd: Double
        fileprivate let elapsed: Double
        fileprivate let blendDuration: Double
        fileprivate let before: DrivingInput
        fileprivate let after: DrivingInput

        subscript(index: Int) -> DrivingInput {
            let endpoint = firstEnd + Double(index)*step
            let share = clamp(1-(elapsed-endpoint)/max(blendDuration,1e-9),0,1)
            if share == 0 { return before }
            if share == 1 { return after }
            return DrivingInput(throttle:before.throttle+(after.throttle-before.throttle)*share,
                                brake:before.brake+(after.brake-before.brake)*share,
                                steering:before.steering+(after.steering-before.steering)*share)
        }
    }
}

/// Tracks what the app actually receives. Poll intervals describe the game
/// loop; value changes are observations, not Bluetooth report timestamps.
struct ControllerSamples {
    struct Reading {
        let time: Double
        let raw: DrivingInput
        let mappedSteering: Double
    }
    private(set) var reading: Reading?
    private(set) var samples: [Reading] = []
    private(set) var intervals: [Double] = []
    private(set) var distinctChanges = 0
    private var lastChangedTime: Double?

    mutating func reset() { self = ControllerSamples() }
    mutating func update(raw: DrivingInput, deadzone: Double, at time: Double) {
        guard time.isFinite, reading.map({ time > $0.time }) ?? true else { return }
        func valid(_ value: Double, range: ClosedRange<Double>) -> Double {
            value.isFinite ? clamp(value,range.lowerBound,range.upperBound) : 0
        }
        let clean = DrivingInput(throttle:valid(raw.throttle,range:0...1),brake:valid(raw.brake,range:0...1),
                                 steering:valid(raw.steering,range:-1...1))
        let current = Reading(time:time,raw:clean,mappedSteering:ControllerCalibration.steering(clean.steering,deadzone:deadzone))
        if let previous = reading {
            intervals.append(time-previous.time)
            if intervals.count > 240 { intervals.removeFirst(intervals.count-240) }
            let change = max(abs(clean.throttle-previous.raw.throttle),abs(clean.brake-previous.raw.brake),
                             abs(clean.steering-previous.raw.steering))
            if change >= 0.0001 { distinctChanges += 1; lastChangedTime = time }
        }
        reading = current
        samples.append(current)
        let cutoff = time-2.5
        var remove = 0
        while remove + 1 < samples.count && samples[remove+1].time < cutoff { remove += 1 }
        remove = max(remove,samples.count-320)
        if remove > 0 { samples.removeFirst(remove) }
    }
    var pollHz: Double? {
        guard intervals.count >= 12 else { return nil }
        let total = intervals.reduce(0,+)
        return total > 0 ? Double(intervals.count)/total : nil
    }
    var p95Milliseconds: Double? {
        guard intervals.count >= 12 else { return nil }
        let ordered = intervals.sorted()
        return ordered[Int(Double(ordered.count-1)*0.95)] * 1000
    }
    var isChanging: Bool {
        guard let reading, let lastChangedTime else { return false }
        return reading.time-lastChangedTime < 0.3
    }
}

struct InputHistory {
    struct Sample {
        let time: Double
        let throttle: Double
        let brake: Double
        let linePressure: Double
        let absActive: Bool
    }
    static let duration = 5.0
    private(set) var time = 0.0
    private(set) var samples: [Sample] = []

    mutating func reset() { time=0; samples.removeAll(keepingCapacity:true) }

    mutating func update(input: DrivingInput, absActive: Bool, dt: Double, active: Bool, linePressure: Double = 0) {
        guard active, dt.isFinite, dt>0 else { return }
        time += min(dt,0.1)
        func valid(_ value: Double) -> Double { value.isFinite ? clamp(value,0,1) : 0 }
        samples.append(Sample(time:time,throttle:valid(input.throttle),brake:valid(input.brake),
                              linePressure:valid(linePressure),absActive:absActive))
        let cutoff=time-Self.duration
        // Keep the sample just before the left edge for continuous clipping.
        var remove=0
        while remove+1<samples.count && samples[remove+1].time<cutoff { remove += 1 }
        remove=max(remove,samples.count-602)
        if remove>0 { samples.removeFirst(remove) }
    }
}

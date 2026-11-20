import Foundation

struct UpdateCadence {
    private var deadline = 0.0

    mutating func take(at timestamp: Double, interval: Double, forced: Bool = false) -> Bool {
        guard forced || timestamp+0.0004 >= deadline else { return false }
        if forced || deadline == 0 || timestamp-deadline > interval {
            deadline = timestamp+interval
        } else {
            deadline += interval
        }
        return true
    }
}

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

// Integral of a constant-rate key ramp, including any time spent against its stop.
private func keyRamp(_ value: inout Double,toward target: Double,rate: Double,duration: Double) -> Double {
    let timeToTarget = abs(target-value)/rate
    let moving = min(duration,timeToTarget)
    let previous = value
    value = timeToTarget <= duration ? target : value+copysign(rate*moving,target-value)
    return (previous+value)*0.5*moving + value*(duration-moving)
}

/// Converts on/off pedals to repeatable taps. Gamepad values bypass it.
struct KeyboardPedals {
    private(set) var throttle = 0.0
    private(set) var brake = 0.0

    @discardableResult
    mutating func update(throttle pressedThrottle: Bool, brake pressedBrake: Bool, dt: Double) -> DrivingInput {
        guard dt.isFinite, dt > 0 else { return DrivingInput() }
        let duration = min(dt,0.067)
        let gas = pressedThrottle && !pressedBrake
        let throttleArea = keyRamp(&throttle,toward:gas ? 1 : 0,rate:gas ? 4.6 : 12,duration:duration)
        let brakeArea = keyRamp(&brake,toward:pressedBrake ? 1 : 0,rate:pressedBrake ? 7.5 : 19,duration:duration)
        return DrivingInput(throttle:throttleArea/duration,brake:brakeArea/duration)
    }
}

/// A digital steering key moves through wheel travel. Reversals release the
/// old lock quickly as far as centre, then take up lock in the new direction.
struct KeyboardSteering {
    private(set) var value = 0.0

    @discardableResult
    mutating func update(left: Bool,right: Bool,dt: Double) -> Double {
        guard dt.isFinite, dt > 0 else { return 0 }
        let duration = min(dt,0.067)
        let direction = (right ? 1.0 : 0) - (left ? 1.0 : 0)
        if direction == 0 {
            return keyRamp(&value,toward:0,rate:8,duration:duration)/duration
        }
        let centringTime = value*direction < 0 ? min(duration,abs(value)/12) : 0
        let centring = keyRamp(&value,toward:0,rate:12,duration:centringTime)
        let turning = keyRamp(&value,toward:direction,rate:4.4,duration:duration-centringTime)
        return (centring+turning)/duration
    }
}

/// Applies AppKit key transitions on the simulation's monotonic time axis.
struct KeyboardDrivingTimeline {
    private struct Event {
        let key: UInt16
        let pressed: Bool
        let time: Double
        let originalTime: Double
    }

    private var held: Set<UInt16> = []
    private var events: [Event] = []
    private var through: Double?
    private var pedals = KeyboardPedals()
    private var steering = KeyboardSteering()

    static func isDrivingKey(_ key: UInt16) -> Bool {
        switch key {
        case 0,1,2,13,49,123,124,125,126: return true
        default: return false
        }
    }

    var hasPendingPress: Bool { events.contains { $0.pressed } }

    mutating func record(_ key: UInt16,pressed: Bool,at timestamp: Double) {
        guard Self.isDrivingKey(key), timestamp.isFinite else { return }
        var time = max(timestamp,through ?? timestamp)
        if !pressed, let down = events.last(where: { $0.key == key && $0.pressed }) {
            // Events delivered after their physical step still get a small pulse.
            let duration = clamp(timestamp-down.originalTime,0,1/Double(DrivingStepClock.drivingRate))
            time = max(time,down.time+duration)
        }
        let event = Event(key:key,pressed:pressed,time:time,originalTime:timestamp)
        let index = events.firstIndex { $0.time > time } ?? events.endIndex
        events.insert(event,at:index)
    }

    mutating func rebase(at timestamp: Double,holding keys: Set<UInt16>) {
        self = Self()
        through = timestamp
        held = Set(keys.filter(Self.isDrivingKey))
    }

    func current(over analog: DrivingInput) -> DrivingInput {
        merged(analog,pedals.brake,pedals.throttle,steering.value,
               steers:held.contains(0) || held.contains(123) || held.contains(2) || held.contains(124))
    }

    mutating func sample(over analog: DrivingInput,ending end: Double,step: Double) -> DrivingInput {
        let start = max(end-step,through ?? end-step)
        guard end > start else { return current(over:analog) }
        through = end
        if events.isEmpty && held.isEmpty && pedals.brake == 0 && pedals.throttle == 0 && steering.value == 0 {
            return analog
        }
        var cursor = start, brake = 0.0, throttle = 0.0, turn = 0.0
        var steers = false
        var consumed = 0
        while consumed < events.count && events[consumed].time <= end {
            let event = events[consumed]
            advance(to:max(cursor,event.time))
            if event.pressed { held.insert(event.key) } else { held.remove(event.key) }
            consumed += 1
        }
        if consumed > 0 { events.removeFirst(consumed) }
        advance(to:end)
        let duration = end-start
        return merged(analog,brake/duration,throttle/duration,turn/duration,steers:steers)

        func advance(to time: Double) {
            let interval = time-cursor
            guard interval > 0 else { return }
            let left = held.contains(0) || held.contains(123)
            let right = held.contains(2) || held.contains(124)
            steers = steers || left || right
            let average = pedals.update(throttle:held.contains(13) || held.contains(126),
                                        brake:held.contains(1) || held.contains(125) || held.contains(49),dt:interval)
            brake += average.brake*interval
            throttle += average.throttle*interval
            turn += steering.update(left:left,right:right,dt:interval)*interval
            cursor = time
        }
    }

    private func merged(_ analog: DrivingInput,_ brake: Double,_ throttle: Double,_ turn: Double,steers: Bool) -> DrivingInput {
        DrivingInput(throttle:max(analog.throttle,throttle),brake:max(analog.brake,brake),
                     steering:steers || analog.steering == 0 ? turn : analog.steering)
    }
}

/// Advances physics through timestamped input. When a poll is late, keep the
/// previous command for overdue steps and blend over one normal poll interval.
struct DrivingStepClock {
    static let drivingRate = 240
    let step = 1.0/Double(DrivingStepClock.drivingRate)
    let inputInterval = 1.0/120
    private static let maximumCatchUpSteps = 24
    private static let suspensionGap = 0.5
    private var lastSampleTime: Double?
    private var hasCompletedStep = false
    private(set) var remainder = 0.0
    // Keep the latest pose visible until the rebased clock has advanced.
    var displayRemainder: Double { hasCompletedStep ? remainder : inputInterval }
    private var previous = DrivingInput()

    mutating func reset() {
        remainder = 0
        lastSampleTime = nil
        hasCompletedStep = false
        previous = DrivingInput()
    }

    mutating func advance(at timestamp: Double, to input: DrivingInput) -> Batch {
        guard timestamp.isFinite, lastSampleTime.map({ timestamp > $0 }) ?? true else {
            return Batch(count:0,step:step,firstEnd:0,elapsed:0,blendDuration:0,before:previous,after:previous)
        }
        let gap = lastSampleTime.map { timestamp-$0 } ?? 0
        lastSampleTime = timestamp
        // A resumed or suspended loop begins with a fresh input observation.
        if gap == 0 || gap >= Self.suspensionGap {
            remainder = 0
            hasCompletedStep = false
            previous = input
        }
        let elapsed = gap < Self.suspensionGap ? min(gap,Double(Self.maximumCatchUpSteps)*step) : 0
        let total = remainder+elapsed
        let count = min(Self.maximumCatchUpSteps,Int((total/step+1e-9).rounded(.down)))
        let result = Batch(count:count,step:step,firstEnd:step-remainder,elapsed:elapsed,
                           blendDuration:min(elapsed,inputInterval),before:previous,after:input)
        remainder = max(0,total-Double(count)*step)
        if count > 0 { hasCompletedStep = true }
        if elapsed > 0 { previous = input }
        return result
    }

    struct Batch {
        let count: Int
        fileprivate let step: Double
        fileprivate let firstEnd: Double
        let elapsed: Double
        fileprivate let blendDuration: Double
        fileprivate let before: DrivingInput
        fileprivate let after: DrivingInput

        func stepEnd(_ index: Int,at timestamp: Double) -> Double {
            timestamp - elapsed + firstEnd + Double(index)*step
        }

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

/// Tracks what the app actually receives, with separate timing for the game
/// loop and macOS input change events visible to that loop.
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
    private var lastSystemEvent: Double?
    private var systemEventIntervals: [Double] = []

    mutating func reset() { self = ControllerSamples() }
    mutating func update(raw: DrivingInput, deadzone: Double, at time: Double, systemEvent: Double? = nil) {
        guard time.isFinite, reading.map({ time > $0.time }) ?? true else { return }
        if let systemEvent { observeSystemEvent(at:systemEvent) }
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
    private mutating func observeSystemEvent(at timestamp: Double) {
        guard timestamp.isFinite, timestamp > 0 else { return }
        if let previous = lastSystemEvent {
            let gap = timestamp-previous
            guard gap > 0 else { return }
            if gap > 0.2 { systemEventIntervals.removeAll(keepingCapacity:true) }
            else {
                systemEventIntervals.append(gap)
                if systemEventIntervals.count > 120 { systemEventIntervals.removeFirst() }
            }
        }
        lastSystemEvent = timestamp
    }
    var systemEventMedianMilliseconds: Double? {
        guard systemEventIntervals.count >= 12 else { return nil }
        let ordered = systemEventIntervals.sorted()
        let middle = ordered.count / 2
        let median = ordered.count.isMultiple(of:2) ? (ordered[middle-1]+ordered[middle])/2 : ordered[middle]
        return median * 1000
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
    static let capacity = Int(duration)*DrivingStepClock.drivingRate+2
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
        remove=max(remove,samples.count-Self.capacity)
        if remove>0 { samples.removeFirst(remove) }
    }
}

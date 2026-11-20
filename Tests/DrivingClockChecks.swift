import Foundation

@main struct DrivingClockChecks {
    static var failures = 0

    static func check(_ condition: Bool,_ description: String) {
        print("\(condition ? "PASS" : "FAIL")  \(description)")
        if !condition { failures += 1 }
    }

    static func main() {
        checkNormalCadence()
        checkLateInput()
        checkBoundedCatchUp()
        checkSuspension()
        checkReset()
        checkInvalidStamps()
        checkSamplingCadences()
        checkShortKeyboardTap()
        if failures > 0 { exit(1) }
    }

    static func checkNormalCadence() {
        for rate in [30,60,120,240] {
            var clock = DrivingStepClock()
            let start = 50_000.0
            let seed = clock.advance(at:start,to:DrivingInput())
            let frames = (1...rate).map { index in
                clock.advance(at:start+Double(index)/Double(rate),to:DrivingInput(throttle:1))
            }
            let physicsSteps = frames.reduce(0) { $0+$1.count }
            let elapsed = frames.reduce(0) { $0+$1.elapsed }
            check(seed.count == 0 && physicsSteps == 240 && abs(elapsed-1) < 1e-8 && clock.remainder < 1e-8,
                  "\(rate) Hz produces one second of 240 Hz physics and input history")
        }
        var clock = DrivingStepClock()
        _ = clock.advance(at:0,to:DrivingInput())
        let input = clock.advance(at:1.0/120,to:DrivingInput(throttle:1,brake:0.25,steering:-0.6))
        check(input.count == 2 && input[0].throttle == 0.5 && input[0].brake == 0.125 && input[0].steering == -0.3 &&
              input[1].throttle == 1 && input[1].brake == 0.25 && input[1].steering == -0.6,
              "Ordinary polls retain the previous interpolation of pedals and steering")
    }

    static func checkLateInput() {
        var clock = DrivingStepClock()
        _ = clock.advance(at:0,to:DrivingInput())
        let partial = clock.advance(at:0.004,to:DrivingInput())
        let delayed = clock.advance(at:0.054,to:DrivingInput(brake:1,steering:-1))
        check(partial.count == 0 && delayed.count == 12 &&
              (0..<9).allSatisfy { delayed[$0].brake == 0 && delayed[$0].steering == 0 } &&
              (0.51...0.53).contains(delayed[11].brake) && (-0.53 ... -0.51).contains(delayed[11].steering) &&
              abs(clock.remainder-0.004) < 1e-8,
              "A partial step before a delay preserves the original blend and timestamp fraction")
        clock.reset()
        _ = clock.advance(at:0,to:DrivingInput(throttle:1))
        let batch = clock.advance(at:0.095,to:DrivingInput(brake:1,steering:-1))
        let overdueCommand = batch.count >= 20 && (0..<20).allSatisfy {
            batch[$0].throttle == 1 && batch[$0].brake == 0 && batch[$0].steering == 0
        }
        check(batch.count == 22 && abs(batch.elapsed-0.095) < 1e-9 && overdueCommand &&
              abs(batch[20].brake-0.1) < 1e-9 && abs(batch[21].brake-0.6) < 1e-9 &&
              abs(batch[21].steering+0.6) < 1e-9 && abs(batch[21].throttle-0.4) < 1e-9,
              "A 95 ms hitch recovers its physics interval without applying the observed brake or steering early")
        let following = clock.advance(at:0.095+1.0/120,to:DrivingInput(brake:1))
        check(following.count == 2 && following[0].brake == 1 && following[1].brake == 1 && clock.remainder < clock.step,
              "The first ordinary poll after a hitch stays current with no overdue whole steps")
    }

    static func checkBoundedCatchUp() {
        var clock = DrivingStepClock()
        _ = clock.advance(at:0,to:DrivingInput())
        let delayed = clock.advance(at:0.19,to:DrivingInput())
        let ordinary = clock.advance(at:0.19+1.0/120,to:DrivingInput())
        check(delayed.count == 24 && delayed.elapsed == 0.1 && ordinary.count == 2,
              "A 190 ms late frame runs at most 24 fixed steps and carries no whole-step debt")
        _ = clock.advance(at:0.20,to:DrivingInput())
        let validFraction = clock.remainder
        let persistentLoad = (1...400).map { tick in
            clock.advance(at:0.2+Double(tick)*0.125,to:DrivingInput())
        }
        check(persistentLoad.allSatisfy { $0.count == 24 && $0.elapsed == 0.1 } &&
              abs(clock.remainder-validFraction) < 1e-9,
              "Sustained 8 Hz remains at a bounded workload and preserves only the fractional step")

        clock.reset()
        _ = clock.advance(at:0,to:DrivingInput())
        let justBeforeStep = 0.004166666662499993
        let partial = clock.advance(at:justBeforeStep,to:DrivingInput())
        let full = clock.advance(at:justBeforeStep+0.1,to:DrivingInput())
        check(partial.count == 0 && full.count == 24 && clock.remainder < clock.step,
              "Floating-point tolerance cannot issue a 25th step at the catch-up boundary")
    }

    static func checkSuspension() {
        var clock = DrivingStepClock()
        _ = clock.advance(at:0,to:DrivingInput(throttle:1))
        _ = clock.advance(at:0.009,to:DrivingInput(throttle:1))
        let resumed = clock.advance(at:2.009,to:DrivingInput(brake:0.72))
        let currentPose = clock.displayRemainder >= clock.inputInterval
        let renderOnly = clock.advance(at:2.010,to:DrivingInput(brake:0.72))
        let waitingPose = clock.displayRemainder >= clock.inputInterval
        let next = clock.advance(at:2.0135,to:DrivingInput(brake:0.72))
        check(resumed.count == 0 && resumed.elapsed == 0 && currentPose && renderOnly.count == 0 && waitingPose &&
              next.count == 1 && next[0].throttle == 0 && next[0].brake == 0.72 && clock.displayRemainder == clock.remainder,
              "A suspended loop holds the current pose until a fresh step and never replays old throttle")
    }

    static func checkReset() {
        var clock = DrivingStepClock()
        _ = clock.advance(at:10,to:DrivingInput())
        _ = clock.advance(at:10.007,to:DrivingInput(throttle:1,steering:1))
        clock.reset()
        let resume = clock.advance(at:10.145,to:DrivingInput())
        let steps = clock.advance(at:10.145+1.0/120,to:DrivingInput())
        check(resume.count == 0 && resume.elapsed == 0 && steps.count == 2 &&
              steps[0].throttle == 0 && steps[1].steering == 0 && clock.remainder < 1e-8,
              "Explicit pause or focus rebases even a short interruption and clears former input")
    }

    static func checkInvalidStamps() {
        var clock = DrivingStepClock()
        _ = clock.advance(at:10,to:DrivingInput(brake:0.25))
        let invalid = [Double.nan,.infinity,-.infinity,9,10].map { timestamp in
            clock.advance(at:timestamp,to:DrivingInput(throttle:1,steering:0.9))
        }
        let next = clock.advance(at:10+1.0/120,to:DrivingInput(brake:0.25))
        check(invalid.allSatisfy { $0.count == 0 && $0.elapsed == 0 } &&
              next.count == 2 && next[0].brake == 0.25 && next[1].throttle == 0,
              "Invalid, stale and duplicate observations cannot deliver controls or move the clock")
    }

    static func checkSamplingCadences() {
        var display60 = UpdateCadence(), display120 = UpdateCadence(), graph = InputHistory()
        var frames60 = 0, frames120 = 0
        let interval = 1.0/Double(DrivingStepClock.drivingRate)
        for tick in 0..<(6*DrivingStepClock.drivingRate) {
            let now = 50_000+Double(tick)*interval
            if display60.take(at:now,interval:1/60) { frames60 += 1 }
            if display120.take(at:now,interval:1/120) { frames120 += 1 }
            graph.update(input:DrivingInput(),absActive:false,dt:interval,active:true)
        }
        check(frames60 == 360 && frames120 == 720,"240 Hz input keeps separate 60 Hz and 120 Hz presentation work")
        check(graph.samples.count <= InputHistory.capacity && abs((graph.samples.first?.time ?? 0)-1) < 0.01,
              "At 240 Hz the input graph retains its full five-second history")
    }

    static func checkShortKeyboardTap() {
        let step = 1.0/240
        var keys = KeyboardDrivingTimeline()
        keys.rebase(at:0,holding:[])
        for key: UInt16 in [2,49] {
            keys.record(key,pressed:true,at:0.001)
            keys.record(key,pressed:false,at:0.002)
        }
        let short = keys.sample(over:DrivingInput(),ending:step,step:step)
        let released = keys.sample(over:DrivingInput(),ending:step*2,step:step)
        check(short.brake > 0 && short.brake < 0.004 && short.steering > 0 && short.steering < 0.004 &&
              released.brake == 0 && released.steering == 0,
              "A sub-step brake and steering tap contributes only its measured travel")
        keys.record(2,pressed:true,at:0.001)
        keys.record(2,pressed:false,at:0.002)
        let deliveredLate = keys.sample(over:DrivingInput(),ending:step*3,step:step)
        keys.rebase(at:step*4,holding:[])
        let afterReset = keys.sample(over:DrivingInput(),ending:step*5,step:step)
        check(abs(deliveredLate.steering-short.steering) < 1e-9 && afterReset.steering == 0,
              "A late tap keeps its duration once, and focus rebasing clears earlier keys")
        keys.record(0,pressed:true,at:step*5)
        keys.record(123,pressed:true,at:step*5)
        _ = keys.sample(over:DrivingInput(),ending:step*6,step:step)
        keys.record(0,pressed:false,at:step*6)
        let alias = keys.sample(over:DrivingInput(),ending:step*7,step:step)
        check(alias.steering < -0.02,"Releasing one left steering key leaves its held alias driving")
        for kind in VehicleKind.allCases {
            func run(stall: Bool) -> (peak: Double, input: [Double]) {
                var clock = DrivingStepClock(), keyboard = KeyboardDrivingTimeline(), vehicle = Vehicle()
                keyboard.rebase(at:0,holding:[])
                _ = clock.advance(at:0,to:DrivingInput())
                vehicle.kind = kind
                vehicle.reset(at:Circuit(kind:.north).start)
                vehicle.velocity = vehicle.forward*(100/3.6)
                for index in vehicle.wheels.indices { vehicle.wheels[index].angularVelocity = vehicle.speed/vehicle.wheelRadius }
                var assists = DrivingAssists(abs:false,tractionControl:false)
                assists.steeringCurve = .precision
                let events: [(Double,Bool,UInt16)] = [(0.505,true,2),(0.525,false,2)]
                var next = 0, samples: [Double] = [], peak = 0.0
                for tick in 1...240 {
                    if stall && (121..<132).contains(tick) { continue }
                    let now = Double(tick)*step
                    while next < events.count && events[next].0 <= now {
                        let event = events[next]
                        keyboard.record(event.2,pressed:event.1,at:event.0)
                        next += 1
                    }
                    let batch = clock.advance(at:now,to:DrivingInput())
                    for index in 0..<batch.count {
                        let input = keyboard.sample(over:batch[index],ending:batch.stepEnd(index,at:now),step:step)
                        vehicle.step(step,input:input,assists:assists,roadDistance:0,roadWidth:12)
                        peak = max(peak,abs(vehicle.steeringAngle)*180 / .pi)
                        samples.append(input.steering)
                    }
                }
                return (peak,samples)
            }
            let normal = run(stall:false), late = run(stall:true)
            check(normal.input.count == 240 && late.input.count == 240 && late.peak > 0.015 && late.peak < 0.05 &&
                  abs(normal.peak-late.peak) < 1e-9 && zip(normal.input,late.input).allSatisfy { abs($0-$1) < 1e-9 },
                  String(format:"20ms keyboard tap at 100 km/h yields the same %.4f° rack angle through a 50ms late poll: %@",late.peak,kind.label))
        }
    }
}

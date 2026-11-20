import Foundation
import simd

@main struct DrivingLessonChecks {
    static var failures = 0
    static let step = 1.0/240

    enum Replay: Equatable {
        case practice, overshoot, stopBeforeBox, brakeBeforeTurning, trailReapply, coast, fullThrottleBeforeExit, noSteering
        case measuredWheelSlip(normalLoad: Double)
        case slowTaper, snapRelease, blendedSnap, heldBrake, noisyBrakeHold, neverBrake, taperReapply, taperWithHeldSample
    }

    static func check(_ condition: Bool,_ message: String) {
        print("\(condition ? "PASS" : "FAIL")  \(message)")
        if !condition { failures += 1 }
    }

    static func run(_ kind: DrivingLessonKind,keyboard: Bool = false,replay: Replay = .practice)
        -> (run: DrivingLessonRun,vehicle: Vehicle,circuit: Circuit,location: TrackLocation) {
        let circuit = Circuit(kind:kind.circuitKind,condition:kind.condition)
        let assists = kind.assists
        var driver = DrivingLessonRun(kind:kind)
        var vehicle = Vehicle()
        check(driver.prepare(&vehicle,circuit:circuit),"Loads the current lesson vehicle and layout: \(kind.title)")
        var location = circuit.nearest(to:vehicle.position)
        var pedals = KeyboardPedals()
        var keySteering = 0.0
        var keyFrames = 0
        var lastBrake = 0.0
        for tick in 0..<6000 where driver.result == nil {
            let station = location.progress
            let target = circuit.sample(at:station+clamp(5+vehicle.speed*0.41,5,17)).point
            let vector = target-vehicle.position
            let right = -simd_dot(vector,vehicle.modelX)
            let wheelAngle = atan(2*vehicle.wheelbase*right/max(1,simd_length_squared(vector)))
            let steer = replay == .noSteering ? 0 : clamp((wheelAngle+vehicle.yawRate*0.07)/vehicle.steeringLimit,-1,1)
            let gas: Double
            let brake: Double
            switch kind {
            case .braking:
                let mark = kind.firstCoachingMark ?? kind.startProgress
                let launch = station < (replay == .stopBeforeBox ? mark-10 : mark) || replay == .overshoot
                gas = launch ? 1 : 0
                brake = launch ? 0 : 1
            case .trailBraking:
                let reapply = replay == .trailReapply && (268..<275).contains(station)
                gas = station >= 270 && !reapply ? 0.38 : 0
                if replay == .slowTaper || replay == .taperReapply || replay == .taperWithHeldSample {
                    let easing = 0.51*clamp((258-station)/24,0,1)
                    let hold = replay == .taperWithHeldSample && tick.isMultiple(of:31)
                    let reapply = replay == .taperReapply && (242..<244).contains(station)
                    brake = reapply ? 0.49 : hold ? lastBrake : easing
                } else if replay == .snapRelease {
                    brake = station < 247 ? 0.43 : 0
                } else if replay == .blendedSnap {
                    brake = 0.43*clamp((247.16-station)/0.16,0,1)
                } else if replay == .heldBrake {
                    brake = 0.32
                } else if replay == .noisyBrakeHold {
                    brake = 0.32+0.002*sin(Double(tick)*0.6)
                } else if replay == .neverBrake {
                    brake = 0
                } else if replay == .brakeBeforeTurning {
                    brake = station < 224 ? 0.67 : 0
                } else {
                    brake = reapply ? 0.31 : station < 229 ? 0.51 : station < 245 ? 0.35 : station < 258 ? 0.16 : 0
                }
            case .wetExit:
                brake = 0
                if replay == .coast { gas = 0 }
                else if replay == .fullThrottleBeforeExit { gas = station < 397 ? 1 : 0.58 }
                else { gas = station < 388 ? 0.10 : station < 410 ? 0.27 : 0.56 }
            }
            lastBrake = brake
            let input: DrivingInput
            if keyboard {
                var throttleKey = gas > 0.4 || (gas > 0 && tick % 60 < Int(gas*80))
                var brakeKey = brake > 0.6
                if kind == .trailBraking {
                    throttleKey = station > 272
                    brakeKey = station < 219 || ((227...251).contains(station) && tick % 68 < 22)
                }
                pedals.update(throttle:throttleKey,brake:brakeKey,dt:step)
                // Model separate 42 ms key taps, with time to observe each
                // correction before the next key press.
                if tick.isMultiple(of:24) && keyFrames <= 0 && abs(steer) > 0.038 {
                    keySteering = copysign(1,steer)
                    keyFrames = 10
                }
                input = DrivingInput(throttle:pedals.throttle,brake:pedals.brake,steering:keyFrames > 0 ? keySteering : 0)
                keyFrames -= 1
            } else {
                var low = 0.0, high = 1.0
                for _ in 0..<10 {
                    let middle = (low+high)/2
                    if Vehicle.steeringResponse(middle,curve:assists.steeringCurve) < abs(steer) { low = middle }
                    else { high = middle }
                }
                input = DrivingInput(throttle:gas,brake:brake,steering:copysign((low+high)/2,steer))
            }
            vehicle.step(step,input:input,assists:assists,roadDistance:location.distance,roadWidth:circuit.width,
                         roadContacts:circuit.wheelContacts(at:vehicle.contactPoints))
            location = circuit.nearest(to:vehicle.position)
            var observed = vehicle
            if case .measuredWheelSlip(let load) = replay,(404...430).contains(location.progress) {
                // Feed a controlled wheel measurement to the coach while
                // retaining the same real vehicle trajectory and wheel dynamics.
                observed.wheels[2].normalLoad = load
                observed.wheels[2].slipRatio = 0.27
            }
            driver.step(step,vehicle:observed,input:input,location:location,circuit:circuit)
        }
        return (driver,vehicle,circuit,location)
    }

    static func main() {
        func medal(_ result: DrivingLessonOutcome?) -> DrivingLessonMedal? {
            if case .passed(let medal) = result { return medal }
            return nil
        }
        check(Set(DrivingLessonKind.allCases.map(\.vehicleKind)) == Set([.porsche,.centenario]),
              "Academy driving exercises cover both available cars")
        for kind in DrivingLessonKind.allCases {
            let analog = run(kind)
            let digital = run(kind,keyboard:true)
            print(String(format:"%@ · analog %@ %.2fs %.1fkm/h · keyboard %@ %.2fs %.1fkm/h",
                         kind.title,analog.run.result?.label ?? "pending",analog.run.elapsed,analog.run.exitSpeedKPH ?? -1,
                         digital.run.result?.label ?? "pending",digital.run.elapsed,digital.run.exitSpeedKPH ?? -1))
            check(medal(analog.run.result).map { $0 >= .silver } == true && medal(digital.run.result) != nil,
                  "The real simulation can complete the lesson with either analogue commands or separate key taps: \(kind.title)")
            check([medal(analog.run.result),medal(digital.run.result)].contains(.gold),
                  "A verified driving trace earns the highest grade: \(kind.title)")
            let speedSatisfied = kind == .braking ? analog.run.peakSpeedKPH >= kind.requiredSpeedKPH :
                (analog.run.exitSpeedKPH ?? 0) >= kind.requiredSpeedKPH
            check(speedSatisfied && analog.run.elapsed > 2 && analog.run.elapsed < 10 && analog.run.progress(at:analog.location) > 0.70,
                  "The run reaches the intended corridor and speed: \(kind.title)")
            var course = analog.run
            let elapsed = course.elapsed
            course.step(step,vehicle:analog.vehicle,input:DrivingInput(),location:analog.location,circuit:analog.circuit)
            check(course.result == analog.run.result && course.elapsed == elapsed && course.feedback == analog.run.feedback,
                  "Scoring and measured feedback remain final after resolving the attempt: \(kind.title)")
            switch analog.run.feedback {
            case .braking(.inBox(let error)):
                let zone = kind.stopZone!
                print(String(format:"Academy · stop %+.2f m from centre",error))
                check(abs(error - (analog.location.progress - (zone.lowerBound+zone.upperBound)/2)) < 0.000001 &&
                      abs(error) <= 3.5,
                      "Stopping feedback preserves the signed distance to the box centre")
            case .trailBraking(let overlap,let release,_):
                print(String(format:"Academy · braking overlap %.2f s · under 2%% line pressure %.2f s",overlap,release))
                check(overlap >= 0.48 && release >= 0.16 && overlap+release < analog.run.elapsed,
                      "Trail-brake feedback measures distinct overlap and uninterrupted low-pressure time")
            case .wetExit(let earlyThrottle,let poweredSlip):
                check(earlyThrottle == 0 && (0..<0.12).contains(poweredSlip),
                      "Smooth wet exit reports no early heavy throttle and little powered slip")
            default: check(false,"Completed lesson returns measured feedback: \(kind.title)")
            }
        }

        func taper(_ replay: Replay, keyboard: Bool = false) -> Double {
            guard case .trailBraking(_,_,let seconds) = run(.trailBraking,keyboard:keyboard,replay:replay).run.feedback else { return -1 }
            return seconds
        }
        let controlled = taper(.slowTaper), keyboard = taper(.practice,keyboard:true)
        let interrupted = taper(.taperReapply), heldSamples = taper(.taperWithHeldSample)
        print(String(format:"Academy · progressive release controlled %.3f s, keyboard %.3f s, reapplication %.3f s, held sample %.3f s",
                     controlled,keyboard,interrupted,heldSamples))
        check(controlled > 0.80 && (0.015...0.070).contains(keyboard),
              "A deliberate analogue taper and the simulated key return register actual loaded pressure relief")
        check([Replay.snapRelease,.blendedSnap,.heldBrake,.noisyBrakeHold,.neverBrake,.brakeBeforeTurning].allSatisfy { taper($0) == 0 },
              "Snap release, hydraulic decay, held pressure, coasting and straight-line release do not report a taper")
        check(interrupted > 0.15 && interrupted < controlled-0.30 && heldSamples > controlled-0.10 && heldSamples < controlled,
              "A fresh application separates tapers and brief held samples preserve the streak without earning duration")

        let overshoot = run(.braking,replay:.overshoot)
        check(overshoot.run.result == .failed(.overshot),
              "Accelerating past the stop box does not earn a medal")
        if case .braking(.crossedBoxEnd(let speed)) = overshoot.run.feedback {
            check(speed == overshoot.vehicle.speedKPH && speed > overshoot.run.kind.requiredSpeedKPH,
                  "Overshoot feedback reports speed at crossing the box end")
        } else { check(false,"Overshoot feedback reports speed at crossing the box end") }
        let earlyStop = run(.braking,replay:.stopBeforeBox)
        if case .braking(.shortOfBox(let distance)) = earlyStop.run.feedback {
            print(String(format:"Academy · early stop %.2f m before the box",distance))
            check(earlyStop.run.result == .failed(.timeout) &&
                  abs(distance - (earlyStop.run.kind.stopZone!.lowerBound-earlyStop.location.progress)) < 0.000001 &&
                  distance > 0 && earlyStop.vehicle.speedKPH < 2,
                  "A settled stop short of the box reports its distance on timeout")
        } else { check(false,"A settled stop short of the box reports its distance on timeout") }
        let noOverlap = run(.trailBraking,replay:.brakeBeforeTurning).run
        check(noOverlap.result == .failed(.technique),
              "Finishing the corner after only straight-line braking misses the trail-brake goal")
        if case .trailBraking(let overlap,let release,_) = noOverlap.feedback {
            check(overlap < 0.14 && release == 0,"Coasting after straight-line braking does not count toward low-pressure time")
        } else { check(false,"Coasting after straight-line braking does not count toward low-pressure time") }
        let trailWithReapplication = run(.trailBraking,replay:.trailReapply).run
        let trailWithoutReapplication = run(.trailBraking).run
        if case .trailBraking(_,let reapplicationRelease,_) = trailWithReapplication.feedback,
           case .trailBraking(_,let release,_) = trailWithoutReapplication.feedback {
            print(String(format:"Academy · under 2%% line pressure %.2f s with a second brake application",reapplicationRelease))
            check(medal(trailWithReapplication.result) != nil && reapplicationRelease >= 0.16 &&
                  reapplicationRelease < release-0.35,
                  "Brake reapplication breaks the low-pressure streak without changing pass eligibility")
        } else { check(false,"Brake reapplication breaks the low-pressure streak without changing pass eligibility") }
        check(run(.wetExit,replay:.coast).run.result == .failed(.tooSlow),
              "Coasting through the wet exit cannot earn the required speed")
        let earlyPower = run(.wetExit,replay:.fullThrottleBeforeExit).run
        check(earlyPower.result == .failed(.earlyPower),
              "Speed alone cannot pass the wet lesson after sustained full throttle before the exit")
        if case .wetExit(let seconds,let slip) = earlyPower.feedback {
            print(String(format:"Academy · heavy throttle %.2f s before mark · powered slip %.2f s",seconds,slip))
            check(seconds > 0.65 && slip <= 0.95,"Wet feedback distinguishes excess early throttle from powered grip loss")
        } else { check(false,"Wet feedback distinguishes excess early throttle from powered grip loss") }
        let loadedSlip = run(.wetExit,replay:.measuredWheelSlip(normalLoad:900)).run
        let unloadedSlip = run(.wetExit,replay:.measuredWheelSlip(normalLoad:80)).run
        let normalWetExit = run(.wetExit).run
        if case .wetExit(let power,let slip) = loadedSlip.feedback {
            print(String(format:"Academy · %.2f s powered slip when a loaded rear tyre spins",slip))
            check(loadedSlip.result == .failed(.lostGrip) && power == 0 && slip > 0.95 &&
                  unloadedSlip.feedback == normalWetExit.feedback && unloadedSlip.result == normalWetExit.result,
                  "Only supported rear tyre spin contributes sustained powered slip")
        } else { check(false,"Only supported rear tyre spin contributes sustained powered slip") }
        check(run(.trailBraking,replay:.noSteering).run.result == .failed(.trackLimits),
              "Driving straight through the real bend breaches the exercise track limits")

        let kind = DrivingLessonKind.braking
        let circuit = Circuit(kind:kind.circuitKind,condition:kind.condition)
        var trial = DrivingLessonRun(kind:kind)
        var car = Vehicle()
        check(!trial.prepare(&car,circuit:Circuit(kind:.north)) && trial.prepare(&car,circuit:circuit),
              "The exercise is restricted to the matching circuit")
        var location = circuit.nearest(to:car.position)
        trial.step(.nan,vehicle:car,input:DrivingInput(throttle:1),location:location,circuit:circuit)
        trial.step(step,vehicle:car,input:DrivingInput(),location:location,circuit:circuit)
        check(trial.elapsed == 0 && !trial.hasStarted && trial.feedback == nil,
              "A stationary lesson waits for a valid driver launch before any feedback")
        car.velocity = -location.tangent*4
        car.gear = 0
        for index in car.wheels.indices { car.wheels[index].angularVelocity = -4/car.wheelRadius }
        for _ in 0..<100 where trial.result == nil {
            car.step(step,input:DrivingInput(),assists:kind.assists,roadDistance:location.distance,roadWidth:circuit.width,
                     roadContacts:circuit.wheelContacts(at:car.contactPoints))
            location = circuit.nearest(to:car.position)
            trial.step(step,vehicle:car,input:DrivingInput(),location:location,circuit:circuit)
        }
        check(trial.result == .failed(.wrongWay),"Sustained reverse movement ends the attempt")
        trial = DrivingLessonRun(kind:kind)
        trial.prepare(&car,circuit:circuit)
        check(trial.result == nil && trial.feedback == nil && trial.elapsed == 0 && trial.peakSpeedKPH == 0 && car.speed == 0 &&
              abs(circuit.nearest(to:car.position).progress-kind.startProgress) < 0.01,
              "A fresh attempt restores the starting car, timing and route")
        let finish = circuit.sample(at:kind.finishProgress)
        let jumped = circuit.nearest(to:finish.point)
        trial.step(step,vehicle:car,input:DrivingInput(throttle:1),location:jumped,circuit:circuit)
        check(trial.result == .failed(.trackLimits) && trial.feedback == .braking(nil),
              "Jumping directly to an objective cannot score the exercise or fabricate a stop")
        if failures > 0 { exit(1) }
    }
}

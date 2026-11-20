import Foundation
import simd
@main struct FeedbackChecks {
    static var failures=0
    static func check(_ valid:Bool,_ message:String) {
        print("\(valid ? "PASS" : "FAIL")  \(message)");if !valid { failures += 1 }
    }
    static func main() {
        var car=Vehicle();car.velocity=car.forward*20
        for i in 0..<4 { car.wheels[i].normalLoad=3100 }
        var feedback=HapticFeedback()
        let idle=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(idle.peak==0,"Smooth straight running does not produce permanent rumble")
        checkAligningMoment()
        checkTrailBrakeFeedback()
        checkRackDetailDuringRelease()
        func cornerTrace(front: Double,rear: Double,load: Double = 3100,lateralForce: Double = 3000) -> [HapticOutput] {
            var sample = car
            var mapping = HapticFeedback()
            for index in sample.wheels.indices {
                sample.wheels[index].normalLoad = load
                sample.wheels[index].relaxedSlipAngle = 0.15
                sample.wheels[index].slidingFraction = index < 2 ? front : rear
                sample.wheels[index].lateralForce = lateralForce
                sample.wheels[index].longitudinalForce = 3000-abs(lateralForce)
            }
            return (0..<60).map { _ in
                mapping.update(vehicle:sample,input:DrivingInput(),impact:.zero,dt:1/60,active:true)
            }
        }
        let frontTrace = cornerTrace(front:0.95,rear:0.18).suffix(30)
        let rearTrace = cornerTrace(front:0.18,rear:0.95).suffix(30)
        let frontStrengths = frontTrace.map(\.combinedGrip), rearStrengths = rearTrace.map(\.combinedGrip)
        let rearLevels = rearStrengths.reduce(into:[Int]()) { values,strength in
            values.append(HapticOutput.compatibilityLevel(for:strength*0.75,previous:values.last ?? 0))
        }
        check(frontStrengths.min()! > 0.15 && frontStrengths.max()!-frontStrengths.min()! < 0.01 &&
              rearStrengths.max()!-rearStrengths.min()! > 0.10 &&
              Set(rearLevels).count >= 3 &&
              frontTrace.last!.sharpness > rearTrace.last!.sharpness+0.20,
              "Front push gives steady scrub while rear breakaway pulses even on a combined handle")
        check(cornerTrace(front:1,rear:1,load:0).allSatisfy { $0.peak == 0 } &&
              cornerTrace(front:1,rear:1,lateralForce:0).allSatisfy { $0.peak == 0 },
              "Airborne and purely longitudinal sliding do not generate cornering cues")
        let balanced = cornerTrace(front:0.95,rear:0.95).suffix(30).map(\.combinedGrip)
        check(balanced.min()! > 0.15 && balanced.max()!-balanced.min()! < 0.01,
              "A balanced four-wheel slide does not falsely signal rear breakaway")
        var fishtail = Vehicle()
        fishtail.kind = .porsche
        fishtail.gear = 0
        fishtail.yawRate = 1.6
        fishtail.velocity = fishtail.forward*22 - fishtail.modelX*(fishtail.yawRate*fishtail.kind.frontAxle)
        for index in fishtail.wheels.indices { fishtail.wheels[index].angularVelocity = 22/fishtail.wheelRadius }
        var recovery = HapticFeedback()
        var initialCue = 0.0, finalCue = 0.0
        for frame in 0..<240 {
            for _ in 0..<4 {
                fishtail.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            }
            finalCue = recovery.update(vehicle:fishtail,input:DrivingInput(),impact:.zero,dt:1/60,active:true).combinedGrip
            if frame < 6 { initialCue = max(initialCue,finalCue) }
        }
        check(initialCue > 0.08 && finalCue < 0.01,
              "A simulated rear-axle disturbance reaches the handles within 100 ms and clears as the car settles")
        car.wheels[1].kerbFeedback=1;car.wheels[3].kerbFeedback=1
        let left=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(left.left>0.3 && left.right==0,"Driver-left kerbs excite the left handle only")
        feedback.reset();car.wheels[1].kerbFeedback=0;car.wheels[3].kerbFeedback=0;car.wheels[0].kerbFeedback=1
        let right=feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true)
        check(right.right>0.3 && right.left==0,"Driver-right kerbs excite the right handle only")
        let paused=feedback.update(vehicle:car,input:DrivingInput(),impact:SIMD2(1,1),dt:0.001,active:false)
        check(paused.peak==0,"Pause immediately clears road and collision vibration")
        car.velocity = .zero
        check(feedback.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:0.05,active:true).peak==0,"Stationary kerb contact does not rumble")
        let hit=feedback.update(vehicle:car,input:DrivingInput(),impact:SIMD2(1,0.25),dt:0.05,active:true)
        check(hit.left>hit.right && hit.left>0,"A stopped car can still receive the directional impact impulse")
        var brakingCar = Vehicle()
        brakingCar.kind = .porsche
        brakingCar.gear = 0
        brakingCar.velocity = brakingCar.forward*34
        for index in brakingCar.wheels.indices {
            brakingCar.wheels[index].angularVelocity = 34/brakingCar.wheelRadius
        }
        var pulse = HapticFeedback()
        let pedal = DrivingInput(brake:1)
        var brakes = DrivingAssists(automatic:false)
        brakes.absLevel = 4
        let absTrace = (0..<160).map { _ -> (Double,Double,HapticOutput) in
            brakingCar.step(1/240,input:pedal,assists:brakes,roadDistance:9,roadWidth:12)
            var movement = brakingCar.absValveActivity
            brakingCar.step(1/240,input:pedal,assists:brakes,roadDistance:9,roadWidth:12)
            movement = max(movement,brakingCar.absValveActivity)
            let cue = pulse.update(vehicle:brakingCar,input:pedal,impact:.zero,dt:1/120,active:true)
            return (movement,brakingCar.absRelease,cue)
        }
        let intervention = absTrace.filter { $0.1 > 0.10 }
        let absFeedback = intervention.map(\.2).max { $0.brake < $1.brake } ?? .zero
        let valvePeak = intervention.map(\.0).max() ?? 0
        let quietPhase = intervention.filter { $0.0 < 0.05 }.map { $0.2.brake }.min() ?? 1
        print(String(format:"ABS valve peak %.2f, brake trigger %.2f / %.2f",valvePeak,absFeedback.brake,quietPhase))
        check(intervention.count > 30 && absFeedback.brake > 0.25 && absFeedback.throttle == 0,
              "A real simulated ABS event is routed to the brake trigger")
        check(valvePeak > 0.12 && absFeedback.brake > quietPhase+0.09,
              "Brake trigger follows valve movement and quiets while pressure is held")
        let strongABS = intervention.map { $0.2.brake }.filter { $0 > 0.54 }
        check(strongABS.count > 5 && strongABS.allSatisfy { $0 < 0.6499 } &&
              Set(strongABS.map { Int(($0*1000).rounded()) }).count >= 4,
              "Strong valve pulses remain distinct without flattening at the brake trigger ceiling")
        var released = HapticOutput.zero
        for _ in 0..<20 {
            for _ in 0..<2 {
                brakingCar.step(1/240,input:DrivingInput(),assists:brakes,roadDistance:9,roadWidth:12)
            }
            released = pulse.update(vehicle:brakingCar,input:DrivingInput(),impact:.zero,dt:1/120,active:true)
        }
        check(released.brake < 0.01 && brakingCar.absValveActivity == 0,
              "ABS feedback fades promptly when the brake unloads")
        feedback.reset();car.velocity=car.forward*20;car.wheels[2].slipRatio=0.9
        let spin=feedback.update(vehicle:car,input:DrivingInput(throttle:1),impact:.zero,dt:0.05,active:true)
        check(spin.throttle>0 && spin.brake==0,"Driven wheel spin is routed to the throttle trigger")
        check(spin.scaled(0).peak==0 && spin.scaled(.nan).peak==0,"Off and invalid gain safely silence all actuators")
        check(HapticOutput(left:9,right:9,brake:9,throttle:9).scaled(1).peak<=0.8,"Feedback saturates at the configured safe output ceiling")
        check(HapticOutput.test(at:0.1).left>0 && HapticOutput.test(at:0.8).right>0 && HapticOutput.test(at:1.3).brake>0 &&
              HapticOutput.test(at:1.9).throttle>0 && HapticOutput.test(at:HapticOutput.testDuration).peak==0,
              "Finite calibration sequence covers both handles and triggers")
        check(absFeedback.combinedGrip >= absFeedback.brake*0.8 && HapticOutput.test(at:1.9).combinedGrip > 0.4,
              "Combined grip mode retains ABS and trigger effects")
        let kerbAndABS = HapticOutput(left:0.27,right:0.04,brake:0.24)
        check(kerbAndABS.combinedGrip > 0.30 && kerbAndABS.combinedGrip < 0.36,
              "The combined Xbox channel preserves weaker brake texture over a kerb")
        check(HapticOutput.compatibilityLevel(for:0.227,previous:4) == 4 &&
              HapticOutput.compatibilityLevel(for:0.235,previous:4) == 5 &&
              HapticOutput.compatibilityLevel(for:0.224,previous:5) == 5,
              "Compatibility output holds its level through a small fluctuation near a boundary")
        var locking = Vehicle()
        locking.velocity = locking.forward*20
        locking.wheels[0].slipRatio = -0.75
        locking.wheels[0].normalLoad = 3100
        var roadFeedback = HapticFeedback()
        let rollingLock = roadFeedback.update(vehicle:locking,input:DrivingInput(brake:0.7),impact:.zero,dt:1/120,active:true)
        locking.wheels[0].normalLoad = 0
        let unloadedLock = roadFeedback.update(vehicle:locking,input:DrivingInput(brake:0.7),impact:.zero,dt:1/120,active:true)
        check(rollingLock.brake > 0.2 && unloadedLock.brake == 0,
              "A loaded locking tyre warns through the brake trigger without false feedback from an unloaded wheel")
        var controlled = Vehicle()
        controlled.velocity = controlled.forward*20
        controlled.tcActive = true
        controlled.tcReduction = 0.5
        var tcFeedback = HapticFeedback()
        let tcCue = tcFeedback.update(vehicle:controlled,input:DrivingInput(throttle:0.6),impact:.zero,dt:0.05,active:true)
        check(tcCue.throttle > 0.08 && tcCue.throttle < 0.14 && tcCue.brake == 0,
              "A traction cut leaves a subtle throttle warning even after spin is suppressed")
        let circuit=Circuit()
        check(kerbElevation(progress:1,distanceFromEdge:0)==0 && kerbElevation(progress:1,distanceFromEdge:0.85)==0,"Kerb entry and exit meet the asphalt without a height step")
        check((0..<100).allSatisfy { (0...0.043).contains(kerbElevation(progress:Double($0)/10,distanceFromEdge:0.4)) },"Shared kerb profile remains within its 42 mm design height")
        checkKerbOnGradient()
        var coupled=Vehicle()
        let contacts=[WheelRoadContact(distance:0,progress:30,kerbsEnabled:true),WheelRoadContact(distance:6.4,progress:30,kerbsEnabled:true),WheelRoadContact(distance:0,progress:27,kerbsEnabled:true),WheelRoadContact(distance:0,progress:27,kerbsEnabled:true)]
        coupled.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12,roadContacts:contacts)
        check(coupled.wheels[1].antiRollForce>0 && abs(coupled.wheels[0].antiRollForce+coupled.wheels[1].antiRollForce)<0.001,"Anti-roll coupling transfers load within the axle without adding net support")
        coupled.heave = -0.12
        coupled.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        check(coupled.wheels.allSatisfy { $0.bumpStopForce>0 && $0.normalLoad>=0 },"Deep suspension compression engages progressive bump stops")
        func stop(_ initialTemperature:Double) -> (Double,Double) {
            var v=Vehicle();v.velocity=v.forward*35
            for i in 0..<4 { v.wheels[i].angularVelocity=35/v.wheelRadius;v.wheels[i].brakeTemperature=initialTemperature }
            for _ in 0..<2400 { v.step(1/240,input:DrivingInput(brake:0.35),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
            return (v.distanceTravelled,v.wheels[0].brakeTemperature)
        }
        let fresh=stop(40),hot=stop(1000)
        print(String(format:"Brake comparison at 35%% pedal: fresh %.2f m, hot %.2f m",fresh.0,hot.0))
        check(fresh.1>40,"Braking work raises rotor temperature")
        check(hot.0>fresh.0*1.08,"Overheated brakes increase stopping distance at equal 35% pedal demand")
        var swept = Vehicle(); swept.kind = .porsche; swept.gear = 0; swept.velocity = swept.forward*34
        for i in swept.wheels.indices { swept.wheels[i].angularVelocity = 34/swept.wheelRadius }
        for _ in 0..<288 { swept.step(1/240,input:DrivingInput(brake:0.90),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        let hotSurface = swept.wheels[0].brakeSurfaceTemperature, warmRotor = swept.wheels[0].brakeTemperature
        swept.reset(at:circuit.start,preservingCondition:true)
        let bothPreserved = swept.wheels[0].brakeSurfaceTemperature == hotSurface && swept.wheels[0].brakeTemperature == warmRotor
        for _ in 0..<720 { swept.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        print(String(format:"911 disc face / bulk %.1f/%.1f°C after braking, %.1f/%.1f°C after three seconds",
                     hotSurface,warmRotor,swept.wheels[0].brakeSurfaceTemperature,swept.wheels[0].brakeTemperature))
        check(hotSurface > warmRotor+20 && warmRotor > 40 && bothPreserved &&
              swept.wheels[0].brakeSurfaceTemperature < hotSurface-15 && swept.wheels[0].brakeTemperature > warmRotor+3,
              "A braking pulse heats the swept face first, then the rotor keeps warming as the face cools")
        var repair=Vehicle();repair.wheels[0].brakeTemperature=850
        repair.reset(at:circuit.start,preservingCondition:true)
        check(repair.wheels[0].brakeTemperature==850,"Recovery preserves overheated brake condition")
        repair.service(setup:TyreSetup())
        check(repair.wheels.allSatisfy { $0.brakeTemperature==40 && $0.brakeSurfaceTemperature==40 } &&
              repair.brakeCapacityShare == 1,"Service restores disc surface, rotor temperature and available torque")
        check(CircuitKind.allCases.allSatisfy { !Circuit(kind:$0).cornerDistances.isEmpty },"All six maps derive braking markers from their own bends")
        if failures>0 {exit(1)}
    }

    static func checkTrailBrakeFeedback() {
        let water = WheelRoadContact(distance:0,progress:0,kerbsEnabled:false,waterDepth:0.55)
        let contacts = Array(repeating:water,count:4)
        func trace(turn: Bool, cadence: Int) -> (samples: [HapticOutput], absActive: Bool) {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.service(setup:TyreSetup(compound:.wet))
            car.velocity = car.forward*28
            for index in car.wheels.indices {
                car.wheels[index].angularVelocity = 28/car.wheelRadius
                car.wheels[index].temperature = 57
            }
            var haptics = HapticFeedback(), signal = HapticOutput.zero
            var samples = [HapticOutput]()
            var absActive = false
            for tick in 1...264 {
                let seconds = Double(tick-1)/240
                let release = clamp((seconds-0.25)/0.75,0,1)
                let steering = turn ? 0.5*clamp((seconds-0.10)/0.45,0,1) : 0
                let input = DrivingInput(brake:0.57*(1-release),steering:steering)
                car.step(1/240,input:input,assists:DrivingAssists(automatic:false),
                         roadDistance:0,roadWidth:12,roadContacts:contacts)
                absActive = absActive || car.absActive
                if tick.isMultiple(of:240/cadence) {
                    signal = haptics.update(vehicle:car,input:input,impact:.zero,dt:1/Double(cadence),active:true)
                }
                if tick.isMultiple(of:24) { samples.append(signal) }
            }
            return (samples,absActive)
        }
        let straight = trace(turn:false,cadence:120)
        let turn = trace(turn:true,cadence:120)
        let coarse = trace(turn:true,cadence:60)
        let cue = turn.samples.map(\.brake)
        let maximumCadenceDifference = zip(turn.samples,coarse.samples).map { abs($0.brake-$1.brake) }.max() ?? 1
        check(!straight.absActive && !turn.absActive && cue[2] > 0.13 && cue[4] > 0.09 &&
              cue[4] > cue[5] && cue[5] > cue[6]+0.035 && cue[6] > cue[7] && cue[10] < 0.002,
              "Partial pedal feedback rises and fades through a real trail-brake release without ABS")
        check(cue[5] > straight.samples[5].brake+0.018 && turn.samples[5].throttle == 0 &&
              turn.samples[5].combinedGrip > 0.10,
              "An increasingly loaded front tyre adds trail-brake texture on the dedicated and combined channels")
        check(maximumCadenceDifference < 0.007,
              "Brake haptic envelope agrees at 60 and 120 updates per second")
        print(String(format:"Wet 911 at 31%% pedal: straight / turning brake cue %.3f / %.3f, cadence delta %.4f",
                     straight.samples[5].brake,cue[5],maximumCadenceDifference))
    }

    static func checkKerbOnGradient() {
        let dt = 1.0/240, speed = 26.0
        func meanFeedback(grade: Double) -> SIMD2<Double> {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            for index in car.wheels.indices { car.wheels[index].angularVelocity = speed/car.wheelRadius }
            var sum = SIMD2<Double>.zero
            for tick in 0..<720 {
                // Prescribe the same motion and relief on both straight road profiles.
                car.position = SIMD2(0,Double(tick)*dt*speed)
                car.heading = 0
                car.velocity = SIMD2(0,speed)
                car.yawRate = 0
                let contacts = car.contactPoints.enumerated().map { index, point in
                    WheelRoadContact(distance:index.isMultiple(of:2) ? 4.8 : 6.4,progress:point.y,
                                     kerbsEnabled:true,elevation:grade*point.y,gradient:SIMD2(0,grade))
                }
                car.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.6,
                         roadWidth:12,roadContacts:contacts)
                if tick >= 240 {
                    sum += SIMD2(car.wheels[0].kerbFeedback,car.wheels[1].kerbFeedback)
                }
            }
            return sum/480
        }
        let flat = meanFeedback(grade:0), climb = meanFeedback(grade:0.08)
        check(flat.x == 0 && climb.x == 0 && flat.y > 0.25 && abs(climb.y-flat.y) < 0.025,
              "Identical driver-left kerbs keep their tactile strength on flat and uphill asphalt")

        func loadedKerb(heave: Double) -> (load: Double, cue: Double) {
            var car = Vehicle()
            car.heave = heave
            car.velocity = car.forward*speed
            let contacts = (0..<4).map { index in
                WheelRoadContact(distance:index == 1 ? 6.4 : 4.8,progress:14.5,kerbsEnabled:true)
            }
            car.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.6,
                     roadWidth:12,roadContacts:contacts)
            return (car.wheels[1].normalLoad,car.wheels[1].kerbFeedback)
        }
        let loaded = loadedKerb(heave:0.025), light = loadedKerb(heave:0.11)
        check(light.load > 100 && loaded.load > light.load && light.cue > 0 && loaded.cue > light.cue*1.2,
              "Kerb texture remains stronger through a loaded contact patch")
    }

    static func checkAligningMoment() {
        func sample(degrees: Double, speed: Double = 22) -> (moment: Double, cue: HapticOutput) {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            let angle = degrees * .pi / 180
            car.velocity = car.forward * speed + car.modelX * (abs(speed) * tan(angle))
            for i in car.wheels.indices {
                car.wheels[i].temperature = 57
                car.wheels[i].angularVelocity = speed / car.wheelRadius
                car.wheels[i].relaxedSlipAngle = angle
            }
            car.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            var mapping = HapticFeedback(), signal = HapticOutput.zero
            for _ in 0..<30 {
                signal = mapping.update(vehicle:car,input:DrivingInput(),impact:.zero,dt:1/120,active:true)
            }
            return (car.wheels[0].aligningMoment + car.wheels[1].aligningMoment, signal)
        }
        let small = sample(degrees:1), loaded = sample(degrees:3)
        let approachingSlide = sample(degrees:8), sliding = sample(degrees:12)
        check(small.moment > 0 && loaded.moment > small.moment &&
              approachingSlide.moment < loaded.moment * 0.25 && sliding.moment == 0,
              "The front contact patches develop aligning torque before sliding and lose it at saturation")
        let opposite = sample(degrees:-1), reverse = sample(degrees:1,speed:-22)
        check(abs(opposite.moment + small.moment) < 1e-6 && abs(reverse.moment + small.moment) < 1e-5,
              "Mirrored sideslip and reversed rolling direction each reverse pneumatic trail torque")
        check(small.cue.left > 0.04 && small.cue.right == 0 &&
              abs(small.cue.left - opposite.cue.right) < 1e-6 && sliding.cue.combinedGrip > small.cue.combinedGrip,
              "Light rolling corners load the corresponding handle before sustained scrub takes over")
        print(String(format:"911 front aligning torque at 1/3/8/12 degrees: %.1f / %.1f / %.1f / %.1f Nm",
                     small.moment,loaded.moment,approachingSlide.moment,sliding.moment))
    }

    static func checkRackDetailDuringRelease() {
        let wetRoad = WheelRoadContact(distance:0,progress:170,kerbsEnabled:false,waterDepth:0.55)
        let contacts = Array(repeating:wetRoad,count:4)
        var car = Vehicle()
        car.kind = .porsche
        car.gear = 0
        car.service(setup:TyreSetup(compound:.wet))
        car.velocity = car.forward*28
        for index in car.wheels.indices {
            car.wheels[index].temperature = 57
            car.wheels[index].angularVelocity = 28/car.wheelRadius
        }
        var mapped = HapticFeedback(), scrubOnly = HapticFeedback(), coarse = HapticFeedback()
        var lateDetails = [Double]()
        var lateCombinedDetails = [Double]()
        var brakingMatches = true
        var cadenceDifference = 0.0
        var input = DrivingInput()
        for tick in 0...208 {
            let time = Double(tick)/240
            input = DrivingInput(brake:0.57*(1-clamp((time-0.25)/0.78,0,1)),
                                 steering:0.45*clamp((time-0.10)/0.55,0,1))
            car.step(1/240,input:input,assists:DrivingAssists(automatic:false),
                     roadDistance:0,roadWidth:12,roadContacts:contacts)
            guard tick.isMultiple(of:2) else { continue }
            let full = mapped.update(vehicle:car,input:input,impact:.zero,dt:1/120,active:true)
            if tick.isMultiple(of:4) {
                let slower = coarse.update(vehicle:car,input:input,impact:.zero,dt:1/60,active:true)
                if tick >= 184 { cadenceDifference = max(cadenceDifference,abs(full.left-slower.left)) }
            }
            var sameTyres = car
            sameTyres.wheels[0].aligningMoment = 0
            sameTyres.wheels[1].aligningMoment = 0
            let baseline = scrubOnly.update(vehicle:sameTyres,input:input,impact:.zero,dt:1/120,active:true)
            if tick >= 184 {
                lateDetails.append(full.left-baseline.left)
                lateCombinedDetails.append(full.combinedGrip-baseline.combinedGrip)
                brakingMatches = brakingMatches && full.brake == baseline.brake && full.right == baseline.right
            }
        }
        let peakDetail = lateDetails.max() ?? 0
        let minimumDetail = lateDetails.min() ?? 0
        check(lateDetails.count == 13 && minimumDetail > 0.010 && peakDetail < 0.023 &&
              (lateCombinedDetails.min() ?? 0) > 0.010 && brakingMatches,
              "Real late trail release retains a small directional rack cue under scrub without raising brake vibration")
        check(cadenceDifference < 0.006,"The layered handle follows the same release at 60 and 120 samples per second")
        let stopped = mapped.update(vehicle:car,input:input,impact:SIMD2(1,1),dt:1/120,active:false)
        let resumed = mapped.update(vehicle:car,input:input,impact:.zero,dt:1/120,active:true)
        var fresh = HapticFeedback()
        let fromZero = fresh.update(vehicle:car,input:input,impact:.zero,dt:1/120,active:true)
        check(stopped == .zero && resumed == fromZero,
              "Turning feedback clears immediately on inactivity and reconnects without stale texture")

        func kerb(rack: Double) -> HapticOutput {
            var textured = car
            textured.wheels[0].aligningMoment = rack
            textured.wheels[1].aligningMoment = rack
            for index in [1,3] {
                textured.wheels[index].kerbFeedback = 0.93
                textured.wheels[index].normalLoad = 2800
            }
            var mapping = HapticFeedback()
            var output = HapticOutput.zero
            for _ in 0..<24 {
                output = mapping.update(vehicle:textured,input:input,impact:.zero,dt:1/120,active:true)
            }
            return output
        }
        let brush = kerb(rack:0), steeredBrush = kerb(rack:15), otherSide = kerb(rack:-15)
        let layer = steeredBrush.left-brush.left
        check(brush.left > 0.50 && steeredBrush.left < 0.8 && layer > 0 && layer < 0.016 &&
              steeredBrush.right == brush.right && otherSide.right > brush.right+0.015 &&
              otherSide.left == brush.left,
              "A strong brush limits extra rack texture through headroom and keeps clear left/right routing")
        print(String(format:"Late wet release carries %.3f–%.3f rack texture, %.3f on a strong brush, cadence delta %.4f",
                     minimumDetail,peakDetail,layer,cadenceDifference))
    }
}

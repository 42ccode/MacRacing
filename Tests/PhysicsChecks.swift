import Foundation
import simd

@main
struct PhysicsChecks {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS  \(message)") }
        else { print("FAIL  \(message)"); failures += 1 }
    }

    static func main() {
        let circuit = Circuit()
        let dt = 1.0 / 120
        checkRidgeProfile()
        checkCombinedSlip()
        checkTrailBrakeRamp()
        checkSmallBrakeCorrections()
        checkTrailBrakeCountersteer()
        checkABSValveRefill()
        checkTreadWidths()
        checkStandingWaterPressure()
        checkTrackDrying()
        var oldPose = Vehicle()
        oldPose.heading = .pi - 0.01
        oldPose.wheels[0].rotation = 6.27
        oldPose.wheels[0].surfaceHeight = 0.02
        var pose = oldPose
        pose.heading = -.pi + 0.01
        pose.position = SIMD2(4,-2)
        pose.wheels[0].rotation = 0.03
        pose.wheels[0].surfaceHeight = 0.04
        let interpolated = pose.displayPose(previous:oldPose.renderSample,fraction:0.5)
        check(simd_distance(interpolated.position,SIMD2(2,-1)) < 1e-8 &&
              abs(abs(interpolated.heading)-Double.pi) < 1e-8 &&
              abs(interpolated.wheels[0].rotation-6.29159265) < 0.001 &&
              abs(interpolated.wheels[0].surfaceHeight-0.03) < 0.001 && pose.position.x == 4,
              "Render interpolation crosses angle seams without altering physics coordinates")
        var car = Vehicle()
        car.reset(at: circuit.start)
        let start = car.position
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(simd_distance(car.position, start) < 0.001, "Stationary car stays stationary")
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(throttle: 0, brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speed < 0.001, "Braking at rest never drives backwards")

        car.reset(at: circuit.start)
        for _ in 0..<1200 { car.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speedKPH > 100 && car.speedKPH < 240, "Full throttle accelerates plausibly: \(Int(car.speedKPH)) km/h in 10 seconds")
        check(car.gear > 1, "Automatic gearbox shifts up")
        check(abs(simd_dot(car.position - start, car.modelX)) < 0.01, "Straight acceleration does not drift sideways")
        for _ in 0..<960 { car.step(dt, input: DrivingInput(brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.speedKPH < 1, "Full braking stops the car")

        car.reset(at: circuit.start)
        for _ in 0..<600 { car.step(dt, input: DrivingInput(throttle: 0.5, steering: 0.5), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12) }
        check(car.position.x.isFinite && car.position.y.isFinite && car.speed < 100, "Turning integration stays finite and bounded")
        check(car.yawRate < 0, "Driver-right input turns clockwise when viewed from above")

        var road = Vehicle()
        var grass = Vehicle()
        for _ in 0..<600 {
            road.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
            grass.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 10, roadWidth: 12)
        }
        check(grass.speed < road.speed * 0.80, "Grass has reduced grip and increased resistance")

        var loaded = Vehicle()
        for _ in 0..<240 {
            loaded.step(dt, input: DrivingInput(), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let stationaryLoad = loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(abs(stationaryLoad - loaded.mass * 9.81) < 1, "Four spring loads balance gravity at rest")
        var follower = Vehicle(); follower.kind = .centenario; follower.gear = 0
        follower.velocity = follower.forward*50
        for i in follower.wheels.indices { follower.wheels[i].angularVelocity = 50/follower.wheelRadius }
        var leader = follower
        leader.position += follower.forward*12
        let wake = AirWake.behind(follower,leaders:[leader])
        var alongside = leader; alongside.position += follower.modelX*3.5
        var behind = leader; behind.position -= follower.forward*25
        check(wake.intensity > 0.8 && AirWake.behind(follower,leaders:[alongside,behind]).intensity == 0,
              "Wake follows the car ahead and vanishes outside its corridor")
        var undisturbed = follower
        for _ in 0..<240 {
            follower.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12,wake:wake)
            undisturbed.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(follower.speed > undisturbed.speed+0.08 && follower.aeroLoad.x < undisturbed.aeroLoad.x*0.85 &&
              follower.aeroLoad.x/follower.aeroLoad.y < undisturbed.aeroLoad.x/undisturbed.aeroLoad.y,
              "Following reduces drag and loses proportionally more front downforce")
        for _ in 0..<240 {
            follower.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(follower.wakeStrength < 0.003, "Clean airflow returns smoothly after moving out of the wake")
        var scrape = Vehicle(); scrape.velocity = SIMD2(1.6,28)
        let scrapeSpeed = scrape.hitBarrier(outward:SIMD2(1,0))
        check(abs(scrapeSpeed-1.6) < 0.001 && scrape.velocity.x < 0 &&
              scrape.velocity.y > 27 && abs(scrape.yawRate) > 0.01,
              "A shallow wall scrape redirects its normal component and retains most forward speed")
        var frontal = Vehicle(); frontal.velocity = frontal.forward*28
        let frontalSpeed = frontal.hitBarrier(outward:frontal.forward)
        check(abs(frontalSpeed-28) < 0.001 && frontal.forwardSpeed < 0 &&
              frontal.speed < 5 && abs(frontal.yawRate) < 0.001,
              "A centered wall impact dissipates speed without introducing artificial yaw")
        var reversingAway = Vehicle(); reversingAway.velocity = reversingAway.forward*8
        check(reversingAway.hitBarrier(outward:-reversingAway.forward) == 0 && reversingAway.speed == 8,
              "A car moving away from the wall receives no impact impulse")
        let wallCircuit = Circuit(kind:.ridge)
        let wallSample = wallCircuit.sample(at:220)
        for kind in VehicleKind.allCases {
            let twoSidesStop = [-1.0,1.0].allSatisfy { side in
                var car = Vehicle()
                car.kind = kind
                let normal = wallSample.right*side
                car.heading = atan2(normal.x,normal.y)
                car.position = wallSample.point+normal*(Circuit.guardRailInnerEdge-3.5)
                car.velocity = normal*92
                car.gear = 0
                for i in car.wheels.indices { car.wheels[i].angularVelocity = 92/car.wheelRadius }
                for _ in 0..<16 {
                    let position = wallCircuit.nearest(to:car.position)
                    car.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:position.distance,
                             roadWidth:wallCircuit.width,roadContacts:wallCircuit.wheelContacts(at:car.contactPoints))
                    let projected = wallCircuit.nearest(to:car.position)
                    if let contact = car.constrainToGuardRail(at:projected) {
                        let settled = wallCircuit.nearest(to:car.position)
                        return contact.closingSpeed > 80 && simd_dot(car.velocity,contact.normal) < 0 &&
                            settled.distance < Circuit.guardRailInnerEdge-1.7 &&
                            car.constrainToGuardRail(at:settled) == nil
                    }
                }
                return false
            }
            check(twoSidesStop,"Both guardrails stop the front of a 331 km/h car at the solved footprint: \(kind.label)")
        }
        func inferWheelInertia(_ kind: VehicleKind) -> SIMD2<Double> {
            var car = Vehicle()
            car.kind = kind
            car.gear = 0
            car.heave = 0.15
            car.velocity = car.forward*26
            let omega = 26/car.wheelRadius
            for i in car.wheels.indices { car.wheels[i].angularVelocity = omega }
            let t = 1.0/720
            let assists = DrivingAssists(abs:false,tractionControl:false,automatic:false)
            car.step(t,input:DrivingInput(brake:1),assists:assists,roadDistance:0,roadWidth:12)
            let scale = 4050*sqrt(car.mass/1260.0)*car.brakeLinePressure*t
            let front = scale*assists.frontBrakeBias/(omega-car.wheels[0].angularVelocity)
            let rear = scale*(1-assists.frontBrakeBias)/(omega-car.wheels[2].angularVelocity)
            return SIMD2(front,rear)
        }
        let porscheWheel = inferWheelInertia(.porsche), centenarioWheel = inferWheelInertia(.centenario)
        check((1.41...1.43).contains(porscheWheel.x) && (1.82...1.84).contains(porscheWheel.y) &&
              (1.63...1.65).contains(centenarioWheel.x) && (2.16...2.18).contains(centenarioWheel.y),
              "The brake solver uses the individual front and rear rotating assemblies when grip is absent")
        func aeroSample(_ kind: VehicleKind, speed: Double, frontDamage: Double = 0) -> Vehicle {
            var car = Vehicle()
            car.kind = kind
            car.gear = 0
            car.damage.front = frontDamage
            car.velocity = car.forward * speed
            for i in car.wheels.indices { car.wheels[i].angularVelocity = speed / car.wheelRadius }
            car.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            return car
        }
        let slowAero = aeroSample(.centenario,speed:25).aeroLoad
        let fastAero = aeroSample(.centenario,speed:50).aeroLoad
        let roadCarAero = aeroSample(.porsche,speed:50).aeroLoad
        let damagedAero = aeroSample(.centenario,speed:50,frontDamage:0.8).aeroLoad
        check(simd_distance(fastAero,slowAero*4) < 0.001 &&
              fastAero.x + fastAero.y > 4 * (roadCarAero.x + roadCarAero.y),
              "Downforce grows with forward speed and distinguishes road and high-downforce presets")
        check(damagedAero.x < fastAero.x*0.6 && abs(damagedAero.y-fastAero.y) < 0.001,
              "Front body damage changes aerodynamic balance by reducing front downforce")
        for _ in 0..<720 {
            loaded.step(dt, input: DrivingInput(throttle: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let frontStaticFraction = (loaded.wheelbase - 1.485) / loaded.wheelbase
        let acceleratingFraction = (loaded.wheels[0].normalLoad + loaded.wheels[1].normalLoad) / loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(acceleratingFraction < frontStaticFraction - 0.01, "Acceleration transfers normal load towards the rear wheels")
        for _ in 0..<60 {
            loaded.step(dt, input: DrivingInput(brake: 1), assists: DrivingAssists(), roadDistance: 0, roadWidth: 12)
        }
        let brakingFraction = (loaded.wheels[0].normalLoad + loaded.wheels[1].normalLoad) / loaded.wheels.reduce(0) { $0 + $1.normalLoad }
        check(brakingFraction > frontStaticFraction + 0.03, "Braking transfers normal load towards the front wheels")
        check(loaded.wheels.allSatisfy { $0.temperature.isFinite && $0.normalLoad >= 0 }, "Wheel temperatures and unilateral contact loads remain physical")

        var locked = road
        var noABS = DrivingAssists()
        noABS.abs = false
        for _ in 0..<80 {
            locked.step(dt, input: DrivingInput(brake: 1), assists: noABS, roadDistance: 0, roadWidth: 12)
        }
        check(locked.speed > 3 && locked.wheels.contains {
            $0.slipRatio < -0.8 && $0.rollingContactSpeed < locked.speed*0.2 && $0.slidingPower > 1000
        }, "A wheel locked by braking without ABS loses rolling speed and dissipates sliding power")

        var splitGrip = Vehicle()
        for _ in 0..<240 {
            splitGrip.step(dt, input: DrivingInput(throttle: 0.8), assists: DrivingAssists(), roadDistance: 6.7, roadWidth: 12, roadLateral: 6.7)
        }
        check(abs(splitGrip.wheels[2].longitudinalForce - splitGrip.wheels[3].longitudinalForce) > 50,
              "Contact patches respond independently when one side is on grass")
        func brakeOnSplitSurface(grassOnLeft: Bool) -> Vehicle {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.velocity = car.forward * 30
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 30 / car.wheelRadius }
            let contacts = car.wheels.indices.map { i in
                WheelRoadContact(distance: (i % 2 == 1) == grassOnLeft ? 6.9 : 0, progress:0, kerbsEnabled:false)
            }
            for _ in 0..<120 {
                car.step(1/240,input:DrivingInput(brake:0.8),assists:DrivingAssists(automatic:false),
                         roadDistance:0,roadWidth:12,roadContacts:contacts)
            }
            return car
        }
        let grassLeft = brakeOnSplitSurface(grassOnLeft:true)
        let grassRight = brakeOnSplitSurface(grassOnLeft:false)
        check(abs(grassLeft.yawRate) > 0.1 && abs(grassLeft.yawRate + grassRight.yawRate) < 0.005 &&
              abs(grassLeft.longitudinalG - grassRight.longitudinalG) < 0.005 && grassLeft.wheels.contains { $0.slidingPower > 100 },
              "Mirrored split-surface stops give opposite yaw and dissipate measurable sliding work")
        var dryABS = Vehicle()
        dryABS.kind = .porsche
        dryABS.gear = 0
        dryABS.velocity = dryABS.forward*30
        for i in dryABS.wheels.indices {
            dryABS.wheels[i].angularVelocity = 30/dryABS.wheelRadius
            dryABS.wheels[i].temperature = 70
        }
        var dryAssist = DrivingAssists(automatic:false)
        dryAssist.absLevel = 5
        var wheelLocked = false
        for _ in 0..<700 where dryABS.speed >= 8 {
            dryABS.step(1/240,input:DrivingInput(brake:1),assists:dryAssist,roadDistance:0,roadWidth:12)
            wheelLocked = wheelLocked || dryABS.wheels.contains { $0.slipRatio < -0.65 }
        }
        check(!wheelLocked && dryABS.speed < 8 && dryABS.distanceTravelled < 45,
              "Strong ABS uses dry grip without sustained wheel lock or unnecessary braking distance")
        var dusty = WheelState()
        var clean = WheelState()
        for _ in 0..<50 {
            dusty.evolve(0.02,slipPower:0,speed:15,load:3000,locked:false,grass:true)
            clean.evolve(0.02,slipPower:0,speed:15,load:3000,locked:false,grass:false)
        }
        let dirtyGrip = dusty.gripFactor
        check(dusty.surfaceContamination > 0.8 && dirtyGrip < clean.gripFactor*0.85,
              "Rolling through grass deposits contamination that lowers tyre grip")
        dusty.evolve(0.1,slipPower:0,speed:0,load:3000,locked:false,grass:false)
        let parkedContamination = dusty.surfaceContamination
        for _ in 0..<100 {
            dusty.evolve(0.02,slipPower:0,speed:20,load:3000,locked:false,grass:false)
        }
        check(parkedContamination > 0.8 && dusty.surfaceContamination < 0.4 &&
              dusty.gripFactor > dirtyGrip*1.08,
              "Contamination persists at rest and clears with distance back on asphalt")
        func wetStop(depth: Double, compound: TyreCompound, lateral: Double = 0) -> Double {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.service(setup:TyreSetup(compound:compound))
            car.velocity = car.forward * 30
            for index in car.wheels.indices {
                car.wheels[index].angularVelocity = 30 / car.wheelRadius
                car.wheels[index].temperature = 57
            }
            let contacts = Array(repeating:WheelRoadContact(distance:lateral,progress:0,kerbsEnabled:lateral > 0,
                                                            waterDepth:depth),count:4)
            for _ in 0..<2400 {
                if car.speed < 0.2 { break }
                car.step(1/240,input:DrivingInput(brake:1),assists:DrivingAssists(automatic:false),
                         roadDistance:0,roadWidth:12,roadContacts:contacts)
            }
            return car.distanceTravelled
        }
        let dryDistance = wetStop(depth:0,compound:.medium)
        let wetSlickDistance = wetStop(depth:0.55,compound:.medium)
        let wetTyreDistance = wetStop(depth:0.55,compound:.wet)
        print(String(format:"108 km/h stop: dry %.1f m, wet slick %.1f m, wet tyre %.1f m",dryDistance,wetSlickDistance,wetTyreDistance))
        check(wetSlickDistance > dryDistance * 1.25 && wetTyreDistance < wetSlickDistance * 0.9,
              "Surface water lengthens braking and wet tyres recover grip")
        let dryKerb = wetStop(depth:0,compound:.medium,lateral:6.45)
        let wetKerb = wetStop(depth:0.55,compound:.wet,lateral:6.45)
        let wetPaintSeam = wetStop(depth:0.55,compound:.wet,lateral:6.0)
        print(String(format:"108 km/h wet tyre: asphalt %.1f m, edge %.1f m, kerb %.1f m",wetTyreDistance,wetPaintSeam,wetKerb))
        check(dryKerb > dryDistance * 1.025 && wetKerb > wetTyreDistance * 1.11 &&
              wetPaintSeam > wetTyreDistance && wetPaintSeam < wetKerb,
              "Painted kerb has lower wet grip and the tread blends the asphalt-to-paint transition")
        func waterSplit(left: Bool) -> Vehicle {
            var car = Vehicle(); car.kind = .porsche; car.gear = 0
            car.velocity = car.forward*40
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 40/car.wheelRadius }
            let contacts = car.wheels.indices.map { i in
                WheelRoadContact(distance:0,progress:200,kerbsEnabled:false,
                                 waterDepth:(i % 2 == 1) == left ? 1.18 : 0.25)
            }
            for _ in 0..<80 {
                car.step(1/240,input:DrivingInput(brake:0.9),assists:DrivingAssists(),roadDistance:0,roadWidth:12,
                         roadContacts:contacts)
            }
            return car
        }
        let standingLeft = waterSplit(left:true), standingRight = waterSplit(left:false)
        check(abs(standingLeft.yawRate) > 0.08 && abs(standingLeft.yawRate+standingRight.yawRate) < 0.005 &&
              standingLeft.wheels[1].spray > standingLeft.wheels[0].spray*1.5,
              "Standing water weakens one side's braking and increases spray with mirrored yaw")

        // Condition model: controlled energy input isolates temperature, pressure and abrasion.
        var hotTyre = WheelState()
        func coastAtPressure(_ pressure: Double) -> Vehicle {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.velocity = car.forward*30
            car.service(setup:TyreSetup(coldPressure:pressure))
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 30/car.wheelRadius }
            for _ in 0..<3600 {
                car.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            }
            return car
        }
        let softer = coastAtPressure(1.30), firmer = coastAtPressure(2.10)
        check(softer.speedKPH < firmer.speedKPH-0.9 && softer.wheels[0].temperature > firmer.wheels[0].temperature+1,
              "Lower pressure dissipates more energy and warms the tread faster in an otherwise identical coast")
        let coldPressure = hotTyre.pressure
        for _ in 0..<1200 { hotTyre.evolve(0.1, slipPower: 12000, speed: 25, load: 3100, locked: false, grass: false) }
        check(hotTyre.temperature > 70 && hotTyre.coreTemperature > 38 && hotTyre.pressure > coldPressure,
              "Slip work heats the tread and carcass and raises tyre pressure")
        let hotTemperature = hotTyre.temperature
        for _ in 0..<1200 { hotTyre.evolve(0.1, slipPower: 0, speed: 0, load: 3100, locked: false, grass: false) }
        check(hotTyre.temperature < hotTemperature && hotTyre.temperature >= 26, "Parked tyres cool towards ambient")
        var coolTrackTyre = WheelState(), hotTrackTyre = WheelState()
        for _ in 0..<600 {
            coolTrackTyre.evolve(0.1,slipPower:0,speed:20,load:3100,locked:false,grass:false,surfaceTemperature:25)
            hotTrackTyre.evolve(0.1,slipPower:0,speed:20,load:3100,locked:false,grass:false,surfaceTemperature:45)
        }
        check(hotTrackTyre.temperature > coolTrackTyre.temperature + 1 &&
              hotTrackTyre.coreTemperature > coolTrackTyre.coreTemperature,
              "Road temperature changes tread and carcass temperature under matched loads")
        func treadSample(pressure: Double, lateral: Double, water: Double = 0) -> WheelState {
            var wheel = WheelState(); wheel.setup.coldPressure = pressure
            for _ in 0..<300 {
                wheel.evolve(0.05,slipPower:7500,speed:28,load:3100,locked:false,grass:false,
                             surfaceTemperature:28,lateralWork:lateral,waterDepth:water)
            }
            return wheel
        }
        let softTread = treadSample(pressure:1.35,lateral:0).treadTemperatures
        let firmTread = treadSample(pressure:2.1,lateral:0).treadTemperatures
        check(softTread.x > softTread.y+5 && softTread.z > softTread.y+5 &&
              firmTread.y > firmTread.x+1,
              "Low pressure concentrates scrub heat at the shoulders, high pressure at the centre")
        let outside = treadSample(pressure:1.87,lateral:0.85)
        let inside = treadSample(pressure:1.87,lateral:-0.85)
        check(outside.treadTemperatures.z > outside.treadTemperatures.x+5 &&
              simd_distance(outside.treadTemperatures,SIMD3(inside.treadTemperatures.z,inside.treadTemperatures.y,inside.treadTemperatures.x)) < 0.0001,
              "Mirrored corner loads heat opposite parts of the tread")
        let cooled = treadSample(pressure:1.87,lateral:0.85,water:1.15)
        check(cooled.temperature < outside.temperature-2 && cooled.coreTemperature < outside.coreTemperature,
              "Wet tread transfers more heat into the road than a dry tread under matched load")
        var reinstalled = Vehicle()
        reinstalled.wheels[0] = outside
        reinstalled.reset(at:circuit.start,preservingCondition:true)
        check(reinstalled.wheels[0].treadTemperatures == outside.treadTemperatures,
              "Track recovery preserves each zone's temperature")
        reinstalled.service(setup:TyreSetup())
        check(reinstalled.wheels.allSatisfy { $0.treadTemperatures == SIMD3(repeating:38) },
              "A tyre change resets all tread zones independently of the prior temperature")
        var soft = WheelState(), hard = WheelState()
        soft.setup.compound = .soft; hard.setup.compound = .hard
        for _ in 0..<1000 {
            soft.evolve(0.1, slipPower: 10000, speed: 20, load: 3100, locked: false, grass: false)
            hard.evolve(0.1, slipPower: 10000, speed: 20, load: 3100, locked: false, grass: false)
        }
        check(soft.wear > hard.wear * 2, "Soft compound wears faster under identical slip work")
        var worn = WheelState(); worn.temperature = 85; worn.coreTemperature = 65
        let freshGrip = worn.gripFactor
        worn.wear = 0.9
        check(worn.gripFactor < freshGrip * 0.75, "Worn tread reduces available grip")
        var lockedTyre = WheelState()
        for _ in 0..<500 { lockedTyre.evolve(0.1, slipPower: 50000, speed: 25, load: 3100, locked: true, grass: false) }
        check(lockedTyre.punctured && lockedTyre.flatSpot == 1 && lockedTyre.pressure < 0.1,
              "Prolonged wheel lock flat-spots the tyre, wears through and deflates it")
        var lightHit = Vehicle(); lightHit.impact(normalSpeed: 1, outwardNormal: SIMD2(1,0))
        check(lightHit.damage.worst == 0, "Parking-speed contact does not damage the car")
        var frontHit = Vehicle(); frontHit.impact(normalSpeed: 16, outwardNormal: SIMD2(0,1))
        var rearHit = Vehicle(); rearHit.impact(normalSpeed: 16, outwardNormal: SIMD2(0,-1))
        check(frontHit.damage.front > 0.5 && frontHit.damage.rear == 0 && frontHit.powerFactor < 1,
              "Front impact damages the nose and engine and reduces power")
        check(rearHit.damage.rear > 0.5 && rearHit.damage.front == 0,
              "Rear impact damages the rear independently")
        var sideHit = Vehicle(); sideHit.impact(normalSpeed: 20, outwardNormal: SIMD2(1,0))
        check(sideHit.damage.suspension[1] > sideHit.damage.suspension[0] && sideHit.wheels[1].punctured,
              "Driver-left side impact bends that suspension and can puncture its tyre")
        let damageBeforeRecovery = sideHit.damage.suspension[1]
        sideHit.reset(at: circuit.start, preservingCondition: true)
        check(sideHit.damage.suspension[1] == damageBeforeRecovery && sideHit.wheels[1].punctured && sideHit.speed == 0,
              "Track recovery preserves tyre and mechanical damage")
        for _ in 0..<600 { sideHit.step(dt,input:DrivingInput(throttle:0.6),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(sideHit.position.x.isFinite && sideHit.speed.isFinite && abs(sideHit.yawRate) < 10,
              "Bent suspension and a puncture remain numerically stable while driving")
        check(abs(sideHit.yawRate) > 0.001, "Asymmetric damage affects straight-line handling")
        let fitted = TyreSetup(compound: .hard, coldPressure: 1.8)
        sideHit.service(setup: fitted)
        check(sideHit.damage.worst == 0 && sideHit.wheels.allSatisfy { !$0.punctured && $0.wear == 0 && $0.flatSpot == 0 && $0.setup.compound == .hard && $0.setup.coldPressure == 1.8 },
              "Service repairs mechanical damage and fits the selected fresh tyre setup")
        var wornBrake = road, freshBrake = road
        for i in 0..<4 { wornBrake.wheels[i].wear = 0.95 }
        let freshStart = freshBrake.position, wornStart = wornBrake.position
        for _ in 0..<1200 {
            freshBrake.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
            wornBrake.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(simd_distance(wornBrake.position,wornStart) > simd_distance(freshBrake.position,freshStart) * 1.10,
              "Worn tyres increase measured stopping distance in the full vehicle solver")

        var endurance = Vehicle()
        endurance.impact(normalSpeed:12,outwardNormal:SIMD2(1,0))
        for frame in 0..<36000 {
            endurance.step(1.0/60,input:DrivingInput(throttle:0.6,brake:frame % 1200 > 1000 ? 0.7 : 0,steering:0.15),
                assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(endurance.speed.isFinite && endurance.position.x.isFinite && endurance.coolantTemperature <= 160 &&
            endurance.wheels.allSatisfy { $0.temperature.isFinite && $0.pressure.isFinite && (0...1).contains($0.wear) && $0.normalLoad >= 0 },
              "Ten simulated minutes with damage keep thermal, wear and motion states bounded")

        var idleEngine = Vehicle()
        for _ in 0..<7200 { idleEngine.step(1.0/60,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check((80...95).contains(idleEngine.coolantTemperature), "Thermostat keeps an idling engine near operating temperature")

        var kerbCar = Vehicle()
        kerbCar.velocity = kerbCar.forward * 15
        for w in 0..<4 { kerbCar.wheels[w].angularVelocity = 15 / kerbCar.wheelRadius }
        let leftContacts = [WheelRoadContact(distance:4.5,progress:30,kerbsEnabled:true),
            WheelRoadContact(distance:6.4,progress:30,kerbsEnabled:true),
            WheelRoadContact(distance:4.5,progress:27.2,kerbsEnabled:true),
            WheelRoadContact(distance:6.4,progress:27.2,kerbsEnabled:true)]
        kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:leftContacts)
        check(kerbCar.wheels[1].surface == .kerb && kerbCar.wheels[3].surface == .kerb && kerbCar.wheels[0].surface == .asphalt && kerbCar.wheels[2].surface == .asphalt,
              "Per-wheel contact identifies driver-left kerb while car centre remains on asphalt")
        check(kerbCar.wheels[1].suspensionTravel > kerbCar.wheels[0].suspensionTravel && kerbCar.wheels[1].kerbFeedback > 0 && kerbCar.wheels[0].kerbFeedback == 0,
              "Raised kerb compresses the contacting suspension and excites only that side")
        var parkedKerb = Vehicle()
        parkedKerb.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:leftContacts)
        check(parkedKerb.kerbFeedback == 0, "A parked wheel on a kerb produces no continuous rumble")
        let noKerb = leftContacts.map { WheelRoadContact(distance:$0.distance,progress:$0.progress,kerbsEnabled:false) }
        kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:5.5,roadWidth:12,roadContacts:noKerb)
        check(kerbCar.wheels.allSatisfy { $0.surface != .kerb }, "Wheel sampling respects the end of a kerb segment")
        for _ in 0..<120 { kerbCar.step(dt,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(kerbCar.kerbFeedback < 0.0001, "Kerb feedback decays after rejoining asphalt")
        var accelerating = Vehicle()
        for _ in 0..<360 { accelerating.step(dt,input:DrivingInput(throttle:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(accelerating.driverG.y > 0 && accelerating.wheels[2].suspensionTravel > accelerating.wheels[0].suspensionTravel,
              "Acceleration G and rear suspension compression agree with weight transfer")
        for _ in 0..<30 { accelerating.step(dt,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(accelerating.driverG.y < 0 && accelerating.wheels[0].suspensionTravel > accelerating.wheels[2].suspensionTravel,
              "Braking G and front suspension compression agree with weight transfer")
        var rightTurn = Vehicle()
        for _ in 0..<360 { rightTurn.step(dt,input:DrivingInput(throttle:0.6,steering:0.3),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(rightTurn.driverG.x > 0, "G-meter driver-right acceleration is positive")
        let points = rightTurn.contactPoints
        check(abs(simd_dot(points[1]-points[0],rightTurn.modelX)-rightTurn.trackWidth) < 1e-9 &&
              abs(simd_dot(points[0]-points[2],rightTurn.forward)-rightTurn.wheelbase) < 1e-9,
              "Contact sample locations follow both wheel track and vehicle heading")

        check(circuit.length > 1000 && circuit.length < 2500, "Closed circuit length: \(Int(circuit.length)) metres")
        let onTrack = circuit.nearest(to: circuit.start.point)
        check(onTrack.distance < 0.05, "Track projection finds the start")
        let a = circuit.sample(at: 100)
        let b = circuit.sample(at: circuit.length + 100)
        check(simd_distance(a.point, b.point) < 0.001, "Track sampling wraps continuously")
        check(lapTime(65.123) == "1:05.123", "Lap formatter preserves milliseconds")

        var session = RaceSession()
        car.reset(at: circuit.start)
        session.resetLap(at: 8)
        // Drive the whole centreline to test ordered gates and a valid finish.
        for step in 0...16000 {
            let distance = 8 + Double(step) * 0.1
            let sample = circuit.sample(at: distance)
            car.position = sample.point
            car.velocity = sample.tangent * 12
            car.heading = atan2(sample.tangent.x, sample.tangent.y)
            _ = session.step(dt, vehicle: car, location: circuit.nearest(to: car.position), trackLength: circuit.length, trackWidth: 12)
            if session.completedLaps > 0 { break }
        }
        check(session.completedLaps == 1 && session.best != nil, "Ordered checkpoint traversal records a valid lap")
        check(!session.bestGhost.isEmpty, "A valid best lap retains a ghost recording")
        var recovery = RaceSession()
        recovery.resetLap(at: circuit.length * 0.7)
        check(recovery.checkpoint == 0 && recovery.elapsed == 0, "Recovery resets checkpoint and timing state")

        for kind in [VehicleKind.centenario,.porsche] {
            var preset = Vehicle(); preset.kind = kind
            preset.reset(at:circuit.start)
            for _ in 0..<1200 { preset.step(dt,input:DrivingInput(throttle:0.7,steering:0.02),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
            check(preset.kind == kind && preset.speedKPH > 20 && preset.wheels.allSatisfy { $0.normalLoad.isFinite && $0.temperature.isFinite },
                  "Vehicle preset drives stably and survives reset: \(kind.label)")
            preset.reset(at:circuit.start,preservingCondition:true); preset.service(setup:TyreSetup())
            check(preset.kind == kind && preset.mass == kind.mass && preset.contactPoints.count == 4,"Recovery and repair preserve vehicle selection: \(kind.label)")
        }
        var slipByLevel: [Double] = [], lockByLevel: [Double] = [], cutByLevel: [Double] = []
        for level in [0,1,3,5] {
            let assists = DrivingAssists(absLevel:level,tcLevel:level)
            var car = Vehicle(); car.kind = .centenario
            var slip = 0.0, cut = 0.0
            for _ in 0..<360 {
                car.step(1.0/120,input:DrivingInput(throttle:1),assists:assists,roadDistance:9,roadWidth:12)
                slip += max(0,car.wheels[2].slipRatio); cut += car.tcReduction
            }
            slipByLevel.append(slip); cutByLevel.append(cut)
            car = Vehicle(); car.velocity = car.forward*30
            for i in 0..<4 { car.wheels[i].angularVelocity = 30/car.wheelRadius }
            var lock = 0.0, release = 0.0
            for _ in 0..<240 {
                car.step(1.0/120,input:DrivingInput(brake:1),assists:assists,roadDistance:9,roadWidth:12)
                lock += max(0,-car.wheels[0].slipRatio); release += car.absRelease
            }
            lockByLevel.append(lock)
            check(level == 0 ? (cut == 0 && release == 0) : (cut > 0 && release > 0),
                  "Assist level \(level) produces the corresponding torque and brake intervention")
        }
        check(slipByLevel[3] < slipByLevel[2] && slipByLevel[2] < slipByLevel[1] && slipByLevel[1] < slipByLevel[0],
              "Higher TCS levels progressively reduce driven-wheel slip on grass")
        check(cutByLevel[3] > cutByLevel[1],"Strong TCS measurably cuts more drive torque than weak TCS")
        check(lockByLevel[3] < lockByLevel[2] && lockByLevel[2] < lockByLevel[1] && lockByLevel[1] < lockByLevel[0],
              "Higher ABS levels progressively reduce front-wheel locking on grass")
        func steerAxles(_ kind: VehicleKind, speed: Double, input: Double) -> Vehicle {
            var car = Vehicle()
            car.kind = kind
            car.gear = 0
            car.velocity = car.forward*speed
            for i in car.wheels.indices { car.wheels[i].angularVelocity = speed/car.wheelRadius }
            for _ in 0..<100 {
                car.step(1/240,input:DrivingInput(steering:input),assists:DrivingAssists(automatic:false),
                         roadDistance:0,roadWidth:12)
            }
            return car
        }
        let slowLamborghini = steerAxles(.centenario,speed:8,input:0.45)
        let fastLamborghini = steerAxles(.centenario,speed:43,input:0.45)
        let leftLamborghini = steerAxles(.centenario,speed:8,input:-0.45)
        let conventional = steerAxles(.porsche,speed:8,input:0.45)
        let lowRatio = slowLamborghini.rearSteeringAngle/slowLamborghini.steeringAngle
        let highRatio = fastLamborghini.rearSteeringAngle/fastLamborghini.steeringAngle
        print(String(format:"Centenario rear/front steer at 29 and 155 km/h: %.3f / %.3f",lowRatio,highRatio))
        check((-0.23 ... -0.13).contains(lowRatio) && (0.07...0.13).contains(highRatio) &&
              abs(slowLamborghini.wheelSteer(2)+leftLamborghini.wheelSteer(3)) < 0.0001 &&
              slowLamborghini.wheels[2].lateralForce < 0 && conventional.wheelSteer(2) == 0,
              "Centenario steers both rear tyres opposite at low speed and together with the front at speed")
        let preview = fastLamborghini.displayPose(previous:slowLamborghini.renderSample,fraction:0.5)
        check(abs(preview.rearSteeringAngle-(fastLamborghini.rearSteeringAngle+slowLamborghini.rearSteeringAngle)/2) < 0.00001,
              "The displayed rear-wheel direction follows fixed-step interpolation")
        var rack = Vehicle()
        rack.kind = .porsche; rack.steeringAngle = 0.10
        let turbo911 = rack.handwheelAngle
        rack.steeringAngle = 0.52
        let porscheLock = rack.handwheelAngle
        rack.kind = .centenario
        check((1.48...1.50).contains(turbo911) && abs(porscheLock-0.52*13.3) < 1e-9 &&
              abs(rack.handwheelAngle-0.52*13.6) < 1e-9,
              "The cockpit follows the 911 progressive rack and Centenario linear ratio")
        var exitCar = Vehicle()
        exitCar.kind = .centenario
        exitCar.gear = 2
        exitCar.velocity = exitCar.forward*16
        for i in exitCar.wheels.indices { exitCar.wheels[i].angularVelocity = 16/exitCar.wheelRadius }
        let pool = Array(repeating:WheelRoadContact(distance:0,progress:20,kerbsEnabled:false,waterDepth:0.8),count:4)
        var wheelspin = 0.0
        for _ in 0..<480 {
            exitCar.step(1/240,input:DrivingInput(throttle:0.85,steering:0.4),assists:DrivingAssists(automatic:false),
                         roadDistance:0,roadWidth:12,roadContacts:pool)
            wheelspin += max(0,exitCar.wheels[2].slipRatio,exitCar.wheels[3].slipRatio)/240
        }
        check(exitCar.speedKPH > 73 && wheelspin < 0.28,
              "Wet corner exit keeps acceleration while traction control limits combined-load wheelspin")
        for kind in CircuitKind.allCases {
            let map = Circuit(kind:kind)
            var minGap = Double.infinity
            for a in map.samples { for b in map.samples {
                let d = abs(a.distance-b.distance)
                if min(d,map.length-d)>60 { minGap = min(minGap,simd_distance(a.point,b.point)) }
            }}
            check(minGap > 32,"Track road and barrier corridors do not overlap: \(kind.label)")
            check(simd_distance(map.sample(at:-0.01).point,map.sample(at:0.01).point)<0.03 && map.samples.allSatisfy { map.nearest(to:$0.point).distance<0.001 },
                  "Track projection and finish seam remain continuous: \(kind.label)")
            var session = RaceSession(), car = Vehicle(); session.resetLap(at:map.start.distance)
            for step in 0...Int(map.length+30) {
                let sample = map.sample(at:8+Double(step))
                car.position = sample.point; car.velocity = sample.tangent*10; car.heading = atan2(sample.tangent.x,sample.tangent.y)
                _ = session.step(0.1,vehicle:car,location:map.nearest(to:car.position),trackLength:map.length,trackWidth:map.width)
                if session.completedLaps>0 { break }
            }
            check(session.completedLaps == 1 && session.best != nil,"A complete ordered lap can be recorded on \(kind.label)")
        }
        for kind in VehicleKind.allCases {
            var turning = Vehicle(); turning.kind = kind; turning.steeringAngle = 0.3
            let leftRadius = turning.wheelbase/tan(turning.wheelSteer(1)) + turning.trackWidth/2
            let rightRadius = turning.wheelbase/tan(turning.wheelSteer(0)) - turning.trackWidth/2
            check(turning.wheelSteer(1)>turning.wheelSteer(0) && abs(leftRadius-rightRadius)<1e-8,
                  "Inner and outer front wheels share a turning centre: \(kind.label)")
            turning.steeringAngle = -0.3
            check(abs(turning.wheelSteer(0))>abs(turning.wheelSteer(1)) && turning.wheelSteer(2)==0,
                  "Ackermann geometry mirrors correctly for driver-right: \(kind.label)")
            func laneChange(_ step:Double, _ sign:Double) -> Vehicle {
                var car=Vehicle(); car.kind=kind; car.velocity=car.forward*30
                for i in 0..<4 { car.wheels[i].angularVelocity=30/car.wheelRadius }
                for frame in 0..<Int(6/step) {
                    let t=Double(frame)*step
                    let steer=t<2 ? sign*0.35*sin(t * .pi) : 0
                    car.step(step,input:DrivingInput(throttle:0.12,steering:steer),assists:DrivingAssists(),roadDistance:0,roadWidth:12,kerbsEnabled:false)
                }
                return car
            }
            let a=laneChange(1/120,1), b=laneChange(1/120,-1), fine=laneChange(1/240,1)
            check(a.speed.isFinite && abs(a.yawRate)<0.015 && abs(a.roll)<0.005 && abs(a.steeringAngle)<0.0001,
                  "108 km/h double lane change settles after steering release: \(kind.label)")
            check(abs(a.position.x+b.position.x)<0.02 && abs(a.position.y-b.position.y)<0.02,
                  "Mirrored double lane changes have symmetric responses: \(kind.label)")
            check(simd_distance(a.position,fine.position)<0.25 && abs(a.yawRate-fine.yawRate)<0.01,
                  "Lane-change path converges across 120/240 Hz outer timesteps: \(kind.label)")
            check(a.wheels.allSatisfy { abs($0.rotation)<2 * .pi && $0.normalLoad>=0 && $0.relaxedSlipAngle.isFinite },
                  "Wheel phase and tyre state remain bounded after repeated rotation: \(kind.label)")
        }
        var coasting=Vehicle(); coasting.wheels[3].angularVelocity=0.000001
        coasting.step(1/720,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        check(coasting.tcReduction==0 && !coasting.tcActive,
              "Tiny differential torques with closed throttle cannot report TCS intervention")
        func atSpeed(_ kind: VehicleKind, _ input: DrivingInput) -> Vehicle {
            var sample = Vehicle(); sample.kind = kind; sample.gear = 3
            sample.velocity = sample.forward*30
            for i in sample.wheels.indices { sample.wheels[i].angularVelocity = 30/sample.wheelRadius }
            for _ in 0..<120 {
                sample.step(1/240,input:input,assists:DrivingAssists(automatic:false),roadDistance:0,roadWidth:12)
            }
            return sample
        }
        let centred = atSpeed(.centenario,DrivingInput(throttle:0.15,steering:0.2))
        let committed = atSpeed(.centenario,DrivingInput(throttle:0.15,steering:0.65))
        check((0.15...0.28).contains(centred.driverG.x) && committed.driverG.x > 0.60,
              "High-speed corrections are progressive while larger inputs can still corner hard")
        func steeringSample(_ curve: SteeringCurve, axis: Double) -> Vehicle {
            var sample = Vehicle(); sample.kind = .centenario; sample.gear = 3
            sample.velocity = sample.forward*30
            for i in sample.wheels.indices { sample.wheels[i].angularVelocity = 30/sample.wheelRadius }
            var assists = DrivingAssists(automatic:false); assists.steeringCurve = curve
            for _ in 0..<100 {
                sample.step(1/240,input:DrivingInput(throttle:0.15,steering:axis),assists:assists,roadDistance:0,roadWidth:12)
            }
            return sample
        }
        let precision = steeringSample(.precision,axis:0.2), direct = steeringSample(.direct,axis:0.2)
        let precisionFull = steeringSample(.precision,axis:1), directFull = steeringSample(.direct,axis:1)
        check(direct.driverG.x > precision.driverG.x*1.5 &&
              abs(directFull.steeringAngle-precisionFull.steeringAngle) < 1e-9 &&
              precisionFull.driverG.x > 0.6,
              "Precision mode reduces small corrections without removing full steering authority")
        var steeringNoise = steeringSample(.precision,axis:0)
        var noisePeak = 0.0
        for i in 0..<120 {
            steeringNoise.step(1/240,input:DrivingInput(steering:i%8 < 4 ? 0.035 : -0.035),
                               assists:DrivingAssists(automatic:false),roadDistance:0,roadWidth:12)
            noisePeak = max(noisePeak,abs(steeringNoise.steeringAngle))
        }
        var reversal = steeringSample(.standard,axis:0.4)
        for _ in 0..<20 {
            reversal.step(1/240,input:DrivingInput(steering:-0.6),assists:DrivingAssists(automatic:false),
                          roadDistance:0,roadWidth:12)
        }
        check(noisePeak < 0.0007 && reversal.steeringAngle > 0.035,
              "The high-speed rack quiets chatter but crosses centre promptly on deliberate countersteer")
        let lift = atSpeed(.centenario,DrivingInput(throttle:0.049))
        let tip = atSpeed(.centenario,DrivingInput(throttle:0.051))
        check(abs(lift.longitudinalG-tip.longitudinalG)<0.005,
              "The transition into engine braking is continuous around closed throttle")
        let lightBrake = atSpeed(.porsche,DrivingInput(brake:0.25))
        let mediumBrake = atSpeed(.porsche,DrivingInput(brake:0.50))
        let deepBrake = atSpeed(.porsche,DrivingInput(brake:0.75))
        let fullBrake = atSpeed(.porsche,DrivingInput(brake:1))
        check((-0.32 ... -0.18).contains(lightBrake.longitudinalG) &&
              lightBrake.longitudinalG - mediumBrake.longitudinalG > 0.2 &&
              mediumBrake.longitudinalG - deepBrake.longitudinalG > 0.2 &&
              fullBrake.longitudinalG < -0.85 && !lightBrake.absActive && fullBrake.absActive,
              "The lightest preset builds braking progressively, with ABS reserved for deep braking on asphalt")
        var releaseBrake = deepBrake
        for _ in 0..<20 {
            releaseBrake.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        check(releaseBrake.brakeLinePressure < 0.01 && releaseBrake.absRelease == 0,
              "Releasing a deeply pressed pedal clears pressure and ABS promptly")
        var transient=Vehicle(); transient.velocity=transient.forward*20; transient.steeringAngle=0.12
        for i in 0..<4 { transient.wheels[i].angularVelocity=20/transient.wheelRadius }
        transient.step(1/720,input:DrivingInput(steering:-0.6),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        let firstForce=abs(transient.wheels[0].lateralForce)
        check(abs(transient.wheels[0].relaxedSlipAngle)<abs(transient.wheels[0].slipAngle)*0.2,
              "A sudden steer builds contact-patch deflection progressively")
        for _ in 0..<12 { transient.step(1/720,input:DrivingInput(steering:-0.6),assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
        check(abs(transient.wheels[0].lateralForce)>firstForce*2,
              "Lateral tyre force builds over travelled distance after steering input")
        func firstCornerResponse(pressure: Double) -> Double {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.service(setup:TyreSetup(coldPressure:pressure))
            car.velocity = car.forward*20
            car.steeringAngle = -0.12
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 20/car.wheelRadius }
            car.step(1/720,input:DrivingInput(steering:0.7),assists:DrivingAssists(automatic:false),
                     roadDistance:0,roadWidth:12)
            return abs(car.wheels[0].relaxedSlipAngle/car.wheels[0].slipAngle)
        }
        let softResponse = firstCornerResponse(pressure:1.30)
        let firmResponse = firstCornerResponse(pressure:2.10)
        check((0.03...0.12).contains(softResponse) && firmResponse > softResponse*1.2,
              "Tyre inflation changes initial cornering-force buildup while preserving a transient response")
        var longitudinal = Vehicle()
        longitudinal.gear = 0
        longitudinal.velocity = longitudinal.forward * 20
        for i in longitudinal.wheels.indices {
            longitudinal.wheels[i].angularVelocity = 19 / longitudinal.wheelRadius
        }
        longitudinal.step(1/720,input:DrivingInput(brake:1),assists:DrivingAssists(abs:false),roadDistance:0,roadWidth:12)
        let patch = longitudinal.wheels[0]
        check(patch.longitudinalForce < 0 && abs(patch.relaxedSlipRatio) < abs(patch.slipRatio)*0.3,
              "Longitudinal grip builds through the contact patch instead of jumping to the kinematic slip")
        func edgeForce(at distance: Double) -> Double {
            var car = Vehicle()
            car.gear = 0
            car.velocity = car.forward * 20
            for i in car.wheels.indices {
                car.wheels[i].angularVelocity = 17 / car.wheelRadius
                car.wheels[i].relaxedSlipRatio = -0.15
            }
            let contacts = Array(repeating:WheelRoadContact(distance:distance,progress:0,kerbsEnabled:false),count:4)
            car.step(1/720,input:DrivingInput(brake:1),assists:DrivingAssists(abs:false),roadDistance:distance,roadWidth:12,roadContacts:contacts)
            return abs(car.wheels[0].longitudinalForce)
        }
        let roadForce = edgeForce(at:6.23)
        let grassForce = edgeForce(at:6.47)
        let edgeStep = abs(edgeForce(at:6.349)-edgeForce(at:6.351))
        check(roadForce > grassForce*1.5 && edgeStep < (roadForce-grassForce)*0.05,
              "A wheel crossing the grass edge loses grip progressively across the tread")
        if failures > 0 { exit(1) }
        print("\nAll physics and timing checks passed.")
    }

    static func checkTrackDrying() {
        let circuit = Circuit(kind:.grand,condition:.wet)
        var drying = TrackDrying(circuit:circuit)
        let massFilm = 0.75
        check(drying.depth(from:massFilm,at:500,lateral:0) == massFilm,
              "A drying race begins with the exact baseline water film")
        let speed = 28.0, dt = TrackDrying.interval
        for _ in 0..<12 {
            for progress in stride(from:466.0,through:554,by:speed*dt) {
                drying.advance(dt)
                for lane in [-0.8,0.8] {
                    drying.displace(at:progress,lateral:lane,travelled:speed*dt,speed:speed,load:3450,treadWidth:0.24)
                    drying.displace(at:progress-2.6,lateral:lane,travelled:speed*dt,speed:speed,load:3450,treadWidth:0.24)
                }
            }
        }
        let line = drying.depth(from:massFilm,at:500,lateral:0.8)
        let outside = drying.depth(from:massFilm,at:500,lateral:3.6)
        print(String(format:"Track drying after repeated traffic: %.3f mm on line, %.3f mm clear of traffic",line,outside))
        check(line < outside-0.13 && line >= 0.035 && outside < massFilm && outside > massFilm-0.02,
              "Only driven areas lose significant water while nearby wet tarmac remains damp")
        check(drying.depth(from:massFilm,at:500,lateral:6.1) == massFilm,
              "The track surface grid does not alter the verge or kerb beyond the driving surface")
        var parked = drying
        for _ in 0..<20 {
            parked.displace(at:500,lateral:0.8,travelled:0,speed:0,load:3600,treadWidth:0.26)
        }
        check(parked.depth(from:massFilm,at:500,lateral:0.8) == line,
              "Stationary tyres do not continuously displace water")
        let beforeRunoff = outside-line
        for _ in 0..<40 { parked.advance(1) }
        let remainingContrast = parked.depth(from:massFilm,at:500,lateral:3.6)-parked.depth(from:massFilm,at:500,lateral:0.8)
        check(remainingContrast > 0 && remainingContrast < beforeRunoff*0.77,
              "Runoff gradually reduces sharp differences when the cars have gone")

        var seam = TrackDrying(circuit:circuit)
        seam.advance(dt)
        seam.displace(at:circuit.length-0.4,lateral:0.4,travelled:1.2,speed:24,load:3200,treadWidth:0.21)
        let d100 = seam.depth(from:massFilm,at:circuit.length-0.001,lateral:0.4)
        let d0 = seam.depth(from:massFilm,at:0.001,lateral:0.4)
        check(abs(d100-d0) < 0.0002 && d100 < massFilm-0.003,"Water marks stay continuous across the lap seam")
        let onLine = circuit.sample(at:500)
        let patch = onLine.point+onLine.right*0.8
        let nominal = circuit.wheelContacts(at:[patch])[0]
        let wornLine = circuit.wheelContacts(at:[patch],drying:drying)[0]
        check(wornLine.waterDepth < nominal.waterDepth*0.75 && wornLine.distance == nominal.distance &&
              wornLine.elevation == nominal.elevation && wornLine.gradient == nominal.gradient,
              "The same ground contact feeds the vehicle solver with local water and unchanged track geometry")
        func roll(contact: WheelRoadContact) -> Vehicle {
            var car = Vehicle()
            car.kind = .porsche
            car.service(setup:TyreSetup(compound:.wet))
            car.velocity = car.forward*speed
            for i in car.wheels.indices { car.wheels[i].angularVelocity = (speed-2)/car.wheelRadius }
            car.step(1/240,input:DrivingInput(brake:0.4),assists:DrivingAssists(),roadDistance:0,roadWidth:12,
                     roadContacts:Array(repeating:contact,count:4))
            return car
        }
        let soaked = roll(contact:nominal), cleared = roll(contact:wornLine)
        check(cleared.wheels[0].spray < soaked.wheels[0].spray && cleared.wheels[0].waterFilm < soaked.wheels[0].waterFilm &&
              abs(cleared.wheels[0].longitudinalForce) > abs(soaked.wheels[0].longitudinalForce),
              "A rolling wet tyre gets less spray and more longitudinal grip where traffic has cleared water")
    }

    static func checkTreadWidths() {
        // All wheels are sampled at the same lateral coordinate to isolate
        // contact width from track width, steering and weight distribution.
        let grassEdge = 6.35
        func sample(_ kind: VehicleKind,at distance: Double,painted: Bool = false) -> Vehicle {
            var car = Vehicle()
            car.kind = kind
            car.gear = 0
            car.velocity = car.forward*22
            for i in car.wheels.indices {
                car.wheels[i].angularVelocity = 17/car.wheelRadius
                car.wheels[i].relaxedSlipRatio = -0.23
            }
            let contacts = Array(repeating:WheelRoadContact(distance:distance,progress:20,
                kerbsEnabled:painted,waterDepth:0.65),count:4)
            car.step(1/720,input:DrivingInput(brake:1),assists:DrivingAssists(abs:false),roadDistance:distance,
                     roadWidth:12,roadContacts:contacts)
            return car
        }

        let lamborghiniOutside = sample(.centenario,at:grassEdge+0.12)
        let porscheOutside = sample(.porsche,at:grassEdge+0.12)
        check(lamborghiniOutside.wheels[0].pavedContactFraction == 0 &&
              lamborghiniOutside.wheels[2].pavedContactFraction > 0.03 &&
              porscheOutside.wheels[0].pavedContactFraction == 0 &&
              porscheOutside.wheels[2].pavedContactFraction > 0 &&
              porscheOutside.wheels[2].pavedContactFraction < lamborghiniOutside.wheels[2].pavedContactFraction,
              "Both staggered rear treads retain contact farther beyond the verge, especially the wider Centenario")
        let shoulders = stride(from:-0.19,through:0.19,by:0.01).map {
            sample(.porsche,at:grassEdge+$0).wheels[2].pavedContactFraction
        }
        check(shoulders.first == 1 && shoulders.last == 0 &&
              zip(shoulders,shoulders.dropFirst()).allSatisfy { $0 >= $1 } &&
              shoulders.contains { (0.48...0.52).contains($0) },
              "A wide tyre blends through a monotone, centred contact transition")
        let paintedApproach = sample(.centenario,at:5.88,painted:true)
        let plainRoad = sample(.centenario,at:5.88)
        check(paintedApproach.wheels[0].longitudinalForce == plainRoad.wheels[0].longitudinalForce &&
              abs(paintedApproach.wheels[2].longitudinalForce) < abs(plainRoad.wheels[2].longitudinalForce),
              "A wide rear tread reaches the wet paint first while the narrower front stays on asphalt")
    }

    static func checkTrailBrakeCountersteer() {
        let dt = 1.0/240
        let assists = DrivingAssists()
        for kind in VehicleKind.allCases {
            for condition in TrackCondition.allCases {
                let circuit = Circuit(kind:.north,condition:condition)
                let setup = TyreSetup(compound:condition == .wet ? .wet : .medium)
                var car = Vehicle()
                car.kind = kind
                car.reset(at:circuit.sample(at:32))
                car.service(setup:setup)
                car.velocity = car.forward*31
                car.gear = 3
                car.rpm = car.speed/car.wheelRadius*car.gearRatios[2]*kind.finalDrive*60/(2 * .pi)
                for index in car.wheels.indices {
                    car.wheels[index].angularVelocity = car.speed/car.wheelRadius
                    car.wheels[index].temperature = setup.compound.optimum
                    car.wheels[index].coreTemperature = (setup.compound.optimum+26)/2
                }
                var input = DrivingInput()
                var forces: [Double] = []
                var load = 0.0
                for step in 0..<240 {
                    let time = Double(step)*dt-0.85
                    if time > 0.12 { break }
                    if step.isMultiple(of:2) {
                        let steering = 0.30*tanh((time+0.27)*18)-0.52*tanh(max(time,0)*26)
                        input = DrivingInput(brake:time < 0 ? 0.84 : 0,steering:steering)
                    }
                    let location = circuit.nearest(to:car.position)
                    car.step(dt,input:input,assists:assists,roadDistance:location.distance,roadWidth:circuit.width,
                             roadLateral:location.lateral,roadProgress:location.progress,
                             roadContacts:circuit.wheelContacts(at:car.contactPoints))
                    if time >= -0.02 {
                        forces.append(car.wheels[0].lateralForce+car.wheels[1].lateralForce)
                        load += car.wheels[0].normalLoad+car.wheels[1].normalLoad
                    }
                }
                var squaredChanges = 0.0
                for index in 2..<forces.count {
                    let change = forces[index]-2*forces[index-1]+forces[index-2]
                    squaredChanges += change*change
                }
                let rmsForceChange = sqrt(squaredChanges/Double(forces.count-2))
                let normalized = rmsForceChange/(load/Double(forces.count))
                print(String(format:"%@ %@ · front-force transient %.3f%% of mean axle load",kind.label,condition.label,normalized*100))
                check(normalized < 0.0115,"The combined-slip brake release keeps the front axle response smooth on \(condition.label): \(kind.label)")
            }
        }
    }

    static func checkABSValveRefill() {
        var wetRelease: Vehicle?
        for wet in [false,true] {
            for rate in [240,1440] {
                let dt = 1.0/Double(rate)
                let contacts = Array(repeating:WheelRoadContact(distance:0,progress:20,kerbsEnabled:false,
                                                               waterDepth:wet ? 0.55 : 0),count:4)
                var car = Vehicle()
                car.kind = .porsche
                car.gear = 0
                car.service(setup:TyreSetup(compound:wet ? .wet : .medium))
                car.velocity = car.forward*34
                for i in car.wheels.indices {
                    car.wheels[i].angularVelocity = car.speed/car.wheelRadius
                    car.wheels[i].temperature = wet ? 57 : 80
                }
                let assists = DrivingAssists(automatic:false)
                for frame in 0..<rate/4 {
                    let elapsed = Double(frame)*dt
                    let steering = 0.85*clamp((elapsed-0.17)/0.20,0,1)
                    car.step(dt,input:DrivingInput(brake:0.99,steering:steering),assists:assists,
                             roadDistance:0,roadWidth:12,roadContacts:contacts)
                }

                var crossing = false
                var rebounded = false
                for frame in 1...rate/8 {
                    let previousLine = car.brakeLinePressure
                    let previous = car.wheels.map { $0.brakePressure*previousLine }
                    let steering = 0.85*clamp((Double(frame)*dt+0.08)/0.20,0,1)
                    let controls = DrivingInput(steering:steering)
                    car.step(dt,input:controls,assists:assists,roadDistance:0,roadWidth:12,roadContacts:contacts)
                    guard previousLine > 0.025, car.brakeLinePressure <= 0.025 else { continue }
                    crossing = true
                    rebounded = car.wheels.indices.contains { i in
                        car.wheels[i].brakePressure*car.brakeLinePressure > previous[i]+1e-8
                    }
                    // At the live cadence an outer step can straddle the threshold.
                    car.step(dt,input:controls,assists:assists,roadDistance:0,roadWidth:12,roadContacts:contacts)
                    if wet && rate == 240 { wetRelease = car }
                    break
                }
                check(crossing && !rebounded && !car.absActive && car.wheels.contains { $0.brakePressure < 0.9 },
                      "Caliper pressure continues falling when ABS commands end on \(wet ? "wet" : "dry") asphalt at \(rate) Hz")
            }
        }

        guard let wetRelease else {
            check(false,"Wet ABS refill has a live state to reset")
            return
        }
        func cleared(_ car: Vehicle) -> Bool {
            !car.absActive && car.absRelease == 0 && car.absValveActivity == 0 &&
                car.wheels.allSatisfy { $0.brakePressure == 1 }
        }
        var disabled = wetRelease
        disabled.step(1/240,input:DrivingInput(),assists:DrivingAssists(abs:false),roadDistance:0,roadWidth:12)
        var restarted = wetRelease
        restarted.reset(at:TrackSample(point:.zero,tangent:SIMD2(0,1),distance:0),preservingCondition:true)
        check(cleared(disabled) && cleared(restarted) && restarted.brakeLinePressure == 0,
              "Disabling ABS and restarting both discard retained caliper modulation")

        for work in PitServiceWork.allCases {
            var serviced = wetRelease
            serviced.damage.front = 0.38
            let pressure = serviced.brakeLinePressure
            let before = serviced.wheels
            serviced.completePitService(PitServicePlan(work:work,damage:serviced.damage,tyreSetup:TyreSetup()))
            check(cleared(serviced) && serviced.brakeLinePressure == pressure &&
                    zip(before,serviced.wheels).allSatisfy {
                        $0.brakeTemperature == $1.brakeTemperature && $0.brakeSurfaceTemperature == $1.brakeSurfaceTemperature
                    },
                  "Pit work clears caliper modulation and keeps rotor heat: \(work.rawValue)")
        }
    }

    static func checkSmallBrakeCorrections() {
        for kind in VehicleKind.allCases {
            var car = Vehicle()
            car.kind = kind
            car.velocity = car.forward * 32
            car.gear = 3
            for index in car.wheels.indices { car.wheels[index].angularVelocity = 32/car.wheelRadius }
            let assists = DrivingAssists(), step = 1.0/240
            let base = 0.11, increment = 0.012
            for _ in 0..<112 {
                car.step(step,input:DrivingInput(brake:Vehicle.brakeTravel(for:base),steering:0.22),
                         assists:assists,roadDistance:0,roadWidth:12)
            }
            func settlingSteps(direction: Double) -> Int {
                var trial = car
                let input = DrivingInput(brake:Vehicle.brakeTravel(for:base+direction*increment),steering:0.22)
                for index in 1...40 {
                    trial.step(step,input:input,assists:assists,roadDistance:0,roadWidth:12)
                    if direction*(trial.brakeLinePressure-base) >= 0.9*increment { return index }
                }
                return 41
            }
            let increase = settlingSteps(direction:1), decrease = settlingSteps(direction:-1)
            check((6...9).contains(increase) && abs(increase-decrease) <= 1,
                  "A small increase in settled brake pressure follows the pedal as readily as a small release: \(kind.label)")
        }
    }

    static func checkTrailBrakeRamp() {
        var assists = DrivingAssists(abs:false,tractionControl:false,automatic:false)
        var car = Vehicle()
        car.kind = .porsche
        car.gear = 0
        car.velocity = car.forward * 28
        for i in car.wheels.indices {
            car.wheels[i].angularVelocity = 28 / car.wheelRadius
            car.wheels[i].temperature = 57
        }
        let dt = 1.0 / 240
        for _ in 0..<60 {
            car.step(dt,input:DrivingInput(brake:0.75),assists:assists,roadDistance:0,roadWidth:12)
        }
        var sumError = 0.0, peakError = 0.0
        var monotone = true
        for frame in 1...96 {
            let t = Double(frame) / 96
            let travel = 0.75 - 0.60 * t
            let previous = car.brakeLinePressure
            car.step(dt,input:DrivingInput(brake:travel,steering:0.55*t),assists:assists,roadDistance:0,roadWidth:12)
            let error = abs(car.brakeLinePressure - assists.brakeCurve.pressure(for:travel))
            monotone = monotone && car.brakeLinePressure <= previous
            sumError += error
            peakError = max(peakError,error)
        }
        print(String(format:"911 400 ms trail ramp: mean / peak line pressure error %.2f / %.2f percentage points",
                     sumError*100/96,peakError*100))
        check(monotone && sumError/96 < 0.015 && peakError < 0.025 && car.yawRate < -0.20,
              "A rolling brake release tracks the pedal through turn-in without a pressure rebound")

        for curve in BrakeCurve.allCases {
            assists.brakeCurve = curve
            let travel = Vehicle.brakeTravel(for:0.001,curve:curve)
            let expected = curve.pressure(for:travel)
            let command = DrivingInput(brake:travel)
            var reapplied = car, retained = car
            for _ in 0..<60 {
                reapplied.step(dt,input:DrivingInput(),assists:assists,roadDistance:0,roadWidth:12)
            }
            for _ in 0..<240 {
                reapplied.step(dt,input:command,assists:assists,roadDistance:0,roadWidth:12)
                retained.step(dt,input:command,assists:assists,roadDistance:0,roadWidth:12)
            }
            check(abs(reapplied.brakeLinePressure-expected) < 1e-6 && abs(retained.brakeLinePressure-expected) < 1e-6,
                  "A feathered pedal can rebuild the same low line pressure after an apex lift: \(curve.label)")
        }
    }

    static func checkCombinedSlip() {
        let assists = DrivingAssists(abs:false, tractionControl:false, automatic:false)
        var locked = Vehicle()
        locked.kind = .porsche
        locked.gear = 0
        for _ in 0..<80 {
            locked.step(1/240,input:DrivingInput(brake:1),assists:assists,roadDistance:0,roadWidth:12)
        }
        locked.velocity = locked.forward * 24 + locked.modelX * 4
        locked.steeringAngle = -0.18
        for index in locked.wheels.indices {
            locked.wheels[index].relaxedSlipRatio = -1
        }
        locked.step(1/720,input:DrivingInput(brake:1,steering:1),assists:assists,roadDistance:0,roadWidth:12)
        let contact = locked.wheels[0]
        let steer = locked.wheelSteer(0)
        let along = contact.longitudinalForce * cos(steer) - contact.lateralForce * sin(steer)
        let across = contact.lateralForce * cos(steer) + contact.longitudinalForce * sin(steer)
        check(contact.angularVelocity == 0 && contact.slidingFraction == 1 &&
              along < 0 && abs(across / along - 4.0 / 24.0) < 1e-6,
              "A fully locked steered wheel slides against its ground velocity even during a steering transient")

        var entry = Vehicle()
        entry.kind = .porsche
        entry.gear = 0
        entry.velocity = entry.forward * 28
        for index in entry.wheels.indices {
            entry.wheels[index].angularVelocity = 28 / entry.wheelRadius
            entry.wheels[index].temperature = 57
        }
        func applyPedal(_ car: inout Vehicle, travel: Double, frames: Int) {
            for _ in 0..<frames {
                car.step(1/240,input:DrivingInput(brake:travel,steering:0.62),assists:assists,roadDistance:0,roadWidth:12)
            }
        }
        applyPedal(&entry,travel:0.90,frames:84)
        var held = entry, eased = entry, released = entry
        applyPedal(&held,travel:0.90,frames:48)
        applyPedal(&eased,travel:0.45,frames:48)
        applyPedal(&released,travel:0,frames:48)
        func frontLateralForce(_ car: Vehicle) -> Double {
            abs(car.wheels[0].lateralForce + car.wheels[1].lateralForce)
        }
        let heldForce = frontLateralForce(held)
        let easedForce = frontLateralForce(eased)
        let releasedForce = frontLateralForce(released)
        print(String(format:"911 combined slip after 200 ms: front lateral force %.0f / %.0f / %.0f N at 90 / 45 / 0 percent brake",
                     heldForce,easedForce,releasedForce))
        check(held.wheels[0].slidingFraction > 0.99 && abs(held.wheels[0].slipRatio) > 0.99 &&
              abs(released.wheels[0].slipRatio) < 0.08 && easedForce > heldForce * 1.3 &&
              releasedForce > heldForce * 2 && abs(released.yawRate) > abs(held.yawRate),
              "Progressive brake release restores front cornering force and yaw authority on the same turn-in")
    }

    static func checkStandingWaterPressure() {
        let pressures = [1.30,1.80,2.30]
        let speed = 45.0
        func slidingForce(compound: TyreCompound,depth: Double,pressure: Double) -> Double {
            var car = Vehicle()
            car.kind = .porsche
            car.gear = 0
            car.service(setup:TyreSetup(compound:compound,coldPressure:pressure))
            car.velocity = car.forward*speed
            for index in car.wheels.indices {
                car.wheels[index].coreTemperature = 26
                car.wheels[index].temperature = compound.optimum
            }
            let contacts = Array(repeating:WheelRoadContact(distance:0,progress:0,kerbsEnabled:false,
                                                            waterDepth:depth),count:4)
            // A single tyre substep keeps both surfaces at the same load and pressure.
            car.step(1.0/720,input:DrivingInput(brake:1),assists:DrivingAssists(abs:false,automatic:false),
                     roadDistance:0,roadWidth:12,roadContacts:contacts)
            return abs(car.wheels[0].longitudinalForce)
        }
        for compound in [TyreCompound.medium,.wet] {
            let unchanged = [0.0,0.35,0.55].allSatisfy { depth in
                pressures.allSatisfy {
                    compound.wetGrip(waterDepth:depth,speed:speed,pressure:$0) ==
                        compound.wetGrip(waterDepth:depth,speed:speed)
                }
            }
            let standing = pressures.map { compound.wetGrip(waterDepth:1.30,speed:speed,pressure:$0) }
            let shallow = compound.wetGrip(waterDepth:0.55,speed:speed)
            let existingLoss = shallow-standing[1]
            check(unchanged && compound.wetGrip(waterDepth:1.30,speed:13,pressure:pressures[0]) ==
                  compound.wetGrip(waterDepth:1.30,speed:13),
                  "Dry, damp and low-speed friction are exactly independent of the standing-water pressure correction")
            check(standing[0] < standing[1] && standing[1] < standing[2] &&
                  standing.allSatisfy { abs($0-standing[1]) <= existingLoss*0.08+1e-12 },
                  "Standing water increases low-pressure grip loss with a bounded high-pressure recovery")
            let forceRatios = pressures.map { pressure in
                slidingForce(compound:compound,depth:1.30,pressure:pressure) /
                    slidingForce(compound:compound,depth:0.55,pressure:pressure)
            }
            check(zip(forceRatios,standing).allSatisfy { abs($0-$1/shallow) < 1e-9 },
                  "The solver uses live gauge pressure for the individual tyre's wet contact force")
        }
    }

    static func checkRidgeProfile() {
        let ridge = Circuit(kind:.ridge)
        let dry = Circuit()
        let crest = ridge.length * 0.30, hollow = ridge.length * 0.66
        let gradeProgress = ridge.length * 0.192
        let grade = ridge.roadProfile(at:gradeProgress).grade
        let bank = ridge.roadProfile(at:crest).crossfall
        check(abs(ridge.roadProfile(at:crest).height-21) < 0.01 &&
              abs(ridge.roadProfile(at:hollow).height+12) < 0.01 &&
              (0.07...0.09).contains(grade) && abs(bank-0.062) < 0.0001,
              "Ridge Ring has a 33 m elevation range and 6.2% banking at its crest")
        check(stride(from:-108.0,to:155,by:1).allSatisfy {
            ridge.roadProfile(at:$0,lateral:10).height == 0
        } && dry.roadProfile(at:gradeProgress,lateral:3).height == 0,
              "Pit entry, timing seam, grid and existing flat circuits stay level")
        let maximumSlopeError = (0..<150).map { i in
            let progress = ridge.length * Double(i)/150
            let slope = ridge.roadProfile(at:progress,lateral:4).grade
            let numerical = (ridge.roadProfile(at:progress+0.02,lateral:4).height -
                             ridge.roadProfile(at:progress-0.02,lateral:4).height)/0.04
            return abs(slope-numerical)
        }.max() ?? 1
        check(maximumSlopeError < 0.0001, "Ridge Ring elevation and longitudinal gradient agree at each sample")
        func coast(reversed: Bool) -> Double {
            let sample = ridge.sample(at:gradeProgress)
            let tangent = reversed ? -sample.tangent : sample.tangent
            var car = Vehicle(); car.kind = .porsche
            car.reset(at:TrackSample(point:sample.point,tangent:tangent,distance:sample.distance))
            car.gear = 0; car.velocity = tangent * 20
            for i in car.wheels.indices { car.wheels[i].angularVelocity = 20/car.wheelRadius }
            for _ in 0..<240 {
                car.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12,
                         roadContacts:ridge.wheelContacts(at:car.contactPoints))
            }
            return car.speed
        }
        let uphill = coast(reversed:false), downhill = coast(reversed:true)
        print(String(format:"Ridge coasting after one second from 72 km/h: %.2f uphill, %.2f downhill km/h",uphill*3.6,downhill*3.6))
        check(uphill < 19.4 && downhill > 20.25 && downhill-uphill > 1.3,
              "The same car gains speed downhill and slows on the matched climb")
        var crestCar = Vehicle(); crestCar.kind = .porsche; crestCar.reset(at:ridge.sample(at:crest))
        for _ in 0..<480 {
            crestCar.step(1/240,input:DrivingInput(brake:1),assists:DrivingAssists(),roadDistance:0,roadWidth:12,
                          roadContacts:ridge.wheelContacts(at:crestCar.contactPoints))
        }
        check(abs(crestCar.roadElevation-21) < 0.02 && crestCar.roll > 0.04 &&
              crestCar.wheels.allSatisfy { $0.normalLoad > 1800 && $0.normalLoad < 5000 } &&
              abs(crestCar.wheels.reduce(0) { $0+$1.normalLoad } - crestCar.mass*9.81) < crestCar.mass*9.81*0.02,
              "A stopped car follows the crest bank with all four wheels loaded")
    }
}

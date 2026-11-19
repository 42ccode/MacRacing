import AVFoundation

@main struct AudioChecks {
    /// Eight seconds in the cockpit under identical driver inputs on level asphalt.
    static func renderDrive(_ kind: VehicleKind,recording: URL,buffer: AVAudioPCMBuffer,preview: AVAudioFile?) throws {
        let frames = buffer.frameCapacity
        let rate = buffer.format.sampleRate
        let sound = EngineSound(recordingURL:recording)
        try sound.engine.enableManualRenderingMode(.offline,format:buffer.format,maximumFrameCount:frames)
        defer { sound.engine.stop() }
        var car = Vehicle()
        car.kind = kind
        var idleEnergy = 0.0, driveEnergy = 0.0, coastEnergy = 0.0
        var peak = 0.0, quietPeak = 0.0, scrub = 0.0
        var cuts = 0, limitedSamples = 0, gears = Set<Int>()
        var previousSample = [0.0,0.0]
        var insideStep = 0.0, boundaryStep = 0.0
        for tick in 0..<480 {
            let gas = (60..<300).contains(tick) ? 1.0 : 0.0
            let turn = clamp(Double(tick-360)/30,0,1)
            let brake = tick >= 360 ? 0.82 * clamp(Double(445-tick)/55,0,1) : 0
            let input = DrivingInput(throttle:gas,brake:brake,steering:turn*0.72)
            for _ in 0..<4 { car.step(1.0/240,input:input,assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
            // A fixed centre listening point isolates car differences across all eight takes.
            let road = RoadSound(vehicle:car,listenerPosition:car.position,listenerRight:-car.modelX)
            if tick >= 360 { scrub = max(scrub,road.tyreScrub) }
            if car.ignitionFraction < 1 { cuts += 1 }
            gears.insert(car.gear)
            sound.muted = (456..<468).contains(tick)
            sound.update(rpm:car.rpm,throttle:car.engineThrottle,ignition:car.ignitionFraction,
                         powertrain:car.powertrainSound,
                         cockpit:true,kerb:car.kerbFeedback,roadSpeed:car.speed,roadSound:road,
                         spray:car.wheels.map(\.spray).max() ?? 0,kind:kind,paused:tick >= 468)
            guard sound.errorMessage == nil, sound.engine.isRunning,
                  try sound.engine.renderOffline(frames,to:buffer) == .success,
                  buffer.frameLength == frames else { fatalError("Audio render failed for \(kind.label)") }
            for channel in 0..<2 {
                let values = UnsafeBufferPointer(start:buffer.floatChannelData![channel],count:Int(frames))
                for (offset,sample) in values.enumerated() {
                    let x = Double(sample)
                    let step = abs(x-previousSample[channel])
                    if offset == 0 { boundaryStep = max(boundaryStep,step) }
                    else { insideStep = max(insideStep,step) }
                    previousSample[channel] = x
                    precondition(x.isFinite)
                    peak = max(peak,abs(x))
                    if abs(x) > 0.74 { limitedSamples += 1 }
                    if (15..<45).contains(tick) { idleEnergy += x*x }
                    if (240..<270).contains(tick) { driveEnergy += x*x }
                    if (315..<345).contains(tick) { coastEnergy += x*x }
                    if tick >= 466 { quietPeak = max(quietPeak,abs(x)) }
                }
            }
            try preview?.write(from:buffer)
        }
        let idle = sqrt(idleEnergy/rate), drive = sqrt(driveEnergy/rate), coast = sqrt(coastEnergy/rate)
        print(String(format:"%@ · idle/load/coast RMS %.3f/%.3f/%.3f, peak %.3f, scrub %.3f, %d gears",
                     kind.label,idle,drive,coast,peak,scrub,gears.count))
        // The mixer has a 0.75 soft ceiling. Sustained flattening is audible well below PCM clipping.
        precondition(limitedSamples < Int(0.001 * 8 * rate * 2),"Mix spends too long at the output ceiling for \(kind.label)")
        precondition(drive > max(0.012,idle*1.1) && coast > 0.002 && peak < 1 && quietPeak < 0.00002)
        precondition(boundaryStep < insideStep*1.2+0.01,"Discontinuity at a driving control update for \(kind.label)")
        precondition(kind == .honda ? idle < 0.002 : idle > 0.01)
        precondition(scrub > 0.15)
        if kind == .mazda { precondition(gears.count >= 2 && cuts > 0) }
        print("PASS  \(kind.label) plays idle, acceleration, lift and trail braking, then fades to silence")
    }

    static func checkLoadTransitions(recording: URL, buffer: AVAudioPCMBuffer, preview: AVAudioFile?) throws {
        let sound = EngineSound(recordingURL:recording)
        try sound.engine.enableManualRenderingMode(.offline, format:buffer.format, maximumFrameCount:buffer.frameCapacity)
        defer { sound.engine.stop() }
        var car = Vehicle()
        car.kind = .mazda
        car.gear = 0
        let aids = DrivingAssists(abs:false, tractionControl:false, automatic:true)
        let ear = SIMD3(0.376,0.965,-0.24)
        let perspective = VehicleSoundPerspective(kind:.mazda,localEar:ear,localRight:SIMD3(-1,0,0),cockpit:true)
        var blipRPM = 0.0, freeLoad = 0.0, pullLoad = 0.0, coastOverrun = 0.0
        var maxSkid = 0.0
        for tick in 0..<780 {
            let sec = Double(tick)/60
            let neutralBlip = (0.5..<1.0).contains(sec)
            let pulling = (3.0..<8.0).contains(sec)
            let braking = (10.0..<11.0).contains(sec)
            if tick == 165 {
                precondition(car.requestShift(1,pedals:DrivingInput(brake:1),automatic:true) == .shifted)
            }
            let pedal = neutralBlip ? 0.78 : (pulling ? clamp((sec-3)*2,0,0.95) : 0)
            let input = DrivingInput(throttle:pedal, brake:braking ? 0.95 : 0, steering:braking ? 0.20 : 0)
            for _ in 0..<4 {
                car.step(1/240,input:input,assists:aids,roadDistance:0,roadWidth:12)
            }
            let drive = car.powertrainSound
            let listener = car.position + car.modelX*ear.x + car.forward*ear.z
            let road = RoadSound(vehicle:car,listenerPosition:listener,listenerRight:-car.modelX)
            if neutralBlip { blipRPM = max(blipRPM,car.rpm); freeLoad = max(freeLoad,drive.driveLoad) }
            if pulling { pullLoad = max(pullLoad,drive.driveLoad) }
            if (8.5..<10).contains(sec) { coastOverrun = max(coastOverrun,drive.overrun) }
            if braking { maxSkid = max(maxSkid,road.tyreScrub) }
            sound.update(rpm:car.rpm, throttle:car.engineThrottle, ignition:car.ignitionFraction,
                         powertrain:drive, perspective:perspective, cockpit:true, roadSpeed:car.speed, roadSound:road,
                         kind:car.kind, paused:tick >= 774)
            guard sound.errorMessage == nil,
                  try sound.engine.renderOffline(buffer.frameCapacity,to:buffer) == .success else {
                fatalError("MX-5 load transition render failed")
            }
            try preview?.write(from:buffer)
        }
        precondition(blipRPM > 2000 && freeLoad == 0 && pullLoad > 0.5 && coastOverrun > 0.02 && maxSkid > 0.25)
        print(String(format:"PASS  MX-5 free rev / pull / overrun / brake: %.0f rpm, %.3f / %.3f drive, %.3f overrun, %.3f skid",
                     blipRPM,freeLoad,pullLoad,coastOverrun,maxSkid))
    }

    static func main() throws {
        let recording = URL(fileURLWithPath: CommandLine.arguments[1])
        let rate = 44100.0
        let frames: AVAudioFrameCount = 735 // one 60 Hz driving update
        let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)!
        func output(at argument: Int) throws -> AVAudioFile? {
            guard CommandLine.arguments.indices.contains(argument) else { return nil }
            return try AVAudioFile(forWriting:URL(fileURLWithPath:CommandLine.arguments[argument]), settings:[
                AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:rate, AVNumberOfChannelsKey:2,
                AVLinearPCMBitDepthKey:16, AVLinearPCMIsFloatKey:false
            ])
        }
        let preview = try output(at:2)
        try checkLoadTransitions(recording:recording,buffer:buffer,preview:output(at:3))

        for kind in VehicleKind.allCases {
            try renderDrive(kind,recording:recording,buffer:buffer,preview:preview)
        }
        func sample(kerb: Double = 0, scrub: Double = 0, spray: Double = 0, kind: VehicleKind = .concept,
                    traffic: [OpponentMotor] = [], signal: Int = 0, master: Double = 1,
                    motor: Double = 1, effects: Double = 1, throttle: Double = 0.4, speed: Double = 20, rpm: Double = 3000,
                    roadSound: RoadSound? = nil, powertrain: PowertrainSound? = nil,
                    perspective: VehicleSoundPerspective = VehicleSoundPerspective(), cockpit: Bool = true) throws -> (left: [Float],right: [Float]) {
            let comparison = EngineSound(recordingURL:recording)
            comparison.masterVolume = master
            comparison.motorVolume = motor
            comparison.effectsVolume = effects
            try comparison.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:frames)
            defer { comparison.engine.stop() }
            var left: [Float] = [], right: [Float] = []
            for tick in 0..<60 {
                comparison.update(rpm:rpm,throttle:throttle,powertrain:powertrain,perspective:perspective,cockpit:cockpit,kerb:kerb,roadSpeed:speed,tyreScrub:scrub,roadSound:roadSound,spray:spray,kind:kind,
                                  opponents:traffic,raceSignal:tick >= 10 ? signal : 0,paused:false)
                guard try comparison.engine.renderOffline(frames,to:buffer) == .success else { fatalError("Road audio render failed") }
                left.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(frames)))
                right.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![1],count:Int(frames)))
            }
            return (left,right)
        }
        // Hold crank speed and pedal fixed while changing the work at the shaft.
        // Isolate the motor so road noise cannot make this comparison pass.
        func motorSegment(throttle: Double, drive: Double, overrun: Double) throws -> [Float] {
            let state = PowertrainSound(driveLoad:drive, overrun:overrun, shaftRPM:3000)
            return Array(try sample(kind:.mazda,effects:0,throttle:throttle,powertrain:state).left.suffix(22050))
        }
        func signalRMS(_ signal: [Float]) -> Double {
            sqrt(signal.reduce(0.0) { $0+Double($1)*Double($1) }/Double(signal.count))
        }
        let neutral = try motorSegment(throttle:0.55,drive:0,overrun:0)
        let loaded = try motorSegment(throttle:0.55,drive:0.55,overrun:0)
        let released = try motorSegment(throttle:0,drive:0,overrun:0)
        let backDriven = try motorSegment(throttle:0,drive:0,overrun:0.6)
        let freeRMS = signalRMS(neutral), pullRMS = signalRMS(loaded)
        let freeLiftRMS = signalRMS(released), overrunRMS = signalRMS(backDriven)
        // Energy above a 1 kHz one-pole crossover, relative to the overall
        // signal. Turning up the same recording leaves this ratio unchanged.
        func trebleShare(_ signal: [Float], rms: Double) -> Double {
            let coefficient = 1-exp(-2 * .pi * 1000/rate)
            var low = Double(signal[0]), energy = 0.0
            for frame in signal {
                let x = Double(frame)
                low += (x-low)*coefficient
                energy += (x-low)*(x-low)
            }
            return sqrt(energy/Double(signal.count))/rms
        }
        let neutralTreble = trebleShare(neutral,rms:freeRMS), loadedTreble = trebleShare(loaded,rms:pullRMS)
        precondition(loadedTreble > neutralTreble*1.03, "The loaded engine should brighten even after level matching")
        precondition(pullRMS > freeRMS*1.12 && overrunRMS > freeLiftRMS*1.05,
                     "Drive work and backdrive should be audible independently of crank speed and pedal position")
        print(String(format:"PASS  Matched 3000 rpm MX-5 isolated motor RMS: neutral/pull %.3f/%.3f; released/overrun %.3f/%.3f",
                     freeRMS,pullRMS,freeLiftRMS,overrunRMS))
        print(String(format:"PASS  Matched 3000 rpm, 55%% pedal, normalized high-pass RMS: %.3f free / %.3f pulling",neutralTreble,loadedTreble))
        // Turn right in each cockpit. A front-mounted engine now lies to the
        // left of the listener and a rear-mounted one lies to the right.
        let localEar = SIMD3(0.36,1,-0.15), turnedRight = SIMD3(-cos(1.22),0,-sin(1.22))
        func glance(_ kind: VehicleKind) throws -> (left: [Float],right: [Float]) {
            let atSeat = VehicleSoundPerspective(kind:kind,localEar:localEar,localRight:turnedRight,cockpit:true)
            return try sample(kind:kind,effects:0,perspective:atSeat)
        }
        let frontEngine = try glance(.mazda), rearEngine = try glance(.porsche)
        precondition(signalRMS(frontEngine.left) > 1.1*signalRMS(frontEngine.right) &&
                     signalRMS(rearEngine.right) > 1.1*signalRMS(rearEngine.left))
        func chaseLevel(_ eye: SIMD3<Double>) throws -> Double {
            let atCamera = VehicleSoundPerspective(kind:.mazda,localEar:eye,localRight:SIMD3(-1,0,0),cockpit:false)
            return try signalRMS(sample(kind:.mazda,effects:0,perspective:atCamera,cockpit:false).left)
        }
        let nearLevel = try chaseLevel(SIMD3(0,2.05,-5.8)), farLevel = try chaseLevel(SIMD3(0,3.5,-10.5))
        precondition(farLevel < 0.8*nearLevel && farLevel > 0.01)
        print(String(format:"PASS  Cockpit glance separates front and rear engines; chase motor RMS %.3f near / %.3f far",nearLevel,farLevel))
        let smooth = try sample().left, rough = try sample(kerb:1).left
        let difference = zip(smooth,rough).reduce(0.0) { $0 + pow(Double($1.0-$1.1),2) }
        precondition(sqrt(difference/Double(smooth.count)) > 0.01 && rough.allSatisfy { $0.isFinite && abs($0) < 0.75 })
        print("PASS  Kerb audio changes the rendered output without clipping")
        let scrub = try sample(scrub:1).left
        let scrubDifference = zip(smooth,scrub).reduce(0.0) { $0 + pow(Double($1.0-$1.1),2) }
        precondition(sqrt(scrubDifference/Double(scrub.count)) > 0.01 && scrub.allSatisfy { $0.isFinite && abs($0) < 0.75 })
        print("PASS  Tyre scrub is audible at the same engine load without clipping")
        let spray = try sample(spray:1).left
        let sprayDifference = zip(smooth,spray).reduce(0.0) { $0 + pow(Double($1.0-$1.1),2) }
        precondition(sqrt(sprayDifference/Double(smooth.count)) > 0.01 && spray.allSatisfy { $0.isFinite && abs($0) < 0.75 })
        print("PASS  Wet tyre spray adds a distinct audio cue at matched speed and RPM")
        func contactState(forward: Double, lateral: Double = 0, tread: SIMD4<Double>,
                          edge: Double = 0, film: Double = 0, heave: Double = 0) -> Vehicle {
            var car = Vehicle()
            car.kind = .mazda
            car.gear = 0
            car.heave = heave
            car.velocity = car.forward * forward + car.modelX * lateral
            for i in car.wheels.indices { car.wheels[i].angularVelocity = tread[i] / car.wheelRadius }
            let ground = WheelRoadContact(distance:edge,progress:0,kerbsEnabled:false,waterDepth:film)
            car.step(1.0/240,input:DrivingInput(),assists:DrivingAssists(automatic:false),
                     roadDistance:0,roadWidth:12,roadContacts:Array(repeating:ground,count:4))
            return car
        }
        let leftSlip = SIMD4(20.0,0,20,20)
        var leftTyre = contactState(forward:20,tread:leftSlip)
        leftTyre.wheels[1].kerbFeedback = 0.7
        let road = RoadSound(vehicle:leftTyre)
        let grass = RoadSound(vehicle:contactState(forward:20,tread:leftSlip,edge:8))
        let wet = RoadSound(vehicle:contactState(forward:20,tread:leftSlip,film:0.8))
        let airborne = RoadSound(vehicle:contactState(forward:20,tread:leftSlip,heave:1))
        let burnoutCar = contactState(forward:0,tread:SIMD4(0,0,18,18))
        let burnout = RoadSound(vehicle:burnoutCar)
        let rollingCar = contactState(forward:20,tread:SIMD4(repeating:20))
        let gentleCar = contactState(forward:20,lateral:1.2,tread:SIMD4(repeating:20))
        let slidingCar = contactState(forward:20,lateral:5,tread:SIMD4(repeating:20))
        let rolling = RoadSound(vehicle:rollingCar), gentle = RoadSound(vehicle:gentleCar)
        let sliding = RoadSound(vehicle:slidingCar)
        precondition(road.tyreScrub > 0.75 && wet.tyreScrub < 0.35 * road.tyreScrub &&
                     grass.tyreScrub == 0 && airborne.tyreScrub == 0 && airborne.rolling == 0)
        precondition(burnoutCar.speed < 0.1 && burnout.rolling < 0.001 && burnout.tyres.level[2] > 0.4)
        precondition(rolling.tyreScrub < 0.001 && gentle.tyreScrub > rolling.tyreScrub &&
                     sliding.tyreScrub > gentle.tyreScrub * 2 && sliding.tyres.slide[0] > gentle.tyres.slide[0])
        let totalWork = { (car: Vehicle) in car.wheels.reduce(0.0) { $0 + $1.slidingPower } / 1000 }
        print(String(format:"PASS  Sliding work (kW) coast %.4f, light turn %.2f, slide %.1f, single slow wheel %.1f, standing wheelspin %.1f",
                     totalWork(rollingCar),totalWork(gentleCar),totalWork(slidingCar),totalWork(leftTyre),totalWork(burnoutCar)))
        print(String(format:"PASS  Dry/wet/grass/airborne skid mix %.3f/%.3f/%.3f/%.3f",road.tyreScrub,wet.tyreScrub,grass.tyreScrub,airborne.tyreScrub))
        let isolatedRoad = try sample(kerb:0.7,motor:0,roadSound:road)
        func energy(_ values: [Float]) -> Double {
            values.suffix(22050).reduce(0) { $0+Double($1*$1) }
        }
        func skidOnly(_ road: RoadSound) throws -> (left: [Float],right: [Float]) {
            var contact = RoadSound()
            contact.tyres = road.tyres
            return try sample(motor:0,roadSound:contact)
        }
        let lightScrub = try skidOnly(gentle), sustained = try skidOnly(sliding), standing = try skidOnly(burnout)
        let stereoDifference = zip(standing.left.suffix(22050),standing.right.suffix(22050)).reduce(0.0) {
            $0 + pow(Double($1.0-$1.1),2)
        }
        precondition(energy(lightScrub.left) > 0.001 && energy(sustained.left) > 9*energy(lightScrub.left) &&
                     stereoDifference > energy(standing.left)*0.02)
        print(String(format:"PASS  Isolated recorded tyre RMS light/heavy slide %.4f/%.4f, spinning axle has independent stereo sources",
                     sqrt(energy(lightScrub.left)/22050),sqrt(energy(sustained.left)/22050)))
        precondition(road.kerbPan == -1 && road.scrubPan < -0.999 &&
                     energy(isolatedRoad.left) > energy(isolatedRoad.right)*4)
        print("PASS  Loaded driver-left kerb and scrub cues stay on the left audio channel")
        var rightContact = contactState(forward:20,tread:SIMD4(0,20,20,20))
        rightContact.wheels[0].kerbFeedback = 0.8
        let seat = rightContact.modelX * 0.376 - rightContact.forward * 0.24
        let straight = -rightContact.modelX
        let glance = straight * cos(1.22) - rightContact.forward * sin(1.22)
        let ahead = RoadSound(vehicle:rightContact,listenerPosition:seat,listenerRight:straight)
        let turned = RoadSound(vehicle:rightContact,listenerPosition:seat,listenerRight:glance)
        let chase = RoadSound(vehicle:rightContact,listenerPosition:-rightContact.forward*10.5,listenerRight:straight)
        rightContact.wheels.swapAt(0,2)
        let rear = RoadSound(vehicle:rightContact,listenerPosition:seat,listenerRight:glance)
        precondition(ahead.kerbPan > 0.4 && chase.kerbPan > 0 && chase.kerbPan < 0.1 &&
                     turned.kerbPan < -0.4 && rear.kerbPan > 0.4 &&
                     abs(turned.kerbPan-turned.scrubPan) < 0.001 && abs(rear.kerbPan-rear.scrubPan) < 0.001)
        print("PASS  Front and rear tyre cues cross the listener independently when looking right and narrow in the chase camera")
        func rollingRoad(speed: Double) -> RoadSound {
            RoadSound(vehicle:contactState(forward:speed,tread:SIMD4(repeating:speed)))
        }
        let stoppedRoad = try sample(motor:0,speed:0,roadSound:rollingRoad(speed:0))
        let cityRoad = try sample(motor:0,speed:20,roadSound:rollingRoad(speed:20))
        let fastRoad = try sample(motor:0,speed:35,roadSound:rollingRoad(speed:35))
        precondition(energy(stoppedRoad.left) < 1e-8 && energy(cityRoad.left) > 0.01 &&
                     energy(fastRoad.left) > energy(cityRoad.left)*1.3,
                     "Straight-road ambience should build from rest as wheel speed rises")
        print("PASS  Coasting on loaded asphalt adds speed-dependent road noise and stops at rest")
        let lifting = try sample(motor:0,throttle:0,roadSound:road)
        let accelerating = try sample(motor:0,throttle:1,roadSound:road)
        let leakage = zip(lifting.left.suffix(22050),accelerating.left.suffix(22050)).reduce(0.0) {
            $0 + pow(Double($1.0-$1.1),2)
        }
        precondition(leakage < energy(lifting.left)*0.0001,"Throttle must not brighten isolated tyre audio at constant slip")
        print("PASS  Isolated tyre tone stays consistent across throttle changes at matched road speed and slip")
        let pulse = try sample(motor:0,roadSound:RoadSound(absModulation:0.7))
        let noValve = try sample(motor:0)
        precondition(pulse.left == pulse.right && energy(pulse.left) > energy(noValve.left)+0.04 &&
                     pulse.left.allSatisfy { $0.isFinite && abs($0)<0.16 })
        print("PASS  ABS valve texture is quiet, centered and distinct from normal braking")
        func amplitude(_ values: [Float], frequency: Double) -> Double {
            let samples = values.suffix(22050)
            var real = 0.0, imaginary = 0.0
            for (index,value) in samples.enumerated() {
                let phase = Double(index)*frequency*2 * .pi / rate
                real += Double(value)*cos(phase)
                imaginary += Double(value)*sin(phase)
            }
            return 2*hypot(real,imaginary)/Double(samples.count)
        }
        // Compare energy near the first three firing orders at two steady speeds.
        // Field recordings carry sidebands and can have a stronger overtone than fundamental.
        func firingBand(_ values: [Float],frequency: Double) -> Double {
            var power = 0.0
            for order in 1...3 {
                for offset in stride(from:-4.0,through:4.0,by:2.0) {
                    let a = amplitude(values,frequency:frequency*Double(order)+offset)
                    power += a*a
                }
            }
            return sqrt(power)
        }
        for (kind,frequency) in [(VehicleKind.porsche,150.0),(.ferrari,200),(.centenario,300)] {
            let steady = try sample(kind:kind)
            let faster = try sample(kind:kind,rpm:3600)
            let low = firingBand(steady.left,frequency:frequency)
            let high = firingBand(faster.left,frequency:frequency*1.2)
            print(String(format:"%@ · firing bands at 3000/3600 rpm %.3f/%.3f",kind.label,low,high))
            precondition(low > 0.01 && high > 0.01 &&
                         low > 1.15*firingBand(steady.left,frequency:frequency*1.2) &&
                         high > 1.15*firingBand(faster.left,frequency:frequency),
                         "Combustion orders must move with crank speed for \(kind.label)")
            precondition(steady.left == steady.right && steady.left.allSatisfy { $0.isFinite && abs($0)<0.75 })
            print(String(format:"PASS  %@ firing orders track %.0f to %.0f Hz as RPM rises",kind.label,frequency,frequency*1.2))
        }
        let fourCylinder = try [VehicleKind.concept,.bmw,.mazda,.lotus].map { kind in
            (kind,Array(try sample(kind:kind).left.suffix(22050)))
        }
        var mostSimilar = 0.0
        for (index,first) in fourCylinder.enumerated() {
            for second in fourCylinder.prefix(index) {
                let dot = zip(first.1,second.1).reduce(0.0) { $0 + Double($1.0*$1.1) }
                let similarity = abs(dot) / sqrt(energy(first.1)*energy(second.1))
                precondition(similarity < 0.97,"Near-identical audio for \(first.0.label) and \(second.0.label) at matched RPM and load")
                mostSimilar = max(mostSimilar,similarity)
            }
        }
        print(String(format:"PASS  Four-cylinder profiles produce distinct audio at matched RPM and load (peak correlation %.3f)",mostSimilar))
        let electric = try sample(kind:.honda)
        precondition(energy(electric.left) > 0.1 && amplitude(electric.left,frequency:400) < 0.015)
        print("PASS  Electric drive has audible recorded texture without combustion firing harmonics")
        let basePlayer = Vehicle()
        var approaching = Vehicle()
        approaching.heading = -.pi/2
        approaching.velocity = approaching.forward * 20
        approaching.gear = 3
        for i in approaching.wheels.indices { approaching.wheels[i].angularVelocity = 20/approaching.wheelRadius }
        for _ in 0..<180 {
            approaching.step(1/240,input:DrivingInput(throttle:0.78),assists:DrivingAssists(automatic:false),
                             roadDistance:0,roadWidth:12)
        }
        approaching.position = SIMD2(8,0)
        let near = OpponentMotor.relative(to:basePlayer,opponent:approaching,listenerRight:SIMD2(1,0))
        let pastRival = OpponentMotor.relative(to:basePlayer,opponent:approaching,listenerRight:SIMD2(1,0),
                                             listenerPosition:SIMD2(12,0))
        precondition(pastRival.pan < -0.99 && pastRival.volume > near.volume && pastRival.doppler < 1)
        print("PASS  Moving the camera past the same rival reverses panning and relative pitch")
        approaching.position = SIMD2(-70,0)
        let far = OpponentMotor.relative(to:basePlayer,opponent:approaching,listenerRight:SIMD2(1,0))
        precondition(near.doppler > 1 && far.doppler < 1 && near.pan > 0.99 && far.pan < -0.99 &&
                     near.volume > 20*far.volume && near.powertrain.driveLoad > 0.55)
        // Park the listener's electric car so the measured signal comes solely
        // from the rival. A grid car is audible before its first physics step.
        var grid = Vehicle()
        grid.position = SIMD2(8,0)
        let parked = OpponentMotor.relative(to:basePlayer,opponent:grid,listenerRight:SIMD2(1,0))
        let passing = try sample(kind:.honda,traffic:[near],effects:0,speed:0)
        let idling = try sample(kind:.honda,traffic:[parked],effects:0,speed:0)
        let receding = try sample(kind:.honda,traffic:[far],effects:0,speed:0)
        let pullRival = sqrt(energy(passing.right)/22050)
        let idleRival = sqrt(energy(idling.right)/22050)
        let farRival = sqrt(energy(receding.left)/22050)
        precondition(abs(parked.powertrain.shaftRPM-grid.rpm) < 1 && idleRival > 0.002 &&
                     pullRival > 1.35*idleRival && farRival > 0 && farRival < pullRival/10 &&
                     energy(passing.left) < 1e-8 && energy(idling.left) < 1e-8 && energy(receding.right) < 1e-8)
        print(String(format:"PASS  Isolated rival RMS at idle / approaching under load / receding %.4f / %.4f / %.4f; output follows its side",
                     idleRival,pullRival,farRival))
        let countdown = try sample(signal:3), green = try sample(signal:4)
        func signalDifference(_ source: [Float], from start: Int, to end: Int) -> Double {
            zip(source[start..<end],smooth[start..<end]).reduce(0) { $0+abs(Double($1.0-$1.1)) }/Double(end-start)
        }
        let start = Int(frames)*10
        precondition(countdown.left == countdown.right && green.left == green.right &&
                     signalDifference(countdown.left,from:start+500,to:start+4000) > 0.035 &&
                     signalDifference(green.left,from:start+6500,to:start+10000) > 0.035 &&
                     signalDifference(countdown.left,from:start+6500,to:start+10000) < 0.0001 &&
                     signalDifference(green.left,from:start+15000,to:start+21000) < 0.0001)
        print("PASS  Countdown and green signals are centered, distinct, and end even if the stage remains active")
        let half = try sample(master:0.5).left
        let quietMotor = try sample(motor:0,effects:1).left
        let quietEffects = try sample(kerb:1,effects:0).left
        func rms(_ values: [Float]) -> Double {
            let tail = values.suffix(20000)
            return sqrt(tail.reduce(0) { $0+Double($1*$1) }/Double(tail.count))
        }
        precondition(abs(rms(half)/rms(smooth)-0.5)<0.01 && rms(quietMotor)<0.001 &&
                     abs(rms(quietEffects)-rms(smooth))<0.001)
        print("PASS  Master, engine and effects volume act on their own audio paths")
    }
}

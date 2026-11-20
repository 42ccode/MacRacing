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
            // A fixed centre listening point isolates car differences across both takes.
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
        precondition(idle > 0.01)
        precondition(scrub > 0.15)
        if kind == .porsche { precondition(gears.count >= 2 && cuts > 0) }
        print("PASS  \(kind.label) plays idle, acceleration, lift and trail braking, then fades to silence")
    }

    static func checkLoadTransitions(recording: URL, buffer: AVAudioPCMBuffer, preview: AVAudioFile?) throws {
        let sound = EngineSound(recordingURL:recording)
        try sound.engine.enableManualRenderingMode(.offline, format:buffer.format, maximumFrameCount:buffer.frameCapacity)
        defer { sound.engine.stop() }
        var car = Vehicle()
        car.kind = .porsche
        car.gear = 0
        let aids = DrivingAssists(abs:false, tractionControl:false, automatic:false)
        let ear = SIMD3(0.376,0.965,-0.24)
        let perspective = VehicleSoundPerspective(kind:.porsche,localEar:ear,localRight:SIMD3(-1,0,0),cockpit:true)
        var blipRPM = 0.0, freeLoad = 0.0, pullLoad = 0.0, coastOverrun = 0.0
        var maxSkid = 0.0
        var upshift: Double?, downshift: Double?
        for tick in 0..<780 {
            let sec = Double(tick)/60
            let neutralBlip = (0.5..<1.0).contains(sec)
            let pulling = (3.0..<7.3).contains(sec)
            let rollOn = (8.35..<9.10).contains(sec)
            let braking = (10.5..<11.5).contains(sec)
            if tick == 165 {
                precondition(car.requestShift(1,pedals:DrivingInput(brake:1),automatic:false) == .shifted)
            }
            let pedal = neutralBlip ? 0.78 : (pulling ? clamp((sec-3)*2,0,0.95) : (rollOn ? 0.42 : 0))
            let brake = braking ? 0.95 : ((9.10..<10.5).contains(sec) ? 0.72 : 0)
            let input = DrivingInput(throttle:pedal, brake:brake, steering:braking ? 0.20 : 0)
            if pulling && car.gear == 1 && car.rpm > 6200,
               car.requestShift(1,pedals:input,automatic:false) == .shifted { upshift = sec }
            if sec >= 9.55 && car.gear == 2,
               car.requestShift(-1,pedals:input,automatic:false) == .shifted { downshift = sec }
            for _ in 0..<4 {
                car.step(1/240,input:input,assists:aids,roadDistance:0,roadWidth:12)
            }
            let drive = car.powertrainSound
            let listener = car.position + car.modelX*ear.x + car.forward*ear.z
            let road = RoadSound(vehicle:car,listenerPosition:listener,listenerRight:-car.modelX)
            if neutralBlip { blipRPM = max(blipRPM,car.rpm); freeLoad = max(freeLoad,drive.driveLoad) }
            if pulling { pullLoad = max(pullLoad,drive.driveLoad) }
            if (7.6..<8.35).contains(sec) { coastOverrun = max(coastOverrun,drive.overrun) }
            if braking { maxSkid = max(maxSkid,road.tyreScrub) }
            sound.update(rpm:car.rpm, throttle:car.engineThrottle, ignition:car.ignitionFraction,
                         powertrain:drive, perspective:perspective, cockpit:true, roadSpeed:car.speed, roadSound:road,
                         kind:car.kind, paused:tick >= 774)
            guard sound.errorMessage == nil,
                  try sound.engine.renderOffline(buffer.frameCapacity,to:buffer) == .success else {
                fatalError("911 load transition render failed")
            }
            try preview?.write(from:buffer)
        }
        precondition(blipRPM > 2000 && freeLoad == 0 && pullLoad > 0.5 && coastOverrun > 0.02 && maxSkid > 0.25)
        guard let upshift, let downshift, downshift < 11.5 else {
            fatalError("911 preview must contain both shifts: up \(String(describing:upshift)), down \(String(describing:downshift))")
        }
        print(String(format:"PASS  911 blip %.0f rpm, upshift %.2f s, downshift %.2f s, overrun %.3f, skid %.3f",
                     blipRPM,upshift,downshift,coastOverrun,maxSkid))
    }

    static func checkCabinShift(_ kind: VehicleKind, recording: URL, buffer: AVAudioPCMBuffer) throws {
        let frames = buffer.frameCapacity
        func render(shifting: Bool) throws -> [Double] {
            let sound = EngineSound(recordingURL:recording)
            sound.effectsVolume = 0
            try sound.engine.enableManualRenderingMode(.offline,format:buffer.format,maximumFrameCount:frames)
            defer { sound.engine.stop() }
            var meanSquare = [Double](repeating:0,count:96)
            for tick in meanSquare.indices {
                let lift = shifting && tick >= 58
                let phase = shifting && (24..<34).contains(tick) ? clamp(Double(tick-30)/4,0,1) : 1
                let drive = lift ? 0 : 0.8*(0.35+0.65*phase)
                // Hold shaft speed fixed so the same samples play in both runs.
                let state = PowertrainSound(driveLoad:drive,overrun:lift ? 0.55 : 0,shaftRPM:3500,
                                            inGear:true,shiftEngagement:phase)
                sound.update(rpm:3500,throttle:lift ? 0 : 0.8,ignition:0.35+0.65*phase,powertrain:state,
                             cockpit:true,kind:kind,paused:false)
                guard try sound.engine.renderOffline(frames,to:buffer) == .success,
                      let samples = buffer.floatChannelData?[0] else { fatalError("Cabin render failed") }
                for frame in 0..<Int(frames) { meanSquare[tick] += Double(samples[frame])*Double(samples[frame])/Double(frames) }
            }
            return meanSquare
        }
        func rms(_ values: [Double], _ ticks: Range<Int>) -> Double {
            sqrt(values[ticks].reduce(0,+)/Double(ticks.count))
        }
        let control = try render(shifting:false), transition = try render(shifting:true)
        let cut = rms(transition,25..<30), coast = rms(transition,69..<95)
        let cutRatio = cut/rms(control,25..<30)
        let recoveryRatio = rms(transition,38..<58)/rms(control,38..<58)
        let liftRatio = coast/rms(control,69..<95)
        print(String(format:"%@ cabin RMS relative to held load · cut %.3f / recovery %.3f / lift %.3f",
                     kind.label,cutRatio,recoveryRatio,liftRatio))
        precondition(cut > 0.015 && cutRatio < 0.78 && (0.90...1.05).contains(recoveryRatio) &&
                     coast > 0.015 && liftRatio < 0.70)
        print("PASS  \(kind.label) maintains a rotating engine through the shift and restores its loaded sound")
    }

    static func checkCoastDownshiftMounts(recording: URL, buffer: AVAudioPCMBuffer) throws {
        let freeClutch = 0.12
        let engagedClutch = 0.62
        let transition = 72
        let frames = buffer.frameCapacity
        var perspective = VehicleSoundPerspective()
        perspective.motorChannels = .zero // Isolate the seat path at a fixed crank speed.

        func render(before: Double, after: Double) throws -> Double {
            let sound = EngineSound(recordingURL:recording)
            sound.effectsVolume = 0
            try sound.engine.enableManualRenderingMode(.offline,format:buffer.format,maximumFrameCount:frames)
            defer { sound.engine.stop() }
            var energy = 0.0, count = 0
            for tick in 0..<(transition + 6) {
                let overrun = tick < transition ? before : after
                let shaft = PowertrainSound(overrun:overrun,shaftRPM:3000,inGear:true)
                sound.update(rpm:3000,throttle:0,powertrain:shaft,perspective:perspective,cockpit:true,
                             kind:.porsche,paused:false)
                let status = try sound.engine.renderOffline(frames,to:buffer)
                precondition(status == .success && buffer.frameLength == frames)
                // Sample 50–100 ms after the change, while mount load is still
                // settling. The constant-overrun runs use the same clip phase.
                guard tick >= transition + 3 else { continue }
                for sample in UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(frames)) {
                    energy += Double(sample) * Double(sample)
                    count += 1
                }
            }
            return sqrt(energy / Double(count))
        }

        let light = try render(before:freeClutch,after:freeClutch)
        let loaded = try render(before:engagedClutch,after:engagedClutch)
        let release = try render(before:engagedClutch,after:freeClutch) / light
        let restoration = try render(before:freeClutch,after:engagedClutch) / loaded
        print(String(format:"Coast seat RMS relative to settled load · clutch release %.3f / restoration %.3f",release,restoration))
        precondition(light > 0.008 && loaded > 1.5*light &&
                     (0.99...1.015).contains(release) && (1.025...1.11).contains(restoration),
                     "Mounts should take up returning backdrive load after a coast downshift")
        print("PASS  Closed-throttle downshifts unload the mounts during clutch release and accent returning backdrive")
    }

    static func checkRaceCues(recording: URL, buffer: AVAudioPCMBuffer) throws {
        let sound = EngineSound(recordingURL: recording)
        let frames = buffer.frameCapacity
        let block = Int(frames)
        try sound.engine.enableManualRenderingMode(.offline, format: buffer.format, maximumFrameCount: frames)
        defer { sound.engine.stop() }

        func render(_ ticks: Int) throws -> [Float] {
            var samples = [Float]()
            samples.reserveCapacity(ticks * block)
            for _ in 0..<ticks {
                let status = try sound.engine.renderOffline(frames, to: buffer)
                precondition(status == .success && buffer.frameLength == frames)
                let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: block)
                let right = UnsafeBufferPointer(start: buffer.floatChannelData![1], count: block)
                precondition(left.elementsEqual(right), "Isolated UI cue should be centered")
                precondition(left.allSatisfy { $0.isFinite && abs($0) <= 0.75 })
                samples.append(contentsOf: left)
            }
            return samples
        }

        func peak<T: Collection>(_ samples: T) -> Float where T.Element == Float {
            samples.reduce(0) { max($0, abs($1)) }
        }

        func rms(_ samples: [Float]) -> Double {
            sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        }

        func play(_ cue: RaceAudioCue, ticks: Int = 54) throws -> [Float] {
            sound.playCue(cue)
            return try render(ticks)
        }

        sound.playCue(.checkered)
        precondition(!sound.engine.isRunning, "Race cue must not start the audio device")
        try sound.engine.start()
        precondition(sound.engine.isRunning)
        let warmup = try render(40)
        precondition(peak(warmup) == 0, "A cue requested before audio startup must not play later")

        var takes = [RaceAudioCue: [Float]]()
        for cue in RaceAudioCue.allCases {
            let take = try play(cue)
            precondition(peak(take) > 0.035 && peak(take) < 0.18 && take.first == 0)
            precondition(peak(take.suffix(19 * block)) == 0, "A held race state must remain silent after the cue")
            let biggestStep = zip(take, take.dropFirst()).reduce(Float.zero) { max($0, abs($1.0 - $1.1)) }
            precondition(biggestStep < 0.028, "Cue onset, note handoff or tail clicked")
            takes[cue] = take
        }
        let finish = takes[.checkered]!
        let lastLap = takes[.finalLap]!
        precondition(takes[.trainingPassed] != takes[.trainingFailed] && finish != lastLap)
        precondition(peak(finish[(24 * block)..<(30 * block)]) > 0.035 && peak(lastLap.suffix(33 * block)) == 0)
        print("PASS  All five race cues render distinct centered envelopes with bounded peaks and silent tails")

        sound.masterVolume = 0.5
        _ = try render(1)
        let halfMaster = try play(.checkered)
        precondition(abs(rms(halfMaster) / rms(finish) - 0.5) < 0.003)
        sound.masterVolume = 1
        sound.effectsVolume = 0.5
        _ = try render(1)
        let halfEffects = try play(.checkered)
        precondition(abs(rms(halfEffects) / rms(finish) - 0.5) < 0.003)
        sound.effectsVolume = 0
        let noEffects = try play(.checkered)
        sound.effectsVolume = 1
        sound.masterVolume = 0
        let noMaster = try play(.checkered)
        sound.masterVolume = 1
        sound.muted = true
        let muted = try play(.checkered)
        sound.muted = false
        let unmuted = try render(40)
        precondition(peak(noEffects) == 0 && peak(noMaster) == 0 && peak(muted) == 0 && peak(unmuted) == 0)
        sound.playCue(.checkered)
        sound.muted = true
        let canceledByMute = try render(38)
        sound.muted = false
        let afterMute = try render(1)
        precondition(peak(canceledByMute) == 0 && peak(afterMute) == 0)
        print("PASS  Master/effects scale the race cue and mute clears pending playback")

        sound.playCue(.finalLap)
        sound.playCue(.yellowFlag)
        let beginning = try render(5)
        sound.playCue(.finalLap)
        sound.playCue(.yellowFlag)
        let ending = try render(49)
        precondition(beginning + ending == lastLap, "Busy cue must ignore duplicates and lower-priority advisories")

        _ = try play(.finalLap, ticks: 5)
        sound.playCue(.checkered)
        sound.playCue(.yellowFlag)
        let replaced = try render(54)
        precondition(replaced.dropFirst(441).elementsEqual(finish.prefix(replaced.count - 441)),
                     "A finish cue must follow a 10 ms release of the lower-priority cue")
        print("PASS  Duplicate/advisory requests are dropped while busy and checkered can supersede last lap")

        sound.playCue(.checkered)
        sound.cancelCue()
        let canceledBeforeStart = try render(36)
        precondition(peak(canceledBeforeStart) == 0)
        let beforeReplay = try play(.checkered, ticks: 5)
        sound.cancelCue()
        let afterReplay = try render(38)
        precondition(abs(beforeReplay.last! - afterReplay.first!) < 0.028 && peak(afterReplay.dropFirst(block)) == 0)
        let beforeLiveMute = try play(.trainingPassed, ticks: 5)
        sound.muted = true
        let afterLiveMute = try render(37)
        sound.muted = false
        precondition(peak(beforeLiveMute) > 0.035 && peak(afterLiveMute.dropFirst(block)) == 0)
        print("PASS  Replay entry and in-flight mute release active playback without clicks or stale cues")

        sound.update(rpm: 3100, throttle: 0.72, paused: false)
        let drive = try render(10)
        precondition(peak(drive) > 0.08)
        sound.playCue(.checkered)
        sound.update(rpm: 3100, throttle: 0.72, paused: true)
        let result = try render(54)
        precondition(result.dropFirst(9 * block).elementsEqual(finish.dropFirst(9 * block)),
                     "Result pause must preserve the entire remaining cue once the engine fades")
        precondition(sound.engine.isRunning && sound.errorMessage == nil)
        print("PASS  Finish cue continues through the paused result while the engine fades to silence")
    }

    static func checkContactSound(recording: URL,buffer: AVAudioPCMBuffer) throws {
        let sound = EngineSound(recordingURL:recording)
        let frames = buffer.frameCapacity, block = Int(frames)
        try sound.engine.enableManualRenderingMode(.offline,format:buffer.format,maximumFrameCount:frames)
        defer { sound.engine.stop() }

        func hit(_ speed: Double,position: SIMD2<Double> = SIMD2(0,2)) {
            sound.playContact(ContactSound(closingSpeed:speed,position:position),listenerPosition:.zero,
                              listenerRight:SIMD2(1,0),cockpit:true)
        }
        func render(_ ticks: Int) throws -> [SIMD2<Float>] {
            var samples = [SIMD2<Float>]()
            samples.reserveCapacity(ticks*block)
            for _ in 0..<ticks {
                let status = try sound.engine.renderOffline(frames,to:buffer)
                precondition(status == .success && buffer.frameLength == frames)
                let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
                for frame in 0..<block { samples.append(SIMD2(left[frame],right[frame])) }
            }
            precondition(samples.allSatisfy { $0.x.isFinite && $0.y.isFinite && max(abs($0.x),abs($0.y)) <= 0.75 })
            return samples
        }
        func take(_ speed: Double,position: SIMD2<Double> = SIMD2(0,2)) throws -> [SIMD2<Float>] {
            hit(speed,position:position)
            return try render(54)
        }
        func quiet<T: Collection>(_ samples: T) -> Bool where T.Element == SIMD2<Float> {
            samples.allSatisfy { $0 == .zero }
        }
        func attackRMS(_ samples: [SIMD2<Float>],channel: Int) -> Double {
            let attack = samples.prefix(4_410)
            return sqrt(attack.reduce(0.0) { $0+Double($1[channel])*Double($1[channel]) }/Double(attack.count))
        }
        sound.motorVolume = 0
        func update(paused: Bool) { sound.update(rpm:0,throttle:0,kind:.porsche,paused:paused) }

        hit(12)
        precondition(!sound.engine.isRunning)
        update(paused:false)
        let warm = try render(150)
        let parkingContact = try take(0.9)
        let distantContact = try take(12,position:SIMD2(65,0))
        precondition(quiet(warm.suffix(8*block)) && quiet(parkingContact) && quiet(distantContact),
                     "Contact requests never start the audio engine or leak in from outside range")
        print("PASS  Contact audio skips startup events, parking-speed touches, and events beyond range")

        let light = try take(2.1)
        let firm = try take(10)
        let lowerBoundary = try take(5.49), upperBoundary = try take(5.51)
        let lightRMS = attackRMS(light,channel:0), firmRMS = attackRMS(firm,channel:0)
        let boundaryRatio = attackRMS(upperBoundary,channel:0)/attackRMS(lowerBoundary,channel:0)
        precondition(lightRMS > 0.015 && firmRMS > 2.3*lightRMS && (0.97...1.04).contains(boundaryRatio) &&
                     light != firm && quiet(light.suffix(12*block)) && quiet(firm.suffix(12*block)))
        print(String(format:"PASS  Recorded light / firm contact attack %.3f / %.3f RMS; take boundary ratio %.3f and silent tails",
                     lightRMS,firmRMS,boundaryRatio))

        let right = try take(8,position:SIMD2(3,0)), left = try take(8,position:SIMD2(-3,0))
        let farther = try take(8,position:SIMD2(24,0))
        let nearer = attackRMS(right,channel:1)
        precondition(right.map(\.x) == left.map(\.y) && right.map(\.y) == left.map(\.x) &&
                     nearer > 2*attackRMS(right,channel:0) &&
                     nearer > 4*attackRMS(farther,channel:1))
        print("PASS  Contact follows listener side and range")

        hit(2.1)
        hit(10)
        hit(1.6)
        let coalesced = try render(54)
        hit(2.1)
        let first = try render(4)
        hit(2.1)
        hit(1.6)
        let tail = try render(50)
        hit(2.1)
        _ = try render(4)
        hit(10)
        let replaced = try render(54)
        precondition(coalesced == firm && first+tail == light &&
                     replaced.dropFirst(441).elementsEqual(firm.prefix(replaced.count-441)),
                     "Only the strongest pending contact survives; an active contact releases before replacement")
        print("PASS  Multiple contacts are bounded and stronger arrivals replace the prior tail without restarting duplicates")

        hit(10)
        _ = try render(Int(ceil(0.4*44_100/Double(block))))
        hit(2.1)
        let secondHit = try render(54)
        precondition(secondHit.dropFirst(441).elementsEqual(light.prefix(secondHit.count-441)))
        print("PASS  A second physical contact at the solver cooldown remains audible after a stronger impact")

        sound.motorVolume = 0
        _ = try render(16)
        let motorMuted = try take(10)
        sound.effectsVolume = 0.5
        _ = try render(16)
        let halfEffects = try take(10)
        sound.effectsVolume = 1
        _ = try render(16)
        precondition(motorMuted == firm && abs(attackRMS(halfEffects,channel:0)/firmRMS-0.5) < 0.003)
        print("PASS  Contact follows effects volume independently of engine volume")

        func verifyRelease(_ cancel: () -> Void,restore: () -> Void) throws {
            hit(10)
            let beginning = try render(3)
            cancel()
            let ending = try render(5)
            restore()
            let resumed = try render(19)
            precondition(!quiet(beginning) && !quiet(ending.prefix(441)) &&
                         quiet(ending.dropFirst(441)) && quiet(resumed))
            precondition(ending[440] == .zero && abs(beginning.last!.x-ending.first!.x) < 0.10)
        }
        try verifyRelease({ sound.cancelContact() },restore:{})
        try verifyRelease({ sound.muted = true },restore:{ sound.muted = false })
        try verifyRelease({ sound.effectsVolume = 0 },restore:{ sound.effectsVolume = 1 })
        try verifyRelease({ update(paused:true) },restore:{ update(paused:false) })
        sound.pausePlayback()
        hit(10)
        update(paused:false)
        let suppressed = try render(54)
        precondition(quiet(suppressed))
        print("PASS  Explicit cancellation, pause, mute, and zero effects release the active impact without stale playback")
    }

    static func checkReplaySound(recording: URL,buffer: AVAudioPCMBuffer) throws {
        let direction = SIMD2<Double>(0,1)
        let approaching = OpponentMotor.doppler(along:direction,source:direction * -32,listener:.zero)
        let receding = OpponentMotor.doppler(along:direction,source:direction*32,listener:.zero)
        let following = OpponentMotor.doppler(along:direction,source:direction*32,listener:direction*32)
        precondition(approaching > 1.09 && receding < 0.92 && following == 1)
        print("PASS  A fixed trackside listener hears the changing pitch of a pass while a matched chase does not")

        let sound = EngineSound(recordingURL:recording)
        let length = buffer.frameCapacity
        try sound.engine.enableManualRenderingMode(.offline,format:buffer.format,maximumFrameCount:length)
        defer { sound.engine.stop() }
        func render() throws -> Double {
            guard try sound.engine.renderOffline(length,to:buffer) == .success, let left = buffer.floatChannelData?[0] else {
                fatalError("Replay audio render failed")
            }
            return (0..<Int(length)).reduce(0) { max($0,abs(Double(left[$1]))) }
        }
        let drive = PowertrainSound(driveLoad:0.67,overrun:0,shaftRPM:3490,inGear:true)
        let view = VehicleSoundPerspective(kind:.porsche,localEar:SIMD3(5,1,-2),localRight:SIMD3(1,0,0),
                                           cockpit:false,doppler:approaching)
        func publish() {
            sound.update(rpm:3490,throttle:0.63,powertrain:drive,perspective:view,cockpit:false,kind:.porsche,paused:false)
        }
        publish()
        var cruising = 0.0
        for _ in 0..<12 { cruising = max(cruising,try render()) }
        sound.pausePlayback()
        for _ in 0..<12 { _ = try render() }
        let quiet = try render()
        publish()
        var resumed = 0.0
        for _ in 0..<12 { resumed = max(resumed,try render()) }
        precondition(cruising > 0.015 && quiet == 0 && resumed > 0.015)
        print("PASS  Playback fades to silence on pause and resumes the recorded sound targets")
    }

    static func main() throws {
        setlinebuf(stdout)
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
        try checkRaceCues(recording: recording, buffer: buffer)
        try checkContactSound(recording:recording,buffer:buffer)
        try checkReplaySound(recording:recording,buffer:buffer)
        try checkCoastDownshiftMounts(recording:recording,buffer:buffer)

        for kind in VehicleKind.allCases {
            try renderDrive(kind,recording:recording,buffer:buffer,preview:preview)
            try checkCabinShift(kind,recording:recording,buffer:buffer)
        }
        func sample(kerb: Double = 0, scrub: Double = 0, spray: Double = 0, kind: VehicleKind = .porsche,
                    traffic: [OpponentMotor] = [], signal: Int = 0, cue: RaceAudioCue? = nil, master: Double = 1,
                    motor: Double = 1, effects: Double = 1, throttle: Double = 0.4, speed: Double = 20, rpm: Double = 3000,
                    roadSound: RoadSound? = nil, powertrain: PowertrainSound? = nil,
                    perspective: VehicleSoundPerspective = VehicleSoundPerspective(), cockpit: Bool = true,
                    isolateRival: Bool = false) throws -> (left: [Float],right: [Float]) {
            let comparison = EngineSound(recordingURL:recording)
            comparison.masterVolume = master
            comparison.motorVolume = motor
            comparison.effectsVolume = effects
            try comparison.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:frames)
            defer { comparison.engine.stop() }
            var listener = perspective
            if isolateRival { listener.motorChannels = .zero }
            var left: [Float] = [], right: [Float] = []
            for tick in 0..<(isolateRival ? 180 : 60) {
                if tick == 10, let cue { comparison.playCue(cue) }
                comparison.update(rpm:rpm,throttle:throttle,powertrain:powertrain,perspective:listener,cockpit:cockpit && !isolateRival,kerb:kerb,roadSpeed:speed,tyreScrub:scrub,roadSound:roadSound,spray:spray,kind:kind,
                                  opponents:traffic,raceSignal:tick >= 10 ? signal : 0,paused:false)
                guard try comparison.engine.renderOffline(frames,to:buffer) == .success else { fatalError("Road audio render failed") }
                left.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(frames)))
                right.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![1],count:Int(frames)))
            }
            if isolateRival { return (Array(left.suffix(44100)),Array(right.suffix(44100))) }
            return (left,right)
        }
        // Hold crank speed and pedal fixed while changing the work at the shaft.
        // Isolate the motor so road noise cannot make this comparison pass.
        func motorSegment(throttle: Double, drive: Double, overrun: Double) throws -> [Float] {
            let state = PowertrainSound(driveLoad:drive, overrun:overrun, shaftRPM:3000,
                                        inGear:drive > 0 || overrun > 0)
            return Array(try sample(kind:.porsche,effects:0,throttle:throttle,powertrain:state).left.suffix(22050))
        }
        func signalRMS(_ signal: [Float]) -> Double {
            sqrt(signal.reduce(0.0) { $0+Double($1)*Double($1) }/Double(signal.count))
        }
        for kind in VehicleKind.allCases {
            func tyrePass(_ radialSpeed: Double) throws -> Int {
                let direction = SIMD2<Double>(1,0)
                let ratio = OpponentMotor.doppler(along:direction,source:direction*radialSpeed,listener:.zero)
                let mic = VehicleSoundPerspective(kind:kind,localEar:SIMD3(4,1,0),localRight:SIMD3(1,0,0),
                                                  cockpit:false,doppler:ratio)
                let trackside = try sample(scrub:1,kind:kind,motor:0,speed:0,perspective:mic,cockpit:false)
                let segment = trackside.right.suffix(16_384)
                precondition(signalRMS(Array(segment)) > 0.001)
                return zip(segment,segment.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            }
            let approaching = try tyrePass(-38), alongside = try tyrePass(0), leaving = try tyrePass(38)
            print("Trackside tyre crossings "+kind.label+" "+String(approaching)+" / "+String(alongside)+" / "+String(leaving))
            precondition(Double(approaching) > Double(alongside)*1.055 && Double(leaving)*1.045 < Double(alongside))
            print("PASS  Trackside tyre pitch rises then falls across a pass for "+kind.label)
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
        print(String(format:"PASS  Matched 3000 rpm 911 isolated motor RMS: neutral/pull %.3f/%.3f; released/overrun %.3f/%.3f",
                     freeRMS,pullRMS,freeLiftRMS,overrunRMS))
        print(String(format:"PASS  Matched 3000 rpm, 55%% pedal, normalized high-pass RMS: %.3f free / %.3f pulling",neutralTreble,loadedTreble))
        let localEar = SIMD3(0.36,1,-0.15)
        let rightLook = SIMD3(-cos(1.22),0,-sin(1.22))
        let leftLook = SIMD3(-cos(1.22),0,sin(1.22))
        for kind in VehicleKind.allCases {
            let toward = VehicleSoundPerspective(kind:kind,localEar:localEar,localRight:rightLook,cockpit:true)
            let away = VehicleSoundPerspective(kind:kind,localEar:localEar,localRight:leftLook,cockpit:true)
            let right = try sample(kind:kind,effects:0,perspective:toward)
            let left = try sample(kind:kind,effects:0,perspective:away)
            precondition(signalRMS(right.right) > 1.04*signalRMS(right.left) &&
                         signalRMS(left.left) > 1.02*signalRMS(left.right))
        }
        func chaseLevel(_ eye: SIMD3<Double>) throws -> Double {
            let atCamera = VehicleSoundPerspective(kind:.porsche,localEar:eye,localRight:SIMD3(-1,0,0),cockpit:false)
            return try signalRMS(sample(kind:.porsche,effects:0,perspective:atCamera,cockpit:false).left)
        }
        let nearLevel = try chaseLevel(SIMD3(0,2.05,-5.8)), farLevel = try chaseLevel(SIMD3(0,3.5,-10.5))
        precondition(farLevel < 0.8*nearLevel && farLevel > 0.01)
        print(String(format:"PASS  Cockpit glance follows both rearward engine sources; chase motor RMS %.3f near / %.3f far",nearLevel,farLevel))
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
        func positionedWater(_ strength: SIMD4<Double>) -> RoadSound {
            var vehicle = Vehicle()
            vehicle.applyReplayPose(vehicle.renderSample,hasElevation:false,braking:false,spray:strength)
            var road = RoadSound()
            road.placeSources(for:vehicle,at:vehicle.position,right:-vehicle.modelX)
            return road
        }
        let dryWater = positionedWater(.zero)
        let equalWater = positionedWater(SIMD4(repeating:0.5))
        let leftWater = positionedWater(SIMD4(0,0.5,0,0.5))
        let rightWater = positionedWater(SIMD4(0.5,0,0.5,0))
        precondition(dryWater.spray?.level == 0 && equalWater.spray?.level == 0.5 &&
                     abs(equalWater.spray?.pan ?? 1) < 1e-12 &&
                     abs((leftWater.spray?.level ?? 0)-sqrt(0.125)) < 1e-12 &&
                     leftWater.spray?.level == rightWater.spray?.level &&
                     (leftWater.spray?.pan ?? 0) < -0.2 && (rightWater.spray?.pan ?? 0) > 0.2)
        let legacyWater = try sample(spray:0.5)
        let balancedWater = try sample(roadSound:equalWater)
        let measuredDry = try sample(roadSound:dryWater)
        precondition(legacyWater.left == balancedWater.left && legacyWater.right == balancedWater.right &&
                     measuredDry.left == smooth && measuredDry.right == smooth,
                     "Equal-spray and dry contacts should match the previous scalar mix sample for sample")
        let wetLeft = try sample(motor:0,roadSound:leftWater)
        let wetRight = try sample(motor:0,roadSound:rightWater)
        let chaseWetLeft = try sample(motor:0,roadSound:leftWater,cockpit:false)
        func sprayRMS(_ waveform: [Float]) -> Double { signalRMS(Array(waveform.suffix(22_050))) }
        let wetLeftRatio = sprayRMS(wetLeft.left) / sprayRMS(wetLeft.right)
        let wetRightRatio = sprayRMS(wetRight.right) / sprayRMS(wetRight.left)
        let chaseWetLeftRatio = sprayRMS(chaseWetLeft.left) / sprayRMS(chaseWetLeft.right)
        precondition((1.15...2.5).contains(wetLeftRatio) && abs(wetLeftRatio-wetRightRatio) < 0.01 &&
                     wetLeftRatio < chaseWetLeftRatio && wetLeft.left == wetRight.right && wetLeft.right == wetRight.left,
                     "The wet side must be reversible without hard-panning the cockpit")
        print(String(format:"PASS  Dry and balanced spray keep scalar parity; mirrored wet cabin/chase separation %.2f/%.2f",
                     wetLeftRatio,chaseWetLeftRatio))
        func contactState(forward: Double, lateral: Double = 0, tread: SIMD4<Double>,
                          edge: Double = 0, film: Double = 0, heave: Double = 0, kind: VehicleKind = .porsche) -> Vehicle {
            var car = Vehicle()
            car.kind = kind
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
        for (kind,frequency) in [(VehicleKind.porsche,150.0),(.centenario,300)] {
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
        let flatSix = Array(try sample(kind:.porsche).left.suffix(22050))
        let v12 = Array(try sample(kind:.centenario).left.suffix(22050))
        let correlation = abs(zip(flatSix,v12).reduce(0.0) { $0 + Double($1.0*$1.1) }) /
            sqrt(energy(flatSix)*energy(v12))
        precondition(correlation < 0.70)
        print(String(format:"PASS  The 911 flat-six and Centenario V12 retain distinct signatures, correlation %.3f",correlation))
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
        // Silence the listener so the measured signal comes solely
        // from the rival. A grid car is audible before its first physics step.
        var grid = Vehicle()
        grid.position = SIMD2(8,0)
        let parked = OpponentMotor.relative(to:basePlayer,opponent:grid,listenerRight:SIMD2(1,0))
        let passing = try sample(traffic:[near],effects:0,speed:0,isolateRival:true)
        let idling = try sample(traffic:[parked],effects:0,speed:0,isolateRival:true)
        let receding = try sample(traffic:[far],effects:0,speed:0,isolateRival:true)
        let pullRival = sqrt(energy(passing.right)/22050)
        let idleRival = sqrt(energy(idling.right)/22050)
        let farRival = sqrt(energy(receding.left)/22050)
        precondition(abs(parked.powertrain.shaftRPM-grid.rpm) < 1 && idleRival > 0.002 &&
                     pullRival > 1.35*idleRival && farRival > 0 && farRival < pullRival/10 &&
                     energy(passing.left) < 1e-8 && energy(idling.left) < 1e-8 && energy(receding.right) < 1e-8)
        print(String(format:"PASS  Isolated rival RMS at idle / approaching under load / receding %.4f / %.4f / %.4f; output follows its side",
                     idleRival,pullRival,farRival))
        // Separate cars may hold precisely the same RPM on the grid. Each engine keeps its own recorded phase.
        for kind in VehicleKind.allCases {
            for loaded in [false,true] {
                var car = grid
                car.kind = kind
                var engine = OpponentMotor.relative(to:basePlayer,opponent:car,listenerRight:SIMD2(1,0))
                engine.powertrain = PowertrainSound(driveLoad:loaded ? 0.72 : 0,shaftRPM:loaded ? 3000 : car.rpm,inGear:loaded)
                engine.throttle = loaded ? 0.8 : 0
                var silent = engine
                silent.volume = 0
                let single = try (0..<3).map { slot in
                    try sample(traffic:Array(repeating:silent,count:slot)+[engine],effects:0,speed:0,isolateRival:true).right
                }
                let pairCorrelations = [(0,1),(0,2),(1,2)].map { a,b in
                    let dot = zip(single[a],single[b]).reduce(0.0) { $0+Double($1.0)*Double($1.1) }
                    return dot/sqrt(single[a].reduce(0.0){$0+Double($1*$1)} * single[b].reduce(0.0){$0+Double($1*$1)})
                }
                let together = try sample(traffic:Array(repeating:engine,count:3),effects:0,speed:0,isolateRival:true).right
                let ratio = signalRMS(together)/sqrt(single.map { pow(signalRMS($0),2) }.reduce(0,+))
                print(String(format:"Matched %@ at %.0f RPM, phase correlation %.3f / %.3f / %.3f, combined / independent RMS %.3f",
                             kind.label,engine.powertrain.shaftRPM,pairCorrelations[0],pairCorrelations[1],pairCorrelations[2],ratio))
                precondition(single.allSatisfy { signalRMS($0) > 0.001 } && pairCorrelations.allSatisfy { abs($0) < 0.80 } &&
                             (0.70...1.30).contains(ratio))
                print("PASS  Three independent "+kind.label+" engines retain separate recording phases at matched RPM")
            }
        }
        for kind in VehicleKind.allCases {
            let locked = contactState(forward:20,tread:SIMD4(20,0,20,20),kind:kind)
            let free = contactState(forward:20,tread:SIMD4(repeating:20),kind:kind)
            let grassCar = contactState(forward:20,tread:SIMD4(20,0,20,20),edge:8,kind:kind)
            let airborneCar = contactState(forward:20,tread:SIMD4(20,0,20,20),heave:1,kind:kind)
            func neighbour(_ car: Vehicle,distance: Double = 5,direction: Double = 1) -> OpponentMotor {
                var placed = car
                placed.position = SIMD2(distance,0)
                return OpponentMotor.relative(to:basePlayer,opponent:placed,listenerRight:SIMD2(direction,0))
            }
            func isolated(_ car: OpponentMotor) throws -> (left: Double,right: Double) {
                let audio = try sample(traffic:[car],motor:0,speed:0,isolateRival:true)
                return (signalRMS(audio.left),signalRMS(audio.right))
            }
            let nearTyre = neighbour(locked)
            let right = try isolated(nearTyre), left = try isolated(neighbour(locked,direction:-1))
            let distant = try isolated(neighbour(locked,distance:45))
            let normal = try isolated(neighbour(free))
            let off = try isolated(neighbour(grassCar)), lifted = try isolated(neighbour(airborneCar))
            precondition(nearTyre.tyres.level > 0.5 && nearTyre.tyres.across > 0.95 && nearTyre.tyres.rearShare < 0.025)
            precondition(right.right > 0.002 && right.right > 4*distant.right && right.right > 4*right.left &&
                         abs(right.right-left.left) < 1e-6 && normal.right < 0.00005 && off.right == 0 && lifted.right == 0)
            print(String(format:"PASS  %@ front tyre scrub from a rival at 5 / 45 m RMS %.5f / %.5f, rolling %.6f; mirrored left/right and silent on grass or unloaded",
                         kind.label,right.right,distant.right,normal.right))
        }
        var wetOpponent = approaching
        let wetContact = WheelRoadContact(distance:0,progress:0,kerbsEnabled:false,waterDepth:0.60)
        let wetRoad = Array(repeating:wetContact,count:4)
        for _ in 0..<12 {
            wetOpponent.step(1/240,input:DrivingInput(throttle:0.78),assists:DrivingAssists(automatic:false),
                             roadDistance:0,roadWidth:12,roadContacts:wetRoad)
        }
        wetOpponent.position = SIMD2(5,0)
        func wetRival(at ear: SIMD2<Double> = .zero,right: Double = 1) -> OpponentMotor {
            var source = OpponentMotor.relative(to:basePlayer,opponent:wetOpponent,listenerRight:SIMD2(right,0),listenerPosition:ear)
            source.tyres = DistantTyres() // isolate the independently measured spray
            return source
        }
        let rightRival = wetRival()
        let leftRival = wetRival(right:-1)
        let medium = wetRival(at:SIMD2(-25,0))
        let beyond = wetRival(at:SIMD2(-100,0))
        var drySameRival = rightRival
        drySameRival.wetContact = 0
        let heardRight = try sample(traffic:[rightRival],motor:0,speed:0,isolateRival:true)
        let heardLeft = try sample(traffic:[leftRival],motor:0,speed:0,isolateRival:true)
        let heardMedium = try sample(traffic:[medium],motor:0,speed:0,isolateRival:true)
        let heardBeyond = try sample(traffic:[beyond],motor:0,speed:0,isolateRival:true)
        let mutedWet = try sample(traffic:[rightRival],effects:0,speed:0,isolateRival:true)
        let mutedDry = try sample(traffic:[drySameRival],effects:0,speed:0,isolateRival:true)
        let nearWater = signalRMS(Array(heardRight.right.suffix(22_050)))
        let mediumWater = signalRMS(Array(heardMedium.right.suffix(22_050)))
        precondition(rightRival.wetContact > 0.25 && nearWater > 0.0015 && mediumWater > 0 &&
                     nearWater > 2.5*mediumWater && energy(heardBeyond.right) == 0)
        let mirroredWater = heardRight.right.suffix(22_050) == heardLeft.left.suffix(22_050)
        precondition(mirroredWater && signalRMS(Array(heardRight.left.suffix(22_050))) < nearWater/5,
                     "Rival spray must follow the passing side")
        let unchangedMotor = mutedWet.right.suffix(22_050) == mutedDry.right.suffix(22_050)
        precondition(unchangedMotor && signalRMS(Array(mutedWet.right.suffix(22_050))) > 0.01,
                     "The effects slider must silence rival spray separately from the engine")
        print(String(format:"PASS  Wet rival stereo follows the passing side, falls with distance (RMS %.4f/%.4f), and remains separate from engine gain",
                     nearWater,mediumWater))
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
        let underLoad = try sample(kind:.porsche, throttle:0.91, speed:38, rpm:5800).left
        let liveFinish = try sample(kind:.porsche, cue:.checkered, throttle:0.91, speed:38, rpm:5800).left
        let cueDifference = zip(liveFinish, underLoad).map { $0 - $1 }
        let duringFinish = Array(cueDifference[start..<(start + 23_000)])
        precondition(signalRMS(duringFinish) > 0.022 && liveFinish.allSatisfy { abs($0) <= 0.75 })
        precondition(liveFinish.prefix(start) == underLoad.prefix(start) &&
                     liveFinish.suffix(10_000) == underLoad.suffix(10_000))
        print(String(format:"PASS  Race cue remains measurable under full engine load (RMS %.3f), with unchanged driving outside the cue",
                     signalRMS(duringFinish)))
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

import AVFoundation

@main struct AudioChecks {
    static func main() throws {
        let recording = URL(fileURLWithPath: CommandLine.arguments[1])
        let sound = EngineSound(recordingURL: recording)
        let rate = 44100.0
        let frames: AVAudioFrameCount = 735 // one 60 Hz driving update
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try sound.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        defer { sound.engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        let preview: AVAudioFile? = try CommandLine.arguments.count > 2 ? AVAudioFile(
            forWriting: URL(fileURLWithPath: CommandLine.arguments[2]), settings: [
                AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:rate, AVNumberOfChannelsKey:2,
                AVLinearPCMBitDepthKey:16, AVLinearPCMIsFloatKey:false
            ]) : nil
        var car = Vehicle()
        var idleEnergy = 0.0, driveEnergy = 0.0, quietPeak = 0.0, peak = 0.0
        var gears: Set<Int> = [], cuts = 0
        for tick in 0..<720 {
            let gas = (90..<530).contains(tick) ? 1.0 : 0.0
            let input = DrivingInput(throttle:gas, brake:tick>=615 ? 0.8 : 0)
            for _ in 0..<4 { car.step(1.0/240,input:input,assists:DrivingAssists(),roadDistance:0,roadWidth:12) }
            gears.insert(car.gear)
            if car.ignitionFraction < 1 { cuts += 1 }
            sound.muted = tick >= 690 && tick < 705
            sound.update(rpm:car.rpm,throttle:gas,ignition:car.ignitionFraction,cockpit:tick < 340,kerb:tick >= 600 ? 0.8 : 0,roadSpeed:20,paused:tick >= 705)
            guard sound.errorMessage == nil, sound.engine.isRunning else { fatalError("Audio graph did not start: \(sound.errorMessage ?? "unknown")") }
            let status = try sound.engine.renderOffline(frames,to:buffer)
            guard status == .success, buffer.frameLength == frames else { fatalError("Offline audio failed: \(status.rawValue)") }
            for index in 0..<Int(frames) {
                let x = Double(buffer.floatChannelData![0][index]); precondition(x.isFinite)
                peak = max(peak,abs(x))
                if (15..<75).contains(tick) {idleEnergy += x*x}
                if (300..<360).contains(tick) {driveEnergy += x*x}
                if tick >= 700 {quietPeak=max(quietPeak,abs(x))}
            }
            try preview?.write(from:buffer)
        }
        let idleRMS = sqrt(idleEnergy/rate), driveRMS = sqrt(driveEnergy/rate)
        precondition(idleRMS > 0.025 && driveRMS > idleRMS*1.25 && peak < 1 && quietPeak < 0.00002)
        precondition(gears.count >= 2 && cuts > 0)
        func sample(kerb: Double = 0, scrub: Double = 0, spray: Double = 0, kind: VehicleKind = .concept,
                    traffic: [OpponentMotor] = [], signal: Int = 0, master: Double = 1,
                    motor: Double = 1, effects: Double = 1,
                    roadSound: RoadSound? = nil) throws -> (left: [Float],right: [Float]) {
            let comparison = EngineSound(recordingURL:recording)
            comparison.masterVolume = master
            comparison.motorVolume = motor
            comparison.effectsVolume = effects
            try comparison.engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:frames)
            defer { comparison.engine.stop() }
            var left: [Float] = [], right: [Float] = []
            for tick in 0..<60 {
                comparison.update(rpm:3000,throttle:0.4,kerb:kerb,roadSpeed:20,tyreScrub:scrub,roadSound:roadSound,spray:spray,kind:kind,
                                  opponents:traffic,raceSignal:tick >= 10 ? signal : 0,paused:false)
                guard try comparison.engine.renderOffline(frames,to:buffer) == .success else { fatalError("Road audio render failed") }
                left.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(frames)))
                right.append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![1],count:Int(frames)))
            }
            return (left,right)
        }
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
        var leftTyre = Vehicle()
        leftTyre.velocity = leftTyre.forward*20
        leftTyre.wheels[1].kerbFeedback = 0.7
        leftTyre.wheels[1].normalLoad = 3100
        leftTyre.wheels[1].gripUsage = 1
        leftTyre.wheels[1].relaxedSlipAngle = 0.3
        let road = RoadSound(vehicle:leftTyre)
        let isolatedRoad = try sample(kerb:0.7,motor:0,roadSound:road)
        func energy(_ values: [Float]) -> Double {
            values.suffix(22050).reduce(0) { $0+Double($1*$1) }
        }
        precondition(road.kerbPan == -1 && road.scrubPan == -1 &&
                     energy(isolatedRoad.left) > energy(isolatedRoad.right)*4)
        print("PASS  Loaded driver-left kerb and scrub cues stay on the left audio channel")
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
        for (kind, frequency) in [(VehicleKind.porsche,150.0),(.ferrari,200),(.centenario,300)] {
            let mix = try sample(kind:kind)
            let peak = amplitude(mix.left,frequency:frequency)
            precondition(peak > 0.09 && peak > amplitude(mix.left,frequency:frequency+17)*8 &&
                         mix.left == mix.right && mix.left.allSatisfy { $0.isFinite && abs($0) < 0.75 })
            print(String(format:"PASS  %@ has a %.0f Hz firing peak at 3000 rpm (amplitude %.3f)",kind.label,frequency,peak))
        }
        let basePlayer = Vehicle()
        var approaching = Vehicle(); approaching.position = SIMD2(8,0); approaching.velocity = SIMD2(-25,0)
        let near = OpponentMotor.relative(to:basePlayer,opponent:approaching,listenerRight:SIMD2(1,0))
        approaching.position = SIMD2(70,0); approaching.velocity = SIMD2(25,0)
        let far = OpponentMotor.relative(to:basePlayer,opponent:approaching,listenerRight:SIMD2(1,0))
        precondition(near.doppler > 1 && far.doppler < 1 && near.pan > 0.99 && near.volume > 20*far.volume)
        let pass = try sample(traffic:[near])
        let leftChange = zip(pass.left,smooth).reduce(0.0) { $0 + abs(Double($1.0-$1.1)) }
        let rightChange = zip(pass.right,smooth).reduce(0.0) { $0 + abs(Double($1.0-$1.1)) }
        precondition(rightChange / rate > 0.015 && leftChange < 1e-6)
        print("PASS  A passing rival pans toward the listener's right, with distance and relative pitch")
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
        print(String(format:"PASS  Engine graph: idle RMS %.3f, loaded RMS %.3f, peak %.3f, muted/paused peak %.6f; %d gears, %d ignition-cut updates",idleRMS,driveRMS,peak,quietPeak,gears.count,cuts))
    }
}

import AVFoundation

@main struct AudioChecks {
    static func main() throws {
        let recording = URL(fileURLWithPath: CommandLine.arguments[1])
        let sound = EngineSound(recordingURL: recording)
        let rate = 44100.0
        let frames: AVAudioFrameCount = 735 // one 60 Hz driving update
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        try sound.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        defer { sound.engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        let preview: AVAudioFile? = try CommandLine.arguments.count > 2 ? AVAudioFile(
            forWriting: URL(fileURLWithPath: CommandLine.arguments[2]), settings: [
                AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:rate, AVNumberOfChannelsKey:1,
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
            sound.update(rpm:car.rpm,throttle:gas,ignition:car.ignitionFraction,cockpit:tick < 340,paused:tick >= 705)
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
        print(String(format:"PASS  Engine graph: idle RMS %.3f, loaded RMS %.3f, peak %.3f, muted/paused peak %.6f; %d gears, %d ignition-cut updates",idleRMS,driveRMS,peak,quietPeak,gears.count,cuts))
    }
}

import AVFoundation
import os

struct MotorControls {
    var rpm = 950.0
    var throttle = 0.0
    var ignition = 1.0
    var cockpit = true
    var audible = false
}

/// One continuous render stream. Only the render thread advances the recording,
/// firing cycle and filters. The main thread publishes targets once per tick.
private final class MotorVoice {
    let controls = OSAllocatedUnfairLock(initialState: MotorControls())
    static let sampleRate = 44100.0
    private let recording: [Float]
    private let seam = 480
    private var cursor = 0.0
    private var firingPhase = 0.0
    private var randomState: UInt32 = 0x676173
    private var targets = MotorControls()
    private var rpm = 950.0
    private var load = 0.0
    private var ignition = 1.0
    private var gain = 0.0
    private var filtered = 0.0
    private var air = 0.0
    private var exhaust = Pipe(frequency: 122, decay: 0.013)
    private var intake = Pipe(frequency: 344, decay: 0.006)

    private struct Pipe {
        let feedback: Double
        let damping: Double
        let excitation: Double
        var previous = 0.0
        var older = 0.0

        init(frequency: Double, decay: Double) {
            let angle = 2 * Double.pi * frequency / MotorVoice.sampleRate
            let pole = exp(-1 / (decay * MotorVoice.sampleRate))
            feedback = 2 * pole * cos(angle)
            damping = pole * pole
            excitation = sin(angle)
        }

        mutating func tick(_ pulse: Double) -> Double {
            let next = feedback * previous - damping * older + pulse * excitation
            older = previous
            previous = next
            return next
        }
    }

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == Self.sampleRate, file.length > 4096,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for index in mono.indices { mono[index] += channels[channel][index] / Float(channelCount) }
        }
        let mean = mono.reduce(0,+) / Float(count)
        recording = mono.map { $0 - mean }
    }

    private func sample(at position: Double) -> Double {
        let index = Int(position)
        let fraction = Float(position - Double(index))
        let next = (index + 1) % recording.count
        return Double(recording[index] + (recording[next] - recording[index]) * fraction)
    }

    func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        if let latest = controls.withLockIfAvailable({ $0 }) { targets = latest }
        let level = targets.audible ? 1.0 : 0.0
        if level == 0 && gain < 0.00001 {
            output.update(repeating: 0,count: count)
            return
        }
        let rate = Self.sampleRate
        let cutoff = (targets.cockpit ? 1450.0 : 3400.0) + 1800 * targets.throttle
        let filterAmount = 1 - exp(-2 * .pi * cutoff / rate)
        for frame in 0..<count {
            rpm += (targets.rpm - rpm) * 0.0012
            load += (targets.throttle - load) * 0.0006
            gain += (level - gain) * 0.003
            ignition += (targets.ignition - ignition) * 0.004
            // Two firing events per crank revolution in this four-stroke inline four.
            firingPhase += rpm / (30 * rate)
            randomState = randomState &* 1664525 &+ 1013904223
            let random = Double(randomState) / Double(UInt32.max)
            var pulse = 0.0
            if firingPhase >= 1 {
                firingPhase -= 1
                if random <= ignition { pulse = 0.88 + 0.24 * random }
            }
            let exhaustNote = exhaust.tick(pulse)
            let intakeNote = intake.tick(pulse)
            var recorded = sample(at: cursor)
            let tail = Double(recording.count - seam)
            if cursor >= tail {
                let mix = (cursor - tail) / Double(seam)
                recorded += (sample(at: cursor - tail) - recorded) * mix
            }
            // The recording's strongest firing band is ~87 Hz. 2610 rpm is a
            // playback reference for this car, not a measured donor-engine RPM.
            cursor += rpm / 2610
            if cursor >= Double(recording.count) { cursor -= tail }
            air += ((random * 2 - 1) - air) * 0.18
            let motor = recorded * (0.39 + 0.35 * load) * (0.32 + 0.68 * ignition)
            let combustion = (0.60 * exhaustNote + 0.27 * intakeNote) * (0.07 + 0.34 * load)
            let sample = motor + combustion + air * load * 0.085
            filtered += (sample - filtered) * filterAmount
            output[frame] = Float(0.75 * gain * tanh(filtered * 1.4))
        }
    }
}

final class EngineSound {
    let engine = AVAudioEngine()
    private let voice: MotorVoice?
    private var nextStartAttempt = 0.0
    var muted = false
    private(set) var errorMessage: String?

    init(recordingURL: URL? = nil) {
        let url = recordingURL ?? Bundle.main.resourceURL!.appendingPathComponent("Assets/Audio/engine-recording.wav")
        do { voice = try MotorVoice(url: url) }
        catch { voice = nil; errorMessage = error.localizedDescription; return }
        guard let voice, let format = AVAudioFormat(standardFormatWithSampleRate: MotorVoice.sampleRate, channels: 1) else { return }
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let channel = UnsafeMutableAudioBufferListPointer(buffers)[0]
            if let data = channel.mData { voice.render(into: data.assumingMemoryBound(to: Float.self), count: Int(frames)) }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func update(rpm: Double, throttle: Double, ignition: Double = 1, cockpit: Bool = true, paused: Bool) {
        guard let voice else { return }
        let audible = !paused && !muted
        voice.controls.withLock {
            $0 = MotorControls(rpm: clamp(rpm, 750, 7500), throttle: clamp(throttle, 0, 1),
                               ignition: clamp(ignition, 0, 1), cockpit: cockpit, audible: audible)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if audible && !engine.isRunning && now >= nextStartAttempt {
            nextStartAttempt = now + 2
            do { try engine.start(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

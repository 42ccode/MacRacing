import AVFoundation
import os

struct MotorControls {
    var rpm = 950.0
    var throttle = 0.0
    var ignition = 1.0
    var cockpit = true
    var audible = false
    var kerb = 0.0
    var roadSpeed = 0.0
    var tyreScrub = 0.0
    var kerbPan = 0.0
    var scrubPan = 0.0
    var absModulation = 0.0
    var spray = 0.0
    var kind = VehicleKind.concept
    var opponents: [OpponentMotor] = []
    var raceSignal = 0
    var motorVolume = 1.0
    var effectsVolume = 1.0
    var masterVolume = 1.0
}

struct RoadSound {
    var kerbPan = 0.0
    var tyreScrub = 0.0
    var scrubPan = 0.0
    var absModulation = 0.0

    init(kerbPan: Double = 0,tyreScrub: Double = 0,scrubPan: Double = 0,absModulation: Double = 0) {
        self.kerbPan = kerbPan
        self.tyreScrub = tyreScrub
        self.scrubPan = scrubPan
        self.absModulation = absModulation
    }

    init(vehicle: Vehicle) {
        let tyres = vehicle.tyreScrubBySide
        let leftKerb = max(vehicle.wheels[1].kerbFeedback,vehicle.wheels[3].kerbFeedback)
        let rightKerb = max(vehicle.wheels[0].kerbFeedback,vehicle.wheels[2].kerbFeedback)
        kerbPan = (rightKerb-leftKerb)/max(0.06,rightKerb+leftKerb)
        tyreScrub = max(tyres.x,tyres.y)
        scrubPan = (tyres.y-tyres.x)/max(0.08,tyres.x+tyres.y)
        absModulation = vehicle.absActive && vehicle.brakeLinePressure > 0.06 ? vehicle.absRelease : 0
    }
}

struct OpponentMotor {
    var rpm: Double
    var volume: Double
    var pan: Double
    var doppler: Double

    static func relative(to player: Vehicle, opponent: Vehicle, listenerRight: SIMD2<Double>) -> Self {
        let offset = opponent.position - player.position
        let distance = hypot(offset.x,offset.y)
        let ray = offset / max(distance,1)
        let right = ray.x*listenerRight.x + ray.y*listenerRight.y
        let playerAlong = player.velocity.x*ray.x + player.velocity.y*ray.y
        let sourceAlong = opponent.velocity.x*ray.x + opponent.velocity.y*ray.y
        let range = clamp(1-distance/82,0,1)
        return OpponentMotor(rpm:opponent.rpm,volume:range*range*0.24/(1+distance/18),
                             pan:clamp(right,-1,1),doppler:clamp((343+playerAlong)/(343+sourceAlong),0.78,1.23))
    }
}

private struct MotorProfile {
    let eventsPerRevolution: Double
    let recording: Double
    let exhaust: Double
    let intake: Double
    let level: Double

    static func forCar(_ kind: VehicleKind) -> MotorProfile {
        switch kind {
        case .concept: return .init(eventsPerRevolution:2,recording:1,exhaust:122,intake:344,level:1)
        case .mazda: return .init(eventsPerRevolution:2,recording:0.84,exhaust:133,intake:395,level:0.94)
        case .bmw: return .init(eventsPerRevolution:2,recording:0.46,exhaust:105,intake:294,level:1.06)
        case .porsche: return .init(eventsPerRevolution:3,recording:0,exhaust:155,intake:342,level:1.0)
        case .ferrari: return .init(eventsPerRevolution:4,recording:0,exhaust:192,intake:483,level:1.05)
        case .centenario: return .init(eventsPerRevolution:6,recording:0,exhaust:144,intake:560,level:1.08)
        case .lotus: return .init(eventsPerRevolution:2,recording:0.72,exhaust:152,intake:420,level:0.93)
        case .honda: return .init(eventsPerRevolution:8,recording:0,exhaust:120,intake:470,level:0.15)
        }
    }
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
    private var filteredSide = 0.0
    private var kerbPan = 0.0
    private var scrubPan = 0.0
    private var absLevel = 0.0
    private var absPhase = 0.0
    private var air = 0.0
    private var roadLevel = 0.0
    private var roadPhase = 0.0
    private var roadNoise = 0.0
    private var scrubLevel = 0.0
    private var scrubPhase = 0.0
    private var sprayLevel = 0.0
    private var sprayNoise = 0.0
    private var exhaust = Pipe(frequency: 122, decay: 0.013)
    private var intake = Pipe(frequency: 344, decay: 0.006)
    private var kind = VehicleKind.concept
    private var profile = MotorProfile.forCar(.concept)
    private var traffic = (0..<3).map { _ in TrafficVoice() }
    private var previousSignal = 0
    private var master = 1.0
    private var motorGain = 1.0
    private var effectsGain = 1.0
    private var signalRemaining = 0.0
    private var signalPhase = 0.0
    private var signalFrequency = 0.0

    private struct TrafficVoice {
        var phase = 0.0
        var frequency = 28.0
        var left = 0.0
        var right = 0.0
        mutating func tick(hz: Double, left targetL: Double, right targetR: Double) -> (Double,Double) {
            left += (targetL-left)*0.00075; right += (targetR-right)*0.00075
            if max(left,right) < 0.00001 { return (0,0) }
            frequency += (hz-frequency)*0.00085
            phase += frequency / MotorVoice.sampleRate
            if phase >= 1 { phase -= 1 }
            let phi = phase * (2 * .pi)
            let note = sin(phi) * 0.64 + sin(2*phi) * 0.23 + sin(3*phi) * 0.13
            return (note*left,note*right)
        }
    }

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

    func render(left output: UnsafeMutablePointer<Float>, right rightOutput: UnsafeMutablePointer<Float>, count: Int) {
        if let latest = controls.withLockIfAvailable({ $0 }) { targets = latest }
        if targets.raceSignal != previousSignal {
            previousSignal = targets.raceSignal
            signalRemaining = previousSignal == 0 ? 0 : (previousSignal == 4 ? 0.29 : 0.12)
            signalFrequency = previousSignal == 4 ? 1150 : 780
            signalPhase = 0
        }
        if kind != targets.kind {
            kind = targets.kind
            profile = MotorProfile.forCar(kind)
            exhaust = Pipe(frequency:profile.exhaust,decay:0.013)
            intake = Pipe(frequency:profile.intake,decay:0.006)
        }
        let level = targets.audible ? 1.0 : 0.0
        if level == 0 && gain < 0.00001 {
            output.update(repeating: 0,count: count)
            rightOutput.update(repeating:0,count:count)
            return
        }
        let rate = Self.sampleRate
        let cutoff = (targets.cockpit ? 1450.0 : 3400.0) + 1800 * targets.throttle
        let filterAmount = 1 - exp(-2 * .pi * cutoff / rate)
        let opponent0 = opponentParameters(0), opponent1 = opponentParameters(1), opponent2 = opponentParameters(2)
        for frame in 0..<count {
            rpm += (targets.rpm - rpm) * 0.0012
            load += (targets.throttle - load) * 0.0006
            gain += (level - gain) * 0.003
            ignition += (targets.ignition - ignition) * 0.004
            firingPhase += rpm * profile.eventsPerRevolution / (60 * rate)
            randomState = randomState &* 1664525 &+ 1013904223
            let random = Double(randomState) / Double(UInt32.max)
            var pulse = 0.0
            if firingPhase >= 1 {
                firingPhase -= 1
                if random <= ignition { pulse = 0.88 + 0.24 * random }
            }
            let exhaustNote = exhaust.tick(pulse)
            let intakeNote = intake.tick(pulse)
            var recorded = 0.0
            if profile.recording > 0 {
                recorded = sample(at: cursor)
                let tail = Double(recording.count - seam)
                if cursor >= tail {
                    let mix = (cursor - tail) / Double(seam)
                    recorded += (sample(at: cursor - tail) - recorded) * mix
                }
                // The strongest recorded firing band is ~87 Hz; 2610 rpm
                // is the playback reference for the inline-four presets.
                cursor += rpm / 2610
                if cursor >= Double(recording.count) { cursor -= tail }
            }
            air += ((random * 2 - 1) - air) * 0.18
            let motor = profile.recording * recorded * (0.39 + 0.35 * load) * (0.32 + 0.68 * ignition)
            let exhaustPulse = (0.60 * exhaustNote + 0.27 * intakeNote) * (0.07 + 0.34 * load)
            let phase = firingPhase * (2 * .pi)
            let formant = (sin(phase) * 0.72 + sin(phase*2)*0.22 + sin(phase*3)*0.06) * ignition
            let generated = formant * (0.055+0.27*load) * (1-profile.recording*0.92)
            let combustion = (exhaustPulse + generated) * profile.level
            roadLevel += (targets.kerb - roadLevel) * 0.001
            roadPhase += (12 + targets.roadSpeed * 1.3) / rate
            roadPhase -= floor(roadPhase)
            roadNoise += ((random * 2 - 1) - roadNoise) * 0.035
            let road = roadLevel * (roadNoise * 1.3 + sin(roadPhase * 2 * .pi) * 0.18)
            scrubLevel += (targets.tyreScrub - scrubLevel) * 0.0009
            scrubPhase += (380 + 13 * targets.roadSpeed + 220 * scrubLevel) / rate
            scrubPhase -= floor(scrubPhase)
            let scrub = scrubLevel * (0.18 * sin(scrubPhase * 2 * .pi) + 0.25 * (random * 2 - 1 - air))
            sprayLevel += (targets.spray - sprayLevel) * 0.0008
            sprayNoise += ((random * 2 - 1) - sprayNoise) * 0.33
            let water = sprayLevel * (sprayNoise - roadNoise) * 0.34
            kerbPan += (targets.kerbPan-kerbPan)*0.0014
            scrubPan += (targets.scrubPan-scrubPan)*0.0014
            absLevel += (targets.absModulation-absLevel)*0.0018
            var absSound = 0.0
            if absLevel > 0.0001 {
                absPhase += 11/rate
                if absPhase >= 1 { absPhase -= 1 }
                let valve = max(0,cos(absPhase*2 * .pi))
                absSound = absLevel*valve*valve*(0.11*roadNoise+0.12*(random*2-1-air))
            }
            let side = (road*kerbPan*0.55 + scrub*scrubPan*0.5)*effectsGain
            filteredSide += (side-filteredSide)*filterAmount
            master += (targets.masterVolume-master)*0.0015
            motorGain += (targets.motorVolume-motorGain)*0.0015
            effectsGain += (targets.effectsVolume-effectsGain)*0.0015
            let sample = (motor + combustion + air * load * 0.085)*motorGain + (road + scrub + water + absSound)*effectsGain
            filtered += (sample - filtered) * filterAmount
            let a = traffic[0].tick(hz:opponent0.0,left:opponent0.1,right:opponent0.2)
            let b = traffic[1].tick(hz:opponent1.0,left:opponent1.1,right:opponent1.2)
            let c = traffic[2].tick(hz:opponent2.0,left:opponent2.1,right:opponent2.2)
            var signal = 0.0
            if signalRemaining > 0 {
                let duration = previousSignal == 4 ? 0.29 : 0.12
                let envelope = min(1,(duration-signalRemaining)*230,signalRemaining*22)
                signal = sin(signalPhase) * envelope * 0.30
                signalPhase += signalFrequency*2 * .pi/rate
                signalRemaining = max(0,signalRemaining-1/rate)
            }
            output[frame] = Float(0.75 * gain * master * tanh((filtered-filteredSide+(a.0+b.0+c.0)*motorGain+signal*effectsGain) * 1.4))
            rightOutput[frame] = Float(0.75 * gain * master * tanh((filtered+filteredSide+(a.1+b.1+c.1)*motorGain+signal*effectsGain) * 1.4))
        }
    }

    private func opponentParameters(_ index: Int) -> (Double,Double,Double) {
        guard targets.opponents.indices.contains(index) else { return (50,0,0) }
        let source = targets.opponents[index]
        let frequency = source.rpm * profile.eventsPerRevolution * source.doppler / 60
        let gain = source.volume * (targets.cockpit ? 0.76 : 1)
        return (frequency,gain*sqrt(0.5*(1-source.pan)),gain*sqrt(0.5*(1+source.pan)))
    }
}

final class EngineSound {
    let engine = AVAudioEngine()
    private let voice: MotorVoice?
    private var nextStartAttempt = 0.0
    var muted = false
    var masterVolume = 1.0
    var motorVolume = 1.0
    var effectsVolume = 1.0
    private(set) var errorMessage: String?

    init(recordingURL: URL? = nil) {
        let url = recordingURL ?? Bundle.main.resourceURL!.appendingPathComponent("Assets/Audio/engine-recording.wav")
        do { voice = try MotorVoice(url: url) }
        catch { voice = nil; errorMessage = error.localizedDescription; return }
        guard let voice, let format = AVAudioFormat(standardFormatWithSampleRate: MotorVoice.sampleRate, channels: 2) else { return }
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let channels = UnsafeMutableAudioBufferListPointer(buffers)
            if channels.count == 2, let left = channels[0].mData, let right = channels[1].mData {
                voice.render(left:left.assumingMemoryBound(to:Float.self),right:right.assumingMemoryBound(to:Float.self),count:Int(frames))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func update(rpm: Double, throttle: Double, ignition: Double = 1, cockpit: Bool = true, kerb: Double = 0,
                roadSpeed: Double = 0, tyreScrub: Double = 0, roadSound: RoadSound? = nil,
                spray: Double = 0, kind: VehicleKind = .concept,
                opponents: [OpponentMotor] = [], raceSignal: Int = 0, paused: Bool) {
        guard let voice else { return }
        let audible = !paused && !muted
        voice.controls.withLock {
            $0 = MotorControls(rpm: clamp(rpm, 750, 7500), throttle: clamp(throttle, 0, 1),
                               ignition: clamp(ignition, 0, 1), cockpit: cockpit, audible: audible,
                               kerb: clamp(kerb, 0, 1), roadSpeed: clamp(roadSpeed, 0, 100),
                               tyreScrub:clamp(roadSound?.tyreScrub ?? tyreScrub,0,1),
                               kerbPan:clamp(roadSound?.kerbPan ?? 0,-1,1),
                               scrubPan:clamp(roadSound?.scrubPan ?? 0,-1,1),
                               absModulation:clamp(roadSound?.absModulation ?? 0,0,1),
                               spray:clamp(spray,0,1),kind:kind,opponents:opponents,
                               raceSignal:audible ? clamp(raceSignal,0,4) : 0,motorVolume:motorVolume,
                               effectsVolume:effectsVolume,masterVolume:masterVolume)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if audible && !engine.isRunning && now >= nextStartAttempt {
            nextStartAttempt = now + 2
            do { try engine.start(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

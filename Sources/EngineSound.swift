import AVFoundation
import os
import simd

enum RaceAudioCue: CaseIterable {
    case finalLap, checkered, yellowFlag, trainingPassed, trainingFailed

    fileprivate var priority: Int {
        switch self {
        case .yellowFlag: return 0
        case .finalLap: return 1
        case .checkered, .trainingPassed, .trainingFailed: return 2
        }
    }

    fileprivate func note(_ index: Int) -> RaceCueNote? {
        switch (self, index) {
        case (.finalLap, 0): return RaceCueNote(587.3, duration: 0.124, gap: 0.032, level: 0.17)
        case (.finalLap, 1): return RaceCueNote(880.0, duration: 0.187, level: 0.18)
        case (.checkered, 0): return RaceCueNote(493.9, duration: 0.108, gap: 0.020, level: 0.20)
        case (.checkered, 1): return RaceCueNote(659.3, duration: 0.113, gap: 0.025, level: 0.20)
        case (.checkered, 2): return RaceCueNote(740.0, duration: 0.273, level: 0.22)
        case (.yellowFlag, 0): return RaceCueNote(698.5, duration: 0.101, gap: 0.027, level: 0.11)
        case (.yellowFlag, 1): return RaceCueNote(587.3, duration: 0.114, level: 0.09)
        case (.trainingPassed, 0): return RaceCueNote(523.3, duration: 0.143, gap: 0.030, level: 0.16)
        case (.trainingPassed, 1): return RaceCueNote(783.9, duration: 0.232, level: 0.19)
        case (.trainingFailed, 0): return RaceCueNote(440.0, duration: 0.107, gap: 0.035, level: 0.14)
        case (.trainingFailed, 1): return RaceCueNote(329.6, duration: 0.205, level: 0.13)
        default: return nil
        }
    }
}

private struct RaceCueNote {
    let phaseStep: Double
    let duration: Int
    let totalFrames: Int
    let level: Double

    init(_ frequency: Double, duration: Double, gap: Double = 0, level: Double) {
        let rate = MotorVoice.sampleRate
        phaseStep = 2 * .pi * frequency / rate
        self.duration = Int((duration * rate).rounded())
        totalFrames = Int(((duration + gap) * rate).rounded())
        self.level = level
    }

    func sample(at frame: Int) -> Double {
        guard frame < duration else { return 0 }
        let phase = Double(frame) * phaseStep
        let attack = min(1, Double(frame) / 530)
        let release = min(1, Double(duration - frame - 1) / 2060)
        let edge = min(attack, release)
        let envelope = edge * edge * (3 - 2 * edge)
        let progress = Double(frame) / Double(duration)
        let strikingPartial = max(0, 1 - Double(frame) / 2700)
        return (sin(phase) + 0.16 * strikingPartial * sin(2 * phase)) * envelope * (1 - 0.62 * progress) * level
    }
}

private struct RaceCuePlayback {
    private static let cancellationFrames = 441
    let cue: RaceAudioCue
    private var noteIndex = 0
    private var frame = 0
    private var note: RaceCueNote?
    private var cancellationProgress = 0
    var shouldFade = false
    var isFinished: Bool { note == nil || cancellationProgress >= Self.cancellationFrames }

    init(_ cue: RaceAudioCue) {
        self.cue = cue
        note = cue.note(0)
    }

    mutating func nextSample() -> Double {
        guard let note else { return 0 }
        let sample = note.sample(at: frame)
        frame += 1
        if frame == note.totalFrames {
            noteIndex += 1
            frame = 0
            self.note = cue.note(noteIndex)
        }
        guard shouldFade else { return sample }
        cancellationProgress += 1
        let tail = 1 - Double(cancellationProgress) / Double(Self.cancellationFrames)
        return sample * tail * tail * (3 - 2 * tail)
    }
}

private struct PositionedContact {
    let firm: Bool
    let level: Double
    let channels: SIMD2<Double>

    init?(_ sound: ContactSound,listenerPosition: SIMD2<Double>,listenerRight: SIMD2<Double>,cockpit: Bool) {
        let speed = sound.closingSpeed
        let offset = sound.position-listenerPosition
        let distance = simd_length(offset)
        guard speed.isFinite,speed >= 1.5,distance.isFinite,distance < 56 else { return nil }
        let severity = clamp((speed-1.5)/12.5,0,1)
        let range = 1-distance/56
        level = (0.024+0.122*pow(severity,0.82))*range*range/(1+distance/(cockpit ? 9 : 14))
        firm = speed >= 5.5

        let width = simd_length(listenerRight)
        let bearing = width.isFinite && width > 1e-6 ? simd_dot(offset,listenerRight/width)/max(1.2,distance) : 0
        let pan = clamp(bearing,-1,1)*(cockpit ? 0.66 : 1)
        channels = SIMD2(sqrt(1-pan),sqrt(1+pan))
    }
}

private struct ContactClip {
    let samples: [Float]
    let attackRMS: Double
    let peak: Double

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false),
              file.processingFormat.sampleRate == MotorVoice.sampleRate,file.processingFormat.channelCount == 1,
              file.length > 0,file.length <= Int64(2*MotorVoice.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)),
              (try? file.read(into:buffer)) != nil,buffer.frameLength > 0,let data = buffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start:data,count:Int(buffer.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { return nil }
        let attack = samples.prefix(Int(MotorVoice.sampleRate/10))
        let attackRMS = sqrt(attack.reduce(0.0) { $0+Double($1)*Double($1) }/Double(attack.count))
        guard attackRMS > 0.005 else { return nil }
        self.samples = samples
        self.attackRMS = attackRMS
        peak = samples.reduce(0) { max($0,abs(Double($1))) }
    }
}

private struct ContactPlayback {
    private static let releaseFrames = 441
    let level: Double
    private let clip: ContactClip
    private let channels: SIMD2<Double>
    private var frame = 0
    private var released = 0
    var fading = false
    var pastAttack: Bool { frame >= Int(MotorVoice.sampleRate*0.2) }
    var finished: Bool { frame >= clip.samples.count || released >= Self.releaseFrames }

    init(_ request: PositionedContact,clip: ContactClip) {
        level = request.level
        self.clip = clip
        // The two source recordings have different attack RMS. Compensate
        // here so measured closing speed controls loudness across the boundary.
        let headroom = 0.95/(clip.peak*request.channels.max())
        channels = min(level/clip.attackRMS,headroom)*request.channels
    }

    mutating func nextSample() -> SIMD2<Double> {
        guard !finished else { return .zero }
        let sample = Double(clip.samples[frame])*channels
        frame += 1
        guard fading else { return sample }
        released += 1
        let tail = 1-Double(released)/Double(Self.releaseFrames)
        return sample*(tail*tail*(3-2*tail))
    }
}

private struct MotorControls {
    var throttle = 0.0
    var ignition = 1.0
    var powertrain = PowertrainSound()
    var perspective = VehicleSoundPerspective()
    var cockpit = true
    var audible = false
    var kerb = 0.0
    var roadSpeed = 0.0
    var rolling = 0.0
    var wind = 0.0
    var tyres = TyreSound()
    var kerbPan = 0.0
    var absModulation = 0.0
    var spray = 0.0
    var sprayPan = 0.0
    var kind = VehicleKind.porsche
    var opponents: (OpponentMotor?,OpponentMotor?,OpponentMotor?) = (nil,nil,nil)
    var raceSignal = 0
    var motorVolume = 1.0
    var effectsVolume = 1.0
    var masterVolume = 1.0
    var pendingCue: RaceAudioCue?
    var cancelCue = false
    var pendingContact: PositionedContact?
    var cancelContact = false
}

/// Approximate acoustic centres in vehicle-local metres (+Z towards the nose).
/// The cabin admits reflected sound on both sides. Outside, sound pressure
/// falls with distance from a source of finite size.
struct VehicleSoundPerspective {
    var motorChannels = SIMD2<Double>(repeating:1)
    var roadGain = 1.0
    var sourceDoppler = 1.0

    init() {}

    init(kind: VehicleKind, localEar: SIMD3<Double>, localRight: SIMD3<Double>, cockpit: Bool,doppler: Double = 1) {
        sourceDoppler = clamp(doppler,0.78,1.23)
        let engineZ: Double
        switch kind {
        case .porsche: engineZ = kind.frontAxle - kind.wheelbase - 0.25
        case .centenario: engineZ = (kind.frontAxle - kind.wheelbase) * 0.7
        }
        let offset = SIMD3(0,0.52,engineZ) - localEar
        let distance = simd_length(offset)
        let pan = clamp(simd_dot(offset,localRight)/max(0.7,distance),-1,1) * (cockpit ? 0.35 : 0.85)
        let gain = cockpit ? 1 : 1.25 / sqrt(1 + distance*distance/9)
        motorChannels = SIMD2(sqrt(1-pan),sqrt(1+pan)) * gain
        if !cockpit { roadGain = 1 / sqrt(1 + simd_length_squared(localEar)/16) }
    }
}

struct OpponentMotor {
    var volume: Double
    var pan: Double
    var doppler: Double
    var kind: VehicleKind
    var powertrain: PowertrainSound
    var throttle = 0.0
    var ignition = 1.0
    var wetContact = 0.0
    var tyreSpeed = 0.0

    var tyres = DistantTyres()
    var tyreChannels = SIMD2<Double>.zero

    private static func attenuation(_ distance: Double) -> Double {
        let range = clamp(1-distance/82,0,1)
        return range*range*0.24/(1+distance/18)
    }

    static func relative(to player: Vehicle, opponent: Vehicle, listenerRight: SIMD2<Double>,
                         listenerPosition: SIMD2<Double>? = nil,listenerVelocity: SIMD2<Double>? = nil,
                         recordedTyres: DistantTyres? = nil) -> Self {
        let offset = opponent.position - (listenerPosition ?? player.position)
        let distance = hypot(offset.x,offset.y)
        let ray = offset / max(distance,1)
        let right = ray.x*listenerRight.x + ray.y*listenerRight.y
        let tyres = recordedTyres ?? TyreSound(vehicle:opponent).distant
        var tyreChannels = SIMD2<Double>.zero
        if tyres.level > 0 {
            let centre = offset + opponent.modelX * (tyres.across * opponent.trackWidth/2)
                + opponent.forward * (opponent.kind.frontAxle - tyres.rearShare * opponent.wheelbase)
            let tyreDistance = simd_length(centre)
            let pan = clamp(simd_dot(centre,listenerRight)/max(1,tyreDistance),-1,1)
            tyreChannels = SIMD2(sqrt(0.5*(1-pan)),sqrt(0.5*(1+pan))) * attenuation(tyreDistance)
        }
        // Replay restores wheel spray in the same pose used for particles.
        let sprayPower = opponent.wheels.reduce(0.0) { $0+$1.spray*$1.spray }
        return OpponentMotor(volume:attenuation(distance),
                             pan:clamp(right,-1,1),doppler:doppler(along:ray,source:opponent.velocity,
                                                                  listener:listenerVelocity ?? player.velocity),
                             kind:opponent.kind,powertrain:opponent.powertrainSound,
                             throttle:opponent.engineThrottle,ignition:opponent.ignitionFraction,
                             wetContact:sqrt(sprayPower/4),tyreSpeed:opponent.speed,tyres:tyres,tyreChannels:tyreChannels)
    }

    static func doppler(along ray: SIMD2<Double>,source: SIMD2<Double>,listener: SIMD2<Double>) -> Double {
        clamp((343+simd_dot(listener,ray))/(343+simd_dot(source,ray)),0.78,1.23)
    }
}

/// Only the render thread advances playback cursors and acoustic envelopes.
private final class MotorVoice {
    let controls = OSAllocatedUnfairLock(initialState: MotorControls())
    static let sampleRate = 44100.0
    private let porscheBank: RecordingBank
    private let centenarioBank: RecordingBank

    private func bank(for kind: VehicleKind) -> RecordingBank {
        kind == .porsche ? porscheBank : centenarioBank
    }
    private let player = DriveVoice(startPhase:0)
    private let tyre: RecordedLoop
    private let rollingTyre: RecordedLoop
    private let wetAsphalt: RecordedLoop?
    private let lightContact: ContactClip?
    private let firmContact: ContactClip?
    private var wetCursor = 0.0
    private var rollingCursor = 0.0
    private var tyreCursors = SIMD4<Double>.zero
    private var targets = MotorControls()
    private var gain = 0.0
    private var filtered = 0.0
    private var filteredSeat = 0.0
    private var cabinCoupling = 0.0
    private var motorChannels = SIMD2<Double>(repeating:1)
    private var roadGain = 1.0
    private var filteredSide = 0.0
    private var kerbPan = 0.0
    private var scrubPans = SIMD4<Double>.zero
    private var absLevel = 0.0
    private var roadLevel = 0.0
    private var roadPhase = 0.0
    private var roadNoise = 0.0
    private var roadRandom: UInt32 = 0xa523e531
    private var rollingLevel = 0.0
    private var windLevel = 0.0
    private var windNoise = 0.0
    private var filteredRoad = 0.0
    private var scrubLevels = SIMD4<Double>.zero
    private var scrubTones = SIMD4<Double>.zero
    private var scrubSlides = SIMD4<Double>.zero
    private var scrubRates = SIMD4<Double>(repeating: 1)
    private var sprayLevel = 0.0
    private var sprayPan = 0.0
    private var sprayNoise = 0.0
    private var kind = VehicleKind.porsche
    private let traffic = [TrafficVoice(enginePhase:0.40,surfacePhase:0.19),
                           TrafficVoice(enginePhase:0.60,surfacePhase:0.47),
                           TrafficVoice(enginePhase:0.76,surfacePhase:0.79)]
    private var filteredRivalSurface = SIMD2<Double>.zero
    private var previousSignal = 0
    private var master = 1.0
    private var motorGain = 1.0
    private var effectsGain = 1.0
    private var signalRemaining = 0.0
    private var signalPhase = 0.0
    private var signalFrequency = 0.0
    private var raceCue: RaceCuePlayback?
    private var replacementCue: RaceAudioCue?
    private var contact: ContactPlayback?
    private var replacementContact: ContactPlayback?

    private struct Layer {
        let clip: RecordedLoop
        let referenceRPM: Double
        var trim = 1.0
    }

    private struct RecordingBand {
        let rpm: Double
        let open: Layer
        let closed: Layer?
    }

    private struct RecordingBank {
        let bands: [RecordingBand]
    }

    private struct BandCursor {
        var open = 0.0, closed = 0.0

        mutating func sample(_ band: RecordingBand, rpm: Double, opening: Double) -> Double {
            let on = band.open.clip.next(&open,rate:rpm/band.open.referenceRPM) * band.open.trim
            guard let coast = band.closed else { return on }
            let off = coast.clip.next(&closed,rate:rpm/coast.referenceRPM) * coast.trim
            return on*sqrt(opening) + off*sqrt(1-opening)
        }
    }

    private struct DriveInput {
        let kind: VehicleKind
        let powertrain: PowertrainSound
        let throttle: Double
        let ignition: Double
        let doppler: Double
    }

    private struct DriveFrame {
        var airborne: Double
        var mounts: Double
    }

    private final class DriveVoice {
        private let startPhase: Double
        private var kind: VehicleKind?
        private var cursors = [BandCursor](repeating:BandCursor(),count:3)
        private var rpm = 0.0
        private var riseRPMPerSecond = 0.0
        private var charge = 0.0
        private var fired = 0.0
        private var work = 0.0
        private var overrun = 0.0
        private var body = 0.0
        private var mountDC = 0.0
        private var transmittedTorque = 0.0
        private var shiftConnection = 1.0
        private var doppler = 1.0

        init(startPhase: Double) { self.startPhase = startPhase }

        func sample(_ input: DriveInput, bank: RecordingBank) -> DriveFrame {
            let shaft = input.powertrain
            if kind != input.kind {
                kind = input.kind
                // Identical cars can idle at the same RPM while their crankshafts remain independent.
                for i in cursors.indices {
                    let band = bank.bands[i]
                    cursors[i] = BandCursor(open:startPhase*Double(band.open.clip.length),
                                            closed:startPhase*Double(band.closed?.clip.length ?? 0))
                }
                rpm = shaft.shaftRPM
                riseRPMPerSecond = 0
                charge = input.throttle
                fired = input.ignition
                work = shaft.driveLoad
                overrun = shaft.overrun
                doppler = input.doppler
                shiftConnection = shaft.shiftEngagement
                transmittedTorque = work - overrun*0.25
                body = 0
                mountDC = 0
            }
            // 8 ms shaft interpolation. Its slope distinguishes a free blip
            // doing flywheel work from an unloaded engine held at steady rpm.
            let rpmDelta = (shaft.shaftRPM-rpm)*0.0028
            rpm += rpmDelta
            riseRPMPerSecond += (rpmDelta*MotorVoice.sampleRate-riseRPMPerSecond)*0.00075
            doppler += (input.doppler-doppler)*0.0014
            charge += (input.throttle-charge)*(input.throttle > charge ? 0.0019 : 0.00075)
            fired += (input.ignition-fired)*0.006
            shiftConnection += (shaft.shiftEngagement-shiftConnection)*0.009
            work += (shaft.driveLoad-work)*(shaft.driveLoad < work ? 0.005 : 0.0017)
            overrun += (shaft.overrun-overrun)*(shaft.overrun > overrun ? 0.0014 : 0.0028)
            let heardRPM = max(0,rpm*doppler)
            let speed = clamp((rpm-900)/6000,0,1)
            let rising = clamp(riseRPMPerSecond/7500,0,1)
            // Fill and empty the intake separately from the torque at the wheels.
            // The gearbox interrupts the loaded sound even while the pedal is held.
            let unloaded = charge*fired*(0.13 + 0.14*speed + 0.37*rising)
            let pressure = max(work,unloaded*(shaft.inGear ? 0.20+0.55*shiftConnection : 1))
            let opening = clamp((0.85*pressure + 0.15*charge*fired)*(1-0.65*overrun),0,1)
            var lower = 0
            while lower+1 < bank.bands.count && rpm >= bank.bands[lower+1].rpm { lower += 1 }
            let lowBand = bank.bands[lower]
            var note = cursors[lower].sample(lowBand,rpm:heardRPM,opening:opening)
            if lower+1 < bank.bands.count && rpm > lowBand.rpm {
                let upper = lower+1
                let highBand = bank.bands[upper]
                let t = clamp((rpm-lowBand.rpm)/(highBand.rpm-lowBand.rpm),0,1)
                // Smooth weights and unit summed power for unrelated recordings.
                let blend = t*t*(3-2*t)
                let high = cursors[upper].sample(highBand,rpm:heardRPM,opening:opening)
                note = note*sqrt(1-blend) + high*sqrt(blend)
            }
            // Exhaust pulses lose upper harmonics as cylinder charge falls.
            // During overrun the wheels still drive the rotating engine. Keep
            // a darker pumping/mechanical component through the ignition cut.
            body += (note-body)*0.064
            mountDC += (body-mountDC)*0.008
            let signedTorque = work - 0.25*overrun
            transmittedTorque += (signedTorque-transmittedTorque)*0.00048
            // The mounts load as the driveline takes up torque on either
            // side. During a coast downshift the brief release unloads them.
            let direction = signedTorque < 0 ? -1.0 : 1.0
            let takeUp = max(0,abs(signedTorque)-max(0,transmittedTorque*direction))
            let mechanical = 0.135 + 0.095*speed + 0.24*overrun
            let idle = 0.27*fired*clamp((1800-rpm)/850,0,1)
            let lowGain = mechanical + idle + 0.82*pressure
            let highGain = 0.048 + 0.07*speed + 0.10*overrun + 0.65*idle + 1.05*pressure
            return DriveFrame(airborne:body*lowGain + (note-body)*highGain,
                              mounts:(body-mountDC)*(0.11+0.22*work+0.25*overrun+0.42*takeUp))
        }
    }

    private struct TrafficMix {
        let input: DriveInput
        let bank: RecordingBank
        let left: Double
        let right: Double
        let wetContact: Double
        let wetRate: Double
        let tyres: DistantTyres
        let tyreChannels: SIMD2<Double>
    }

    private final class TrafficVoice {
        private let drive: DriveVoice
        private var activeMix: TrafficMix?
        private var targetLeft = 0.0, targetRight = 0.0
        private var left = 0.0, right = 0.0
        private var targetWet = 0.0, wet = 0.0
        private var scrubChannels = SIMD2<Double>.zero
        private var targetScrub = SIMD2<Double>.zero
        private var scrubFilter = 0.0
        private var scrubCursor: Double?
        private var wetCursor: Double?
        private let surfacePhase: Double

        init(enginePhase: Double,surfacePhase: Double) {
            self.surfacePhase = surfacePhase
            drive = DriveVoice(startPhase:enginePhase)
        }

        func set(_ mix: TrafficMix?) {
            targetLeft = mix?.left ?? 0
            targetRight = mix?.right ?? 0
            targetWet = mix?.wetContact ?? 0
            targetScrub = mix.map { $0.tyreChannels * $0.tyres.level } ?? .zero
            if let mix { activeMix = mix }
        }

        func tick(wetRecording: RecordedLoop?,tyreRecording: RecordedLoop?) -> (left: Double,right: Double,surface: SIMD2<Double>) {
            left += (targetLeft-left)*0.00075
            right += (targetRight-right)*0.00075
            if targetWet > 0 || wet > 0.00005 { wet += (targetWet-wet)*0.0008 }
            else { wet = 0 }
            scrubChannels += (targetScrub-scrubChannels)*0.0012
            guard let mix = activeMix, max(left,right,scrubChannels.max()) > 0.00001 else { return (0,0,.zero) }
            let note = drive.sample(mix.input,bank:mix.bank).airborne
            var surface = SIMD2<Double>.zero
            if wet > 0.00005, let wetRecording {
                var position = wetCursor ?? surfacePhase*Double(wetRecording.length)
                let water = 0.62*wet*wetRecording.next(&position,rate:mix.wetRate)
                wetCursor = position
                surface = SIMD2(left,right)*water
            }
            if scrubChannels.max() > 0.00001, let tyreRecording {
                var position = scrubCursor ?? (1-surfacePhase)*Double(tyreRecording.length)
                let tread = tyreRecording.next(&position,rate:mix.tyres.rate*mix.input.doppler)
                scrubCursor = position
                scrubFilter += (tread-scrubFilter)*(0.054+0.46*mix.tyres.slide)
                surface += scrubChannels * (scrubFilter*(0.34+0.32*mix.tyres.slide))
            }
            return (note*left,note*right,surface)
        }
    }

    private struct RecordedLoop {
        private let bands: [[Float]]
        var length: Int { bands[0].count }

        init(url: URL) throws {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.sampleRate == MotorVoice.sampleRate, file.length > 4096,
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
            let waveform = mono.map { $0 - mean }
            let loop = Self.joinEnds(waveform)
            let half = Self.decimate(loop)
            let quarter = Self.decimate(half)
            bands = [loop, half, quarter, Self.decimate(quarter)]
        }

        // Align the two ends before overlapping them. A fixed cut can cancel a firing
        // harmonic for a few milliseconds every time a driver holds steady RPM.
        private static func joinEnds(_ wave: [Float]) -> [Float] {
            let overlap = 1320
            let latestEnd = wave.count - wave.count % 8
            let search = min(2048, latestEnd / 5)
            var end = latestEnd
            var best = -Double.infinity
            for candidate in stride(from:latestEnd, through:latestEnd-search, by:-8) {
                var cross = 0.0, headPower = 0.0, tailPower = 0.0
                for i in stride(from:0, to:overlap, by:4) {
                    let a = Double(wave[candidate-overlap+i]), b = Double(wave[i])
                    cross += a*b
                    tailPower += a*a
                    headPower += b*b
                }
                let agreement = 2*cross / max(headPower+tailPower,1e-12)
                if agreement > best { end = candidate; best = agreement }
            }
            var joined = Array(wave[overlap..<end-overlap])
            for i in 0..<overlap {
                let t = Double(i) / Double(overlap-1)
                let blend = t*t*(3-2*t)
                let normalization = sqrt(1-2*blend*(1-blend)*(1-clamp(best,0,1)))
                let tail = Double(wave[end-overlap+i]), head = Double(wave[i])
                joined.append(Float((tail*(1-blend)+head*blend)/normalization))
            }
            return joined
        }

        // Half-band FIR, built once per level outside the audio render callback.
        private static func decimate(_ input: [Float]) -> [Float] {
            let radius = 15
            let taps: [Double] = (-radius...radius).map { offset in
                let x = Double(offset)
                let sinc = offset == 0 ? 0.5 : sin(.pi*x*0.5)/(.pi*x)
                return sinc * (0.5+0.5*cos(.pi*x/Double(radius)))
            }
            let sum = taps.reduce(0,+)
            return (0..<input.count/2).map { i in
                var value = 0.0
                for (j,tap) in taps.enumerated() {
                    let index = (2*i+j-radius+input.count) % input.count
                    value += Double(input[index])*tap
                }
                return Float(value/sum)
            }
        }

        func next(_ cursor: inout Double, rate: Double) -> Double {
            func sample(_ band: Int) -> Double {
                let wave = bands[band]
                let position = cursor / Double(1 << band)
                let index = Int(position)
                let next = index+1 == wave.count ? 0 : index+1
                return Double(wave[index] + (wave[next]-wave[index])*Float(position-Double(index)))
            }
            let band = rate >= 4 ? 2 : (rate >= 2 ? 1 : 0)
            let blend = clamp(rate/Double(1 << band)-1,0,1)
            let lo = sample(band)
            let value = blend > 0 ? lo + (sample(band+1)-lo)*blend : lo
            cursor += rate
            if cursor >= Double(bands[0].count) { cursor -= Double(bands[0].count) }
            return value
        }
    }

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        func layer(_ filename: String, _ rpm: Double, trim: Double = 1) throws -> Layer {
            try Layer(clip:RecordedLoop(url:directory.appendingPathComponent(filename + ".wav")),referenceRPM:rpm,trim:trim)
        }
        func band(_ filename: String, _ rpm: Double, trim: Double = 1) throws -> RecordingBand {
            try RecordingBand(rpm:rpm,open:layer(filename,rpm,trim:trim),closed:nil)
        }
        func paired(_ family: String, _ rpm: Int) throws -> RecordingBand {
            let speed = Double(rpm)
            return try RecordingBand(rpm:speed,open:layer("\(family)-on-\(rpm)",speed),
                                     closed:layer("\(family)-off-\(rpm)",speed))
        }
        porscheBank = try RecordingBank(bands:[band("flat-six",1860),paired("gt3rs",3000),paired("gt3rs",6000)])
        centenarioBank = try RecordingBank(bands:[band("v12",1430),paired("svj",3000),paired("svj",6000)])
        tyre = try RecordedLoop(url:directory.appendingPathComponent("tyre-skid.wav"))
        rollingTyre = try RecordedLoop(url:directory.appendingPathComponent("road-roll.wav"))
        let wetURL = directory.appendingPathComponent("road-wet.wav")
        wetAsphalt = FileManager.default.fileExists(atPath:wetURL.path) ? try? RecordedLoop(url:wetURL) : nil
        lightContact = ContactClip(url:directory.appendingPathComponent("body-contact-light.wav"))
        firmContact = ContactClip(url:directory.appendingPathComponent("body-contact-firm.wav"))
        tyreCursors = SIMD4(0.0,0.27,0.54,0.78) * Double(tyre.length)
    }

    private func receiveCue(_ pending: RaceAudioCue?, cancel: Bool) {
        if cancel {
            raceCue?.shouldFade = true
            replacementCue = nil
        }
        guard let pending else { return }
        if let current = raceCue {
            if let replacementCue, replacementCue.priority >= pending.priority { return }
            guard current.shouldFade || current.cue.priority < pending.priority else { return }
            replacementCue = pending
            raceCue?.shouldFade = true
        } else {
            raceCue = RaceCuePlayback(pending)
        }
    }

    private func nextCueSample() -> Double {
        guard var playback = raceCue else { return 0 }
        let value = playback.nextSample()
        if playback.isFinished {
            raceCue = replacementCue.map(RaceCuePlayback.init)
            replacementCue = nil
        } else {
            raceCue = playback
        }
        return value * effectsGain
    }

    private func receiveContact(_ pending: PositionedContact?,cancel: Bool) {
        if cancel {
            contact?.fading = true
            replacementContact = nil
        }
        guard let pending else { return }
        let clip = pending.firm ? (firmContact ?? lightContact) : (lightContact ?? firmContact)
        guard let clip else { return }
        if let current = contact {
            guard current.fading || current.pastAttack || pending.level > current.level*1.12 else { return }
            if let replacementContact, replacementContact.level > pending.level { return }
            replacementContact = ContactPlayback(pending,clip:clip)
            contact?.fading = true
        } else {
            contact = ContactPlayback(pending,clip:clip)
        }
    }

    private func addingContact(to base: SIMD2<Double>) -> SIMD2<Double> {
        guard var playback = contact else { return base }
        let sample = playback.nextSample()*clamp(effectsGain,0,1)
        if playback.finished {
            contact = replacementContact
            replacementContact = nil
        } else {
            contact = playback
        }
        let ceiling = 0.75*master
        return base+sample*SIMD2(ceiling-abs(base.x),ceiling-abs(base.y))
    }

    private func advanceSharedVolumes() {
        master += (targets.masterVolume - master) * 0.0015
        effectsGain += (targets.effectsVolume - effectsGain) * 0.0015
    }

    func render(left output: UnsafeMutablePointer<Float>, right rightOutput: UnsafeMutablePointer<Float>, count: Int) {
        if let latest = controls.withLockIfAvailable({ state in
            let latest = state
            state.pendingCue = nil
            state.cancelCue = false
            state.pendingContact = nil
            state.cancelContact = false
            return latest
        }) {
            targets = latest
            receiveCue(latest.pendingCue, cancel: latest.cancelCue)
            let canPlayContact = latest.audible && latest.masterVolume > 0 && latest.effectsVolume > 0
            receiveContact(canPlayContact ? latest.pendingContact : nil,cancel:latest.cancelContact || !canPlayContact)
        }
        if targets.raceSignal != previousSignal {
            previousSignal = targets.raceSignal
            signalRemaining = previousSignal == 0 ? 0 : (previousSignal == 4 ? 0.29 : 0.12)
            signalFrequency = previousSignal == 4 ? 1150 : 780
            signalPhase = 0
        }
        if kind != targets.kind {
            filtered = 0
            filteredSeat = 0
            gain = 0
            kind = targets.kind
        }
        let level = targets.audible ? 1.0 : 0.0
        if level == 0 && gain < 0.00001 {
            // A result overlay pauses the world. This path can finish a cue
            // without stepping the motors, roads or traffic under the overlay.
            if raceCue != nil || contact != nil {
                for frame in 0..<count {
                    advanceSharedVolumes()
                    let sample = addingContact(to:SIMD2(repeating:0.75 * master * nextCueSample()))
                    output[frame] = Float(sample.x)
                    rightOutput[frame] = Float(sample.y)
                }
            } else {
                master = targets.masterVolume
                effectsGain = targets.effectsVolume
                output.update(repeating: 0,count: count)
                rightOutput.update(repeating:0,count:count)
            }
            return
        }
        let rate = Self.sampleRate
        let cabinTarget = targets.cockpit ? 1.0 : 0.0
        let airOpen = 1 - exp(-2 * .pi * 6900 / rate)
        let airCabin = 1 - exp(-2 * .pi * 2450 / rate)
        let seatFilter = 1 - exp(-2 * .pi * (230 + 100*(2.6-kind.wheelbase)) / rate)
        let roadFilter = 1 - exp(-2 * .pi * (targets.cockpit ? 2450.0 : 5900.0) / rate)
        let doppler = targets.perspective.sourceDoppler
        let kerbStep = targets.roadSpeed * doppler * 7 / (2 * .pi * rate) // kerbElevation uses sin(progress * 7)
        let rollingRate = clamp(0.72 + targets.roadSpeed*0.013,0.72,1.45)*doppler
        let sprayRate = clamp(0.84+targets.roadSpeed*0.009,0.84,1.40)*doppler
        traffic[0].set(opponentParameters(targets.opponents.0))
        traffic[1].set(opponentParameters(targets.opponents.1))
        traffic[2].set(opponentParameters(targets.opponents.2))
        let powertrain = DriveInput(kind:kind,powertrain:targets.powertrain,throttle:targets.throttle,
                                    ignition:targets.ignition,doppler:targets.perspective.sourceDoppler)
        let bank = bank(for:kind)
        for frame in 0..<count {
            gain += (level - gain) * 0.003
            let motor = player.sample(powertrain,bank:bank)
            roadRandom = roadRandom &* 1664525 &+ 1013904223
            let texture = Double(roadRandom) * (2.0 / Double(UInt32.max)) - 1
            roadLevel += (targets.kerb - roadLevel) * 0.001
            roadPhase += kerbStep
            roadPhase -= floor(roadPhase)
            roadNoise += (texture - roadNoise) * 0.035
            let rib = sin(roadPhase * 2 * .pi)
            let road = roadLevel * (roadNoise * (0.65+0.32*rib) + 0.055*rib)
            rollingLevel += (targets.rolling - rollingLevel) * 0.00055
            let rolling = rollingTyre.next(&rollingCursor,rate:rollingRate) * rollingLevel * 0.22
            windLevel += (targets.wind-windLevel)*0.00025
            windNoise += (roadNoise-windNoise)*0.012
            let wind = windLevel * (roadNoise-windNoise) * (targets.cockpit ? 0.12 : 0.23)
            scrubSlides += (targets.tyres.slide - scrubSlides) * 0.0013
            scrubRates += (targets.tyres.rate*doppler - scrubRates) * 0.0013
            scrubPans += (targets.tyres.pan - scrubPans) * 0.0014
            var scrub = 0.0, scrubSide = 0.0
            for i in 0..<4 {
                let change = targets.tyres.level[i] - scrubLevels[i]
                scrubLevels[i] += change * (change > 0 ? 0.0020 : 0.00085)
                guard scrubLevels[i] > 0.00005 else { continue }
                let recording = tyre.next(&tyreCursors[i],rate:scrubRates[i])
                let slide = scrubSlides[i]
                scrubTones[i] += (recording-scrubTones[i]) * (0.054 + 0.46*slide)
                let sample = scrubLevels[i] * (0.34 + 0.32*slide) * scrubTones[i]
                scrub += sample
                scrubSide += sample * scrubPans[i]
            }
            sprayLevel += (targets.spray - sprayLevel) * 0.0008
            sprayPan += (targets.sprayPan - sprayPan) * 0.0008
            sprayNoise += (texture - sprayNoise) * 0.33
            let noise = sprayNoise-roadNoise
            let sprayTexture: Double
            if let wetAsphalt, sprayLevel > 0.00005 {
                sprayTexture = 0.58*wetAsphalt.next(&wetCursor,rate:sprayRate)+0.09*noise
            } else { sprayTexture = 0.34*noise }
            let water = sprayLevel*sprayTexture
            kerbPan += (targets.kerbPan-kerbPan)*0.0014
            let valveRate = targets.absModulation > absLevel ? 0.009 : 0.0024
            absLevel += (targets.absModulation-absLevel)*valveRate
            let absSound = absLevel*(0.085*roadNoise+0.073*(sprayNoise-roadNoise))
            let waterSide = water*sprayPan*(targets.cockpit ? 0.48 : 0.68)
            let side = (road*kerbPan*0.55 + scrubSide*0.5 + waterSide)*effectsGain
            filteredSide += (side-filteredSide)*roadFilter
            advanceSharedVolumes()
            motorGain += (targets.motorVolume-motorGain)*0.0015
            cabinCoupling += (cabinTarget-cabinCoupling)*0.0014
            filtered += (motor.airborne*motorGain-filtered)*(airOpen+(airCabin-airOpen)*cabinCoupling)
            filteredSeat += (motor.mounts*motorGain-filteredSeat)*seatFilter
            let surfaceMix = (road + rolling + wind + scrub + water + absSound)*effectsGain
            filteredRoad += (surfaceMix-filteredRoad)*roadFilter
            let wetRecording = effectsGain > 1e-6 ? wetAsphalt : nil
            let tyreRecording = effectsGain > 1e-6 ? tyre : nil
            let a = traffic[0].tick(wetRecording:wetRecording,tyreRecording:tyreRecording)
            let b = traffic[1].tick(wetRecording:wetRecording,tyreRecording:tyreRecording)
            let c = traffic[2].tick(wetRecording:wetRecording,tyreRecording:tyreRecording)
            let rivalSurface = a.surface+b.surface+c.surface
            if rivalSurface != .zero || filteredRivalSurface != .zero {
                filteredRivalSurface += (rivalSurface-filteredRivalSurface)*roadFilter
                if rivalSurface == .zero && max(abs(filteredRivalSurface.x),abs(filteredRivalSurface.y)) < 1e-8 {
                    filteredRivalSurface = .zero
                }
            }
            var signal = 0.0
            if signalRemaining > 0 {
                let duration = previousSignal == 4 ? 0.29 : 0.12
                let envelope = min(1,(duration-signalRemaining)*230,signalRemaining*22)
                signal = sin(signalPhase) * envelope * 0.30
                signalPhase += signalFrequency*2 * .pi/rate
                signalRemaining = max(0,signalRemaining-1/rate)
            }
            motorChannels += (targets.perspective.motorChannels-motorChannels)*0.0014
            roadGain += (targets.perspective.roadGain-roadGain)*0.0014
            let seat = filteredSeat*cabinCoupling
            let left = filtered*motorChannels.x + seat + (filteredRoad-filteredSide)*roadGain
            let right = filtered*motorChannels.y + seat + (filteredRoad+filteredSide)*roadGain
            let worldLeft = 0.75 * gain * master * tanh((left+(a.left+b.left+c.left)*motorGain+(signal+filteredRivalSurface.x)*effectsGain) * 1.4)
            let worldRight = 0.75 * gain * master * tanh((right+(a.right+b.right+c.right)*motorGain+(signal+filteredRivalSurface.y)*effectsGain) * 1.4)
            let cue = nextCueSample()
            // Preserve the existing vehicle mix and fit the centered cue into
            // the remaining headroom independently on each channel.
            let base = SIMD2(worldLeft + cue * (0.75 * master - abs(worldLeft)),
                             worldRight + cue * (0.75 * master - abs(worldRight)))
            let sample = addingContact(to:base)
            output[frame] = Float(sample.x)
            rightOutput[frame] = Float(sample.y)
        }
    }

    private func opponentParameters(_ source: OpponentMotor?) -> TrafficMix? {
        guard let source else { return nil }
        let state = source.powertrain
        let input = DriveInput(kind:source.kind,powertrain:state,throttle:source.throttle,
                               ignition:source.ignition,doppler:source.doppler)
        let gain = source.volume * (targets.cockpit ? 0.76 : 1)
        return TrafficMix(input:input,bank:bank(for:source.kind),
                          left:gain*sqrt(0.5*(1-source.pan)),right:gain*sqrt(0.5*(1+source.pan)),
                          wetContact:clamp(source.wetContact,0,1),
                          wetRate:clamp(0.84+source.tyreSpeed*0.009,0.84,1.40)*source.doppler,
                          tyres:source.tyres,tyreChannels:source.tyreChannels*(targets.cockpit ? 0.76 : 1))
    }

}

final class EngineSound {
    let engine = AVAudioEngine()
    private let voice: MotorVoice?
    private var nextStartAttempt = 0.0
    var muted = false {
        didSet {
            if muted {
                cancelCue()
                cancelContact()
            }
        }
    }
    var masterVolume = 1.0 { didSet { publishCueVolumes() } }
    var motorVolume = 1.0
    var effectsVolume = 1.0 { didSet { publishCueVolumes() } }
    private(set) var errorMessage: String?

    init(recordingURL: URL? = nil) {
        let url = recordingURL ?? Bundle.main.resourceURL!.appendingPathComponent("Assets/Audio/flat-six.wav")
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

    /// Call on live transitions. A cue never starts the engine or queues for a
    /// later session. Lower priority and duplicate in-flight requests coalesce.
    func playCue(_ cue: RaceAudioCue) {
        guard !muted, masterVolume > 0, effectsVolume > 0, engine.isRunning else { return }
        voice?.controls.withLock { state in
            if let current = state.pendingCue, current.priority >= cue.priority { return }
            state.pendingCue = cue
        }
    }

    /// Clear pending cues and release an active cue when leaving live play.
    func cancelCue() {
        voice?.controls.withLock { state in
            state.pendingCue = nil
            state.cancelCue = true
        }
    }

    func playContact(_ sound: ContactSound,listenerPosition: SIMD2<Double>,
                     listenerRight: SIMD2<Double>,cockpit: Bool) {
        guard !muted,masterVolume > 0,effectsVolume > 0,engine.isRunning,
              let request = PositionedContact(sound,listenerPosition:listenerPosition,
                                              listenerRight:listenerRight,cockpit:cockpit) else { return }
        voice?.controls.withLock { state in
            guard state.audible else { return }
            if let latest = state.pendingContact,latest.level > request.level { return }
            state.pendingContact = request
        }
    }

    func cancelContact() {
        voice?.controls.withLock {
            $0.pendingContact = nil
            $0.cancelContact = true
        }
    }

    func pausePlayback() {
        voice?.controls.withLock {
            $0.audible = false
            $0.raceSignal = 0
            $0.pendingContact = nil
            $0.cancelContact = true
        }
    }

    private func publishCueVolumes() {
        voice?.controls.withLock { state in
            state.masterVolume = masterVolume
            state.effectsVolume = effectsVolume
            if masterVolume <= 0 || effectsVolume <= 0 {
                state.pendingCue = nil
                state.cancelCue = true
                state.pendingContact = nil
                state.cancelContact = true
            }
        }
    }

    func update(rpm: Double, throttle: Double, ignition: Double = 1, powertrain: PowertrainSound? = nil,
                perspective: VehicleSoundPerspective = VehicleSoundPerspective(), cockpit: Bool = true, kerb: Double = 0,
                roadSpeed: Double = 0, tyreScrub: Double = 0, roadSound: RoadSound? = nil,
                spray: Double = 0, kind: VehicleKind = .porsche,
                opponents: [OpponentMotor] = [], raceSignal: Int = 0, paused: Bool) {
        guard let voice else { return }
        let audible = !paused && !muted
        let measured = powertrain ?? PowertrainSound(driveLoad:throttle*ignition,overrun:0,shaftRPM:rpm,inGear:roadSpeed > 0)
        let state = PowertrainSound(driveLoad:clamp(measured.driveLoad,0,1),overrun:clamp(measured.overrun,0,1),
                                    shaftRPM:max(0,measured.shaftRPM),inGear:measured.inGear,
                                    shiftEngagement:clamp(measured.shiftEngagement,0,1),
                                    regeneration:clamp(measured.regeneration,0,1))
        let rivals = (opponents.first,opponents.count > 1 ? opponents[1] : nil,opponents.count > 2 ? opponents[2] : nil)
        let positionedSpray = roadSound?.spray
        voice.controls.withLock {
            $0 = MotorControls(throttle: clamp(throttle, 0, 1),
                               ignition: clamp(ignition, 0, 1), powertrain:state, perspective:perspective, cockpit: cockpit, audible: audible,
                               kerb: clamp(kerb, 0, 1), roadSpeed: clamp(roadSpeed, 0, 100),
                               rolling:clamp(roadSound?.rolling ?? 0,0,1.35),wind:clamp(roadSound?.wind ?? 0,0,1),
                               tyres:roadSound?.tyres ?? RoadSound(tyreScrub:tyreScrub).tyres,
                               kerbPan:clamp(roadSound?.kerbPan ?? 0,-1,1),
                               absModulation:clamp(roadSound?.absModulation ?? 0,0,1),
                               spray:clamp(positionedSpray?.level ?? spray,0,1),
                               sprayPan:clamp(positionedSpray?.pan ?? 0,-1,1),kind:kind,opponents:rivals,
                               raceSignal:audible ? clamp(raceSignal,0,4) : 0,motorVolume:motorVolume,
                               effectsVolume:effectsVolume,masterVolume:masterVolume,
                               pendingCue:$0.pendingCue,cancelCue:$0.cancelCue,
                               pendingContact:audible ? $0.pendingContact : nil,
                               cancelContact:!audible || $0.cancelContact)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if audible && !engine.isRunning && now >= nextStartAttempt {
            nextStartAttempt = now + 2
            cancelCue()
            cancelContact()
            do { try engine.start(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

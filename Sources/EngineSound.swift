import AVFoundation
import os
import simd

struct MotorControls {
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
    var kind = VehicleKind.concept
    var opponents: (OpponentMotor?,OpponentMotor?,OpponentMotor?) = (nil,nil,nil)
    var raceSignal = 0
    var motorVolume = 1.0
    var effectsVolume = 1.0
    var masterVolume = 1.0
}

/// Approximate acoustic centres in vehicle-local metres (+Z towards the nose).
/// The cabin admits reflected sound on both sides. Outside, sound pressure
/// falls with distance from a source of finite size.
struct VehicleSoundPerspective {
    var motorChannels = SIMD2<Double>(repeating:1)
    var roadGain = 1.0

    init() {}

    init(kind: VehicleKind, localEar: SIMD3<Double>, localRight: SIMD3<Double>, cockpit: Bool) {
        let engineZ: Double
        switch kind {
        case .mazda, .bmw: engineZ = kind.frontAxle * 0.8
        case .porsche: engineZ = kind.frontAxle - kind.wheelbase - 0.25
        case .honda: engineZ = kind.frontAxle - kind.wheelbase
        case .ferrari, .centenario, .lotus, .concept: engineZ = (kind.frontAxle - kind.wheelbase) * 0.7
        }
        let offset = SIMD3(0,0.52,engineZ) - localEar
        let distance = simd_length(offset)
        let pan = clamp(simd_dot(offset,localRight)/max(0.7,distance),-1,1) * (cockpit ? 0.35 : 0.85)
        let gain = cockpit ? 1 : 1.25 / sqrt(1 + distance*distance/9)
        motorChannels = SIMD2(sqrt(1-pan),sqrt(1+pan)) * gain
        if !cockpit { roadGain = 1 / sqrt(1 + simd_length_squared(localEar)/16) }
    }
}

/// Four independent playback targets in wheel order (FR, FL, RR, RL).
struct TyreSound {
    var level = SIMD4<Double>.zero
    var slide = SIMD4<Double>.zero
    var rate = SIMD4<Double>(repeating: 1)
    var pan = SIMD4<Double>.zero
}

struct RoadSound {
    var rolling = 0.0
    var wind = 0.0
    var kerbPan = 0.0
    var tyres = TyreSound()
    var tyreScrub: Double { (tyres.level * tyres.level).sum().squareRoot() }
    var scrubPan: Double {
        let power = tyres.level * tyres.level
        return (tyres.pan * power).sum() / max(0.000001, power.sum())
    }
    var absModulation = 0.0

    init(kerbPan: Double = 0,tyreScrub: Double = 0,scrubPan: Double = 0,absModulation: Double = 0) {
        self.kerbPan = kerbPan
        tyres.level[0] = clamp(tyreScrub,0,1)
        tyres.slide[0] = tyres.level[0]
        tyres.pan[0] = clamp(scrubPan,-1,1)
        self.absModulation = absModulation
    }

    init(vehicle: Vehicle, listenerPosition: SIMD2<Double>? = nil, listenerRight: SIMD2<Double>? = nil) {
        var pavedPower = SIMD4<Double>.zero
        var dryLevel = SIMD4<Double>.zero
        var kerbEnergy = 0.0, kerbMoment = 0.0
        let points = listenerPosition != nil && listenerRight != nil ? vehicle.contactPoints : []
        let quarterWeight = vehicle.mass * 9.81 / 4
        let speed = vehicle.speed
        wind = clamp(speed*speed / (55*55),0,1)
        for (index,wheel) in vehicle.wheels.enumerated() {
            let weight = clamp(wheel.normalLoad / quarterWeight,0,1.5)
            let pavement = wheel.pavedContactFraction
            rolling += weight * (0.20 + 0.80 * pavement) * clamp(wheel.rollingContactSpeed/38,0,1.35) / 4
            pavedPower[index] = wheel.slidingPower * pavement
            dryLevel[index] = 1 / (1 + 3.5 * wheel.waterFilm)
            let slip = wheel.contactSlipSpeed
            tyres.slide[index] = wheel.slidingFraction * slip / (slip + 1.4) * dryLevel[index]
            tyres.rate[index] = 0.86 + 0.28 * slip / (slip + 5)
            tyres.pan[index] = index.isMultiple(of:2) ? 1 : -1
            if let ear = listenerPosition, let right = listenerRight {
                let offset = points[index]-ear
                let pan = clamp((offset.x*right.x + offset.y*right.y)/max(1,hypot(offset.x,offset.y)),-1,1)
                let kerbPower = wheel.kerbFeedback * wheel.kerbFeedback
                kerbEnergy += kerbPower
                kerbMoment += pan * kerbPower
                tyres.pan[index] = pan
            }
        }
        let leftKerb = max(vehicle.wheels[1].kerbFeedback,vehicle.wheels[3].kerbFeedback)
        let rightKerb = max(vehicle.wheels[0].kerbFeedback,vehicle.wheels[2].kerbFeedback)
        kerbPan = (rightKerb-leftKerb)/max(0.06,rightKerb+leftKerb)
        // Convert the share of mechanical power at each contact to an audio
        // amplitude. A shared headroom term keeps a four-wheel lock bounded.
        let referencePower = 16_000.0 // W, mix calibration
        let total = referencePower + pavedPower.sum()
        for index in 0..<4 { tyres.level[index] = sqrt(pavedPower[index] / total) * dryLevel[index] }
        if !points.isEmpty {
            kerbPan = kerbMoment/max(0.000001,kerbEnergy)
        }
        absModulation = vehicle.absActive && vehicle.brakeLinePressure > 0.06 ? vehicle.absRelease : 0
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

    static func relative(to player: Vehicle, opponent: Vehicle, listenerRight: SIMD2<Double>,
                         listenerPosition: SIMD2<Double>? = nil) -> Self {
        let offset = opponent.position - (listenerPosition ?? player.position)
        let distance = hypot(offset.x,offset.y)
        let ray = offset / max(distance,1)
        let right = ray.x*listenerRight.x + ray.y*listenerRight.y
        let playerAlong = player.velocity.x*ray.x + player.velocity.y*ray.y
        let sourceAlong = opponent.velocity.x*ray.x + opponent.velocity.y*ray.y
        let range = clamp(1-distance/82,0,1)
        return OpponentMotor(volume:range*range*0.24/(1+distance/18),
                             pan:clamp(right,-1,1),doppler:clamp((343+playerAlong)/(343+sourceAlong),0.78,1.23),
                             kind:opponent.kind,powertrain:opponent.powertrainSound,
                             throttle:opponent.engineThrottle,ignition:opponent.ignitionFraction)
    }
}

/// Only the render thread advances playback cursors and acoustic envelopes.
private final class MotorVoice {
    let controls = OSAllocatedUnfairLock(initialState: MotorControls())
    static let sampleRate = 44100.0
    private let banks: [RecordingBank]
    private let player = DriveVoice()
    private let tyre: RecordedLoop
    private let rollingTyre: RecordedLoop
    private var rollingCursor = 0.0
    private var tyreCursors = SIMD4<Double>.zero
    private var targets = MotorControls()
    private var gain = 0.0
    private var filtered = 0.0
    private var motorChannels = SIMD2<Double>(repeating:1)
    private var roadGain = 1.0
    private var filteredSide = 0.0
    private var kerbPan = 0.0
    private var scrubPans = SIMD4<Double>.zero
    private var absLevel = 0.0
    private var absPhase = 0.0
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
    private var sprayNoise = 0.0
    private var kind = VehicleKind.concept
    private let traffic = (0..<3).map { _ in TrafficVoice() }
    private var previousSignal = 0
    private var master = 1.0
    private var motorGain = 1.0
    private var effectsGain = 1.0
    private var signalRemaining = 0.0
    private var signalPhase = 0.0
    private var signalFrequency = 0.0

    private struct Layer {
        let clip: RecordedLoop
        let referenceRPM: Double
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
            let on = band.open.clip.next(&open,rate:rpm/band.open.referenceRPM)
            guard let coast = band.closed else { return on }
            let off = coast.clip.next(&closed,rate:rpm/coast.referenceRPM)
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

    private final class DriveVoice {
        private var kind: VehicleKind?
        private var cursors = [BandCursor](repeating:BandCursor(),count:3)
        private var rpm = 0.0
        private var riseRPMPerSecond = 0.0
        private var throttle = 0.0
        private var fired = 0.0
        private var work = 0.0
        private var overrun = 0.0
        private var body = 0.0
        private var doppler = 1.0

        func sample(_ input: DriveInput, bank: RecordingBank) -> Double {
            let shaft = input.powertrain
            if kind != input.kind {
                kind = input.kind
                for i in cursors.indices { cursors[i] = BandCursor() }
                rpm = shaft.shaftRPM
                riseRPMPerSecond = 0
                throttle = input.throttle
                fired = input.ignition
                work = shaft.driveLoad
                overrun = shaft.overrun
                doppler = input.doppler
                body = 0
            }
            // 8 ms shaft interpolation. Its slope distinguishes a free blip
            // doing flywheel work from an unloaded engine held at steady rpm.
            let rpmDelta = (shaft.shaftRPM-rpm)*0.0028
            rpm += rpmDelta
            riseRPMPerSecond += (rpmDelta*MotorVoice.sampleRate-riseRPMPerSecond)*0.00075
            doppler += (input.doppler-doppler)*0.0014
            throttle += (input.throttle-throttle)*0.0010
            fired += (input.ignition-fired)*0.0035
            work += (shaft.driveLoad-work)*(shaft.driveLoad < work ? 0.0025 : 0.0010)
            overrun += (shaft.overrun-overrun)*0.0010
            let heardRPM = max(0,rpm*doppler)
            if input.kind == .honda {
                let drive = bank.bands[0].open
                let note = drive.clip.next(&cursors[0].open,rate:heardRPM/drive.referenceRPM)
                // A rotating, unloaded reduction gear is faint. Electrical
                // torque brightens the recording, including at low wheel speed.
                let spinning = clamp(rpm/680,0,1)
                body += (note-body)*0.085
                return spinning*(body*(0.12+0.55*work) + (note-body)*(0.05+0.84*work))
            }
            let speed = clamp((rpm-900)/6000,0,1)
            let rising = clamp(riseRPMPerSecond/7500,0,1)
            let freeRev = throttle*fired*(0.13 + 0.14*speed + 0.37*rising)
            // Transmitted driveLoad already includes ignition cut and traction control.
            let pressure = max(work,freeRev)
            let opening = clamp(0.82*pressure + 0.18*throttle*fired,0,1)
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
            let mechanical = 0.135 + 0.095*speed + 0.24*overrun
            let idle = 0.27*fired*clamp((1800-rpm)/850,0,1)
            let lowGain = mechanical + idle + 0.82*pressure
            let highGain = 0.048 + 0.07*speed + 0.10*overrun + 0.65*idle + 1.05*pressure
            return body*lowGain + (note-body)*highGain
        }
    }

    private struct TrafficMix {
        let input: DriveInput
        let bank: RecordingBank
        let left: Double
        let right: Double
    }

    private final class TrafficVoice {
        private let drive = DriveVoice()
        private var activeMix: TrafficMix?
        private var targetLeft = 0.0, targetRight = 0.0
        private var left = 0.0, right = 0.0

        func set(_ mix: TrafficMix?) {
            targetLeft = mix?.left ?? 0
            targetRight = mix?.right ?? 0
            if let mix { activeMix = mix }
        }

        func tick() -> (Double,Double) {
            left += (targetLeft-left)*0.00075
            right += (targetRight-right)*0.00075
            guard max(left,right) > 0.00001, let mix = activeMix else { return (0,0) }
            let note = drive.sample(mix.input,bank:mix.bank)
            return (note*left,note*right)
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
        func layer(_ filename: String, _ rpm: Double) throws -> Layer {
            try Layer(clip:RecordedLoop(url:directory.appendingPathComponent(filename + ".wav")),referenceRPM:rpm)
        }
        func band(_ filename: String, _ rpm: Double) throws -> RecordingBand {
            try RecordingBand(rpm:rpm,open:layer(filename,rpm),closed:nil)
        }
        func paired(_ family: String, _ rpm: Int) throws -> RecordingBand {
            let speed = Double(rpm)
            return try RecordingBand(rpm:speed,open:layer("\(family)-on-\(rpm)",speed),
                                     closed:layer("\(family)-off-\(rpm)",speed))
        }
        banks = try VehicleKind.allCases.map { kind in
            let bands: [RecordingBand]
            switch kind {
            case .concept:
                let quiet = try Layer(clip:RecordedLoop(url:url),referenceRPM:2610)
                bands = try [RecordingBand(rpm:2610,open:layer("inline-load",2750),closed:quiet)]
            case .mazda: bands = try [band("mx5-idle",1010),band("mx5-mid",2029),band("mx5-load",5354)]
            case .bmw: bands = try [band("e30-low",810),band("e30-exhaust",3796),band("e30-high",5007)]
            case .lotus: bands = try [band("elise-low",835),band("elise-exhaust",2322),band("elise-high",5966)]
            case .porsche: bands = try [band("flat-six",1860),paired("gt3rs",3000),paired("gt3rs",6000)]
            case .centenario: bands = try [band("v12",1430),paired("svj",3000),paired("svj",6000)]
            case .ferrari: bands = try [band("ferrari-exhaust",1560),band("ferrari-mid",3183),band("ferrari-high",6191)]
            case .honda:
                // The original EV excerpt used a 24 m/s reference. Express it
                // in simulated rotor RPM using this car's tyre and reduction.
                let motorRPM = 24/kind.radius*kind.finalDrive*60/(2 * .pi)
                bands = try [band("electric",motorRPM)]
            }
            return RecordingBank(bands:bands)
        }
        tyre = try RecordedLoop(url:directory.appendingPathComponent("tyre-skid.wav"))
        rollingTyre = try RecordedLoop(url:directory.appendingPathComponent("road-roll.wav"))
        tyreCursors = SIMD4(0.0,0.27,0.54,0.78) * Double(tyre.length)
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
            filtered = 0
            gain = 0
            kind = targets.kind
        }
        let level = targets.audible ? 1.0 : 0.0
        if level == 0 && gain < 0.00001 {
            output.update(repeating: 0,count: count)
            rightOutput.update(repeating:0,count:count)
            return
        }
        let rate = Self.sampleRate
        let cutoff = targets.cockpit ? 2450.0 : 6900.0
        let filterAmount = 1 - exp(-2 * .pi * cutoff / rate)
        let roadFilter = 1 - exp(-2 * .pi * (targets.cockpit ? 2450.0 : 5900.0) / rate)
        let kerbStep = targets.roadSpeed * 7 / (2 * .pi * rate) // kerbElevation uses sin(progress * 7)
        let rollingRate = clamp(0.72 + targets.roadSpeed*0.013,0.72,1.45)
        traffic[0].set(opponentParameters(targets.opponents.0))
        traffic[1].set(opponentParameters(targets.opponents.1))
        traffic[2].set(opponentParameters(targets.opponents.2))
        let powertrain = DriveInput(kind:kind,powertrain:targets.powertrain,throttle:targets.throttle,
                                    ignition:targets.ignition,doppler:1)
        let bank = banks[kind.rawValue]
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
            scrubRates += (targets.tyres.rate - scrubRates) * 0.0013
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
            sprayNoise += (texture - sprayNoise) * 0.33
            let water = sprayLevel * (sprayNoise - roadNoise) * 0.34
            kerbPan += (targets.kerbPan-kerbPan)*0.0014
            absLevel += (targets.absModulation-absLevel)*0.0018
            var absSound = 0.0
            if absLevel > 0.0001 {
                absPhase += 11/rate
                if absPhase >= 1 { absPhase -= 1 }
                let valve = max(0,cos(absPhase*2 * .pi))
                absSound = absLevel*valve*valve*(0.16*roadNoise+0.14*(sprayNoise-roadNoise))
            }
            let side = (road*kerbPan*0.55 + scrubSide*0.5)*effectsGain
            filteredSide += (side-filteredSide)*roadFilter
            master += (targets.masterVolume-master)*0.0015
            motorGain += (targets.motorVolume-motorGain)*0.0015
            effectsGain += (targets.effectsVolume-effectsGain)*0.0015
            let sample = motor*motorGain
            filtered += (sample - filtered) * filterAmount
            let surfaceMix = (road + rolling + wind + scrub + water + absSound)*effectsGain
            filteredRoad += (surfaceMix-filteredRoad)*roadFilter
            let a = traffic[0].tick()
            let b = traffic[1].tick()
            let c = traffic[2].tick()
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
            let left = filtered*motorChannels.x + (filteredRoad-filteredSide)*roadGain
            let right = filtered*motorChannels.y + (filteredRoad+filteredSide)*roadGain
            output[frame] = Float(0.75 * gain * master * tanh((left+(a.0+b.0+c.0)*motorGain+signal*effectsGain) * 1.4))
            rightOutput[frame] = Float(0.75 * gain * master * tanh((right+(a.1+b.1+c.1)*motorGain+signal*effectsGain) * 1.4))
        }
    }

    private func opponentParameters(_ source: OpponentMotor?) -> TrafficMix? {
        guard let source else { return nil }
        let state = source.powertrain
        let input = DriveInput(kind:source.kind,powertrain:state,throttle:source.throttle,
                               ignition:source.ignition,doppler:source.doppler)
        let gain = source.volume * (targets.cockpit ? 0.76 : 1)
        return TrafficMix(input:input,bank:banks[source.kind.rawValue],
                          left:gain*sqrt(0.5*(1-source.pan)),right:gain*sqrt(0.5*(1+source.pan)))
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

    func update(rpm: Double, throttle: Double, ignition: Double = 1, powertrain: PowertrainSound? = nil,
                perspective: VehicleSoundPerspective = VehicleSoundPerspective(), cockpit: Bool = true, kerb: Double = 0,
                roadSpeed: Double = 0, tyreScrub: Double = 0, roadSound: RoadSound? = nil,
                spray: Double = 0, kind: VehicleKind = .concept,
                opponents: [OpponentMotor] = [], raceSignal: Int = 0, paused: Bool) {
        guard let voice else { return }
        let audible = !paused && !muted
        let shaftRPM = kind == .honda ? max(0,roadSpeed)/kind.radius*kind.finalDrive*60/(2 * .pi) : rpm
        let measured = powertrain ?? PowertrainSound(driveLoad:throttle*ignition,overrun:0,shaftRPM:shaftRPM)
        let state = PowertrainSound(driveLoad:clamp(measured.driveLoad,0,1),overrun:clamp(measured.overrun,0,1),
                                    shaftRPM:max(0,measured.shaftRPM))
        let rivals = (opponents.first,opponents.count > 1 ? opponents[1] : nil,opponents.count > 2 ? opponents[2] : nil)
        voice.controls.withLock {
            $0 = MotorControls(throttle: clamp(throttle, 0, 1),
                               ignition: clamp(ignition, 0, 1), powertrain:state, perspective:perspective, cockpit: cockpit, audible: audible,
                               kerb: clamp(kerb, 0, 1), roadSpeed: clamp(roadSpeed, 0, 100),
                               rolling:clamp(roadSound?.rolling ?? 0,0,1.35),wind:clamp(roadSound?.wind ?? 0,0,1),
                               tyres:roadSound?.tyres ?? RoadSound(tyreScrub:tyreScrub).tyres,
                               kerbPan:clamp(roadSound?.kerbPan ?? 0,-1,1),
                               absModulation:clamp(roadSound?.absModulation ?? 0,0,1),
                               spray:clamp(spray,0,1),kind:kind,opponents:rivals,
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

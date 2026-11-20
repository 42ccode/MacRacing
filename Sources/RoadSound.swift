import Foundation
import simd

/// The world-space contact point and relative normal speed from the collision solver.
struct ContactSound: Equatable {
    let closingSpeed: Double
    let position: SIMD2<Double>
}

/// One acoustically unresolved group of tyres as heard from a second car.
struct DistantTyres {
    var level = 0.0
    var slide = 0.0
    var rate = 1.0
    // Power-weighted position across the track (−1 to +1) and from front to rear (0 to 1).
    var across = 0.0
    var rearShare = 0.5

    func interpolated(to next: Self, fraction: Double) -> Self {
        let level = level + (next.level - level) * fraction
        guard level > 0 else { return Self() }
        // A silent endpoint has no source location. Fade the measured source in place.
        let share = next.level * fraction / level
        return Self(level:level,slide:slide+(next.slide-slide)*share,rate:rate+(next.rate-rate)*share,
                    across:across+(next.across-across)*share,rearShare:rearShare+(next.rearShare-rearShare)*share)
    }
}

/// Four independent playback targets in wheel order (FR, FL, RR, RL).
struct TyreSound {
    var level = SIMD4<Double>.zero
    var slide = SIMD4<Double>.zero
    var rate = SIMD4<Double>(repeating: 1)
    var pan = SIMD4<Double>.zero

    init() {}

    init(vehicle: Vehicle) {
        var pavedPower = SIMD4<Double>.zero
        var dryLevel = SIMD4<Double>.zero
        for (index,wheel) in vehicle.wheels.enumerated() {
            pavedPower[index] = wheel.slidingPower * wheel.pavedContactFraction
            dryLevel[index] = 1 / (1 + 3.5 * wheel.waterFilm)
            let slip = wheel.contactSlipSpeed
            slide[index] = wheel.slidingFraction * slip / (slip + 1.4) * dryLevel[index]
            rate[index] = 0.86 + 0.28 * slip / (slip + 5)
            pan[index] = index.isMultiple(of:2) ? 1 : -1
        }
        let total = 16_000 + pavedPower.sum() // reference power in W plus all four contacts
        for i in 0..<4 { level[i] = sqrt(pavedPower[i] / total) * dryLevel[i] }
    }

    var distant: DistantTyres {
        let power = level * level
        let total = power.sum()
        guard total > 1e-10 else { return DistantTyres() }
        let weights = power / total
        return DistantTyres(level:sqrt(total),slide:(weights*slide).sum(),rate:(weights*rate).sum(),
                           across:weights[1]+weights[3]-weights[0]-weights[2],
                           rearShare:weights[2]+weights[3])
    }
}

struct RoadSound {
    var rolling = 0.0
    var wind = 0.0
    var kerbPan = 0.0
    private var kerbPower = SIMD4<Double>.zero
    var kerbIntensity: Double { kerbPower.max().squareRoot() }
    var tyres = TyreSound()
    var tyreScrub: Double { (tyres.level * tyres.level).sum().squareRoot() }
    var scrubPan: Double {
        let power = tyres.level * tyres.level
        return (tyres.pan * power).sum() / max(0.000001, power.sum())
    }
    var absModulation = 0.0
    private(set) var spray: (level: Double,pan: Double)?

    init(kerbPan: Double = 0,tyreScrub: Double = 0,scrubPan: Double = 0,absModulation: Double = 0) {
        self.kerbPan = kerbPan
        tyres.level[0] = clamp(tyreScrub,0,1)
        tyres.slide[0] = tyres.level[0]
        tyres.pan[0] = clamp(scrubPan,-1,1)
        self.absModulation = absModulation
    }

    init(vehicle: Vehicle, listenerPosition: SIMD2<Double>? = nil, listenerRight: SIMD2<Double>? = nil) {
        tyres = TyreSound(vehicle:vehicle)
        let quarterWeight = vehicle.mass * 9.81 / 4
        let speed = vehicle.speed
        wind = clamp(speed*speed / (55*55),0,1)
        for (index,wheel) in vehicle.wheels.enumerated() {
            let weight = clamp(wheel.normalLoad / quarterWeight,0,1.5)
            let pavement = wheel.pavedContactFraction
            rolling += weight * (0.20 + 0.80 * pavement) * clamp(wheel.rollingContactSpeed/38,0,1.35) / 4
            kerbPower[index] = wheel.kerbFeedback*wheel.kerbFeedback
        }
        let leftKerb = max(vehicle.wheels[1].kerbFeedback,vehicle.wheels[3].kerbFeedback)
        let rightKerb = max(vehicle.wheels[0].kerbFeedback,vehicle.wheels[2].kerbFeedback)
        kerbPan = (rightKerb-leftKerb)/max(0.06,rightKerb+leftKerb)
        if let listenerPosition, let listenerRight { placeSources(for:vehicle,at:listenerPosition,right:listenerRight) }
        if vehicle.absActive && vehicle.brakeLinePressure > 0.06 {
            absModulation = clamp(0.24*vehicle.absRelease+0.95*vehicle.absValveActivity,0,1)
        }
    }

    /// Place the source observations at the wheel positions for the current camera.
    mutating func placeSources(for vehicle: Vehicle, at position: SIMD2<Double>,right: SIMD2<Double>) {
        var sprayPower = SIMD4<Double>.zero
        for (index,point) in vehicle.contactPoints.enumerated() {
            let offset = point-position
            let pan = clamp(simd_dot(offset,right)/max(1,simd_length(offset)),-1,1)
            tyres.pan[index] = pan
            let water = vehicle.wheels[index].spray
            sprayPower[index] = water*water
        }
        kerbPan = (tyres.pan*kerbPower).sum()/max(0.000001,kerbPower.sum())
        // Combine spray by contact power. Replay already restores the sprays
        // for wheel particles, so audio can position those same observations.
        let totalSprayPower = sprayPower.sum()
        spray = (sqrt(totalSprayPower/4),(tyres.pan*sprayPower).sum()/max(0.000001,totalSprayPower))
    }

    func interpolated(to next: RoadSound,fraction: Double) -> RoadSound {
        var mixed = self
        mixed.rolling += (next.rolling-rolling)*fraction
        mixed.wind += (next.wind-wind)*fraction
        mixed.kerbPan += (next.kerbPan-kerbPan)*fraction
        mixed.kerbPower += (next.kerbPower-kerbPower)*fraction
        mixed.absModulation += (next.absModulation-absModulation)*fraction
        mixed.tyres.level += (next.tyres.level-tyres.level)*fraction
        mixed.tyres.slide += (next.tyres.slide-tyres.slide)*fraction
        mixed.tyres.rate += (next.tyres.rate-tyres.rate)*fraction
        mixed.spray = nil
        return mixed
    }
}

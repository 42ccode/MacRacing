import Foundation
import simd

/// Local race advisories. Uses the same projected locations as race timing.
struct RaceFlags {
    enum Reason: Equatable {
        case stopped, slow, oncoming
    }

    struct Caution: Equatable {
        let entrantIndex: Int
        let distance: Double
        let reason: Reason
    }

    struct Blue: Equatable {
        let entrantIndex: Int
        let distance: Double
    }

    enum Phase: Equatable {
        case countdown, racing, finalLap, finished, retired, timedOut
    }

    private static let scanInterval = 0.05
    private static let holdDuration = 0.65
    private(set) var caution: Caution?
    private(set) var blue: Blue?
    private var pendingIndex: Int?
    private var timeToScan = 0.0
    private var holdTime = 0.0
    private var blueHoldTime = 0.0

    static func phase(for index: Int, in race: SprintRace) -> Phase? {
        guard race.entries.indices.contains(index) else { return nil }
        let entry = race.entries[index]
        switch entry.status {
        case .racing:
            if race.countdown > 0 { return .countdown }
            return race.checkeredTime != nil || entry.laps+1 == race.lapCount ? .finalLap : .racing
        case .finished: return .finished
        case .retired: return .retired
        case .timedOut: return .timedOut
        }
    }

    mutating func reset() { self = RaceFlags() }

    @discardableResult
    mutating func update(_ dt: Double, player: Vehicle, rivals: [TrafficCar],
                         locations: [TrackLocation], circuit: Circuit, line: RacingLine? = nil,
                         race: SprintRace? = nil,active: Bool) -> Caution? {
        guard active, dt.isFinite, dt > 0, !rivals.isEmpty, locations.count == rivals.count+1 else {
            reset()
            return nil
        }
        holdTime = max(0,holdTime-dt)
        if holdTime == 0 { caution = nil }
        blueHoldTime = max(0,blueHoldTime-dt)
        if blueHoldTime == 0 { blue = nil }
        timeToScan -= dt
        guard timeToScan <= 1e-9 else { return caution }
        timeToScan = Self.scanInterval

        let playerLocation = locations[0]
        let pit = circuit.pitLane
        let edge = circuit.width/2 + 0.15
        guard playerLocation.distance <= edge, !pit.contains(playerLocation),
              simd_dot(player.forward,playerLocation.tangent) > 0.28 else {
            caution = nil
            blue = nil
            pendingIndex = nil
            return nil
        }
        if let race, let approach = BlueFlagTraffic.approach(to:0,race:race,field:[player]+rivals.map(\.vehicle),
                                                            location:playerLocation,circuit:circuit,locations:locations) {
            blue = Blue(entrantIndex:approach.entrantIndex,distance:approach.distance)
            blueHoldTime = 0.35
        } else if let warning = blue, locations.indices.contains(warning.entrantIndex) {
            let distance = playerLocation.progress-locations[warning.entrantIndex].progress
            let behind = (distance+circuit.length).truncatingRemainder(dividingBy:circuit.length)
            if behind > 65 || behind < 1 { blue = nil }
        } else { blue = nil }
        let speed = max(0,simd_dot(player.velocity,playerLocation.tangent))
        let lookAhead = clamp(24+0.85*speed+speed*speed/16,35,180)
        let urgent = max(18,0.75*speed)

        func ahead(of rival: Vehicle,at location: TrackLocation) -> Double? {
            let right = SIMD2(location.tangent.y,-location.tangent.x)
            let towardTrack = location.lateral < 0 ? right : -right
            let nearestBody = location.distance-rival.projectedBodyReach(toward:towardTrack)
            guard nearestBody <= edge, !pit.contains(location), !pit.inServiceBox(location) else { return nil }
            let delta = location.progress-playerLocation.progress
            let gap = delta < 0 ? delta+circuit.length : delta
            return gap > 0 ? gap : nil
        }

        // A brief acceleration can make the raw advisory disappear. Keep it
        // stable while the same car stays ahead, then clear it as we pass it.
        if let warning = caution {
            let index = warning.entrantIndex-1
            if rivals.indices.contains(index),
               let gap = ahead(of:rivals[index].vehicle,at:locations[warning.entrantIndex]), gap <= lookAhead+38 {
                caution = Caution(entrantIndex:warning.entrantIndex,distance:gap,reason:warning.reason)
            } else {
                caution = nil
            }
        }
        var nearest: Caution?
        for index in rivals.indices {
            let entrant = index+1
            let location = locations[entrant]
            let rival = rivals[index].vehicle
            guard let gap = ahead(of:rival,at:location), gap < (nearest?.distance ?? .infinity),
                  gap <= lookAhead+35 else { continue }
            let forwardSpeed = simd_dot(rival.velocity,location.tangent)
            let facing = simd_dot(rival.forward,location.tangent)
            let reason: Reason
            let range: Double
            if forwardSpeed < -1.8 || (facing < -0.5 && forwardSpeed < 2 && rival.speed > 1.5) {
                reason = .oncoming
                range = lookAhead+clamp(-forwardSpeed*1.4,0,35)
            } else if rival.speed < 1.5 {
                reason = .stopped
                range = lookAhead
            } else if forwardSpeed < min(8.5,0.4*speed) && speed-forwardSpeed > 8 {
                // The crest or corner ahead has its own expected pace.
                let referenceSpeed = line?.sample(at:location.progress).targetSpeed ?? .infinity
                guard forwardSpeed < referenceSpeed*0.62 else { continue }
                reason = .slow
                range = lookAhead
            } else { continue }
            if gap <= range { nearest = Caution(entrantIndex:entrant,distance:gap,reason:reason) }
        }
        if let nearest, nearest.entrantIndex == caution?.entrantIndex ||
            nearest.entrantIndex == pendingIndex || nearest.distance <= urgent {
            caution = nearest
            holdTime = Self.holdDuration
            pendingIndex = nil
        } else {
            pendingIndex = nearest?.entrantIndex
        }
        return caution
    }
}

/// A warning follows travel along the track, even when a car is rotating.
struct WrongWayMonitor {
    private static let warningDelay = 0.65
    private static let recoveryDelay = 0.45
    private(set) var isActive = false
    private var directionTime = 0.0

    mutating func reset() { self = WrongWayMonitor() }

    @discardableResult
    mutating func update(_ dt: Double, vehicle: Vehicle, location: TrackLocation,
                         circuit: Circuit, active: Bool = true) -> Bool {
        guard active, location.distance <= circuit.width/2 + 2.5, !circuit.pitLane.contains(location) else {
            reset()
            return false
        }
        guard dt.isFinite && dt > 0 else { return isActive }

        let along = simd_dot(vehicle.velocity,location.tangent)
        // Rotation and mostly lateral motion during a slide do not establish
        // travel in either direction.
        let alongTrack = along*along >= 0.5*simd_length_squared(vehicle.velocity)
        let changingState = alongTrack && (isActive ? along > 1.0 : along < -1.2)
        directionTime = changingState ? directionTime+dt : 0
        let delay = isActive ? Self.recoveryDelay : Self.warningDelay
        if directionTime+1e-9 >= delay {
            isActive.toggle()
            directionTime = 0
        }
        return isActive
    }
}

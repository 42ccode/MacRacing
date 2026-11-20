import Foundation
import simd

/// A rolling approach followed by one timed lap. Timing and track limits
/// use the same ordered gates as ordinary practice.
struct QualifyingSession {
    enum Outcome: Equatable {
        case valid, invalid, assisted, timedOut, skipped
    }

    struct Result: Equatable {
        let time: Double?
        let sectors: [Double]
        let outcome: Outcome
    }

    struct Grid {
        struct Row: Equatable {
            let entrantIndex: Int
            let position: Int
            let time: Double?
        }

        let playerGridSlot: Int
        let rivalOrder: [Int]
        let rows: [Row]
    }

    static let timeLimit = 240.0
    private(set) var timing = RaceSession()
    private(set) var elapsed = 0.0
    private(set) var result: Result?
    private var usedAssistance = false

    init(startingAt progress: Double) {
        timing.beginOutLap(at:progress)
    }

    static func rollingCar(kind: VehicleKind, circuit: Circuit, line: RacingLine, tyres: TyreSetup) -> Vehicle {
        let progress = circuit.length-min(78,0.075*circuit.length)
        let sample = line.sample(at:progress)
        let direction = line.sample(at:progress+3).position-line.sample(at:progress-3).position
        let tangent = simd_normalize(direction)
        let launch = TrackSample(point:sample.position,tangent:tangent,distance:progress)
        let speed = clamp(sample.targetSpeed*0.65,9,14)
        var car = Vehicle()
        car.kind = kind
        car.reset(at:launch)
        car.service(setup:tyres)
        car.velocity = tangent*speed
        let omega = speed/car.wheelRadius
        for wheel in car.wheels.indices { car.wheels[wheel].angularVelocity = omega }
        car.rpm = omega*kind.gearRatios[0]*kind.finalDrive*30 / .pi
        return car
    }

    @discardableResult
    mutating func step(_ dt: Double, vehicle: Vehicle, location: TrackLocation, circuit: Circuit,
                       assisted: Bool = false, input: DrivingInput = DrivingInput()) -> Bool {
        guard result == nil, dt.isFinite, dt > 0 else { return false }
        elapsed += dt
        let approaching = timing.waitingForStart
        if !approaching {
            usedAssistance = usedAssistance || assisted
            if circuit.pitLane.contains(location) { timing.invalidate("驶入维修道") }
        }
        if timing.step(dt,vehicle:vehicle,location:location,trackLength:circuit.length,
                       trackWidth:circuit.width,assisted:assisted,input:input) {
            if let time = timing.best, timing.lastValid && !usedAssistance {
                result = Result(time:time,sectors:timing.lastSectors,outcome:.valid)
            } else {
                result = Result(time:nil,sectors:[],outcome:usedAssistance ? .assisted : .invalid)
            }
            return true
        }
        if approaching && !timing.waitingForStart && assisted {
            usedAssistance = true
            timing.invalidate("自动驾驶")
        }
        if elapsed >= Self.timeLimit {
            result = Result(time:nil,sectors:[],outcome:.timedOut)
            return true
        }
        return false
    }

    mutating func skip() {
        guard result == nil else { return }
        result = Result(time:nil,sectors:[],outcome:.skipped)
    }

    /// Run each AI's clean lap independently. This function has no UI or
    /// storage side effects and can run on a utility queue.
    static func referenceTimes(kind: VehicleKind, circuit: Circuit, line: RacingLine,
                               rivals: Int, paceScale: Double,
                               shouldCancel: () -> Bool = { false }) -> [Double?] {
        var times = [Double?](repeating:nil,count:clamp(rivals,1,3))
        let tyres = TyreSetup(compound:circuit.condition == .wet ? .wet : .medium)
        let assists = DrivingAssists()
        let dt = 1.0/120
        let maxSteps = Int(timeLimit/dt)+1
        for index in times.indices {
            var car = rollingCar(kind:kind,circuit:circuit,line:line,tyres:tyres)
            var location = circuit.nearest(to:car.position)
            var session = QualifyingSession(startingAt:location.progress)
            let pace = ComputerTraffic.sprintPace(for:index,scale:paceScale)
            for tick in 0..<maxSteps {
                if tick.isMultiple(of:120) && shouldCancel() { return times }
                let input = ComputerDriver.input(for:car,at:location,circuit:circuit,line:line,pace:pace)
                car.step(dt,input:input,assists:assists,roadDistance:location.distance,roadWidth:circuit.width,
                         roadLateral:location.lateral,roadProgress:location.progress,
                         kerbsEnabled:circuit.hasKerb(at:location.progress),roadContacts:circuit.wheelContacts(at:car.contactPoints))
                location = circuit.nearest(to:car.position)
                if car.constrainToGuardRail(at:location) != nil {
                    location = circuit.nearest(to:car.position)
                }
                if session.step(dt,vehicle:car,location:location,circuit:circuit,input:input) {
                    times[index] = session.result?.time
                    break
                }
            }
        }
        return times
    }

    static func grid(playerTime: Double?, rivalTimes: [Double?]) -> Grid {
        let times = [playerTime]+Array(rivalTimes.prefix(3))
        let clean = times.map { value -> Double? in
            guard let value, value.isFinite, value > 15, value <= timeLimit else { return nil }
            return value
        }
        let indices = clean.indices.sorted { a,b in
            // Ties at the displayed millisecond keep the previously seeded
            // rival order. The player's lap is set after the AI references.
            let first = clean[a].map { Int($0*1000) } ?? Int.max
            let second = clean[b].map { Int($0*1000) } ?? Int.max
            if first != second { return first < second }
            return (a == 0 ? clean.count : a) < (b == 0 ? clean.count : b)
        }
        let rows = indices.enumerated().map { place,index in
            Grid.Row(entrantIndex:index,position:place+1,time:clean[index])
        }
        return Grid(playerGridSlot:indices.firstIndex(of:0) ?? 0,
                    rivalOrder:indices.filter { $0 != 0 }.map { $0-1 },rows:rows)
    }
}

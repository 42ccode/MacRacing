import Foundation
import simd

struct TrafficCar {
    var vehicle: Vehicle
    let pace: Double
    let lane: Double
}

struct ComputerDriver {
    static func wantsControl(_ input: DrivingInput) -> Bool {
        input.throttle > 0.12 || input.brake > 0.12 || abs(input.steering) > 0.22
    }

    static func canDrive(_ vehicle: Vehicle, at location: TrackLocation, on circuit: Circuit) -> Bool {
        vehicle.gear > 0 && location.distance < circuit.width/2 + 1 && simd_dot(vehicle.forward, location.tangent) > 0.25
    }

    static func input(for car: Vehicle, at location: TrackLocation, circuit: Circuit, line: RacingLine,
                      pace: Double, lane: Double = 0, traffic: [Vehicle] = []) -> DrivingInput {
        let lookAhead = clamp(5 + car.speed*0.37, 5, 22)
        let aimProgress = location.progress + lookAhead
        let aim = line.sample(at: aimProgress).position + circuit.sample(at: aimProgress).right * lane
        let direction = aim-car.position
        let right = -simd_dot(direction, car.modelX)
        let pursuit = atan(2*car.wheelbase*right/max(1, simd_length_squared(direction)))
        let steeringLimit = 0.52 / (1+abs(car.forwardSpeed)/20)
        let requested = clamp((pursuit + car.yawRate*0.075)/steeringLimit, -1, 1)
        // Invert the same nonlinear input curve used by the vehicle solver.
        var low = 0.0, high = 1.0
        for _ in 0..<10 {
            let mid = (low+high)/2
            if mid*(0.45+0.55*mid*mid) < abs(requested) {low = mid} else {high = mid}
        }
        let steering = copysign((low+high)/2, requested)
        let preview = min(7, 1+car.speed*0.16)
        var target = line.sample(at: location.progress+preview).targetSpeed*pace
        // Keep a following gap when another car occupies the intended corridor.
        for other in traffic {
            let offset = other.position-car.position
            let ahead = simd_dot(offset, car.forward)
            let lateral = -simd_dot(offset, car.modelX)
            let aimOffset = right * clamp(ahead/max(lookAhead,1), 0, 1)
            if ahead > 0 && ahead < max(18,car.speed*1.3) && abs(lateral-aimOffset) < 2.05 {
                let frontSpeed = max(0,simd_dot(other.velocity,car.forward))
                target = min(target,max(0,frontSpeed+(ahead-5-car.speed*0.45)*0.85))
            }
        }
        let error = target-car.speed
        return DrivingInput(throttle: clamp(error*0.20,0,1), brake: clamp((-error-0.45)*0.23,0,1), steering: steering)
    }
}

struct TrafficContact {
    let normal: SIMD2<Double> // From the first car toward the second.
    let closingSpeed: Double

    static func resolve(_ first: inout Vehicle, _ second: inout Vehicle) -> TrafficContact? {
        guard simd_distance(first.position, second.position) < 4.6 else {return nil}
        // Three overlapping circles approximate each footprint while keeping
        // side-by-side clearance narrower than front-to-back clearance.
        var depth = 0.0
        var normal = first.forward
        for front in [-1.22,0,1.22] {
            for rear in [-1.22,0,1.22] {
                let separation = second.position+second.forward*rear-first.position-first.forward*front
                let distance = simd_length(separation)
                if 1.96-distance > depth {
                    depth = 1.96-distance
                    normal = distance > 0.001 ? separation/distance : first.forward
                }
            }
        }
        guard depth > 0 else {return nil}
        let firstShare = second.mass/(first.mass+second.mass)
        first.position -= normal*depth*firstShare
        second.position += normal*depth*(1-firstShare)
        let closing = max(0,simd_dot(first.velocity-second.velocity, normal))
        first.velocity -= normal*closing*1.08*firstShare
        second.velocity += normal*closing*1.08*(1-firstShare)
        return TrafficContact(normal: normal, closingSpeed: closing)
    }
}

struct ComputerTraffic {
    private(set) var cars: [TrafficCar] = []
    private var stepClock = 0.0

    mutating func reset(count: Int, kind: VehicleKind, circuit: Circuit, from progress: Double) {
        stepClock = 0
        cars = (0..<clamp(count,0,3)).map { index in
            let sample = circuit.sample(at: progress+13+Double(index)*11)
            var car = Vehicle(); car.kind = kind; car.reset(at: sample)
            let lane = [-0.72,0.72,0.0][index]
            car.position += sample.right*lane
            return TrafficCar(vehicle: car, pace: [0.72,0.78,0.84][index], lane: lane)
        }
    }

    mutating func step(_ dt: Double, player: inout Vehicle, circuit: Circuit, line: RacingLine) -> TrafficContact? {
        guard !cars.isEmpty else {return nil}
        stepClock += dt
        if stepClock >= 1/120 {
            let elapsed = stepClock
            stepClock = 0
            let snapshot = cars.map(\.vehicle)
            for index in cars.indices {
                var car = snapshot[index]
                let location = circuit.nearest(to: car.position)
                let others = snapshot.indices.filter { $0 != index }.map { snapshot[$0] }+[player]
                let command = ComputerDriver.input(for: car, at: location, circuit: circuit, line: line,
                                                   pace: cars[index].pace, lane: cars[index].lane, traffic: others)
                car.step(elapsed, input: command, assists: DrivingAssists(), roadDistance: location.distance,
                         roadWidth: circuit.width, roadLateral: location.lateral, roadProgress: location.progress,
                         kerbsEnabled: circuit.hasKerb(at: location.progress))
                let current = circuit.nearest(to: car.position)
                if current.distance > 15 {
                    let normal = (car.position-current.point)/current.distance
                    car.position = current.point+normal*15
                    car.velocity -= normal*max(0,simd_dot(car.velocity,normal))*1.1
                }
                cars[index].vehicle = car
            }
            for i in cars.indices {
                for j in cars.indices where j > i {
                    var first = cars[i].vehicle, second = cars[j].vehicle
                    if TrafficContact.resolve(&first,&second) != nil {
                        cars[i].vehicle = first; cars[j].vehicle = second
                    }
                }
            }
        }
        var strongest: TrafficContact?
        for index in cars.indices {
            if let contact = TrafficContact.resolve(&player,&cars[index].vehicle),
               contact.closingSpeed > (strongest?.closingSpeed ?? 0) {strongest = contact}
        }
        return strongest
    }
}

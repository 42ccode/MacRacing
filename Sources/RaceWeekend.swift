import Foundation

enum RaceDifficulty: Int, CaseIterable, Codable {
    case rookie, club, pro

    var label: String {
        switch self {
        case .rookie: return "入门"
        case .club: return "俱乐部"
        case .pro: return "挑战"
        }
    }

    var paceScale: Double {
        switch self {
        case .rookie: return 0.89
        case .club: return 1
        case .pro: return 1.07
        }
    }
}

struct RaceConfiguration: Codable, Equatable {
    var laps = 2
    var rivals = 3
    var difficulty = RaceDifficulty.club
    var startAtFront = false
    var matchTyresToWeather = true
    var qualifying: Bool? = nil
    var drying: Bool? = nil

    static var lapOptions: [Int] { SprintRace.lapOptions }

    mutating func validate() {
        if !Self.lapOptions.contains(laps) { laps = 2 }
        rivals = clamp(rivals,1,3)
    }

    var gridSlot: Int { startAtFront ? 0 : rivals }
    var usesQualifying: Bool { qualifying == true }
    var usesDryingTrack: Bool { drying == true }

    func fittedTyres(from planned: TyreSetup, on condition: TrackCondition) -> TyreSetup {
        guard matchTyresToWeather else { return planned }
        var setup = planned
        if condition == .wet { setup.compound = .wet }
        else if setup.compound == .wet { setup.compound = .medium }
        return setup
    }
}

/// Race history keeps the original numeric identity of cars from earlier versions.
@propertyWrapper
struct RecordedVehicle: Codable, Equatable {
    let rawID: Int
    init(wrappedValue: VehicleKind) { rawID = wrappedValue.rawValue }
    init(from decoder: Decoder) throws { rawID = try decoder.singleValueContainer().decode(Int.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawID)
    }
    var wrappedValue: VehicleKind { VehicleKind(rawValue:rawID) ?? .porsche }
    var projectedValue: Int { rawID }
}

/// A player's result survives restarting a race and reopening the app.
struct RaceRecord: Codable, Equatable {
    static let historyLimit = 24
    static let pageSize = 6
    let id: UUID
    let date: Date
    @RecordedVehicle var vehicle: VehicleKind
    var recordedVehicleLabel: String { VehicleKind(rawValue:$vehicle)?.label ?? "已退役车型" }
    let circuit: CircuitKind
    let wet: Bool
    let configuration: RaceConfiguration
    let completedLaps: Int
    let place: Int?
    let totalTime: Double?
    let bestLap: Double?
    let penaltySeconds: Double
    let assisted: Bool
    var cup: CupEntry? = nil
    var qualifiedGridPlace: Int? = nil
    var pitStops: Int? = nil
    var lappedFinish: Bool? = nil
    var timedOut: Bool? = nil
    var lapHistory: [RaceLap]? = nil

    var isValid: Bool {
        guard (0...7).contains($vehicle), RaceConfiguration.lapOptions.contains(configuration.laps),
              (1...3).contains(configuration.rivals),
              (0...configuration.laps).contains(completedLaps),
              qualifiedGridPlace.map({ (1...configuration.rivals+1).contains($0) }) ?? true,
              pitStops.map({ (0...100).contains($0) }) ?? true,
              date.timeIntervalSinceReferenceDate.isFinite,
              (0...7200).contains(penaltySeconds),
              bestLap.map({ (0.1...7200).contains($0) }) ?? true else { return false }
        if let lapHistory {
            guard lapHistory.count == completedLaps,lapHistory.allSatisfy({ (0.001...7200).contains($0.time) }) else { return false }
            let sum = lapHistory.reduce(penaltySeconds) { $0+$1.time }
            if let totalTime, abs(sum-totalTime) > 0.01 { return false }
            let fastest = lapHistory.dropFirst().filter(\.clean).map(\.time).min()
            if let bestLap, let fastest {
                if abs(bestLap-fastest) > 0.001 { return false }
            } else if bestLap != nil || fastest != nil { return false }
        }
        if let place, let totalTime {
            let validDistance = completedLaps == configuration.laps ? lappedFinish != true :
                (lappedFinish == true && completedLaps > 0)
            return (1...configuration.rivals+1).contains(place) &&
                (0.1...21_600).contains(totalTime) && validDistance && timedOut != true
        }
        return place == nil && totalTime == nil && lappedFinish != true
    }

    static func recent(_ records: [Self]) -> [Self] {
        var seen = Set<UUID>()
        return Array(records.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(historyLimit))
    }
}

enum CupSeries: String, Codable, CaseIterable {
    case club, rain, speed

    var name: String {
        switch self {
        case .club: return "俱乐部杯"
        case .rain: return "雨地杯"
        case .speed: return "速度杯"
        }
    }

    var detail: String {
        switch self {
        case .club: return "循序练习制动、走线和连续弯"
        case .rain: return "从湿地短环进入有横坡的高速赛道"
        case .speed: return "高速制动、强动力起步与混合路况"
        }
    }

    var rounds: [CupRound] {
        switch self {
        case .club: return Self.clubRounds
        case .rain: return Self.rainRounds
        case .speed: return Self.speedRounds
        }
    }

    private static let clubRounds = [
        CupRound(vehicle:.porsche,circuit:.sprint,condition:.dry,laps:2,difficulty:.rookie),
        CupRound(vehicle:.centenario,circuit:.north,condition:.dry,laps:2,difficulty:.rookie),
        CupRound(vehicle:.porsche,circuit:.technical,condition:.dry,laps:3,difficulty:.club)
    ]
    private static let rainRounds = [
        CupRound(vehicle:.porsche,circuit:.sprint,condition:.wet,laps:2,difficulty:.club),
        CupRound(vehicle:.centenario,circuit:.valley,condition:.wet,laps:2,difficulty:.club),
        CupRound(vehicle:.porsche,circuit:.ridge,condition:.wet,laps:3,difficulty:.club)
    ]
    private static let speedRounds = [
        CupRound(vehicle:.porsche,circuit:.grand,condition:.dry,laps:3,difficulty:.pro),
        CupRound(vehicle:.centenario,circuit:.ridge,condition:.dry,laps:3,difficulty:.pro),
        CupRound(vehicle:.porsche,circuit:.valley,condition:.wet,laps:3,difficulty:.pro)
    ]
}

struct CupRound {
    let vehicle: VehicleKind
    let circuit: CircuitKind
    let condition: TrackCondition
    let configuration: RaceConfiguration

    init(vehicle: VehicleKind, circuit: CircuitKind, condition: TrackCondition, laps: Int, difficulty: RaceDifficulty) {
        self.vehicle = vehicle
        self.circuit = circuit
        self.condition = condition
        configuration = RaceConfiguration(laps:laps,rivals:3,difficulty:difficulty)
    }

    func accepts(_ record: RaceRecord, previousVehicleID: Int? = nil) -> Bool {
        record.isValid && !record.assisted && (vehicle.rawValue == record.$vehicle || previousVehicleID == record.$vehicle) && circuit == record.circuit &&
            (condition == .wet) == record.wet && configuration == record.configuration
    }

    static func points(for place: Int?) -> Int {
        switch place {
        case 1: return 10
        case 2: return 7
        case 3: return 5
        case 4: return 3
        default: return 0
        }
    }
}

struct CupEntry: Codable, Equatable {
    let series: CupSeries
    let roundIndex: Int
}

enum CupMedal: String, Codable {
    case bronze, silver, gold

    init?(points: Int) {
        switch points {
        case 27...: self = .gold
        case 20...: self = .silver
        case 14...: self = .bronze
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .bronze: return "铜牌"
        case .silver: return "银牌"
        case .gold: return "金牌"
        }
    }
}

struct CupProgress: Codable, Equatable {
    private(set) var records: [RaceRecord] = []
    private(set) var bestPoints: Int? = nil

    var points: Int { records.reduce(0) { $0+CupRound.points(for:$1.place) } }

    mutating func validate(for series: CupSeries) {
        let savedBest = bestPoints
        let validPrefix = records
        records = []
        bestPoints = savedBest.flatMap { (0...series.rounds.count*10).contains($0) ? $0 : nil }
        for record in validPrefix {
            let historical: [Int]
            switch series {
            case .club: historical = [4,6,3]
            case .rain: historical = [7,4,2]
            case .speed: historical = [1,5,2]
            }
            let previous = historical.indices.contains(records.count) ? historical[records.count] : nil
            if !recordRound(record,for:series,previousVehicleID:previous) { break }
        }
    }

    @discardableResult
    mutating func recordRound(_ record: RaceRecord, for series: CupSeries, previousVehicleID: Int? = nil) -> Bool {
        let index = records.count
        guard record.cup == CupEntry(series:series,roundIndex:index), series.rounds.indices.contains(index),
              series.rounds[index].accepts(record,previousVehicleID:previousVehicleID), !records.contains(where: { $0.id == record.id }) else { return false }
        records.append(record)
        if records.count == series.rounds.count { bestPoints = max(bestPoints ?? 0,points) }
        return true
    }

    mutating func startNewRun() { records.removeAll() }
}

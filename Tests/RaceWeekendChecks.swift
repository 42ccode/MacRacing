import Foundation

@main struct RaceWeekendChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ title: String) {
        print("\(condition ? "PASS" : "FAIL")  \(title)")
        if !condition { failures += 1 }
    }

    static func result(_ series: CupSeries, _ roundIndex: Int,place: Int?,assisted: Bool = false,lapsDown: Int = 0) -> RaceRecord {
        let round = series.rounds[roundIndex]
        return RaceRecord(id:UUID(),date:Date(),vehicle:round.vehicle,circuit:round.circuit,
            wet:round.condition == .wet,configuration:round.configuration,
            completedLaps:place == nil ? 0 : round.configuration.laps-lapsDown,place:place,
            totalTime:place == nil ? nil : 145.25,bestLap:place == nil || round.configuration.laps-lapsDown < 2 ? nil : 65.82,
            penaltySeconds:0,assisted:assisted,cup:CupEntry(series:series,roundIndex:roundIndex),
            lappedFinish:lapsDown > 0 ? true : nil)
    }

    static func liveGaps() {
        func advance(_ race: inout SprintRace,_ first: Double,_ second: Double,outside: [Bool]? = nil) {
            let locations = [first,second].map {
                TrackLocation(point:.zero,tangent:.zero,progress:$0,lateral:0,distance:0,segment:0)
            }
            race.step(1,locations:locations,assisted:false,width:12,outside:outside)
        }
        var split = SprintRace(lapCount:8,positions:[0,10],trackLength:400)
        check(split.driverGapAhead == nil,"The grid has no displayed interval before green")
        split.advanceCountdown(3)
        advance(&split,90,108)
        check(split.driverGapAhead == .distance(18),"Before the player reaches a timing point the gap uses distance")
        advance(&split,106,210)
        let expected = 1+10.0/16-90.0/98
        var error = Double.infinity
        if case .timed(let measured) = split.driverGapAhead { error = abs(measured-expected) }
        check(error < 1e-10,"An exact within-step crossing compares the same checkpoint even when the rival reached the next one")
        let current = split.driverGapAhead
        advance(&split,146,260)
        check(split.driverGapAhead == current,"Between timing points the last measured time gap stays steady")

        var pass = SprintRace(lapCount:8,positions:[10,0],trackLength:400)
        pass.advanceCountdown(3)
        advance(&pass,112,106)
        advance(&pass,116,121)
        check(pass.driverGapAhead == .distance(5),"A pass between checkpoints updates the rival immediately and uses distance until comparable timing")

        var invalid = SprintRace(lapCount:8,positions:[0,10],trackLength:400)
        invalid.advanceCountdown(3)
        advance(&invalid,90,108,outside:[false,true])
        advance(&invalid,106,210)
        check(invalid.driverGapAhead == .distance(104),"An off-track checkpoint crossing cannot be used as a timing reference")

        var lapped = SprintRace(lapCount:8,positions:[10,20],trackLength:400)
        lapped.advanceCountdown(3)
        for station in [120.0,220,320,20] { advance(&lapped,10,station) }
        check(lapped.driverGapAhead == .laps(1),"A physically complete lap of separation is shown as a lap deficit")
    }

    static func main() throws {
        liveGaps()
        var setup = RaceConfiguration(laps:999,rivals:-2,difficulty:.pro,startAtFront:true)
        setup.validate()
        let planned = TyreSetup(compound:.soft,coldPressure:1.8)
        let wet = setup.fittedTyres(from:planned,on:.wet)
        check(setup.laps == 2 && setup.rivals == 1 && setup.gridSlot == 0 &&
              wet.compound == .wet && wet.coldPressure == planned.coldPressure && planned.compound == .soft,
              "Race configuration validates the grid and fits weather tyres without changing garage pressure")
        setup.matchTyresToWeather = false
        check(setup.fittedTyres(from:planned,on:.wet) == planned,"Garage tyre override applies to wet races")

        let series = CupSeries.club
        let first = result(series,0,place:1)
        var progress = CupProgress()
        check(!progress.recordRound(result(series,1,place:2),for:series) &&
              !progress.recordRound(result(series,0,place:1,assisted:true),for:series),
              "Cup progression rejects out-of-order and auto-driven rounds")
        check(progress.recordRound(first,for:series) && !progress.recordRound(first,for:series) &&
              progress.points == 10 && progress.bestPoints == nil,
              "An official round awards points once")
        check(progress.recordRound(result(series,1,place:2),for:series) &&
              progress.recordRound(result(series,2,place:1),for:series) && progress.bestPoints == 27 &&
              CupMedal(points:progress.points) == .gold,
              "Final cup points award the correct medal")
        progress.startNewRun()
        check(progress.records.isEmpty && progress.points == 0 && progress.bestPoints == 27,
              "A fresh cup retains the best completed total")
        check(progress.recordRound(result(series,0,place:nil),for:series) && progress.points == 0 &&
              progress.records.count == 1,"A confirmed retirement is an official zero-point round")
        let data = try JSONEncoder().encode(progress)
        var restored = try JSONDecoder().decode(CupProgress.self,from:data)
        restored.validate(for:series)
        check(restored == progress,"Cup results and best score survive a JSON round trip")
        restored.validate(for:.rain)
        check(restored.records.isEmpty,"A saved round cannot award points in another series")
        var lapped = result(series,0,place:4,lapsDown:1)
        lapped.lapHistory = [RaceLap(time:145.25,clean:true)]
        var incomplete = lapped
        incomplete.lappedFinish = nil
        var anotherAttempt = CupProgress()
        let lapDownReload = try JSONDecoder().decode(RaceRecord.self,from:JSONEncoder().encode(lapped))
        check(lapDownReload == lapped && lapDownReload.completedLaps == 1 && !incomplete.isValid &&
              anotherAttempt.recordRound(lapDownReload,for:series) && anotherAttempt.points == 3,
              "A credited finish one lap down remains a scored arrival after reload")
        var corruptLaps = lapped
        corruptLaps.lapHistory = [RaceLap(time:62,clean:true),RaceLap(time:83.25,clean:false)]
        check(!corruptLaps.isValid && first.lapHistory == nil && first.isValid,
              "Lap history validates against saved distance and older race records load without it")

        var archivedJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(first)) as! [String:Any]
        archivedJSON["vehicle"] = 4
        let archived = try JSONDecoder().decode(RaceRecord.self,from:JSONSerialization.data(withJSONObject:archivedJSON))
        let reencoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(archived)) as! [String:Any]
        check(archived.$vehicle == 4 && archived.recordedVehicleLabel == "已退役车型" &&
              archived.isValid && reencoded["vehicle"] as? Int == 4,
              "History preserves a retired car's original identifier and a readable label")

        let duplicates = [first,first]+(0..<30).map { _ in result(series,0,place:1) }
        let history = RaceRecord.recent(duplicates)
        check(history.count == RaceRecord.historyLimit && Set(history.map(\.id)).count == history.count &&
              history.first == first,"Race history keeps the newest unique records within its storage limit")
        if failures > 0 { exit(1) }
    }
}

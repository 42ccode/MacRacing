import Foundation
import simd
@main struct TrainingChecks {
    static var failures=0
    static func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL")  \(name)");if !value {failures += 1}}
    static func tick(_ session:inout RaceSession,progress:Double,speed:Double=20,dt:Double=0.1,off:Bool=false) {
        var car=Vehicle();car.position=SIMD2(progress,0);car.velocity=SIMD2(speed,0)
        let loc=TrackLocation(point:car.position,tangent:SIMD2(1,0),progress:progress,lateral:0,distance:off ? 20 : 0,segment:0)
        _ = session.step(dt,vehicle:car,location:loc,trackLength:1200,trackWidth:12)
    }
    static func lap(speed:Double=20,dt:Double=0.1,off:Bool=false,record:LapRecord?=nil) -> RaceSession {
        var session=RaceSession();session.restore(record);session.resetLap(at:0)
        for i in 1...20000 {
            let distance=Double(i)*dt*speed,progress=distance.truncatingRemainder(dividingBy:1200)
            tick(&session,progress:progress,speed:speed,dt:dt,off:off && progress>400 && progress<420)
            if session.completedLaps>0 {break}
        }
        return session
    }
    static func main() throws {
        let reference=lap();guard let record=reference.record else {fatalError("Missing reference")}
        check(abs(record.time-60)<0.001,"Constant-speed lap completes in 60 seconds")
        check(record.sectors.count==3 && record.sectors.allSatisfy {abs($0-20)<0.001},"Three sector crossings interpolate to 20 seconds each")
        check(abs(record.sectors.reduce(0,+)-record.time)<0.001,"Sector durations sum to the completed lap")
        check(reference.lastValid && reference.newBest,"Valid lap updates personal best and completion status")
        let irregular=lap(speed:21,dt:0.37)
        check(abs((irregular.best ?? 0)-1200/21)<0.001,"Finish timing interpolates within a non-aligned simulation step")
        check(irregular.lastSectors.allSatisfy {abs($0-400/21)<0.001},"Sector timing interpolates within non-aligned steps")
        for (speed,expected) in [(24.0,-5.0),(15.0,10.0),(20.0,0.0)] {
            var current=RaceSession();current.restore(record);current.resetLap(at:0)
            let steps=Int(600/speed/0.1)
            for i in 1...steps {tick(&current,progress:Double(i)*speed*0.1,speed:speed)}
            check(abs((current.delta ?? 999)-expected)<0.001,"Distance-matched delta at half lap: \(expected) seconds")
        }
        let invalid=lap(off:true,record:record)
        check(!invalid.lastValid && invalid.best==record.time && !invalid.newBest,"Off-track lap cannot replace an existing best")
        check(invalid.record?.trace.count==record.trace.count,"Invalid lap preserves the saved reference trace")
        var wrong=RaceSession();wrong.restore(record);wrong.resetLap(at:0)
        for i in 1...50 {tick(&wrong,progress:Double(i)*2)}
        for i in 1...10 {tick(&wrong,progress:100-Double(i)*2,speed:-20)}
        check(!wrong.validLap && wrong.invalidReason=="逆向行驶" && wrong.delta==nil,"Sustained reverse driving invalidates lap and suppresses delta")
        var recovery=RaceSession();recovery.restore(record);recovery.resetLap(at:700)
        tick(&recovery,progress:710)
        check(recovery.waitingForStart && recovery.elapsed==0 && recovery.delta==nil,"Recovery away from start waits for a fresh timing lap")
        tick(&recovery,progress:1199);tick(&recovery,progress:1)
        check(!recovery.waitingForStart && recovery.checkpoint==0 && recovery.elapsed<0.1,"Returning across start begins a clean flying lap")
        var skip=RaceSession();skip.resetLap(at:0);tick(&skip,progress:2);tick(&skip,progress:500)
        check(!skip.validLap && skip.delta==nil,"Jumping ahead cannot manufacture a valid lap")
        var noReference=RaceSession();noReference.resetLap(at:0);tick(&noReference,progress:2)
        check(noReference.delta==nil,"No reference displays no invented delta")
        let decoded=try JSONDecoder().decode(LapRecord.self,from:JSONEncoder().encode(record))
        check(decoded.isValid && decoded.time==record.time,"Best lap survives JSON serialization")
        let corrupt=LapRecord(time:record.time,sectors:record.sectors,trace:[record.trace[0],record.trace[0]],ghost:record.ghost)
        check(!corrupt.isValid,"Non-monotonic or incomplete reference traces are rejected")
        let badSectors=LapRecord(time:record.time,sectors:[1,2,3],trace:record.trace,ghost:record.ghost)
        check(!badSectors.isValid,"Inconsistent sector totals are rejected")
        var badGhost=record.ghost;badGhost[1]=badGhost[0]
        check(!LapRecord(time:record.time,sectors:record.sectors,trace:record.trace,ghost:badGhost).isValid,"Duplicate ghost timestamps are rejected")
        let keys=VehicleKind.allCases.flatMap { car in CircuitKind.allCases.map {LapRecord.key(vehicle:car,circuit:$0)} }
        check(Set(keys).count==keys.count,"All vehicle and circuit record keys are distinct")
        check(reference.ghost(at:30) != nil && reference.ghost(at:61)==nil,"Restored ghost interpolation stays within recorded lap duration")
        if failures>0 {exit(1)}
    }
}

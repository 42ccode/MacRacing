import Foundation
@main struct InputHistoryChecks {
    static var failures=0
    static func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL")  \(name)");if !value {failures += 1}}
    static func main() {
        var keyboard = KeyboardPedals()
        keyboard.update(throttle:false,brake:true,dt:1/30)
        check((0.23...0.27).contains(keyboard.brake), "A keyboard brake tap produces partial travel")
        for _ in 0..<16 { keyboard.update(throttle:true,brake:true,dt:1/120) }
        check(keyboard.brake == 1 && keyboard.throttle == 0, "Holding the keyboard brake reaches full braking and takes priority")
        for _ in 0..<7 { keyboard.update(throttle:false,brake:false,dt:1/120) }
        check(keyboard.brake == 0 && keyboard.throttle == 0, "Keyboard pedals clear within one short release")
        var history=InputHistory()
        for _ in 0..<3600 {history.update(input:DrivingInput(throttle:0.31,brake:0.72),absActive:true,dt:1/60,active:true)}
        check(history.samples.count<=302,"A minute of driving retains only the five-second input window")
        check(abs(history.time-60)<0.0001 && abs((history.samples.first?.time ?? 0)-55)<0.02,"History uses elapsed time instead of stretching samples to the chart width")
        let now=history.time, count=history.samples.count
        for _ in 0..<120 {history.update(input:DrivingInput(),absActive:false,dt:1/60,active:false)}
        check(history.time==now && history.samples.count==count,"Pause and service freeze the input timeline")
        check(history.samples.last?.throttle==0.31 && history.samples.last?.brake==0.72 && history.samples.last?.absActive==true,"Simultaneous pedal input is preserved alongside independent ABS indication")
        history.update(input:DrivingInput(),absActive:false,dt:1/60,active:true)
        check(history.samples.last?.throttle==0 && history.samples.last?.brake==0,"Pedal release reaches zero without smoothing or a held peak")
        history.update(input:DrivingInput(brake:0.5),absActive:true,dt:1/120,active:true,linePressure:0.18)
        check(history.samples.last?.brake == 0.5 && history.samples.last?.linePressure == 0.18,
              "Pedal history retains actual pressure independently from trigger travel")
        history.reset()
        check(history.samples.isEmpty && history.time==0,"Recovery, restart and vehicle changes can clear previous history")
        history.update(input:DrivingInput(throttle:.nan,brake:2),absActive:false,dt:1/60,active:true)
        check(history.samples.last?.throttle==0 && history.samples.last?.brake==1,"Invalid and out-of-range input cannot corrupt graph coordinates")
        let before=history.time
        for dt in [Double.nan,Double.infinity,0,-1] {history.update(input:DrivingInput(),absActive:false,dt:dt,active:true)}
        check(history.time==before && history.samples.count==1,"Invalid time steps do not advance the history")
        var slow=InputHistory(), fast=InputHistory()
        for _ in 0..<180 {slow.update(input:DrivingInput(throttle:1),absActive:false,dt:1/30,active:true)}
        for _ in 0..<360 {fast.update(input:DrivingInput(throttle:1),absActive:false,dt:1/60,active:true)}
        check(abs(slow.time-fast.time)<0.0001,"30 and 60 Hz produce the same visible time scale")
        for _ in 0..<10000 {history.update(input:DrivingInput(),absActive:false,dt:0.0001,active:true)}
        check(history.samples.count<=InputHistory.capacity,"Unexpectedly high sampling rates remain memory bounded")
        var pad = ControllerSamples()
        for i in 0..<360 {
            pad.update(raw:DrivingInput(),deadzone:0.08,at:Double(i)/120)
        }
        check(abs((pad.pollHz ?? 0)-120) < 0.01 && abs((pad.p95Milliseconds ?? 0)-1000/120) < 0.01 &&
              pad.distinctChanges == 0 && !pad.isChanging && pad.samples.count <= 303,
              "Stable controller state still measures the game's cadence independently of value changes")
        pad.update(raw:DrivingInput(throttle:2,brake:.nan,steering:-0.09),deadzone:0.08,at:3)
        let reading = pad.reading
        check(reading?.raw.throttle == 1 && reading?.raw.brake == 0 && (reading?.mappedSteering ?? 1) < 0 &&
              abs(reading?.mappedSteering ?? 1) < 0.005 && pad.isChanging && pad.distinctChanges == 1,
              "Raw pedal and axis values remain distinct from the eased steering sent to the game")
        pad.update(raw:DrivingInput(steering:1),deadzone:0.08,at:2)
        check(pad.reading?.time == 3 && ControllerCalibration.steering(-1,deadzone:0.30) == -1 &&
              ControllerCalibration.steering(0.05,deadzone:0.08) == 0,
              "Out-of-order samples are dropped while full steering travel and deadzone are preserved")
        pad.reset()
        check(pad.samples.isEmpty && pad.reading == nil && pad.pollHz == nil && pad.distinctChanges == 0,
              "A disconnected controller clears diagnostic state")
        for i in 0..<81 {
            pad.update(raw:DrivingInput(),deadzone:0.08,at:Double(i)/120,systemEvent:10+Double(i/2)/60)
        }
        check(abs((pad.systemEventMedianMilliseconds ?? 0)-1000/60) < 0.01 &&
              abs((pad.pollHz ?? 0)-120) < 0.01 && pad.distinctChanges == 0,
              "Repeated reads at 120 Hz do not duplicate distinct 60 Hz macOS event timestamps")
        pad.update(raw:DrivingInput(),deadzone:0.08,at:0.7,systemEvent:Double.nan)
        pad.update(raw:DrivingInput(),deadzone:0.08,at:0.8,systemEvent:9)
        check(abs((pad.systemEventMedianMilliseconds ?? 0)-1000/60) < 0.01,
              "Unavailable or older system timestamps do not affect event timing")
        for i in 0..<80 {
            pad.update(raw:DrivingInput(),deadzone:0.08,at:1+Double(i)/120,systemEvent:12+Double(i/3)/40)
        }
        check(abs((pad.systemEventMedianMilliseconds ?? 0)-25) < 0.01,
              "Idle time between input bursts is excluded from the next event cadence")
        pad.reset()
        check(pad.systemEventMedianMilliseconds == nil,"Reset clears timing from the previous controller")
        if failures>0 {exit(1)}
    }
}

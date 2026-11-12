import Foundation
@main struct InputHistoryChecks {
    static var failures=0
    static func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL")  \(name)");if !value {failures += 1}}
    static func main() {
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
        check(history.samples.count<=602,"Unexpectedly high sampling rates remain memory bounded")
        if failures>0 {exit(1)}
    }
}

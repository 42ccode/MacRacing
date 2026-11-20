import Foundation
import simd

@main struct RaceReplayChecks {
    static var failures = 0

    static func check(_ result: Bool,_ message: String) {
        print("\(result ? "PASS" : "FAIL")  \(message)")
        if !result { failures += 1 }
    }

    static func rollingWindow() {
        var replay = RaceReplay(), car = Vehicle()
        check(!replay.hasFootage && replay.frame(at:0) == nil && replay.startTime == nil && replay.endTime == nil,
              "A new replay has no available frames")
        var captures = 0
        func rivals() -> [Vehicle] { captures += 1; return [] }
        for tick in 0...(240*120) {
            let time = Double(tick)/240
            car.position.x = time*10
            replay.record(time:time,player:car,rivals:rivals())
        }
        check(captures == 2401 && replay.sampleCount == 1802 && replay.duration == 90 && replay.hasFootage,
              "Two simulated minutes record at 20 Hz and retain only the last 90 seconds")
        car.position.x = 1200.27
        replay.record(time:120.027,player:car,rivals:rivals(),final:true)
        let first = replay.frame(at:0)
        let last = replay.frame(at:160)
        check(abs((first?.time ?? 0)-30.027) < 1e-9 && abs((first?.player.position.x ?? 0)-300.27) < 1e-6 &&
              last?.time == 120.027 && last?.player.position.x == 1200.27,
              "Scrubbing clamps to both endpoints and interpolates the exact rolling window edge")
        let sampled = replay.frame(at:110.023)
        check(abs((sampled?.player.position.x ?? 0)-1100.23) < 1e-6,
              "Wrapped storage indexes the correct pair of frames")
        replay.record(time:120.027,player:car,rivals:rivals(),final:true)
        replay.record(time:60,player:car,rivals:rivals(),final:true)
        replay.record(time:.nan,player:car,rivals:rivals(),final:true)
        check(replay.sampleCount == 1802 && replay.endTime == 120.027 && captures == 2403 &&
              replay.frame(at:.nan) == nil,
              "A duplicate finish frame replaces the endpoint and invalid timestamps are ignored")
        replay.reset()
        car.position.x = -15
        replay.record(time:0,player:car,rivals:[])
        check(!replay.hasFootage && replay.sampleCount == 1 && replay.frame(at:900)?.player.position.x == -15 &&
              replay.endTime == 0,
              "Restart drops all previous positions and samples a fresh starting frame")
    }

    static func contactTiming() {
        var replay = RaceReplay()
        let side = ContactSound(closingSpeed:8,position:SIMD2(16,-3))
        let nose = ContactSound(closingSpeed:13,position:SIMD2(23,10))
        replay.record(time:0,player:Vehicle(),rivals:[])
        replay.recordContact(side,at:0.0125)
        replay.recordContact(nose,at:0.8125)
        replay.recordContact(side,at:0.8125)
        replay.recordContact(ContactSound(closingSpeed:.nan,position:.zero),at:1)
        var played: [ContactSound] = []
        replay.playContacts(after:0,through:0.0125) { played.append($0) }
        replay.playContacts(after:0.0125,through:0.8125) { played.append($0) }
        replay.playContacts(after:0.9,through:0.2) { played.append($0) }
        check(played == [side,nose],"Sub-frame contacts retain world coordinates and occur once when normal playback crosses each timestamp")
        replay.record(time:90.2,player:Vehicle(),rivals:[])
        played.removeAll()
        replay.playContacts(after:0,through:91) { played.append($0) }
        check(played == [nose],"Contact playback expires along with footage at the rolling window boundary")
        replay.reset()
        played.removeAll()
        replay.playContacts(after:0,through:1) { played.append($0) }
        check(played.isEmpty,"A rematch starts with an empty contact timeline")
    }

    static func vehiclePoses() {
        var replay = RaceReplay()
        var player = Vehicle()
        player.kind = .centenario
        player.heading = 1.99 * .pi
        player.wheels[0].rotation = 2 * .pi - 0.02
        player.wheels[1].normalLoad = 1400
        player.rpm = 2000
        var cars = [Vehicle(),Vehicle(),Vehicle(),Vehicle()]
        for index in cars.indices { cars[index].position.x = Double(index+1)*8 }
        replay.record(time:0,player:player,rivals:cars)
        player.applyReplayPose(VehicleRenderSample(kind:.centenario,position:SIMD2(8,4),velocity:SIMD2(10,20),
            heading:0.01 * .pi,attitude:SIMD3(0.08,0.06,0.04),steering:0.18,rearSteering:-0.03,
            roadElevation:12,wheelRotations:SIMD4(0.02,0,0,0),wheelHeights:SIMD4(0.01,0.04,0,0)),
            hasElevation:true,braking:true,spray:SIMD4(0,0.2,0.4,0.8))
        player.wheels[1].normalLoad = 2600
        player.wheels[2].punctured = true
        player.gear = 3
        player.rpm = 2400
        player.damage.front = 0.35
        cars[0].position.x = 12
        cars[1].position.x = 18
        cars[2].position.x = 34
        replay.record(time:0.05,player:player,rivals:cars)
        guard let middle = replay.frame(at:0.025), let earlier = replay.frame(at:0.02) else {
            check(false,"Replay exports a displayable interpolated frame")
            return
        }
        let car = middle.player
        check(car.kind == .centenario && car.position == SIMD2(4,2) && car.velocity == SIMD2(5,10) &&
              abs(sin(car.heading)) < 1e-9 && cos(car.heading) > 0 &&
              abs(car.roll-0.03) < 1e-9 && abs(car.steeringAngle-0.09) < 1e-9 &&
              abs(car.rearSteeringAngle+0.015) < 1e-9 && car.roadElevation == 6 &&
              abs(sin(car.wheels[0].rotation)) < 1e-9 && cos(car.wheels[0].rotation) > 0,
              "Replay follows the short heading seam and keeps body, steering and wheel phases continuous")
        check(!earlier.player.brakeLightsActive && car.brakeLightsActive && car.hasRoadElevationSample &&
              car.gear == 3 && car.rpm == 2200 && car.wheels[2].punctured &&
              abs(car.wheels[3].spray-0.4) < 1e-6 && car.wheels[1].normalLoad == 2000 &&
              abs(car.wheels[1].surfaceHeight-0.02) < 1e-9 && car.damage.front == 0.35,
              "Playback restores brake lamps, wet spray, wheel height and race damage")
        var road = middle.playerRoad
        check(road.spray == nil,"Replay keeps unpositioned road sound until it has a listener")
        road.placeSources(for:car,at:car.position,right:-car.modelX)
        let expectedSpray = sqrt((0.1*0.1 + 0.2*0.2 + 0.4*0.4)/4)
        check(abs((road.spray?.level ?? 0)-expectedSpray) < 1e-6 && (road.spray?.pan ?? 0) < 0,
              "Replay positions the same interpolated wet contact used by its wheel particles")
        check(middle.rivals.map { $0.position.x } == [10,17,29] && player.position == SIMD2(8,4),
              "Three rivals keep their slots and playback does not alter the live vehicle")
    }

    static func fastWheels() {
        var replay = RaceReplay(), car = Vehicle()
        car.kind = .centenario
        car.velocity = car.forward*64
        for wheel in car.wheels.indices {
            car.wheels[wheel].angularVelocity = 64/car.wheelRadius
            car.wheels[wheel].rotation = 0.35
        }
        replay.record(time:0,player:car,rivals:[])
        for _ in 0..<12 {
            car.step(1/240,input:DrivingInput(),assists:DrivingAssists(),roadDistance:0,roadWidth:12)
        }
        replay.record(time:0.05,player:car,rivals:[])
        let travelled = car.wheels[0].accumulatedRotation
        let heading = replay.frame(at:0.025)?.player.wheels[0].rotation ?? 0
        let expected = 0.35+travelled/2
        check(travelled > 2 * .pi && abs(sin(heading-expected)) < 1e-8 && cos(heading-expected) > 0.99,
              "A fast wheel preserves complete turns between sparse replay samples")
    }

    static func recordedRivalTyres() {
        for kind in VehicleKind.allCases {
            var rival = Vehicle()
            rival.kind = kind
            rival.velocity = rival.forward * 20
            rival.gear = 0
            for index in rival.wheels.indices { rival.wheels[index].angularVelocity = 20 / rival.wheelRadius }
            let parked = Vehicle()
            var tape = RaceReplay()
            tape.record(time:0,player:parked,rivals:[rival])
            rival.wheels[1].angularVelocity = 0
            rival.step(1/240,input:DrivingInput(),assists:DrivingAssists(automatic:false),roadDistance:0,roadWidth:12)
            let contact = TyreSound(vehicle:rival).distant
            tape.record(time:0.05,player:parked,rivals:[rival])
            let middle = tape.frame(at:0.025)?.rivalAudio.first?.tyres
            let last = tape.frame(at:0.05)?.rivalAudio.first?.tyres
            check(contact.level > 0.5 && abs((last?.level ?? 0)-contact.level) < 1e-9 &&
                  abs((middle?.level ?? 0)-contact.level/2) < 1e-9 &&
                  abs((middle?.across ?? 0)-contact.across) < 1e-9 && abs((middle?.rate ?? 0)-contact.rate) < 1e-9,
                  "\(kind.label) replay fades in sliding tyre power at its actual wheel with the recorded pitch")
        }
    }

    static func recordedSound() {
        var player = Vehicle()
        player.kind = .porsche
        player.gear = 2
        player.velocity = player.forward*20
        for index in player.wheels.indices { player.wheels[index].angularVelocity = 20/player.wheelRadius }
        for _ in 0..<60 {
            player.step(1/240,input:DrivingInput(throttle:0.6),assists:DrivingAssists(automatic:false),roadDistance:0,roadWidth:12)
        }
        var rival = player
        rival.kind = .centenario
        rival.rpm = 4900
        var replay = RaceReplay()
        let underPower = player.powertrainSound
        let openThrottle = player.engineThrottle
        replay.record(time:0,player:player,rivals:[rival])
        for _ in 0..<80 {
            player.step(1/240,input:DrivingInput(brake:0.8,steering:0.6),assists:DrivingAssists(automatic:false),roadDistance:0,roadWidth:12)
        }
        let lifted = player.powertrainSound
        rival.rpm = 5200
        replay.record(time:0.05,player:player,rivals:[rival])
        let midpoint = replay.frame(at:0.025)
        let expectedRPM = (underPower.shaftRPM+lifted.shaftRPM)/2
        check(underPower.driveLoad > 0.1 && lifted.overrun > 0 &&
              abs((midpoint?.playerAudio.powertrain.shaftRPM ?? 0)-expectedRPM) < 0.001 &&
              abs((midpoint?.playerAudio.powertrain.overrun ?? 0)-lifted.overrun/2) < 0.001 &&
              midpoint?.rivalAudio.first?.powertrain.shaftRPM == 5050,
              "Replay interpolates measured shaft load and overrun while keeping the rival motor in its slot")
        if let midpoint, let first = replay.frame(at:0), let last = replay.frame(at:0.05) {
            check(first.controls.brakeTravel == 0 && first.controls.linePressure == 0 &&
                  abs(Double(last.controls.linePressure)-player.brakeLinePressure) < 1e-6 &&
                  abs(Double(midpoint.controls.linePressure)-player.brakeLinePressure/2) < 1e-6 &&
                  abs(Double(midpoint.controls.brakeTravel)-0.4) < 1e-6 &&
                  abs(midpoint.playerAudio.throttle-(openThrottle+player.engineThrottle)/2) < 1e-6 &&
                  midpoint.controls.absActive == player.absActive,
                  "The replay exposes sampled brake travel and hydraulic pressure independently, with the matching throttle opening")
        } else { check(false,"Replay exposes pedal telemetry") }
        let before = replay.frame(at:0)?.playerRoad
        let after = replay.frame(at:0.05)?.playerRoad
        if let before, let after, let midpoint {
            var audio = midpoint.playerRoad
            let placements = audio.tyres.level
            audio.placeSources(for:midpoint.player,at:midpoint.player.position+SIMD2(11,0),right:SIMD2(1,0))
            let meanRolling = (before.rolling+after.rolling)/2
            check(abs(audio.rolling-meanRolling) < 1e-6 && after.tyreScrub > before.tyreScrub &&
                  audio.tyres.pan.max() < -0.5 && audio.tyres.level == placements,
                  "Recorded rolling and tread scrub keep their energy when heard at a different camera position")
        } else { check(false,"Replay exposes its interpolated physical road sounds") }

        var state = RacePlayback(interval:0...1)
        check(state.playsSound,"Normal playing speed enables race audio")
        state.rate = .double
        check(!state.playsSound,"Double-speed playback leaves the normal-time sound faded out")
        state.rate = .normal
        state.togglePlay()
        check(!state.playsSound,"Paused replay publishes silence")
        state.togglePlay()
        state.advance(1)
        check(!state.playsSound,"The replay endpoint stops audio with playback")
    }

    static func main() {
        rollingWindow()
        contactTiming()
        vehiclePoses()
        fastWheels()
        recordedSound()
        recordedRivalTyres()
        if failures > 0 { exit(1) }
    }
}

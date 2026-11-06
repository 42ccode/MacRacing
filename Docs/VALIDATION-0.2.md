# APEX Lab 0.2 validation

Date: 2026-11-04, Asia/Shanghai.

## Build

- Native arm64 macOS application built with local Xcode 27.2 / Swift 6.4.2 in Swift 5 language mode.
- Deployment target: macOS 14.
- No third-party runtime packages required.
- Resources included in the application bundle; no asset downloads occur at game runtime.

## Automated checks

`./test.sh`: **28 checks passed**.

- 22 dynamics, track and timing checks: rest stability, braking at rest, acceleration, automatic shifting, straight-line symmetry, stopping, turning direction and bounded integration, lower grass grip, gravity/static spring balance, acceleration and braking load transfer, non-negative wheel loads and finite temperatures, wheel lock without ABS, split-surface contact response, track length/projection/wrapping, timing formatting, ordered checkpoint gates, ghost recording and recovery reset state.
- 6 geometry/camera checks: preservation of fractional GLB matrices, steering-column transform, level horizon after repeated rotations, camera forward direction, four imported wheel bindings, neutralized authored steering-wheel pose.

These are numerical and regression checks. They do not establish agreement with a real vehicle or iRacing.

## Native-window observations

- Application launches to its entry screen and enters practice through the visible button.
- The imported body, doors and wheels retain their transforms after fixing numeric conversion in the GLB loader.
- Chase view shows the car driving along the road; keyboard throttle increases displayed speed.
- Keyboard throttle followed by braking returns the vehicle to rest.
- Cockpit view clears the headrest and windshield reflection obstruction.
- The new instrument texture displays live speed and gear, rather than the static zero-speed texture supplied with the model.
- The final inspected cockpit frame shows 21 km/h, first gear, a neutral steering wheel, a readable speed display and a clear road view.
- Keyboard turning changes vehicle direction without accumulating camera roll.
- Pause/resume and restart controls are exposed as native accessible buttons.

## Not verified

- Physical Xbox controller was not connected during validation. Hardware trigger mapping, Bluetooth/USB behavior, disconnect behavior and haptic output require a device test.
- No sustained frame-rate benchmark has been recorded. 60 FPS is a rendering target, not a measured result.
- No complete driving lap was manually performed. Lap logic was tested by ordered track traversal in the automated checks.
- Engine sound remains synthesized. No real engine recording is included.
- Handling parameters have not been calibrated against real-world data. No claim of iRacing-equivalent physics or graphics is made.

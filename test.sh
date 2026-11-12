#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build
module_cache="${TMPDIR:-/private/tmp}/apex-lab-swift-module-cache"
xcrun swiftc -O -module-cache-path "$module_cache" \
  Sources/Track.swift Sources/Vehicle.swift Tests/PhysicsChecks.swift -o .build/physics-checks
.build/physics-checks
xcrun swiftc -O -swift-version 5 -module-cache-path "$module_cache" \
  -framework AppKit -framework SceneKit Sources/Track.swift Sources/Vehicle.swift \
  Sources/GLTF.swift Sources/Environment.swift Sources/World.swift Tests/SceneChecks.swift -o .build/scene-checks
.build/scene-checks "$PWD/Assets"
xcrun swiftc -O -swift-version 5 -module-cache-path "$module_cache" -framework AVFoundation \
  Sources/Track.swift Sources/Vehicle.swift Sources/EngineSound.swift Tests/AudioChecks.swift -o .build/audio-checks
.build/audio-checks "$PWD/Assets/Audio/engine-recording.wav"

xcrun swiftc -O -module-cache-path "$module_cache" \
  Sources/Track.swift Sources/Vehicle.swift Sources/HapticFeedback.swift Tests/FeedbackChecks.swift -o .build/feedback-checks
.build/feedback-checks

xcrun swiftc -O -module-cache-path "$module_cache" \
  Sources/Track.swift Sources/Vehicle.swift Sources/InputHistory.swift Tests/InputHistoryChecks.swift -o .build/input-history-checks
.build/input-history-checks

xcrun swiftc -O -module-cache-path "$module_cache" \
  Sources/Track.swift Sources/Vehicle.swift Tests/TrainingChecks.swift -o .build/training-checks
.build/training-checks

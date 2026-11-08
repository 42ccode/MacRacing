#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

mkdir -p .build dist
module_cache="${TMPDIR:-/private/tmp}/apex-lab-swift-module-cache"
app_path="$PWD/dist/APEX Lab.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -module-cache-path "$module_cache" -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SceneKit -framework GameController \
  -framework CoreHaptics -framework AVFoundation \
  Sources/Track.swift Sources/Vehicle.swift Sources/GLTF.swift Sources/Environment.swift Sources/World.swift \
  Sources/Input.swift Sources/EngineSound.swift Sources/HUD.swift Sources/Game.swift Sources/main.swift \
  -o "$app_path/Contents/MacOS/APEXLab"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>APEXLab</string>
  <key>CFBundleIdentifier</key><string>studio.apexlab.firstdrive</string>
  <key>CFBundleName</key><string>APEX Lab</string>
  <key>CFBundleDisplayName</key><string>APEX Lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>11</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>APEX Lab — original driving prototype.</string>
</dict></plist>
PLIST

python3 Tools/copy_assets.py Assets "$app_path/Contents/Resources/Assets"
codesign --force --sign - "$app_path"
print "Built: $app_path"
if [[ "${1:-}" == "--run" ]]; then
  open "$app_path"
fi

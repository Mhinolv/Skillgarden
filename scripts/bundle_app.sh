#!/bin/zsh
# Build SkillgardenApp and wrap it in build/Skillgarden.app so it launches as a normal Mac app.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh --product SkillgardenApp
APP=build/Skillgarden.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/debug/SkillgardenApp" "$APP/Contents/MacOS/Skillgarden"
cp assets/AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Skillgarden</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.skillgarden.app</string>
<key>CFBundleName</key><string>Skillgarden</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$APP"

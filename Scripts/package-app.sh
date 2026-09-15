#!/bin/bash
# Packages the release build of Mikey as a minimal Mikey.app bundle and
# ad-hoc signs it.
#
# Info.plist carries the two entries the app cannot run without:
#   - LSUIElement=YES        → menu-bar agent: no Dock icon, not in Cmd-Tab
#   - NSMicrophoneUsageDescription → required for TCC mic permission
#
# Ad-hoc signing (`codesign --sign -`) is enough for a personal tool launched
# by its owner; note TCC may re-prompt for the mic when the binary changes,
# since an ad-hoc signature has no stable designated requirement.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Mikey.app"

swift build -c release --product Mikey
bin="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$bin/Mikey" "$APP/Contents/MacOS/Mikey"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Mikey</string>
    <key>CFBundleDisplayName</key>
    <string>Mikey</string>
    <key>CFBundleIdentifier</key>
    <string>com.bishesha.mikey</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Mikey</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mikey records microphone audio for your lectures.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Packaged $APP (release binary + Info.plist, ad-hoc signed)"

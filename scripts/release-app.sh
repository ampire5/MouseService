#!/usr/bin/env bash
# Reproducible packaging: universal macOS app, signed ad hoc (no local signing identity).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MouseService --arch arm64 --arch x86_64 -j 4
swift build -c release --product d100h-hid --arch arm64 --arch x86_64 -j 4
bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app=build/release/MouseService.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Library/LaunchDaemons"
cp "$bin_path/MouseService" "$app/Contents/MacOS/MouseService"
cp "$bin_path/d100h-hid" "$app/Contents/Helpers/d100h-hid"
cp Resources/local.mouseservice.d100h.plist "$app/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/Helpers/d100h-hid"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
archive="build/MouseService-v${version}-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive"

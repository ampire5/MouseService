#!/usr/bin/env bash
# Builds build/MouseService.app (release). Usage: scripts/make-app.sh [--install]   (--install puts it in ~/Applications
# and opens it, which registers the launchd agent anew with this build)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=build/MouseService.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Library/LaunchDaemons"
bin_path="$(swift build -c release --show-bin-path)"
cp "$bin_path/MouseService" "$app/Contents/MacOS/MouseService"
cp "$bin_path/d100h-hid" "$app/Contents/Helpers/d100h-hid"
cp Resources/local.mouseservice.d100h.plist "$app/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# The Accessibility permission is tied to the signature's designated requirement. With the local self-signed identity
# "Local Code Signing" (login keychain) that is the bundle ID and the certificate, the same for every build; ad hoc it
# is the build's own hash, and every new build must be allowed again.
if security find-identity -p codesigning | grep -q '"Local Code Signing"'; then
    identity="Local Code Signing"
else
    echo "warning: no \"Local Code Signing\" identity: signed ad hoc, Accessibility must be allowed again" >&2
    identity=-
fi
codesign --force --sign "$identity" "$app/Contents/Helpers/d100h-hid"
codesign --force --sign "$identity" "$app"
echo "Built $app"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    # The running agent (or a 0.1 copy) goes; the copy opened by hand writes ~/Library/LaunchAgents/local.mouseservice.plist,
    # loads it and quits; launchd then starts the agent.
    launchctl bootout "gui/$(id -u)/local.mouseservice" 2>/dev/null || pkill -x MouseService || true
    rm -rf "$HOME/Applications/MouseService.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/MouseService.app" || true   # `open` may report -600: the app is gone by then
    echo "Installed ~/Applications/MouseService.app"
fi

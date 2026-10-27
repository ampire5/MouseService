#!/usr/bin/env bash
# Builds build/MouseService.app (release). Usage: scripts/make-app.sh [--install]   (--install puts it in ~/Applications
# and restarts the launchd agent with it; the first time, it opens the app, which registers the agent)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=build/MouseService.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MouseService" "$app/Contents/MacOS/MouseService"
cp Resources/Info.plist "$app/Contents/Info.plist"
# The launchd agent (SMAppService.agent): login item, restart after a crash, the Mach service clients connect to.
mkdir -p "$app/Contents/Library/LaunchAgents"
cp Resources/local.mouseservice.plist "$app/Contents/Library/LaunchAgents/"
# The Accessibility permission is tied to the signature's designated requirement. With the local self-signed identity
# "Local Code Signing" (login keychain) that is the bundle ID and the certificate, the same for every build; ad hoc it
# is the build's own hash, and every new build must be allowed again.
if security find-identity -p codesigning | grep -q '"Local Code Signing"'; then
    codesign --force --sign "Local Code Signing" "$app"
else
    echo "warning: no \"Local Code Signing\" identity: signed ad hoc, Accessibility must be allowed again" >&2
    codesign --force --sign - "$app"
fi
echo "Built $app"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    agent="gui/$(id -u)/local.mouseservice"
    if launchctl print "$agent" >/dev/null 2>&1; then
        rm -rf "$HOME/Applications/MouseService.app"
        cp -R "$app" "$HOME/Applications/"
        launchctl kickstart -k "$agent"   # the running agent is replaced by the new build
    else
        pkill -x MouseService || true      # a 0.1 copy, not an agent yet
        rm -rf "$HOME/Applications/MouseService.app"
        cp -R "$app" "$HOME/Applications/"
        # Registers the agent and quits; `open` may report -600 as the app is gone by then.
        open "$HOME/Applications/MouseService.app" || true
    fi
    echo "Installed ~/Applications/MouseService.app"
fi

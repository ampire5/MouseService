#!/usr/bin/env bash
# Builds build/MouseService.app (release). Usage: scripts/make-app.sh [--install]   (--install puts it in ~/Applications,
# quits the running copy and opens the new one)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=build/MouseService.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MouseService" "$app/Contents/MacOS/MouseService"
cp Resources/Info.plist "$app/Contents/Info.plist"
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
    pkill -x MouseService || true
    rm -rf "$HOME/Applications/MouseService.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/MouseService.app"
    echo "Installed ~/Applications/MouseService.app"
fi

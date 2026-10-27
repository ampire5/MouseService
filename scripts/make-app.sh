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
# Ad hoc: the Accessibility permission is tied to the signature, so a new build must be allowed again.
codesign --force --sign - "$app"
echo "Built $app"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x MouseService || true
    rm -rf "$HOME/Applications/MouseService.app"
    cp -R "$app" "$HOME/Applications/"
    open "$HOME/Applications/MouseService.app"
    echo "Installed ~/Applications/MouseService.app"
fi

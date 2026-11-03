# MouseService

One owner of the mouse for the Mac. Apps connect to it instead of each driving the mouse themselves. The Logitech MX
Master 4 is handled over HID++ through [LogiHIDPP](https://github.com/ampire5/LogiHIDPP).

## What it does

- **The Logitech mouse for apps.** A menu-bar launchd agent owns the mouse. Apps are clients over a versioned XPC
  contract (`MouseClient`, `MouseContract`).
  - The app in front gets the buttons it diverts or watches, the thumb wheel and the haptics.
  - The wheel ratchets everywhere by default. The window under the pointer can ask for another mode (free spin or
    ratchet) and Precision Scroll, in the areas its app declares; outside them the wheel goes back to the global
    mode. The global mode is a setting, and the SmartShift button changes it where no app does.
  - A client that crashes releases everything at once. A service that crashes is restarted by launchd, and the
    clients come back.
  - The mouse's own settings (haptic strength, panel force) live in the service's Settings.
  - Design: `docs/superpowers/specs/2026-10-27-core-service-design.md`.
- **The side buttons as a trackpad.**
  - A click of back or forward is a page swipe.
  - Back held and dragged is a three-finger swipe that follows the hand: sideways between Spaces, up to Mission
    Control, down to App Exposé.
- **Pointer and wheel per device**, in `~/.config/mouseservice/config.yaml` (a device named once, its app rules nested;
  an old `devices.json` or LinearMouse's file is migrated into it at the first start): pointer speed and acceleration,
  a reversed wheel, scrolls dropped under a modifier. Design: `docs/superpowers/specs/2026-10-27-pointer-wheel-design.md`
  and `2026-10-28-yaml-config-design.md`.

Needs macOS 26 and the Accessibility permission (for the gestures and the scroll rules).

## Install with Homebrew

```sh
brew install --cask ampire5/tap/mouseservice
open /Applications/MouseService.app
```

The first launch registers the service for your login account; it starts automatically at login and restarts after a
crash. Allow **MouseService** in **System Settings → Privacy & Security → Accessibility** for gestures and scroll
rules. Do not run it with `sudo`. If you previously installed a build in `~/Applications`, quit it and remove that
old app first; opening the Homebrew copy registers the new location.

The app is signed ad hoc, without an Apple Developer ID. The cask removes its quarantine flag. After an upgrade,
macOS may require you to remove and re-add MouseService in Accessibility.

```sh
brew update
brew upgrade --cask mouseservice
open /Applications/MouseService.app  # restart the agent with the upgraded app
```

### Settings

Open **Settings…** from the MouseService menu. **Devices** lists connected devices and saved configurations:
choose a device, then adjust speed, acceleration, scroll reversal and the modifier keys that suppress scrolling.
Changes apply immediately. Trackpads keep their system sensitivity until you explicitly change it.

**Mouse** includes side-button gestures, haptic strength, panel force and wheel mode. The Gestures menu toggle
and Settings control stay synchronized. Accessibility permission is required for gestures and scroll rules.

**Import & Export** transfers device rules and service preferences in one JSON file. Each import validates the
whole file before making changes and saves the previous configuration and preferences beside `config.yaml` as
`config.yaml.before-import-<unique-id>.json`. The first UI edit also saves the original YAML as `config.yaml.before-ui`.
YAML formatting and comments may be normalized; device values, application rules and unknown fields are preserved.
Application rules remain supported in YAML but have no UI in this version.

### Default sensitivity

All mice start with pointer **speed 0.125** (0–1 scale) and **acceleration 0.225** (0–40 scale). Trackpads retain their
system settings. Device and app entries in `~/.config/mouseservice/config.yaml` override these values; existing
explicit settings are preserved. Scroll direction and modifier rules remain configurable separately.

For example, use **Edit Devices Config…** in the menu and add your device ID (shown in the device list):

```yaml
devices:
  Example mouse:
    id: 1234:5678
    speed: 0.2
    acceleration: 0.1
    # disable-acceleration: true
```

### Uninstall

```sh
brew uninstall --cask mouseservice
# To also remove saved preferences and device rules:
# brew uninstall --cask --zap mouseservice
```

Homebrew stops and unregisters the agent when removing the app. Normal uninstall keeps your settings.

## Build from source

```sh
swift test
scripts/make-app.sh --install    # ~/Applications/MouseService.app, then ~/Library/LaunchAgents/local.mouseservice.plist
```

Opening the app by hand writes and loads the LaunchAgent, then quits. From then on launchd runs it.

## A client

```swift
import MouseClient
import MouseContract

let mouse = MouseClient()                       // bundle ID from the app
mouse.onButton = { cid, pressed, time in … }    // HID++ control IDs, ProcessInfo.systemUptime
mouse.want(Want(divert: [0xC3]))                // the whole wish, sent again after every reconnect
mouse.start()
```

`swift run mouse-client-probe divert 0xC3` is a test client that prints every event with its latency.

## Private interfaces

The gestures use IOKit's `IOHIDEventCreate` and SkyLight's `SLEventSetIOHIDEvent`. The device rules use
`IOHIDEventSystemClientCreate`, `CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`. All are checked on macOS 27.0.1;
without them that part is off and the menu says so.

## License

GPL-3.0 (LICENSE).

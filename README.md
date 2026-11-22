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
  - Open the MouseService menu to see the MX Master 4's battery percentage and charging status over Logi Bolt.
  - Design: `docs/superpowers/specs/2026-10-27-core-service-design.md`.
- **The side buttons as a trackpad.**
  - A click of back or forward is a page swipe. Apps connected to MouseService receive the side-button click so they
    can use their own button bindings.
  - Hold the gesture button (Back by default) and drag sideways between Spaces, up to Mission Control, or down to
    App Exposé.
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

Open **Settings… → Pointer & Scrolling** from the MouseService menu. Choose a mouse to adjust its pointer profile,
speed, scroll reversal and the modifier keys that suppress scrolling. Settings are saved automatically. Trackpad rules
can be edited in `config.yaml`. A disconnected mouse appears in the picker when its saved entry has `category: mouse`.
Settings adds this field when you edit a connected mouse.

| Profile | Pointer response |
| --- | --- |
| **macOS** | Native curve with the existing acceleration slider and optional disable switch. |
| **Linear** | Constant gain at any movement speed. |
| **Windows EPP–style** | An approximation of Enhance Pointer Precision with lower gain for small movements and an earlier rise for fast movements. |
| **libinput Adaptive–style** | An approximation of the Linux adaptive profile with more deceleration at low speeds and a gradual rise in gain. |

Speed adjusts sensitivity in all four profiles. The Windows and libinput profiles use the macOS HID velocity
estimator, so their feel depends on mouse DPI and report rate.

**Buttons & Wheel** lets you control page swipes on click and system gestures on drag separately. Choose Back or
Forward as the gesture button and adjust the travel threshold. **Gesture Test** shows captured button events and
whether MouseService posted a gesture. Accessibility permission is required for gestures and scroll rules.

Under **Pointer & Scrolling → Application Rules**, choose an app for the selected mouse to edit its overrides. The
pointer and scrolling controls show inherited settings and let you remove individual overrides.

**Import & Export** transfers device rules and service preferences in one JSON file. Each import validates the
whole file before making changes and saves the previous configuration and preferences beside `config.yaml` as
`config.yaml.before-import-<unique-id>.json`. The first UI edit also saves the original YAML as `config.yaml.before-ui`.
YAML formatting and comments may be normalized; device values, application rules and unknown fields are preserved.

### Default sensitivity

All mice start with pointer **speed 0.125** (0–1 scale) and **acceleration 0.225** (0–40 scale). Trackpads retain their
system settings. Device and app entries in `~/.config/mouseservice/config.yaml` override these values; existing
explicit settings are preserved. Scroll direction and modifier rules remain configurable separately.

For example, use **Advanced → Edit Device Rules…** in the menu and add your device ID. Hover over the selected
mouse in **Pointer & Scrolling** to see its ID:

```yaml
devices:
  Example mouse:
    id: 1234:5678
    category: mouse
    speed: 0.2
    pointer-profile: windows-epp
    apps:
      com.example.Editor:
        pointer-profile: linear
```

Use `macos`, `linear`, `windows-epp` or `libinput-adaptive` for `pointer-profile`. The numeric
`acceleration` and `disable-acceleration` settings apply to the macOS profile.

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
mouse.onSwipe = { phase, time in … }             // .began, .ended, or .cancelled
mouse.want(Want(divert: [0xC3]))                // the whole wish, sent again after every reconnect
mouse.start()
```

`swift run mouse-client-probe divert 0xC3` is a test client that prints every event with its latency.
Set `onSwipe` before connecting. `receivesSwipeLifecycle` indicates that the service agreed to deliver swipe phases
over XPC, so a client can ignore the legacy `local.mouseservice.swipeBegan` notification while it is connected.

### Ulanzi D100H

`MouseClient.setD100HDetentsMuted(true)` temporarily disables the dial's physical detents while the client
is in front. Pass `false` when the player window loses focus within the app or when mute is no longer wanted.
MouseService also releases the override when the client leaves the foreground or disconnects. It records the
exact previous setting before writing, checks the device's reply, and retries recovery on reconnect if the
process or device disappeared during the override. This request acts independently of Logitech ownership.

To exercise the request with an updated MouseService agent, run `swift run mouse-client-probe --mute-d100h-detents`.
The probe window requests quiet while focused. Switch to another app or close the window to restore the dial's
setting. macOS may ask for Bluetooth permission for MouseService.

In a build signed with a certificate, choose **Enable D100H Auto-Start…** from the MouseService
menu and approve the background item in System Settings. If the manual reader is already running,
leave the player and stop that reader in its Terminal window. The per-user agent starts the
system daemon on demand. The daemon accepts requests only from MouseService signed by the
same certificate and running as the active console user. It releases the dial when that agent
goes away.

Give the installed reader Input Monitoring permission in **System Settings → Privacy & Security →
Input Monitoring**. Add `~/Applications/MouseService.app/Contents/Helpers/d100h-hid` to the list.
If the daemon was already running when you granted access, restart it once with
`sudo launchctl kickstart -k system/local.mouseservice.d100h`. The reader never opens other devices.

For an ad hoc build or while system approval is pending, start the bundled reader in the same
login session as MouseService:

```sh
sudo ~/Applications/MouseService.app/Contents/Helpers/d100h-hid --service
```

The reader captures just the D100H when a foreground client requests input. After exclusive capture,
MouseService saves both pressed-turn assignments and verifies the two replacements before forwarding input.
Leaving the profile cancels held gestures immediately. MouseService then restores and verifies the saved
assignments before telling the reader to release the device. If verification times out, MouseService
releases the capture and retains the original values in its recovery file for the next connection.
The reader needs administrator privileges because macOS requires them to seize this HID device.
Bluetooth permission belongs to MouseService. The manual reader has to be restarted if the agent exits.

To see the delivered events with a local build, keep the managed reader running and focus
`swift run mouse-client-probe --d100h-input` in a separate terminal.

## Private interfaces

Dock swipes use CoreGraphics event fields on macOS 26. On macOS 27, they use IOKit's `IOHIDEventCreate` and
SkyLight's `SLEventSetIOHIDEvent`. The device rules use
`IOHIDEventSystemClientCreate`, `CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`. All are checked on macOS 27.0.1;
without them that part is off and the menu says so.

## License

GPL-3.0 (LICENSE).

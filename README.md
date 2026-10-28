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

## Build and install

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

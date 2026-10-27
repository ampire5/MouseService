# MouseService

One owner of the mouse for the Mac: apps connect to it instead of each driving the mouse themselves. Design of the
core: `docs/superpowers/specs/2026-10-27-core-service-design.md`.

Now (0.1): the side buttons as a trackpad, replacing Mac Mouse Fix's set-up — a click of back or forward is a page
swipe; back held and dragged is a three-finger swipe that follows the hand: sideways between Spaces, up to Mission
Control, down to App Exposé. Needs the Accessibility permission.

```sh
swift test
scripts/make-app.sh --install    # ~/Applications/MouseService.app
```

The gestures use private interfaces (IOKit's `IOHIDEventCreate`, SkyLight's `SLEventSetIOHIDEvent`), checked on macOS
27.0.1; without them the gestures are off and the menu says so.

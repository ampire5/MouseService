# Pointer and wheel options: LinearMouse replaced

Date: 2026-10-27. Status: being implemented. This is sub-project 4 of the core spec, brought ahead of the core
(`2026-10-27-core-service-design.md`) at the user's request: one program less now.

## What is replaced

This is the user's LinearMouse 0.13 configuration (`~/.config/linearmouse/linearmouse.json`) as it is used today.
The mouse in use is the MX Master 4 on the Bolt receiver (`0x46d:0xc548`). For it LinearMouse does three things:

- **Pointer speed and acceleration.** It sets the device's own HID properties: `HIDPointerResolution` comes from the
  speed, and the property named by `HIDPointerAccelerationType` (here `HIDMouseAcceleration`) gets the
  acceleration. Measured 2026-10-27: resolution 259.5 (speed 0.125) and acceleration 0.225.
- **Reversed vertical scrolling** on the mouse only. The trackpad keeps natural scrolling.
- **Horizontal scrolling dropped while ⌘ or ⌃ is held** (`modifiers.horizontal.command/control: preventDefault`).

Its trackpad rules hold the system's defaults (resolution 400, acceleration 0.875) and change nothing. Rules for
devices that are not connected (Keychron, Microsoft, older Logitech, MX Master 3S) come along with the import and
cost nothing until their device appears.

## Decisions

| Question | Decision |
|---|---|
| Where the rules live | `~/.config/mouseservice/devices.json`. The format is a subset of LinearMouse's: `schemes`, each with an `if` (`device`: `vendorID`, `productID`, `productName`, `serialNumber`, `category`; `app`) and the fields below. On first start, when the file is missing, LinearMouse's file is imported once. No settings UI for now: the user edits text configs (as with `framescrub.conf`). |
| Fields read | `pointer.speed` (0…1), `pointer.acceleration` (0…40), `pointer.disableAcceleration`; `scrolling.reverse` (a Bool or `{vertical, horizontal}`); `scrolling.modifiers.{vertical,horizontal}.{command,shift,option,control}.type == "preventDefault"`. Every other field is ignored; the number of ignored fields is logged. |
| Merging | As in LinearMouse: the schemes whose `if` match are applied in file order, later fields over earlier ones. |
| `app` condition | The frontmost app's bundle ID, for both pointer and scrolling. LinearMouse uses the app under the pointer for scrolling; the only scroll rules with an `app` belong to devices that are not connected. Revisit when the core service follows the pointer anyway. |
| Pointer properties | They are written through a client made by `IOHIDEventSystemClientCreate`, which is private and found with dlsym (the public simple client cannot read these properties, checked 2026-10-27), and the public `IOHIDServiceClient` functions, as LinearMouse's PointerKit does. Speed s maps to resolution `1 / (1/1200 + s·(1/40 − 1/1200))`. Acceleration is written to the key named by `HIDPointerAccelerationType`, or `HIDMouseAcceleration` when there is none, as an IOFixed number. The values a device had when first seen are kept and written back when no rule covers it any more and when the service quits. |
| Device appearance | IOKit matching notifications on `IOHIDEventService` (public, no permission). Each one gives a rescan of the event system's services, again 1 s later, because the event system lists a new service a moment after IOKit does. No polling. |
| Which device a scroll came from | `IOHIDEventGetSenderID(CGEventCopyIOHIDEvent(event))` is the service's registry ID. An event without one (synthetic) passes untouched. |
| Scroll transform | A tap on its own thread at `.userInteractive` (as `SideButtonTap`). Reversal negates all four forms of each delta: integer, fixed-point, point and the IOHIDEvent's scroll value, as LinearMouse does. A dropped event returns nil. The tap reads an immutable snapshot of the rules, swapped under a lock when the rules, the devices or the frontmost app change. |
| Category | A service conforming to digitizer/touch pad (`0x0D`/`0x05`) is a `trackpad`; any other conforming to generic desktop/mouse (`0x01`/`0x02`) is a `mouse`. Only these are touched. |

## Units

- `PointerCore` (pure, tested):
  - the rule model and its parser;
  - matching and merging (device identity, app → resolved settings);
  - the mapping from speed to resolution;
  - the scroll decision (pass, reverse X/Y, drop) for given deltas and modifier flags;
  - the import from LinearMouse.
- `CHIDSPI`: C declarations of the IOKit and CoreGraphics functions not in the SDK headers.
- `PointerSettings` (app, main actor):
  - the device list and the original values;
  - writes the resolved pointer settings;
  - publishes the scroll snapshot;
  - watches the config file and reloads it.
- `ScrollTap` (app, own thread): applies the snapshot to every scroll event.
- Menu:
  - the line "Devices: N rules, M devices matched";
  - "Edit Devices Config…", which opens the file;
  - "Reload Devices Config".

## Order of switching

LinearMouse and MouseService must not both reverse the wheel, or the two reversals cancel. The new build imports the
config, the user quits LinearMouse and removes it from the login items, and MouseService takes over. LinearMouse
gives the pointer properties back when it quits, so MouseService captures the true originals.

## Testing

- Unit tests:
  - parsing the user's real file, a copy of which is kept as a fixture;
  - merging (base scheme plus app scheme), the `if` fields, the speed mapping round trip against the measured
    259.5;
  - the scroll decision for each modifier and axis;
  - the import, which drops unknown fields.
- By hand:
  - the pointer feels as before (resolution 259.5 and acceleration 0.225, read back with the probe);
  - the wheel is reversed and the trackpad is not;
  - ⌘ plus the thumb wheel does nothing;
  - EdgeView's own pointer speed takes over when it is in front.

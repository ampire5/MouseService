# MouseService core: one owner of the mouse, apps as clients

Date: 2026-10-27. Status: design, not implemented. Name of the app and repository: working name (`MouseService`), to be
chosen.

## Problem

FrameScrub and Loupe each talk HID++ to the Logitech mouse themselves (`LogiHIDPP`, one `LogiMouse` per process). The
mouse has one set of diverts, one wheel mode and one haptic strength, so the processes take them from each other:
`LogiHIDPP` re-applies 300 ms after activation because the other app's release may arrive late, keeps a marker per app
in its `UserDefaults`, claims a software ID per process, and documents that another app can switch a watch off. Each
app also writes device settings (haptic strength, panel force) from its own config, so they overwrite each other.
A crashed app leaves the mouse in its state until it is relaunched.

Around it, three more tools touch the mouse: Mac Mouse Fix (back + drag for Spaces and Mission Control), LinearMouse
(linear pointer, inverted wheel), BetterTouchTool. Each is its own owner of buttons and wheel.

## Goal of the whole project

One service that alone owns the mouse; apps (ours and other developers') connect to it by a contract. Sub-projects,
each with its own spec, plan and implementation, in this order:

1. **Core service and contract** (this spec): the service, arbitration, recovery, client package; FrameScrub and Loupe
   move to it with their behaviour unchanged.
2. **Gestures**: back + drag → Mission Control, App Exposé, Spaces as on a trackpad; later more gestures and the wheel's
   touch sensor. Replaces Mac Mouse Fix.
3. **Global Precision Scroll ↔ ratchet**: one link between Precision Scroll and the free-spinning wheel in every app,
   rules per app.
4. **Global pointer and wheel options**: linear pointer movement, inverted wheel. Replaces LinearMouse.
5. **Public SDK**: the stable contract documented, the `Info.plist` declaration level for sandboxed apps, an example,
   distribution.

## Decisions

| Question | Decision |
|---|---|
| No service running | The app has no Logitech features (an ordinary mouse) and its settings say to install the service. No in-app fallback to `LogiHIDPP`: one code path, no conflicts. |
| Contract levels | Two: full XPC for apps outside the sandbox (this spec), a declaration in `Info.plist` for sandboxed apps (sub-project 5). |
| Who owns what | Buttons, haptics and thumb wheel: the frontmost app. Main wheel modes (Precision Scroll, ratchet): the window under the pointer, as scroll events themselves. |
| Device settings | The service's only (haptic strength, panel force). A client asks for a one-off strong play, never writes the setting. |
| Shape of the service | One menu-bar app that is also the agent: a plain LaunchAgent in `~/Library/LaunchAgents` written by the app when opened by hand (`SMAppService` pins the binary's cdhash without a Team ID and refuses every rebuild), a Mach service, settings window on SettingsKit. |
| Transport | Low-level XPC, dictionaries with a versioned schema (not `NSXPCConnection`): any language can be a client; new fields do not break old clients. A Swift client package hides the dictionaries. |

## Components

| Module | Does | Depends on |
|---|---|---|
| `MouseContract` | The message schema: types, encoding to XPC dictionaries and back, the version. No logic, no AppKit. | nothing |
| `MouseClient` | The package apps use: connect, declare wishes, receive events, play haptics. Reconnects by itself when the service restarts and sends its last wishes again. | `MouseContract` |
| `MouseCore` | Pure arbitration: (frontmost app, window under pointer, clients' wishes, settings, mouse state) → wanted state. No hardware, no XPC; fully unit-tested. | `MouseContract` |
| `MouseService.app` | The menu-bar app: XPC listener, tracking of the frontmost app and the window under the pointer, the adapter to `LogiHIDPP`, settings, the status menu (mouse, clients, buttons the system thinks are held, "Release All"). | all above, `LogiHIDPP`, SettingsKit |

`MouseCore` only computes; the app compares the wanted state with the known one and applies the difference. Any
scenario (a client crashes while holding the ratchet; ten app switches a second) is a unit test, not a manual check.

`LogiHIDPP` stays a separate package, used only inside the service. Its cross-process workarounds are removed in a later
plan, once both apps are clients; nothing in it changes in this sub-project.

## Contract v1

General rules:

- Every message is an XPC dictionary with a `type` field. Unknown fields and types are ignored.
- Version `major.minor`, sent by the client in `hello`. A higher major is refused with an error; the client then
  behaves as without the service. New fields come in minor versions.
- **Wishes are whole state, not commands.** Each `want` replaces the client's previous one entirely. A repeat is
  harmless; a lost message is cured by the next one. How to get there is the service's business.
- Event times are `ProcessInfo.systemUptime`: the machine's clock, the same in every process.

Client → service:

| Message | Fields |
|---|---|
| `hello` | contract version, bundle ID. Reply: service version, `device` (mouse present, model, features). |
| `want` | `divert: [control]`, `watch: [control]`, `thumbWheel: Bool` — in effect while the client owns the buttons. `wheel: [{window, rects?, highResolution?, mode?}]` — main-wheel modes over its own windows or parts of them (rects in window coordinates; none: the whole window). |
| `play` | `pattern`, optional `strength`. Played only while the client owns haptics; otherwise dropped silently. |

Service → client:

| Event | Fields |
|---|---|
| `owner` | `true` / `false`: the client owns buttons and haptics now. Replaces the app's own tracking of being active. |
| `button` | control, pressed / released, time. To the owner only. When ownership is lost every held control gets `released`: no press is ever left hanging. |
| `thumbWheel` | steps, time. To the owner only. |
| `wheel` | `highResolution`, `mode`, `byButton` (the user pressed the SmartShift button). To the client whose window is under the pointer, so it can adopt the user's choice. |
| `device` | the mouse appeared or went away, its features changed. |

Not in the contract on purpose: haptic strength, panel force and other device settings; a direct write of the wheel
mode (only a wish over one's own window).

Controls are named by HID++ CIDs as `LogiHIDPP.CID` has them; the contract carries the numbers, the Swift package the
names.

## Arbitration and data flow

Inputs of `MouseCore`, all event-driven:

- **Frontmost app**: `NSWorkspace.didActivateApplicationNotification`, matched to a connected client by PID.
- **Window under the pointer**: needed only while some client has wheel wishes; otherwise the service does not follow
  the pointer at all. When it does: a global `mouseMoved` monitor (listen only, no Accessibility needed); each move only
  compares the point with the cached frame of the current window; `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
  is asked only when the point leaves that frame.
- **Clients' wishes** (each client's last `want`) and the service's settings.
- **Mouse state**: present or not, features, a SmartShift press by the user.

Output, the wanted state: divert set, watch set, thumb wheel, Precision Scroll, wheel mode, the owner (receiver of
buttons and haptics), the receiver of `wheel` events.

Rules:

1. **Owner of buttons and haptics** is the frontmost app if it is a client. Otherwise there is no owner and nothing is
   diverted or watched: the mouse behaves as the system's.
2. **Wheel**: if the window under the pointer belongs to a client and the point is in a declared area, its mode applies.
   Otherwise the mouse's own mode (the one before the service changed it). Sub-project 3 adds a global rule here.
3. **Owner change** in one step: `released` for every held control and `owner: false` to the old owner, then the new
   divert / watch sets, then `owner: true` to the new owner.
4. **Applying by difference**: the service keeps the known state of the mouse and writes only what differs. Writes go
   through one queue per feature where the latest wish wins: ten app switches in a second give one or two writes. No
   300 ms re-apply and no per-app markers: there is one process.
5. **SmartShift button**: the user's choice is adopted as `LogiHIDPP` does now and reported to the client under the
   pointer as `wheel(byButton: true)`; the client decides whether to make it its wish.

Per the repositories' rules (`CLAUDE.md`): no timers or polling at rest; work happens only on events (app switch,
crossing a window frame, a client message, a mouse report). Everything runs on one serial queue at `.userInteractive`
QoS: it is input. Nothing heavy runs there.

## Failures and recovery

- **Client crashes or exits**: the XPC connection is invalidated at once; its wishes are dropped, `MouseCore`
  recomputes, the service applies the difference (diverts released, wheel mode given back). No heartbeat. A client that
  hangs while frontmost stays the owner, as an active app does today; "Release All" in the menu takes it away by hand.
- **Service crashes**: launchd restarts it (login item). At start, before accepting clients, a clean start: every
  divertable control and the thumb wheel released; Precision Scroll turned off and the wheel mode given back if the
  service's marker says it set them. One marker, in the service's settings, not one per app. Clients reconnect
  (`MouseClient`) and send their last `want`.
- **Service quits normally** (menu, update): releases everything synchronously, as `releaseAllSync()` does now.
- **Mouse sleeps, is switched off, reconnects**: `LogiHIDPP` handles it (receiver notifications, `systemDidWake`); the
  service applies the wanted state again after a reconnect.
- **A button stuck in the HID state** (button 6 seen 2026-10-27, system-wide, with no FrameScrub and Mac Mouse Fix off):
  the service never posts a synthetic press without its release. The status menu shows the buttons the system thinks are
  held (`NSEvent.pressedMouseButtons`) with a hint. Clearing someone else's stuck button is not possible: a posted
  release did not clear it.
- **Incompatible client** (higher major version): an error in reply to `hello`; the client works without Logitech
  features.

## Moving FrameScrub and Loupe

Behaviour for the user does not change.

1. The service and `MouseClient` are ready and tested with a test client first.
2. FrameScrub's `LogiMouseBridge` is rewritten over `MouseClient` with the same interface (`onButton`, `onWheelMode`,
   `takeSmartShift`, `wantHighResolutionWheel`, …); the rest of FrameScrub is untouched. "Precision Scroll while the
   pointer is over the video" becomes a declared area (`wheel: [{window, rect: video, highResolution: true}]`) instead
   of switching by pointer moves.
3. Device-setting keys (haptic strength, panel force) leave `framescrub.conf` for the service. The old keys warn once
   ("now in the service's settings"); no migrations.
4. The same for Loupe.
5. Once both are clients, `LogiHIDPP` loses its cross-process workarounds (300 ms re-apply, per-app markers, notes about
   other apps): a separate plan.

## Testing

- `MouseCore`: unit tests of the scenarios — frontmost app switches, a client dies holding a button, ten switches in a
  row, wheel areas and a pointer on their border, a SmartShift press, a service restart with its marker set. Most tests
  live here, without hardware.
- `MouseContract`: encoding round trips; compatibility (an old client against a new service, unknown fields).
- The service: an integration test over real XPC with a fake mouse (`LogiHIDPP`'s `HIDPPTransport` is replaceable); a
  hardware test behind a flag, as `LOGI_HARDWARE=1`.
- Bench (`CLAUDE.md`): the service's CPU at rest ≈ 0; latency from a button press to the client's event (target: under
  2 ms on top of HID++); the cost of following the pointer while the mouse moves. Measured on the Intel Mac too.
- FrameScrub's `docs/logitech-checklist.md`: a manual run after the move.

## Out of scope here

Gestures, the global Precision Scroll ↔ ratchet link, pointer and wheel options, the `Info.plist` declaration level,
public distribution: sub-projects 2–5.

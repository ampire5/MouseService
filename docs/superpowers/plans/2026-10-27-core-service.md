# MouseService core: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One service process owns the Logitech mouse. FrameScrub and Loupe become its clients over a versioned XPC
contract, and for the user they behave as they do now.

**Architecture:**
- `MouseContract` holds the message types and their encoding to and from XPC dictionaries.
- `MouseCore` is a pure arbiter: it turns inputs into a wanted mouse state plus the messages to send.
- `MouseServiceKit` connects the arbiter to XPC peers and to a `MouseDriver` protocol. The real driver wraps
  `LogiHIDPP.LogiMouse`; the tests use a fake one.
- `MouseClient` is the package the apps link.
- The menu-bar app runs as a launchd agent registered with `SMAppService.agent` and exposes a Mach service.

**Tech Stack:** Swift 6.4 toolchain, swift-tools 6.2, macOS 26, low-level XPC (`<xpc/xpc.h>` from Swift), Swift
Testing, LogiHIDPP (unchanged), SettingsKit 0.7.

**Spec:** `docs/superpowers/specs/2026-10-27-core-service-design.md` (approved 2026-10-27).

## Global Constraints

- Contract version `1.0`. Every message is an XPC dictionary with a string `type`. Unknown fields and types are
  ignored. A client whose major version is higher than the service's is refused.
- Wishes are whole state: each `want` replaces the client's previous one.
- Event times are `ProcessInfo.processInfo.systemUptime`, taken when the service receives the mouse's event.
- Controls are HID++ CIDs as `UInt16` (`LogiHIDPP.CID.rawValue`).
- Owner of buttons, haptics and the thumb wheel: the frontmost app, when it is a connected client. With no owner,
  nothing is diverted or watched.
- Wheel modes: those of the window under the pointer, from that window's client's declared areas. Elsewhere, the
  mouse's own mode.
- Device settings (haptic strength, panel force) are the service's alone. A client may only ask for a one-off `play`
  with a strength.
- `LogiHIDPP` does not change in this plan.
- Rules from `CLAUDE.md`: nothing runs at rest (no timers, no polling); the work happens on events. Every timer is
  one-shot and has a stop condition.
- **Threading (a deviation from the spec's "one serial queue").** `LogiMouse` is `@MainActor`, so the service's
  state lives on the main actor and XPC peers are targeted at the main queue. The main thread of this menu-bar agent
  has no other work, and the settings window is open only on demand. The latency bench (Task 7) checks this choice.
- Service names:
  - bundle ID and launchd label: `local.mouseservice`;
  - Mach service: `local.mouseservice.xpc`;
  - agent plist: `Contents/Library/LaunchAgents/local.mouseservice.plist`.
- Commit messages follow the repository's style: one descriptive English sentence, no prefixes, no attribution lines.

## Review Focus

1. **A client that crashes while holding a button or a wheel mode.** Its diverts and its mode are given back at
   once, and no press is left hanging (Task 2 `disconnectWhileHolding`, Task 4 `peerCancelReleases`).
2. **The service restarting under a running client.** The client reports `owner: false`, releases its held
   controls locally, reconnects and resends its last `want`. Behaviour comes back without a user action (Task 4
   `clientRecoversAfterServiceRestart`).
3. **Fast app switching.** Ten activations in a row must leave exactly one owner, with every old owner released and
   the last wish applied (Task 2 `tenSwitches`).
4. **The pointer on the edge of a declared area, or two areas of one window.** The rule is: min edges inclusive, max
   edges exclusive; each field (mode, high resolution) comes from the first entry that matches and sets it (Task 3
   `areaBorder`, `fieldPrecedence`).
5. **No service installed.** The app works as with an ordinary mouse and never retries on a timer; it tries again on
   its next activation (Task 4 `unavailableServiceRetriesOnActivation`).

---

## File structure

```
Package.swift                                   tools 6.2, macOS 26, products MouseClient (+MouseContract)
Sources/MouseContract/Messages.swift            ClientMessage, ServiceMessage, Want, WheelWish, DeviceInfo, …
Sources/MouseContract/XPCCoding.swift           encode / decode to xpc_object_t
Sources/MouseCore/Arbiter.swift                 pure arbitration (owner, buttons, wheel areas)
Sources/MouseServiceKit/MouseDriver.swift       protocol MouseDriver, DriverEvent, MouseState
Sources/MouseServiceKit/Service.swift           Arbiter + driver + peers on the main actor
Sources/MouseServiceKit/Listener.swift          XPC listener and peer connections
Sources/MouseClient/MouseClient.swift           the apps' package
Sources/MouseService/…                          the app: LogiMouseDriver, PointerTracker, AppDelegate, Settings
Sources/mouse-client-probe/main.swift           test client and latency bench
Resources/local.mouseservice.plist              launchd agent
Tests/MouseContractTests, MouseCoreTests, MouseServiceKitTests
docs/bench.md
```

---

### Task 1: The contract and its encoding

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MouseContract/Messages.swift`, `Sources/MouseContract/XPCCoding.swift`
- Test: `Tests/MouseContractTests/XPCCodingTests.swift`

**Interfaces:**
- Produces (all `public`, `Equatable`, `Sendable`):
  ```swift
  public struct ContractVersion: Comparable { let major, minor: Int; static let current = ContractVersion(major: 1, minor: 0) }  // text "1.0"
  public enum WheelMode: UInt8 { case freeSpin = 1, ratchet = 2 }           // same raw values as LogiHIDPP.WheelMode
  public struct WheelWish { var window: Int; var rects: [CGRect]?; var highResolution: Bool?; var mode: WheelMode? }
  public struct Want { var divert: Set<UInt16>; var watch: Set<UInt16>; var thumbWheel: Bool; var wheel: [WheelWish]; static let none }
  public struct ControlInfo { let cid: UInt16; let divertable, watchable: Bool }
  public struct DeviceInfo { var present: Bool; var controls: [ControlInfo]; var thumbWheelStepsPerRevolution: Int?; var haptics: Bool; static let absent }
  public enum ThumbPhase: String { case began, changed, ended }
  public enum ClientMessage { case hello(version: ContractVersion, bundleID: String); case want(Want); case play(pattern: UInt8, strength: UInt8?) }
  public enum ServiceMessage {
      case welcome(serviceVersion: String, device: DeviceInfo)
      case refused(reason: String)
      case owner(Bool)
      case watching(Set<UInt16>)
      case button(cid: UInt16, pressed: Bool, time: Double)
      case thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase, time: Double)
      case wheel(highResolution: Bool, mode: WheelMode?, byButton: Bool)
      case device(DeviceInfo)
  }
  extension ClientMessage { func xpc() -> xpc_object_t; init?(xpc: xpc_object_t) }
  extension ServiceMessage { func xpc() -> xpc_object_t; init?(xpc: xpc_object_t) }
  ```
- The `type` strings are `hello`, `want`, `play`, `welcome`, `refused`, `owner`, `watching`, `button`,
  `thumbWheel`, `wheel` and `device`. Fields are named as in the Swift cases.
- How values are encoded:
  - a `Set<UInt16>` is an XPC array of uint64, sorted;
  - a `CGRect` is an array of 4 doubles `[x, y, w, h]`, in the window's coordinates with the origin at the
    bottom-left of the window frame (AppKit);
  - an optional is an absent key;
  - the version is the string `"1.0"`.
- The `watching` event is an addition to the spec's table. Apps drop AppKit events of watched side buttons
  (`SideButtonFilter`), and the confirmed watch set is the only way they can know which buttons those are.
- `DeviceInfo` carries no model name: `LogiMouse` does not expose one. A later minor version can add it.

- [ ] **Step 1: Package.swift**
  - swift-tools 6.2, `platforms: [.macOS(.v26)]`.
  - New targets: `MouseContract`, `MouseCore` (depends on MouseContract), `MouseServiceKit` (MouseCore,
    MouseContract), `MouseClient` (MouseContract).
  - Product `.library(name: "MouseClient", targets: ["MouseClient", "MouseContract"])`.
  - Test targets for each library.
  - Swift 6 language mode.
  - `swift build` passes with empty placeholder files.
- [ ] **Step 2: Write the failing tests**
  - `roundTripsEveryMessage`: every case of both enums, with every optional both set and absent, encodes and decodes
    to an equal value.
  - `ignoresUnknownFields`: a `want` dictionary with an extra key `"future": 1` decodes to the same `Want`.
  - `unknownTypeIsNil`: `{type: "teleport"}` gives `nil`, and so does a dictionary without `type`.
  - `missingRequiredFieldIsNil`: `button` without `cid` gives `nil`.
  - `versionOrderAndText`: `1.0 < 1.1 < 2.0`, `ContractVersion("1.2") == ContractVersion(major: 1, minor: 2)`, and
    `ContractVersion("x")` is `nil`.
- [ ] **Step 3:** Run `swift test --filter MouseContractTests`. Expected: FAIL to compile.
- [ ] **Step 4: Implement** `Messages.swift` and `XPCCoding.swift`. Use `xpc_dictionary_set_*` and
  `xpc_dictionary_get_*`, and `xpc_array_*` for sets and rects. When decoding a number, check its type with
  `xpc_get_type`.
- [ ] **Step 5:** Run `swift test --filter MouseContractTests`. Expected: PASS.
- [ ] **Step 6:** Commit:
  `git commit -m "Contract v1: client and service messages as versioned XPC dictionaries, unknown fields and types ignored"`.

---

### Task 2: Arbiter, owner and buttons

**Files:**
- Create: `Sources/MouseCore/Arbiter.swift`
- Test: `Tests/MouseCoreTests/OwnerTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  ```swift
  public struct ClientID: Hashable, Sendable { public let raw: Int }
  public struct MouseState: Equatable, Sendable { var divert: Set<UInt16>; var watch: Set<UInt16>; var thumbWheel: Bool; var highResolution: Bool; var mode: WheelMode?; static let released }
  public enum Effect: Equatable, Sendable { case send(ClientID, ServiceMessage); case apply(MouseState); case play(pattern: UInt8, strength: UInt8?) }
  public struct Arbiter: Sendable {
      public init()
      public private(set) var wanted: MouseState          // what the mouse should be now
      public var owner: ClientID? { get }
      public mutating func connect(_ id: ClientID, pid: pid_t) -> [Effect]
      public mutating func disconnect(_ id: ClientID) -> [Effect]
      public mutating func want(_ id: ClientID, _ want: Want) -> [Effect]
      public mutating func frontmost(pid: pid_t?) -> [Effect]
      public mutating func releaseAll() -> [Effect]       // the menu's "Release All": no owner until the next activation
      public mutating func button(cid: UInt16, pressed: Bool, time: Double) -> [Effect]
      public mutating func thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase, time: Double) -> [Effect]
      public mutating func watching(_ cids: Set<UInt16>) -> [Effect]
      public mutating func play(_ id: ClientID, pattern: UInt8, strength: UInt8?) -> [Effect]
  }
  ```
- `.apply` is emitted only when `wanted` changed, and it carries the whole new state. `wanted.divert`, `watch` and
  `thumbWheel` are the owner's `Want`, or empty with no owner.
- The arbiter keeps the set of held controls (pressed and not yet released) for the owner.
- An owner change produces effects in this order:
  1. `send(old, .button(cid, pressed: false, time:))` for each held control, sorted by CID, with the time of the
     change: the last time the arbiter saw (the newest `time` argument it received);
  2. `send(old, .owner(false))`;
  3. `.apply` with the new state;
  4. `send(new, .owner(true))`;
  5. `send(new, .watching(current))`.

- [ ] **Step 1: Write the failing tests.** A helper `pid(n)` makes client `n` with pid `100 + n`.
  - `frontmostClientOwns`: after `connect(1)`, `want(1, divert [0xC3])` and `frontmost(101)`, the effects contain
    `.apply(divert [0xC3])` and `send(1, .owner(true))`.
  - `nonClientFrontmostMeansNoOwner`: `frontmost(999)` gives `owner == nil` and `wanted == .released`.
  - `buttonsGoToOwnerOnly`: client 2 is connected but not frontmost. `button(0xC3, true, 5)` gives exactly
    `[send(1, .button(0xC3, true, 5))]`.
  - `ownerChangeReleasesHeld`: client 1 holds 0xC3 and 0x53, then `frontmost(102)`. The effects are exactly the
    five-step sequence above, with releases for 0x53 then 0xC3.
  - `disconnectWhileHolding`: owner 1 holds 0xC3, then `disconnect(1)`. The result is `[.apply(.released)]`: no
    sends to a gone client, `owner == nil`, and a later `button(0xC3, false, …)` sends nothing.
  - `tenSwitches`: clients 1 and 2 with different wants. After ten alternating `frontmost` calls ending on 2,
    `wanted` is client 2's want, every `owner(true)` is preceded by the previous owner's `owner(false)`, and the
    final owner is 2.
  - `wantFromNonOwnerDoesNotApply`: `want(2, …)` while 1 owns emits no `.apply`.
  - `repeatWantIsSilent`: the same `want` twice emits no effects the second time.
  - `playOnlyForOwner`: `play(1, 5, nil)` from the owner gives `[.play(5, nil)]`; from a non-owner it gives `[]`.
  - `releaseAllUntilNextActivation`: `releaseAll()` releases held controls, gives `owner(false)` and
    `.apply(.released)`. `frontmost(101)` again restores ownership.
  - `connectAfterActivation`: `frontmost(101)` first, then `connect(1)` and `want(1, …)`: client 1 becomes the
    owner on connect.
- [ ] **Step 2:** Run `swift test --filter MouseCoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement `Arbiter`** for the owner, buttons, thumb wheel, watching and play. Thumb-wheel events go
  to the owner only. `watching` is forwarded to the owner and remembered for the next owner.
- [ ] **Step 4:** Run `swift test --filter MouseCoreTests`. Expected: PASS.
- [ ] **Step 5:** Commit:
  `git commit -m "Arbiter: the frontmost client owns buttons and haptics; an owner change releases every held control first"`.

---

### Task 3: Arbiter, wheel areas

**Files:**
- Modify: `Sources/MouseCore/Arbiter.swift`
- Test: `Tests/MouseCoreTests/WheelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PointerPlace: Equatable, Sendable { public var window: Int; public var pid: pid_t; public var point: CGPoint }  // point in window coordinates, bottom-left origin
  extension Arbiter {
      public var followsPointer: Bool { get }             // some connected client has a non-empty `wheel`
      public mutating func pointer(_ place: PointerPlace?) -> [Effect]   // nil: no window, or not a client's
      public mutating func wheelState(highResolution: Bool, mode: WheelMode?, byButton: Bool) -> [Effect]
  }
  ```
- How the wheel is resolved:
  - Only the entries of the client whose pid is `place.pid` and whose `window` is `place.window` count.
  - An entry matches when `rects` is nil, or when some rect contains the point. Containment is `minX <= x < maxX`
    and `minY <= y < maxY`.
  - `wanted.mode` is the `mode` of the first matching entry that sets one, else `nil`.
  - `wanted.highResolution` is the same with `highResolution`, else `false`.
- The client whose matched window it is becomes the wheel receiver. When the receiver changes, the new receiver is
  sent `.wheel(highResolution: <last reported>, mode: <last reported>, byButton: false)`.
- `wheelState` is forwarded to the current receiver unchanged, whether or not `byButton` is set.

- [ ] **Step 1: Write the failing tests.**
  - `modeOverWholeWindow`: wish `[{window 7, mode .freeSpin}]` and the pointer in window 7 of that pid give
    `.apply` with `mode == .freeSpin`. A pointer in window 8 gives `mode == nil`.
  - `areaBorder`: rect `(0,0,100,50)`. The point `(0,0)` matches, `(100,10)` does not, `(99.9,49.9)` matches.
  - `fieldPrecedence`: wish `[{window 7, mode .freeSpin}, {window 7, rects [(0,0,100,50)], highResolution true}]`.
    Inside the rect the result is free spin with high resolution; outside, free spin without it.
  - `otherPidSameWindowNumberIgnored`: a place with the right window number but a different pid gives `mode == nil`.
  - `followsPointerOnlyWithWishes`: the value is false with no wishes and true after a `want` with a non-empty
    `wheel`; after that client disconnects, it is false again.
  - `wheelWishAppliesWithoutOwnership`: client 2 is not frontmost, and the pointer over its window applies its mode.
  - `receiverGetsStateOnEntry` / `byButtonGoesToReceiver`: `wheelState(…, byButton: true)` is sent to the client
    under the pointer only.
  - `clientGoneGivesModeBack`: the receiver disconnects, and `.apply` has `mode == nil` and `highResolution == false`.
- [ ] **Step 2:** Run `swift test --filter MouseCoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the wheel part of `Arbiter`.
- [ ] **Step 4:** Run `swift test --filter MouseCoreTests`. Expected: all PASS.
- [ ] **Step 5:** Commit:
  `git commit -m "Arbiter: wheel modes from the declared areas of the window under the pointer, the mouse's own elsewhere"`.

---

### Task 4: Service, listener and client over real XPC

**Files:**
- Create:
  - `Sources/MouseServiceKit/MouseDriver.swift`
  - `Sources/MouseServiceKit/Service.swift`
  - `Sources/MouseServiceKit/Listener.swift`
  - `Sources/MouseClient/MouseClient.swift`
- Test:
  - `Tests/MouseServiceKitTests/FakeDriver.swift`
  - `Tests/MouseServiceKitTests/ServiceTests.swift`

**Interfaces:**
- Consumes: `Arbiter`, `Effect`, `MouseState`, and the Task 1 messages.
- Produces:
  ```swift
  public enum DriverEvent: Equatable, Sendable {
      case button(cid: UInt16, pressed: Bool)
      case thumbWheel(delta: Int, touching: Bool, phase: ThumbPhase)
      case wheel(highResolution: Bool, mode: WheelMode?, byButton: Bool)
      case device(DeviceInfo)
      case watching(Set<UInt16>)
  }
  @MainActor public protocol MouseDriver: AnyObject {
      var device: DeviceInfo { get }
      var onEvent: ((DriverEvent) -> Void)? { get set }
      func apply(_ state: MouseState)
      func play(pattern: UInt8, strength: UInt8?)
  }
  @MainActor public final class Service {
      public init(driver: any MouseDriver, version: String)
      public func accept(_ peer: xpc_connection_t)             // called by Listener for each new peer
      public func frontmost(pid: pid_t?)
      public func pointer(_ place: PointerPlace?)
      public func releaseAll()
      public var followsPointer: Bool { get }
      public var onFollowsPointerChange: ((Bool) -> Void)?
      public var clients: [(bundleID: String, pid: pid_t, owner: Bool)] { get }   // for the menu
  }
  public final class Listener {
      public init(machService name: String, service: Service)  // XPC_CONNECTION_MACH_SERVICE_LISTENER
      public init(anonymous service: Service)                  // tests
      public var endpoint: xpc_endpoint_t { get }               // anonymous only
  }
  @MainActor public final class MouseClient {
      public static let serviceName = "local.mouseservice.xpc"
      public init(bundleID: String = Bundle.main.bundleIdentifier ?? "")          // Mach service
      public init(bundleID: String, endpoint: xpc_endpoint_t)                      // tests
      public private(set) var isAvailable: Bool   // welcomed by a service now
      public private(set) var isOwner: Bool
      public private(set) var device: DeviceInfo   // .absent until welcomed
      public private(set) var watching: Set<UInt16>
      public private(set) var wheel: (highResolution: Bool, mode: WheelMode?)
      public var onOwner: ((Bool) -> Void)?
      public var onButton: ((_ cid: UInt16, _ pressed: Bool, _ time: Double) -> Void)?
      public var onThumbWheel: ((_ delta: Int, _ touching: Bool, _ phase: ThumbPhase, _ time: Double) -> Void)?
      public var onWheel: ((_ highResolution: Bool, _ mode: WheelMode?, _ byButton: Bool) -> Void)?
      public var onDevice: ((DeviceInfo) -> Void)?
      public var onAvailability: ((Bool) -> Void)?
      public func start()                  // connect + hello; also tries again on NSApplication.didBecomeActive while unavailable
      public func want(_ want: Want)       // stored; sent if it differs from the last sent; resent after every reconnect
      public func play(pattern: UInt8, strength: UInt8? = nil)
  }
  ```
- Service behaviour:
  - Each peer gets a `ClientID` on its `hello`.
  - A higher major version gets `.refused("contract 2.0 not supported, service speaks 1.0")` and its connection
    is cancelled.
  - The peer's pid comes from `xpc_connection_get_pid`.
  - Messages before `hello` are ignored.
  - On `XPC_ERROR_CONNECTION_INVALID` the service calls `arbiter.disconnect`. Driver events are stamped with
    `systemUptime` when they arrive.
  - The `welcome` reply carries the driver's `device`.
  - `.device` events go to every client.
- Client behaviour:
  - On `XPC_ERROR_CONNECTION_INTERRUPTED` (the service died) the client does these steps in order:
    1. It reports `onButton(cid, false, now)` for each control it believes held.
    2. It sets `isOwner = false` and calls `onOwner(false)`.
    3. It sends `hello`, then the last `want`, at once on the same connection. Launchd relaunches the service on
       demand.
  - On `XPC_ERROR_CONNECTION_INVALID` (no such service), or on `refused`, it sets `isAvailable = false` and stays
    quiet until the next activation of the app.

- [ ] **Step 1: Write the failing tests.** They run on the main actor with an anonymous `Listener` and a
  `FakeDriver`, which records `apply` and `play` calls and can `emit(_:)`. Waits use `await` on a short polling
  helper that yields to the main queue with a 2 s timeout. That helper is the only loop in the tests.
  - `helloGetsWelcomeAndDevice`
  - `refusesHigherMajor`: a raw connection sends a `hello` with `2.0`, and gets `refused` followed by an invalid
    connection.
  - `ownerFlowEndToEnd`: the client wants divert `[0xC3]`, and `service.frontmost(clientPid)`. The client gets
    `onOwner(true)`, and the fake driver's last apply has `divert == [0xC3]`. When the driver emits a button
    event, the client's `onButton` is called with a time within 0.1 s of now.
  - `peerCancelReleases`: cancelling the client's connection makes the fake driver's last apply `.released`.
  - `clientRecoversAfterServiceRestart`: tear down the service and listener, make new ones on a new endpoint, and
    inject the endpoint. The client reports `onButton(held, false)` and `onOwner(false)`, then after reconnecting
    sends its last `want` again, so the new fake driver gets the same divert set. To make this testable, the
    client takes `endpointProvider: () -> xpc_endpoint_t?` in its test init and re-asks it on interruption.
  - `unavailableServiceRetriesOnActivation`: a provider returning `nil` gives `isAvailable == false`. Posting
    `NSApplication.didBecomeActiveNotification` with the provider now valid gives `isAvailable == true`.
  - `playFromNonOwnerDropped`: the fake driver records no play.
- [ ] **Step 2:** Run `swift test --filter MouseServiceKitTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the driver protocol, `Service` (it routes `Effect`s), `Listener` and `MouseClient`.
  - Target every connection at `DispatchQueue.main` and use `MainActor.assumeIsolated` in its handlers.
- [ ] **Step 4:** Run `swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit:
  `git commit -m "Service and MouseClient over XPC: hello and version, wishes, owner events, a crashed client released, a restarted service rejoined"`.

---

### Task 5: The real mouse and the pointer

**Files:**
- Create:
  - `Sources/MouseService/LogiMouseDriver.swift`
  - `Sources/MouseService/PointerTracker.swift`
  - `Sources/MouseService/FrontmostTracker.swift`
- Modify: `Package.swift`, which adds `LogiHIDPP` (`https://github.com/ampire5/LogiHIDPP.git`, from `0.1.0`) and
  `MouseServiceKit` to the `MouseService` target.

**Interfaces:**
- Consumes: `MouseDriver`, `DriverEvent`, `MouseState`, `Service.pointer`, `Service.frontmost`, and
  `Service.onFollowsPointerChange`.
- Produces:
  - `final class LogiMouseDriver: MouseDriver`, created with `init(hapticStrength: UInt8?, panelForce: PanelForce)`.
  - `func setHapticStrength(_: UInt8?)` and `func setPanelForce(_: PanelForce)`, where `PanelForce` is a copy of
    FrameScrub's `PanelForceSetting` (`keep`, `factoryDefault`, `percent(Int)` and `value(range:defaultValue:)`),
    renamed.
  - `func releaseAllSync()`.
  - `final class PointerTracker`, created with `init(onChange: (PointerPlace?) -> Void)` and switched with
    `func setActive(_ on: Bool)`.
  - `final class FrontmostTracker`, created with `init(onChange: (pid_t?) -> Void)`.

**LogiMouseDriver.**
- Setup and lifetime:
  - It makes one `LogiMouse()`, calls `start()`, then `setActive(true)` once; it never calls `follow(app:)`.
  - It calls `systemDidWake()` on `NSWorkspace.didWakeNotification`.
  - The default `UserDefaults` markers are the single service marker.
- `apply(state)` maps the state onto `LogiMouse`:
  - `divert` and `watch` become sets of `CID`;
  - `thumbWheel` goes to `divertThumbWheel`;
  - `highResolution` goes to `wantHighResolutionWheel`;
  - `mode` is converted with `LogiHIDPP.WheelMode(rawValue: mode.rawValue)` and goes to `wantWheelMode`.
- Events:
  - Mouse events become `DriverEvent`s. `.connected` and `.disconnected` become `.device(...)`, built from
    `controls`, `stepsPerRevolution` and `hapticStrength != nil`.
  - On the first `.connected` only (the clean start), it calls `divert` with every divertable control, `watch`
    with every watchable one and `divertThumbWheel(true)`, then at once `releaseAll()`, then `apply` of the
    current state.
- `watching`:
  - Re-read `mouse.watching` after every mouse event, and once 0.5 s after each `apply`, with a one-shot
    `DispatchWorkItem` that the next `apply` replaces.
  - Emit `.watching` when the set changed.
- Device settings: the haptic strength and the panel force are written as Loupe's `applyMouseSettings` does now,
  again on every `.connected`.

**PointerTracker.**
- Active only while `service.followsPointer`.
- It installs a global and a local `NSEvent` monitor for `.mouseMoved`, the three `*MouseDragged` kinds and
  `.scrollWheel`.
- Each event compares `NSEvent.mouseLocation` with the cached frame of the current window, and does nothing more
  while the point is inside.
- On leaving the frame (and on every `FrontmostTracker` change):
  - it asks `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)`;
  - then `CGWindowListCopyWindowInfo(.optionIncludingWindow, n)` for `kCGWindowOwnerPID` and `kCGWindowBounds`;
  - it converts the bounds to AppKit screen coordinates by flipping with the primary screen's height;
  - it caches the frame and reports a `PointerPlace` with the point relative to the frame's bottom-left.
- Inactive, it has no monitors.

**FrontmostTracker.** `NSWorkspace.didActivateApplicationNotification` and the current
`NSWorkspace.shared.frontmostApplication` at start.

- [ ] **Step 1:** Implement the three files. Unit tests do not apply here (hardware and AppKit). Task 7's checklist
  verifies them.
- [ ] **Step 2:** Run `swift build`. Expected: success, with no warnings in the new files.
- [ ] **Step 3:** Commit:
  `git commit -m "The service's mouse (LogiMouse, always active, a clean start on first contact) and the window under the pointer, followed only while a client has wheel wishes"`.

---

### Task 6: The app: launchd agent, menu, settings

**Files:**
- Modify:
  - `Sources/MouseService/AppDelegate.swift`
  - `Resources/Info.plist`: `CFBundleShortVersionString` 0.2, `LSMinimumSystemVersion` 26.0
  - `scripts/make-app.sh`
  - `Package.swift`: SettingsKit `https://github.com/ampire5/SettingsKit.git` from `0.7.0`
- Create:
  - `Resources/local.mouseservice.plist`
  - `Sources/MouseService/ServiceSettings.swift`

**Agent plist:**
- `Label` `local.mouseservice`;
- `BundleProgram` `Contents/MacOS/MouseService`;
- `MachServices` `{local.mouseservice.xpc: true}`;
- `RunAtLoad` true;
- `KeepAlive` `{SuccessfulExit: false}`;
- `LimitLoadToSessionType` `Aqua`;
- `ProcessType` `Interactive`.

`make-app.sh` copies the plist to `Contents/Library/LaunchAgents/`. `--install` replaces `pkill` and `open` with
`launchctl kickstart -k gui/$(id -u)/local.mouseservice` when the agent is loaded, and `open` otherwise.

**Launch logic, in `applicationDidFinishLaunching`:**
- Launched by launchd, that is when `ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "local.mouseservice"`:
  1. Run the existing gesture start-up (`SideButtonTap`, unchanged).
  2. Create `LogiMouseDriver`, `Service`, `Listener(machService: "local.mouseservice.xpc")`, the trackers and the
     menu.
- Launched by hand:
  1. Unregister 0.1's `SMAppService.mainApp` if it is enabled.
  2. `SMAppService.agent(plistName: "local.mouseservice.plist").register()`. On `.requiresApproval`, show an alert
     whose button calls `SMAppService.openSystemSettingsLoginItems()`.
  3. If the agent was already enabled, run `launchctl kickstart gui/<uid>/local.mouseservice`.
  4. Terminate.

**Menu, additions to the existing one:**
- the mouse line: "MX Master: connected" or "No Logitech mouse";
- a "Clients" submenu: the bundle IDs, with a check on the owner;
- the held-buttons line, from `NSEvent.pressedMouseButtons`, shown only when non-zero: "Buttons held by the
  system: 6 — a stuck button, reconnect the mouse";
- "Release All" (`service.releaseAll()`);
- "Settings…".
- Remove "Launch at Login"; the agent is the login item now.
- Everything is computed in `menuNeedsUpdate`, so nothing runs at rest.

**Settings window:**
- A `SettingsStore` over `UserDefaults` with the keys `haptic-strength` (`keep` or 0–100, default `keep`) and
  `mx-panel-force` (`keep`, `default` or 0–100, default `0`). The defaults and validation are copied from
  FrameScrub's `Config` for these two keys.
- One page, "Mouse", whose two rows are copied from FrameScrub's `PageMouse.swift` lines 53–63 with "FrameScrub"
  replaced by "MouseService".
- A store change calls the driver's setters.

**Quit:** `applicationWillTerminate` calls `driver.releaseAllSync()` after the gesture tap stops (as now).

- [ ] **Step 1:** Implement the plist, the script, the launch logic, the menu and the settings.
- [ ] **Step 2:** Run `swift build && swift test`. Expected: success and all PASS.
- [ ] **Step 3:** Run `scripts/make-app.sh --install`, then `launchctl print gui/$(id -u)/local.mouseservice | grep state`.
  Expected: `state = running`.
- [ ] **Step 4:** Run `pkill -9 MouseService`, wait 2 s and check the same `launchctl print`. Expected: running
  again, which is the restart after a crash.
- [ ] **Step 5:** Commit:
  `git commit -m "MouseService runs as a launchd agent with a Mach service: restarted after a crash, a menu with the mouse, clients, stuck buttons and Release All, haptic strength and panel force in its own settings"`.

---

### Task 7: Test client, bench and hardware check

**Files:**
- Create: `Sources/mouse-client-probe/main.swift`, `docs/bench.md`, `docs/logitech-checklist.md`
- Modify: `Package.swift`, which adds the executable target `mouse-client-probe` (depends on MouseClient)

**Interfaces:**
- Consumes: `MouseClient`.
- Produces the probe. It is an `NSApplication` with `.regular` activation policy, so it can be frontmost.
  - `mouse-client-probe divert 0xC3,0xC4 [--watch 0x53,0x56] [--thumb] [--wheel freeSpin|ratchet] [--hires]`
  - It prints every event with `now - time` in ms.
  - The `--wheel` and `--hires` options declare its own window as the area.

- [ ] **Step 1:** Implement the probe.
- [ ] **Step 2: Bench**, recorded in `docs/bench.md` with the machine and the date:
  - the service's CPU at rest: `top -l 5 -pid <pid> -stats cpu` with the mouse untouched, target ≈ 0 %;
  - the latency from press to the probe's event: the median and p95 of 50 presses of the gesture button, target
    under 2 ms on top of HID++;
  - the service's CPU while the probe has a wheel area and the mouse circles over windows for 10 s.
  - The rows for the Intel Mac are left empty for the user to fill.
- [ ] **Step 3: The hardware checklist** in `docs/logitech-checklist.md`, run once:
  1. With the probe frontmost, the gesture button arrives. Switching to Finder gives `owner false` and the button
     is the system's again.
  2. `kill -9` the probe while it holds the button diverted: the gesture button works in Finder at once.
  3. `kill -9` the service while the probe is frontmost: the probe logs `owner false` and comes back as owner within
     2 s.
  4. With `--wheel ratchet`, the pointer over the probe's window gives a ratchet, and over the desktop the mouse's
     own mode.
  5. The SmartShift button with `--wheel` and without `0xC4` diverted: the probe gets `wheel byButton true`.
  6. The Mac sleeps and wakes, and step 1 still holds.
- [ ] **Step 4:** Commit:
  `git commit -m "mouse-client-probe, the first bench numbers and the hardware checklist"`.

---

### Task 8: FrameScrub as a client

Repository `~/Projects/GitHub/FrameScrub`, branch `polish-2`.

**Files:**
- Modify:
  - `Package.swift`: `.package(path: "../MouseService")` and the product `MouseClient` for the `FrameScrub`
    target; LogiHIDPP stays for its value types (`HapticPattern`, `HapticChoice`, `WheelMode`, `CID`)
  - `Sources/FrameScrub/LogiMouseBridge.swift`: rewritten over `MouseClient`
  - `Sources/FrameScrub/PlayerWindowController.swift:2443-2475`, `updatePrecisionWheel`
  - `Sources/FrameScrubCore/Config.swift`: the keys `haptic-strength` and `mx-panel-force`
  - `Sources/FrameScrubSettings/Pages/PageMouse.swift`
- Test: `Tests/FrameScrubCoreTests` (the existing config tests file)

**Interfaces:**
- Consumes `MouseClient` from Task 4.
- Keeps the bridge's existing members with their current signatures: `onButton`, `onHighResolution`,
  `onWheelMode`, `onSmartShift`, `watching`, `isHighResolution`, `apply(config:map:)`, `takeSmartShift(_:)` and
  `play(_:config:)`.
- Replaces `wantHighResolutionWheel(_:)`, `wantWheelMode(_:)`, `recheckHighResolutionWheel()` and
  `recheckWheelMode()` with one method:
  `func wantWheel(window: Int?, mode: LogiHIDPP.WheelMode?, highResolutionRect: CGRect?)`.
  - It sends `wheel: [{window, mode}, {window, rects: [rect], highResolution: true}]` when given a window and a
    rect.
  - It sends only the first entry without a rect.
  - It sends `[]` when the window or the mode is nil.

**Behaviour:**
- `apply(config:map:)` builds the `Want`'s divert and watch sets exactly as `sendControls` does now, with 0xC4
  added while it takes SmartShift. It no longer writes the haptic strength or the panel force.
- `updatePrecisionWheel`:
  - It calls `wantWheel(window: window.windowNumber, mode: wants.wheelMode, highResolutionRect: wants.highResolution ? <videoView frame in window coordinates> : nil)`.
  - The rect is `videoView.convert(videoView.bounds, to: nil)`.
  - It keeps `takeSmartShift(wants.wheelMode != nil)`.
  - The two `recheck…` blocks and `precisionCheckedAt` are removed: the service rechecks on its own.
- Line 285 calls `recheckHighResolutionWheel()`; it is removed too.
- `onWheel` maps onto `onHighResolution` (on a change) and `onWheelMode(mode, byButton)`. Button events with CID
  0xC4 go to `onSmartShift`, the rest to `onButton`, as now.
- In `Config`, `haptic-strength` and `mx-panel-force` are accepted, ignored and warned about once per load. The
  warning reads: "`<key>`: now in MouseService's settings".
- In `PageMouse`, the "Strength" and "Panel force" rows are removed. One row is added to the "MX Master" section:
  `.button("MouseService", "Open", description: "Logitech buttons, haptics and Precision Scroll come from MouseService; without it the mouse works as an ordinary one. Haptic strength and panel force are set there.")`.
  It opens the app with `NSWorkspace.shared.openApplication(at:)` via `urlForApplication(withBundleIdentifier: "local.mouseservice")`.

- [ ] **Step 1: Write the failing test** `oldMouseDeviceKeysWarn`. Parsing `haptic-strength=50` and
  `mx-panel-force=10` gives two warnings containing "MouseService", and the config keeps its defaults.
- [ ] **Step 2:** Run `swift test --filter FrameScrubCoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the config change, the bridge, `updatePrecisionWheel`, the settings page and the
  package.
- [ ] **Step 4:** Run `swift build && swift test`. Expected: success and all PASS.
- [ ] **Step 5:** Run `scripts/make-app.sh --install` and go through FrameScrub's own `docs/logitech-checklist.md` with the
  MouseService agent running. Not done until it passes: the "Behaviour for the user does not change" requirement
  stands on this run.
- [ ] **Step 6:** Commit:
  `git commit -m "Logitech mouse through MouseService (MouseClient): the bridge keeps its interface, Precision Scroll over the video is a declared area, haptic strength and panel force moved to the service"`.

---

### Task 9: Loupe as a client

Repository `~/Projects/GitHub/Loupe`, branch `polish-2`. Build with
`. scripts/libjxl-env.sh; swift build --triple "$DEPS_TRIPLE" --product Loupe`.

**Files:**
- Modify:
  - `Package.swift`: `.package(path: "../MouseService")`, `MouseClient` for the `Loupe` target
  - `Sources/Loupe/AppDelegate.swift:556-640` and `:897-905`
  - `Sources/LoupeCore/Config.swift`: the keys `haptic-strength` and `mx-panel-force`
  - `Sources/LoupeSettings/Pages/PageMouse.swift`
- Test: the existing LoupeCore config tests file

**Interfaces:**
- Consumes `MouseClient`.
- `startLogiMouse` becomes `startMouseClient`, which makes one `MouseClient` and calls `start()`.
- `divertMouseInputs` sends `Want(divert:watch:thumbWheel:wheel: [])` with the same three values it computes now.
- `handle(_:)` keeps its body and switches on the client's callbacks:
  - the turn size `stepsPerRevolution` comes from `client.device.thumbWheelStepsPerRevolution`;
  - `heardSideButtons` reads `client.watching`;
  - `LogiHapticPlayer` calls `client.play(pattern: pattern.rawValue, strength:)`;
  - `.connected`, `.highResolutionWheel` and `.wheelMode` disappear;
  - `applyMouseSettings` and `applyPanelForce` are deleted.
- The config keys and the settings page change as in Task 8 ("Loupe" in the texts).

- [ ] **Step 1:** Write the failing test `oldMouseDeviceKeysWarn`, the same as in Task 8 against `LoupeCore`.
- [ ] **Step 2:** Run the LoupeCore tests with the triple. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Build and test. Expected: success and all PASS.
- [ ] **Step 5:** Install Loupe and check by hand:
  - the thumb wheel zooms;
  - a bound MX button fires;
  - haptics play;
  - switching between Loupe and FrameScrub moves the buttons with the front app;
  - no back press is left hanging after a switch made with a button held.
- [ ] **Step 6:** Commit:
  `git commit -m "Logitech mouse through MouseService (MouseClient): diverts, thumb wheel and haptics as a client, device settings moved to the service"`.

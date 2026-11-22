# Ulanzi D100H in FrameScrub

FrameScrub uses the D100H through MouseService 0.5.0 or later. The viewing profile is opt-in.
Set `d100h=yes` in
`~/.config/framescrub/framescrub.conf`. An open, focused player window requests the dial and releases it
when it loses eligibility. See [MouseService setup](../README.md#ulanzi-d100h) for permissions and the reader.

## Viewing controls

| Control | Action |
| --- | --- |
| Top-row left or right | Shuttle backward or forward. Repeating the same direction accelerates. |
| Top-row middle | Stop shuttle. Hold for at least 0.5 s and release to reset speed to 1×. Hold while turning to change speed. |
| Upper buttons to either side of the dial | Tap for previous or next video. Hold for at least 0.5 s and release to seek near the start or end. |
| Turn the dial | Send vertical scroll to the player. Press and turn to use accelerated scrubbing. |
| Lower left + turn | Seek in five-second steps using keyframes. |
| Lower right + turn | Change volume. Hold for at least 0.5 s and release without turning to toggle mute. |

Clockwise moves forward in time or increases speed or volume. A turn with a held modifier consumes
its release action. `d100h-edge-offset` defaults to 10 percent, so the two long presses target 10 and
90 percent. `d100h-mute-detents=yes` temporarily disables physical detents while the verified viewing
profile is active. Hardware checks confirmed detents off at `0x00` and on at `0xFF`. A value of
`0x01` read back successfully without perceptible feedback. Intermediate strength settings remain unverified.

## Data flow and recovery

- [`d100h-hid`](../Sources/d100h-hid/main.swift) exclusively opens the matching HID device and decodes its reports.
  By default, turning while pressing the dial sends the same consumer-control reports as turning normally.
  The managed reader relies on two temporary firmware assignments to distinguish the gestures.
- [`D100HSettings`](../Sources/MouseService/D100HSettings.swift) configures those assignments over CoreBluetooth
  on its serial queue. [`D100HCapture`](../Sources/MouseServiceKit/D100HCapture.swift) waits for read-back
  confirmation before accepting input. Optional detent muting for a viewing client waits for the same confirmation.
- The foreground request and XPC routing live in [`Service`](../Sources/MouseServiceKit/Service.swift).
  FrameScrub's `D100HViewingProfile` maps events to existing playback commands.
  Focus loss or disconnect cancels held gestures before any release action can fire.
- The agent saves original values before writing them. The recovery files are
  `~/Library/Application Support/MouseService/D100H-turns.json` and `D100H-detents.json`.
  A file left after disconnect is a pending restore. Preserve it so the agent can restore the original
  setting when the same dial reconnects.

## Checking wake and reconnect

Run both checks with the same video window in front and the vendor app closed.

1. Sleep and wake the Mac. Turn the dial while staying in FrameScrub. If the first turn does nothing,
   try again after the system wake event. Record when the player first responds.
2. With the Mac awake, power-cycle the D100H. Wait for it to reconnect and turn it in the same player
   window. Record whether any focus change was needed.
3. Switch to another app after the test and check that the original dial behavior returns.

Read the three stages in the unified log.

```sh
log show --last 10m --info --style compact --predicate 'subsystem == "local.mouseservice" AND (category == "D100HHID" OR category == "D100H" OR category == "D100HDaemon" OR eventMessage CONTAINS "System woke")'
```

| Message | What it confirms |
| --- | --- |
| `System woke: refreshing pointer services and settings` | The user agent received the system wake event. macOS can deliver it after screen unlock. |
| `D100H captured` | The helper has the HID device. Input still waits for the Bluetooth profile. |
| `D100H viewing profile ready` | Both pressed-turn assignments were verified and the agent can forward the profile's input. |
| `D100H turn assignments could not be verified` | Bluetooth setup or read-back failed. Compare nearby timeout messages and the recovery files. |
| `D100H released` | The helper released the HID device. An existing recovery file means a restore is still pending. |

Earlier sleep runs found two distinct issues. Unlock could resume the foreground request while the
daemon still rejected connections during system wake. The wake event now resets the reconnect budget
even when the player remains in focus. A later run did regain HID capture automatically, but Bluetooth
timed out after detent muting started early. The current build verifies the turn assignments before
muting detents. The physical wake and power-cycle checks above are still pending on that build.

## Building and packaging

The SwiftPM dependency uses the version tag `v0.5.0`. A local source mirror can resolve a local tag
for development. A clean build that fetches from GitHub needs the tag published to the remote.
The universal MouseService archive is ad hoc signed and supports the manual reader. Automatic
startup uses a certificate-signed MouseService application and helper with the same signing identity.

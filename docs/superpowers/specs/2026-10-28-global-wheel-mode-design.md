# Global wheel mode

Date: 2026-10-28. Sub-project 3 of the core spec (`2026-10-27-core-service-design.md`), cut down at the user's word:
the wheel has one global mode, ratchet by default; a client may ask for another over its own window; outside the
window the wheel goes back to the current global value.

## What changes

| Question | Decision |
|---|---|
| Default | Ratchet. The service always wants a wheel mode while it runs: the mouse's own mode is no longer left alone (it is given back at quit or after a crash, by `LogiHIDPP`'s marker, as before). |
| Who can ask for another | A client, by `WheelWish.mode`, over its declared window or rects, as in the contract today. An app that is not a client cannot. The contract does not change; only what "no wish" means: the global mode, not "the mouse's own". |
| Precision Scroll | Unchanged: a client's wish (`highResolution`), off elsewhere. No link between it and the mode. |
| Changing the global mode | Two ways. A press of the SmartShift button where no client's wish sets the mode (the press arrives as `wheel(byButton: true)` from `LogiHIDPP`, which takes it as the wanted mode and writes nothing back) sets the global mode and saves it. The setting "Wheel mode" (ratchet / free spin) in the service's settings sets it too. Over a client's mode wish a press goes to the client only (rule 6 of the core spec) and the global mode stays. Over a client's area that has no `mode` (only `highResolution`) the effective mode is the global one, so the press sets it and the client hears it too. |
| Where it is kept | `UserDefaults` key `wheel-mode` (`ratchet` or `free-spin`), the service's own settings, as the haptic keys. Not in the hand-edited config file: the service writes it. |
| Following the pointer | Unchanged: only while some client declares wheel areas. With none, the global mode holds everywhere and nothing is watched, so nothing runs at rest. |

## Arbiter

- `globalMode`, ratchet at start, set by `setGlobalMode(_:)` (settings, at launch) and by a press.
- `computeWanted`: `mode = first mode wish over the pointer ?? globalMode`. The mode is never nil.
- A press (`wheelState(byButton: true)`) whose mode source is the global mode sets `globalMode` and gives the effect
  `.globalMode(m)` (only when it changed) for the service to save.
- **A press over a client's mode wish changes what the mouse has but not what is wanted.** The arbiter remembers the
  source the press happened under (`global`, or a client's mode wish). Mouse moves inside the same area apply nothing:
  the user's press is not undone. When the source changes (the pointer leaves the area, the client goes, or its wish
  changes) the state is applied even if it equals the last wanted one, so the global mode comes back.
- `start()`: the first `update()`, called by the service when it is made, so the mode is applied before any client or
  app switch.

## Settings

A `choice` row "Wheel mode" on the Mouse page (SettingsKit's pop-up fills lazily). A press posts the store's change
notification so an open window shows it.

## Tests (MouseCore, no hardware)

Default ratchet from the start; a wish over the whole window or a rect, and the border; the client gone or the pointer
away gives the global mode back; a press outside clients and over a hi-res-only area sets the global mode and says so;
a press over a mode wish sets nothing; a move inside the area after such a press applies nothing; leaving the area
applies the global mode even when it equals the wish; `setGlobalMode` over a wish applies on leaving; ten changes in a
row give one apply per change. The service's tests expect the mode in every applied state and an apply at start.

## By hand

`docs/logitech-checklist.md` step 7: ratchet on the desktop; the probe with `--wheel freeSpin` frees the wheel over
its window only; a SmartShift press on the desktop survives restarting the service.

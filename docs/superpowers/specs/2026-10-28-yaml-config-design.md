# The devices config in YAML

Date: 2026-10-28. Replaces the file format of `2026-10-27-pointer-wheel-design.md` ("Where the rules live"); what the
rules do is unchanged.

`devices.json` was LinearMouse's format, kept for the one-time import: a scheme per condition, each repeating the
device's vendor, product and name, an app rule as a scheme of its own, the result depending on the order of schemes.
The new `~/.config/mouseservice/config.yaml` names a device once and nests its app rules.

```yaml
devices:
  MX Master 4:                      # the name is for people; the device is found by id (and serial)
    id: 46d:c548                    # vendor:product, hex
    speed: 0.125                    # 0…1
    acceleration: 0.225             # 0…40
    disable-acceleration: false
    reverse-scroll: vertical        # none | vertical | horizontal | both
    ignore-horizontal-scroll-with: [command, control]   # also ignore-vertical-scroll-with; shift, option too
    apps:
      com.example.App:              # the frontmost app's bundle ID; the same fields
        speed: 0.066
  Trackpad:
    id: 4c:265
    serial: "AA:BB:CC:DD:EE:FF"     # optional; only that unit
```

## Decisions

| Question | Decision |
|---|---|
| Matching | An entry matches a device by `id` and, when it has one, `serial`. Every matching entry applies in file order, its own fields first and then those of its `apps` entry for the frontmost app; a later field replaces an earlier one. Name and category are not matched (a vendor and product name one kind of device). |
| Field semantics | A field that is present replaces; one that is absent leaves what an earlier entry or the device has. `reverse-scroll` and the two `ignore-…` lists replace as a whole (no per-axis merge). |
| Parser | Yams (libyaml). Values are read from the parsed nodes; `id` as raw text (YAML would read `46d:c548` or `1234:5678` as a number). A wrong type, a bad id or an out-of-range number is an error that names the path; the rules read before stay in force. Unknown keys are ignored and logged. |
| Reload | As before: the file is watched (an editor's replace re-arms the watch), the menu has "Reload Devices Config". Never written by the service. |
| Migration | At start, when `config.yaml` is missing: `devices.json` if there is one (renamed `devices.json.bak`), else LinearMouse's own file. Each device found in the old rules gets an entry whose fields are the old rules' result for it (`resolve`), and each app named for it an `apps` entry with the fields that differ from the device's. The old format is not read after that. Rules that name no device (an `app` alone, or a condition the service cannot check) have no place in the new format: they are listed in a comment at the top. |
| What stays out | Haptic strength, panel force and the wheel mode stay in the service's settings window: the window (and a SmartShift press) writes them, and writing YAML back would lose its comments. |
| Dependency | Yams is in `Package.swift`: clients of `MouseClient` get it in their `Package.resolved` with the next tag. |

## Tests (PointerCore)

- Equivalence: for the scrubbed LinearMouse fixture (and, when `MOUSESERVICE_REAL_CONFIG` names a file, the real one)
  and every device identity in it × (no app and each app named anywhere), the old rules' `resolve` equals the new
  rules' `resolve` of the migrated YAML.
- The format: the example above; the serial's colons; an id YAML would read as a number; field replacement; entries
  merging in file order; errors with paths; unknown keys.
- A migrated file lists what it could not carry.

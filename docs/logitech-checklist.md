# Hardware checklist

A manual run with the MX Master 4, the agent running (`scripts/make-app.sh --install`) and the probe built
(`swift build --product mouse-client-probe`; run it as `$(swift build --show-bin-path)/mouse-client-probe …`). Each
line says what to do and what must happen.

1. `mouse-client-probe divert 0xC3`, click its window: `owner true`; the gesture button prints `button 0xC3 down/up`.
   Click Finder: `owner false`, and the gesture button does what it does without the probe.
2. Probe in front, hold the gesture button, `kill -9` the probe from another terminal: the gesture button works in
   Finder at once, and the service's menu lists no clients.
3. Probe in front: `launchctl kill SIGKILL gui/$(id -u)/local.mouseservice`. The probe prints `owner false`, then
   `available true` and `owner true` within 2 s.
4. `mouse-client-probe divert 0xC3 --wheel ratchet`: over the probe's window the wheel ratchets, over the desktop it
   has the mouse's own mode.
5. Same probe: a press of the SmartShift button over its window prints `wheel … byButton true`.
6. Sleep the Mac, wake it: step 1 still holds.

Run on 2026-10-27, M4 Max, macOS 27.0.1: step 1 (ownership, through System Events activating the probe and Finder)
passed: `owner true`, `watching []`, `owner false`. Steps 1 (buttons) to 6: *pending*, by hand.

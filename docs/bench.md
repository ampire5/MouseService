# Bench

Numbers for the rules in `CLAUDE.md`: what was measured, on which machine, the result. The rows marked *pending*
need hands on the mouse; fill them with `mouse-client-probe` as described.

## The service at rest

`top -l 6 -s 2 -pid <MouseService> -stats pid,cpu,idlew,power`, mouse untouched, one client (the probe) connected
earlier and gone.

| Machine | Date | CPU | Idle wake-ups | Notes |
|---|---|---|---|---|
| MacBook Pro, M4 Max, macOS 27.0.1 | 2026-10-27 | 0.0 % | 0 | RSS 47 MB; 0.22 s CPU since launch |
| Intel Mac | | | | |

## Latency: a press to the client's event

`swift run mouse-client-probe divert 0xC3 --latency 50`, the probe in front, the gesture button pressed 50 times.
The service stamps each report when `LogiMouse` delivers it; the probe prints `now - time`: the service's main
thread, XPC and the client's main thread. Target: under 2 ms (core spec, "Testing").

| Machine | Date | Median | p95 | Notes |
|---|---|---|---|---|
| MacBook Pro, M4 Max, macOS 27.0.1 | | *pending* | *pending* | |
| Intel Mac | | | | |

## Following the pointer

`swift run mouse-client-probe divert 0xC3 --wheel ratchet`, the mouse circling over windows for 10 s; the service's
CPU from `top` as above. Only while a client declares wheel areas; otherwise no monitor exists.

The topmost window's number is asked at most every 8 ms while the pointer stays inside the cached window's frame
(without it, a window that comes above the cached one under the pointer is never seen): `NSWindow.windowNumber(at:)`
cost 7 µs CPU and 25 µs wall per call on the M4 Max (macOS 27), 2026-10-28, so at most 0.1 % of a core.

| Machine | Date | CPU while moving | Notes |
|---|---|---|---|
| MacBook Pro, M4 Max, macOS 27.0.1 | | *pending* | |
| Intel Mac | | | |

## Settings UI, 2026-11-03

Opt-in real-window check: `MOUSESERVICE_UI_BENCH=1 swift test --filter settingsWindowResponsiveness`.
On Apple Silicon, main-thread CPU: first creation/show 110–117 ms; first page visits 8–16 ms; repeated visits
2–4 ms across four rounds without growth. Measured with `CLOCK_THREAD_CPUTIME_ID`. Intel execution was not available;
the release contains both arm64 and x86_64 slices. File reads, YAML parsing for interactive reload, and writes run
off the main actor. Ordinary tests do not open the settings window.

### Settings refinement, 2026-11-19

Measured the real settings window on Apple Silicon (macOS 27.2.1), with a fixture mouse and four navigation rounds.
Times are main-thread CPU milliseconds. The baseline used Swift Build and the final run used SwiftPM's native
build system.

| Action | Before | After |
|---|---:|---:|
| Create and open on Pointer & Scrolling | 169.1 | 129.0 |
| First visit to Buttons & Wheel or Import & Export | 13.7–19.5 | 13.2–19.6 |
| Return to a previously opened page | 4.2–6.3 | 3.6–5.3 |

Optional captures use the default 782 × 637 pt size in light appearance and the minimum 640 × 400 pt size in
dark appearance. Set `MOUSESERVICE_BENCH_OUTPUT` to an existing directory when running the benchmark.

### Application rules and gesture controls, 2026-11-21

The same four-round check on Apple Silicon with macOS 27.2.1 measured 130.3 ms of main-thread CPU to create and
open Settings. First visits took 18.3 ms for Buttons & Wheel and 11.6 ms for Import & Export. Return visits took
3.0–4.3 ms. The application picker was checked at both captured window sizes and wraps its controls in the
narrow layout.

import AppKit
import MouseClient
import MouseContract

// mouse-client-probe divert 0xC3,0xC4 [--watch 0x53,0x56] [--thumb] [--wheel freeSpin|ratchet] [--hires]
//
// A regular app with one window, so it can be frontmost: it asks MouseService for the controls given and prints
// every event with its latency (now - the service's time of the mouse's report, in ms). `--wheel` and `--hires`
// declare the probe's window as the area; `--latency N` prints the median and p95 after N presses.

func cids(_ text: String) -> Set<UInt16> {
    Set(text.split(separator: ",").compactMap { UInt16($0.dropFirst($0.hasPrefix("0x") ? 2 : 0), radix: 16) })
}

var args = Array(CommandLine.arguments.dropFirst())
var divert: Set<UInt16> = []
var watch: Set<UInt16> = []
var thumb = false
var mode: WheelMode?
var hires = false
var latencyCount = 0
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "divert": divert = cids(args.isEmpty ? "" : args.removeFirst())
    case "--watch": watch = cids(args.isEmpty ? "" : args.removeFirst())
    case "--thumb": thumb = true
    case "--wheel": mode = args.isEmpty ? nil : (args.removeFirst() == "ratchet" ? .ratchet : .freeSpin)
    case "--hires": hires = true
    case "--latency": latencyCount = args.isEmpty ? 0 : Int(args.removeFirst()) ?? 0
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
        exit(2)
    }
}
setvbuf(stdout, nil, _IOLBF, 0)

@MainActor final class Probe: NSObject, NSApplicationDelegate {
    let client = MouseClient(bundleID: "local.mouseservice.probe")
    var window: NSWindow!
    var latencies: [Double] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "mouse-client-probe"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let ms = { (time: Double) in String(format: "%.2f ms", (ProcessInfo.processInfo.systemUptime - time) * 1000) }
        client.onAvailability = { print("available \($0)") }
        client.onOwner = { print("owner \($0)") }
        client.onWatching = { print("watching \($0.sorted().map { String(format: "0x%02X", $0) })") }
        client.onDevice = { print("device present \($0.present), \($0.controls.count) controls, haptics \($0.haptics)") }
        client.onWheel = { print("wheel highResolution \($0) mode \(String(describing: $1)) byButton \($2)") }
        client.onThumbWheel = { delta, touching, phase, time in
            print("thumb \(delta) touching \(touching) \(phase) \(ms(time))")
        }
        client.onButton = { [weak self] cid, pressed, time in
            print(String(format: "button 0x%02X %@ ", cid, pressed ? "down" : "up") + ms(time))
            guard let self, pressed, latencyCount > 0 else { return }
            latencies.append((ProcessInfo.processInfo.systemUptime - time) * 1000)
            if latencies.count == latencyCount {
                let sorted = latencies.sorted()
                print(String(format: "latency over %d presses: median %.2f ms, p95 %.2f ms", sorted.count,
                             sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]))
                latencies = []
            }
        }
        client.start()
        var wishes: [WheelWish] = []
        if mode != nil || hires {
            wishes = [WheelWish(window: window.windowNumber, highResolution: hires ? true : nil, mode: mode)]
        }
        client.want(Want(divert: divert, watch: watch, thumbWheel: thumb, wheel: wishes))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe()
app.delegate = probe
app.run()

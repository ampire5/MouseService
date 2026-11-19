import AppKit
import Foundation
import PointerCore
import Testing
@testable import MouseService

/// Opt-in measurement of the real settings window; ordinary tests do not open windows.
@Test @MainActor func settingsWindowResponsiveness() async throws {
    guard ProcessInfo.processInfo.environment["MOUSESERVICE_UI_BENCH"] == "1" else { return }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "MouseServiceBench.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ServiceSettings(defaults: defaults)
    let controller = DeviceSettingsController(file: DevicePreferencesFile(url: directory.appendingPathComponent("config.yaml")),
                                              preferences: store)
    controller.connectedDevices = {
        [DeviceIdentity(vendorID: 0x1234, productID: 1, productName: "Example mouse", category: .mouse),
         DeviceIdentity(vendorID: 0x1234, productID: 2, productName: "Trackpad", category: .trackpad)]
    }
    await controller.refresh()
    func cpu() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
    let start = cpu()
    let window = controller.makeSettingsWindow(autosaveName: name, lastPageDefaultsKey: name)
    window.show(page: "devices")
    print("UI-BENCH first window CPU ms: \((cpu() - start) * 1000)")
    for round in 1...4 {
        for page in ["mouse", "transfer", "devices"] {
            let begin = cpu()
            window.show(page: page)
            print("UI-BENCH round \(round) page \(page) CPU ms: \((cpu() - begin) * 1000)")
        }
    }
    if let output = ProcessInfo.processInfo.environment["MOUSESERVICE_BENCH_OUTPUT"] {
        let nativeWindow = try #require(window.window)
        let view = try #require(nativeWindow.contentView)
        for (appearance, size) in [(NSAppearance.Name.aqua, NSSize(width: 782, height: 637)),
                                   (.darkAqua, NSSize(width: 640, height: 400))] {
            nativeWindow.appearance = NSAppearance(named: appearance)
            for page in ["devices", "mouse", "transfer"] {
                window.show(page: page)
                nativeWindow.setContentSize(size)
                nativeWindow.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let theme = appearance == .aqua ? "light" : "dark"
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("settings-\(page)-\(theme).png"))
            }
        }
    }
    window.close()
    UserDefaults.standard.removeObject(forKey: name)
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
}

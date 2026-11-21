import GestureCore
import os
import SwiftUI

/// Only stores results while the user has explicitly started a test.
final class GestureDiagnostics: Sendable {
    struct Snapshot: Sendable {
        var button: SideButtonGesture.Button?
        var clientPID: pid_t?
        var released = false
        var pageSwipeSent = false
        var mouseClickDelivered = false
        var dockSwipeRecognized = false
        var dockEventSent = false
        var dockPhase: SideButtonGesture.Phase?
    }

    private let state = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)
    var snapshot: Snapshot? { state.withLock { $0 } }

    func start() { state.withLock { $0 = Snapshot() } }
    func stop() { state.withLock { $0 = nil } }
    var isRunning: Bool { state.withLock { $0 != nil } }

    func press(_ button: SideButtonGesture.Button, clientPID: pid_t? = nil) {
        state.withLock {
            if $0 != nil { $0 = Snapshot(button: button, clientPID: clientPID) }
        }
    }
    func release(_ button: SideButtonGesture.Button) {
        state.withLock {
            if $0?.button == button { $0?.released = true }
        }
    }
    func click(delivered: Bool) {
        state.withLock {
            if $0?.button != nil {
                $0?.mouseClickDelivered = delivered
                $0?.pageSwipeSent = !delivered
            }
        }
    }
    func dock(phase: SideButtonGesture.Phase, sent: Bool) {
        guard phase != .changed else { return }
        state.withLock {
            $0?.dockSwipeRecognized = true
            if sent { $0?.dockEventSent = true }
            $0?.dockPhase = phase
        }
    }
}

struct GestureServiceStatus {
    let version: String
    let activeClient: String?
    let listening: Bool
}

struct GestureTestControls: View {
    let controller: DeviceSettingsController
    @State private var running = false
    @State private var result: GestureDiagnostics.Snapshot?
    @State private var status: GestureServiceStatus?
    @State private var failedToStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Check a side-button gesture").font(.headline)
                Spacer()
                Button(running ? "Stop Test" : "Start Test") {
                    if running {
                        result = controller.gestureDiagnostics.snapshot
                        stopTest()
                    } else {
                        controller.gestureDiagnostics.start()
                        controller.gestureTestChanged?()
                        status = controller.gestureServiceStatus(nil)
                        failedToStart = status?.listening != true
                        if failedToStart {
                            result = nil
                            stopTest()
                        } else {
                            result = controller.gestureDiagnostics.snapshot
                            running = true
                        }
                    }
                    status = controller.gestureServiceStatus(result?.clientPID)
                }
            }
            if let status {
                line("Service", "\(status.version) · \(status.listening ? "Listening" : "Gestures inactive")")
                line(result?.clientPID == nil ? "Active client" : "Client at press", status.activeClient ?? "None")
            }
            if failedToStart {
                Text(controller.accessibilityGranted ? "Couldn’t start the mouse event listener."
                     : "Allow Accessibility access to test side buttons.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let result {
                if let button = result.button {
                    line("Button", button == .back ? "Back" : "Forward")
                    if result.dockSwipeRecognized {
                        line("Motion", result.dockPhase == .cancelled ? "Swipe cancelled" : "Swipe recognized")
                        line("Dock event", result.dockEventSent ? "Sent" : "Couldn’t create event")
                    } else if result.pageSwipeSent {
                        line("Result", "Page swipe sent")
                    } else if result.mouseClickDelivered {
                        line("Result", "Mouse click passed through")
                    } else {
                        line("Result", result.released ? "No swipe generated" : "Button down")
                    }
                } else {
                    Text("Click Back or Forward, or hold the gesture button and move the mouse.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .onAppear { status = controller.gestureServiceStatus(nil) }
        .task(id: running) {
            guard running else { return }
            let deadline = ContinuousClock.now + .seconds(30)
            while !Task.isCancelled && ContinuousClock.now < deadline {
                result = controller.gestureDiagnostics.snapshot
                status = controller.gestureServiceStatus(result?.clientPID)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            stopTest()
        }
        .onDisappear { if running { stopTest() } }
    }

    private func stopTest() {
        controller.gestureDiagnostics.stop()
        controller.gestureTestChanged?()
        status = controller.gestureServiceStatus(result?.clientPID)
        running = false
    }

    private func line(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .font(.subheadline)
    }
}

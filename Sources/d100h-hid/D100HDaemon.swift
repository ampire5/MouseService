import CryptoKit
import Foundation
import IOKit.pwr_mgt
import MouseContract
import Security
import SystemConfiguration
import XPC
import os

/// The system launchd job only accepts capture sessions from the signed agent of the active console user.
/// XPC, console notifications and IOHID run on the daemon's main run loop.
@MainActor final class D100HDaemon {
    // The SDK's IOMessage.h macros expand through iokit_common_msg, which Swift cannot import.
    private enum PowerMessage: UInt32 {
        case canSleep = 0xe0000270
        case willSleep = 0xe0000280
        case hasPoweredOn = 0xe0000300
    }
    private let reader = DialReader(fourTurnTest: false, managed: true)
    private let log = Logger(subsystem: "local.mouseservice", category: "D100HDaemon")
    private var consoleUID: uid_t?
    private var unrestoredUID: uid_t?
    private var peer: xpc_connection_t?
    private var recovering = false
    private var listener: xpc_connection_t?
    private var consoleStore: SCDynamicStore?
    private var awaitingRelease: Task<Void, Never>?
    private var releaseDeadline: ContinuousClock.Instant?
    private var awake = true
    private var powerPort: io_connect_t = 0
    private var powerNotification: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var sleepAcknowledgment: Int?

    func run() {
        guard let requirement = Self.agentRequirement() else {
            log.error("D100H automatic start requires a certificate-signed bundle")
            exit(78)
        }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "D100H console session" as CFString, { _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<D100HDaemon>.fromOpaque(context).takeUnretainedValue().updateConsole()
            }
        }, &context),
        SCDynamicStoreSetNotificationKeys(store, ["State:/Users/ConsoleUser"] as CFArray, nil),
        SCDynamicStoreSetDispatchQueue(store, .main) else {
            log.error("Cannot monitor the D100H console session")
            exit(78)
        }
        consoleStore = store
        updateConsole()
        guard monitorPower() else {
            log.error("Cannot monitor D100H sleep and wake")
            exit(78)
        }
        reader.start()
        reader.onCapture = { [weak self] open in
            guard open, let self, let peer else { return }
            unrestoredUID = xpc_connection_get_euid(peer)
        }

        let listener = xpc_connection_create_mach_service(D100HHelperMessage.daemonName, .main,
                                                          UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [weak self] message in
            guard xpc_get_type(message) == XPC_TYPE_CONNECTION else { return }
            nonisolated(unsafe) let connection = message
            MainActor.assumeIsolated { self?.accept(connection, requirement: requirement) }
        }
        xpc_connection_resume(listener)
        CFRunLoopRun()
    }

    private func accept(_ connection: xpc_connection_t, requirement: String) {
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
            xpc_connection_cancel(connection)
            return
        }
        xpc_connection_set_target_queue(connection, .main)
        nonisolated(unsafe) let source = connection // XPC delivers all callbacks for this connection on .main.
        xpc_connection_set_event_handler(connection) { [weak self] message in
            nonisolated(unsafe) let message = message
            MainActor.assumeIsolated { self?.receive(message, from: source) }
        }
        xpc_connection_resume(connection)
    }

    private func receive(_ message: xpc_object_t, from source: xpc_connection_t) {
        if xpc_get_type(message) == XPC_TYPE_ERROR {
            if peer === source { disconnect() }
            return
        }
        switch D100HHelperMessage(xpc: message) {
        case .connect:
            guard awake, peer == nil, let consoleUID, xpc_connection_get_euid(source) == consoleUID,
                  unrestoredUID == nil || unrestoredUID == consoleUID else {
                xpc_connection_cancel(source)
                return
            }
            peer = source
            reader.reportsEnabled = true
            reader.connection = source
            recovering = unrestoredUID != nil
            let response: D100HHelperMessage = recovering ? .recover : .managedHello
            xpc_connection_send_message(source, response.xpc())
        case let .capture(session):
            guard peer === source, !recovering, let session, awaitingRelease == nil, awake,
                  let consoleUID, xpc_connection_get_euid(source) == consoleUID else { return }
            reader.setCapture(session)
        case let .release(restored):
            guard peer === source else { return }
            if restored, unrestoredUID == xpc_connection_get_euid(source) { unrestoredUID = nil }
            reader.setCapture(nil)
            if awaitingRelease != nil || (recovering && !restored) {
                disconnect()
            } else if recovering {
                recovering = false
                xpc_connection_send_message(source, D100HHelperMessage.managedHello.xpc())
            }
        default:
            break
        }
    }

    private func updateConsole() {
        var uid: uid_t = 0
        let user = SCDynamicStoreCopyConsoleUser(consoleStore, &uid, nil) as String?
        let next = user != nil && user != "loginwindow" && uid != 0 ? uid : nil
        guard consoleUID != next else { return }
        consoleUID = next
        retirePeer(after: .seconds(8))
    }

    private func retirePeer(after timeout: Duration) {
        guard let peer, unrestoredUID != nil else { disconnect(); return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        if let releaseDeadline, releaseDeadline <= deadline { return }
        releaseDeadline = deadline
        reader.reportsEnabled = false
        if awaitingRelease == nil { xpc_connection_send_message(peer, D100HHelperMessage.suspend.xpc()) }
        awaitingRelease?.cancel()
        awaitingRelease = Task { [weak self] in
            do { try await Task.sleep(until: deadline) }
            catch { return }
            self?.disconnect()
        }
    }

    private func disconnect() {
        awaitingRelease?.cancel()
        awaitingRelease = nil
        releaseDeadline = nil
        reader.disconnect()
        if let peer { xpc_connection_cancel(peer) }
        peer = nil
        recovering = false
        if let notification = sleepAcknowledgment {
            sleepAcknowledgment = nil
            IOAllowPowerChange(powerPort, notification)
        }
    }

    private func monitorPower() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(context, &powerNotification, { context, _, type, argument in
            guard let context else { return }
            let identifier = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                Unmanaged<D100HDaemon>.fromOpaque(context).takeUnretainedValue().powerChanged(type, identifier)
            }
        }, &powerNotifier)
        guard powerPort != 0, let powerNotification else { return false }
        IONotificationPortSetDispatchQueue(powerNotification, .main)
        return true
    }

    private func powerChanged(_ type: UInt32, _ identifier: Int) {
        switch PowerMessage(rawValue: type) {
        case .canSleep:
            IOAllowPowerChange(powerPort, identifier)
        case .willSleep:
            awake = false
            sleepAcknowledgment = identifier
            retirePeer(after: .seconds(2))
        case .hasPoweredOn:
            awake = true
            updateConsole()
        case nil:
            break
        }
    }

    // Both binaries are signed with the same certificate during bundle packaging.
    private static func agentRequirement() -> String? {
        var code: SecCode?
        var executable: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let signingInfo = info as? [String: Any],
              let certificates = signingInfo[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "identifier \"local.mouseservice\" and certificate leaf = H\"\(hash)\""
    }
}

import Foundation
import IOKit.hid
import MouseClient
import MouseContract
import XPC
import os

/// This process reads only the D100H, and only while MouseService has an active capture session.
@MainActor final class DialReader {
    var connection: xpc_connection_t?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
    private let runLoop: CFRunLoop = CFRunLoopGetMain()
    private let mode = CFRunLoopMode.defaultMode.rawValue
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private let fourTurnTest: Bool
    private let managed: Bool
    private let log = Logger(subsystem: "local.mouseservice", category: "D100HHID")
    private var device: IOHIDDevice?
    private var session: UInt64?
    private var acknowledged = false
    private var decoder: ReportDecoder
    private var retry: Task<Void, Never>?
    private var openFailures = 0
    var reportsEnabled = true
    var onCapture: ((Bool) -> Void)?

    init(fourTurnTest: Bool, managed: Bool) {
        self.fourTurnTest = fourTurnTest
        self.managed = managed
        decoder = ReportDecoder(fourTurnTest: fourTurnTest || managed)
    }

    func start() {
        let matching = [kIOHIDVendorIDKey: 0xfff1, kIOHIDProductIDKey: 0x0082]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            MainActor.assumeIsolated {
                Unmanaged<DialReader>.fromOpaque(context!).takeUnretainedValue().updateDevice()
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, removed in
            MainActor.assumeIsolated {
                Unmanaged<DialReader>.fromOpaque(context!).takeUnretainedValue().removed(removed)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, mode)
    }

    func setCapture(_ session: UInt64?) {
        let changed = self.session != session
        if changed {
            resetDecoder()
            retry?.cancel()
            retry = nil
            openFailures = 0
        }
        self.session = session
        updateDevice(reportIfAlreadyOpen: changed)
    }

    func disconnect() {
        setCapture(nil)
        connection = nil
    }

    func run() {
        start()
        let connection = xpc_connection_create_mach_service(MouseClient.serviceName, .main, 0)
        self.connection = connection
        xpc_connection_set_event_handler(connection) { [weak self] object in
            nonisolated(unsafe) let object = object
            MainActor.assumeIsolated {
                guard let self else { return }
                if xpc_get_type(object) == XPC_TYPE_ERROR {
                    self.close()
                    CFRunLoopStop(self.runLoop)
                } else if case let .refused(reason) = ServiceMessage(xpc: object) {
                    FileHandle.standardError.write(Data("\(reason)\n".utf8))
                    self.close()
                    CFRunLoopStop(self.runLoop)
                } else if case let .capture(session) = D100HHelperMessage(xpc: object) {
                    self.acknowledged = true
                    self.setCapture(session)
                }
            }
        }
        xpc_connection_resume(connection)
        let hello: D100HHelperMessage = managed ? .managedHello : .hello
        xpc_connection_send_message(connection, hello.xpc())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !acknowledged else { return }
            FileHandle.standardError.write(Data("MouseService did not acknowledge the D100H reader\n".utf8))
            CFRunLoopStop(runLoop)
        }
        CFRunLoopRun()
        disconnect()
        xpc_connection_cancel(connection)
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, mode)
        buffer.deallocate()
    }

    private func removed(_ removed: IOHIDDevice) {
        if let device, CFEqual(device, removed) {
            close()
            lostDevice()
        }
        openFailures = 0
        updateDevice(excluding: removed)
    }

    private func updateDevice(excluding removed: IOHIDDevice? = nil, reportIfAlreadyOpen: Bool = false) {
        guard session != nil, reportsEnabled else { if session == nil { close() }; return }
        let matching = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).filter {
            candidate in removed.map { !CFEqual(candidate, $0) } ?? true
        }
        guard matching.count == 1, let target = matching.first else {
            if device != nil { close(); lostDevice() }
            return
        }
        if let device, CFEqual(device, target) {
            if reportIfAlreadyOpen { reportCapture(open: true) }
            return
        }
        if device != nil { close(); lostDevice() }

        let result = IOHIDDeviceOpen(target, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            let code = String(UInt32(bitPattern: result), radix: 16)
            log.error("D100H could not be captured (0x\(code, privacy: .public))")
            scheduleRetry()
            return
        }
        retry?.cancel()
        retry = nil
        openFailures = 0
        device = target
        IOHIDDeviceRegisterInputReportCallback(target, buffer, 256, { context, status, _, type, id, bytes, count in
            guard status == kIOReturnSuccess, type == kIOHIDReportTypeInput,
                  (id == 1 && count == 9 && bytes[0] == 1) || (id == 2 && count == 3 && bytes[0] == 2) else {
                return
            }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let timestamp = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                Unmanaged<DialReader>.fromOpaque(context!).takeUnretainedValue().receive(report, time: timestamp)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(target, runLoop, mode)
        reportCapture(open: true)
        log.info("D100H captured")
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        guard openFailures < 3 else { reportCapture(open: false); return }
        openFailures += 1
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.retry = nil
            self?.updateDevice()
        }
    }

    private func resetDecoder() { decoder = ReportDecoder(fourTurnTest: fourTurnTest || managed) }

    private func close() {
        resetDecoder()
        guard let device else { return }
        self.device = nil
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, mode)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        log.info("D100H released")
    }

    private func lostDevice() {
        if managed { reportCapture(open: false) }
        else { send(.cancelled) }
    }

    private func reportCapture(open: Bool) {
        guard managed, let connection, let session else { return }
        onCapture?(open)
        xpc_connection_send_message(connection, D100HHelperMessage.captured(session: session, open: open).xpc())
    }

    private func receive(_ report: [UInt8], time: Double) {
        guard device != nil, reportsEnabled else { return }
        if report[0] == 1 {
            for event in decoder.keyboard(modifiers: report[1], keys: report[3...]) { send(event, time: time) }
        } else {
            let usage = UInt16(report[1]) | UInt16(report[2]) << 8
            if let event = decoder.consumer(usage) { send(event, time: time) }
        }
    }

    private func send(_ event: D100HInput, time: Double = ProcessInfo.processInfo.systemUptime) {
        guard let connection, let session else { return }
        #if DEBUG
        if MouseClient.serviceName == "local.mouseservice.d100h-test.xpc" {
            FileHandle.standardError.write(Data("D100H input \(time) \(event)\n".utf8))
        }
        #endif
        xpc_connection_send_message(connection, D100HHelperMessage.input(session: session, event: event, time: time).xpc())
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("Usage: sudo d100h-hid --service | --probe [--four-turn-test]\n".utf8))
    exit(2)
}
switch arguments {
case ["--daemon"]:
    D100HDaemon().run()
case ["--service"], ["--probe"], ["--probe", "--four-turn-test"]:
    DialReader(fourTurnTest: arguments.contains("--four-turn-test"), managed: arguments == ["--service"]).run()
default:
    exit(2)
}

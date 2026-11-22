import CoreBluetooth
import Foundation
import MouseServiceKit
import os

/// One on-demand settings connection to a bonded D100H. Bluetooth callbacks and recovery I/O run on `queue`.
final class D100HSettings: NSObject, @unchecked Sendable {
    private enum Property: Hashable {
        case detents
        case assignment(D100HTurnMapping.Slot)
    }

    private struct Pending {
        let property: Property
        let write: UInt16?
    }

    private let queue = DispatchQueue(label: "local.mouseservice.d100h", qos: .utility)
    private let log = Logger(subsystem: "local.mouseservice", category: "D100H")
    private let journalURL: URL
    private let turnsJournalURL: URL
    private let service = CBUUID(string: "1971")
    private let inputID = CBUUID(string: "FD00")
    private let outputID = CBUUID(string: "FD01")
    private var wanted = false
    private var loaded = false
    private var saved: D100HDetentRecovery?
    private var savedTurns: D100HTurnMapping?
    private var turnsWanted = false
    private var turnsResult: (@Sendable (Bool) -> Void)?
    private var turnsDeadline: DispatchWorkItem?
    private var central: CBCentralManager?
    private var dial: CBPeripheral?
    private var output: CBCharacteristic?
    private var ready = false
    private var pending: Pending?
    private var deadline: DispatchWorkItem?
    private var values: [Property: UInt16] = [:]
    private var expectedReadBack: UInt16?
    private var retries = 0
    private var shuttingDown = false
    private var stopping: (@Sendable () -> Void)?

    override convenience init() {
        let url = URL.applicationSupportDirectory.appending(path: "MouseService/D100H-detents.json")
        self.init(journalURL: url)
    }

    init(journalURL: URL) {
        self.journalURL = journalURL
        turnsJournalURL = journalURL.deletingLastPathComponent().appending(path: "D100H-turns.json")
        super.init()
    }

    func recover() { queue.async { self.update() } }

    func setMuted(_ muted: Bool) {
        queue.async {
            guard !self.shuttingDown else { return }
            self.wanted = muted
            self.retries = 0
            self.values[.detents] = nil
            self.update()
        }
    }

    func setTurnMapping(_ enabled: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let finish: @Sendable (Bool) -> Void = { success in
            DispatchQueue.main.async { completion(success) }
        }
        queue.async { [self] in
            guard !shuttingDown else { finish(false); return }
            turnsDeadline?.cancel()
            turnsResult?(false)
            turnsWanted = enabled
            turnsResult = finish
            retries = 0
            for slot in D100HTurnMapping.Slot.allCases { values[.assignment(slot)] = nil }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.turnsWanted = false
                self.finishTurnRequest(false)
                self.update()
            }
            turnsDeadline = deadline
            queue.asyncAfter(deadline: .now() + 7, execute: deadline)
            update()
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.shuttingDown = true
            self.stopping = completion
            self.wanted = false
            self.turnsWanted = false
            self.values.removeAll()
            self.update()
            guard self.stopping != nil else { return }
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishStopping() }
        }
    }

    private func update() {
        do {
            if !loaded {
                saved = try load(D100HDetentRecovery.self, from: journalURL)
                savedTurns = try load(D100HTurnMapping.self, from: turnsJournalURL)
                loaded = true
            }

            guard needsConnection || pending != nil else {
                finishTurnRequest(true)
                disconnect()
                finishStopping()
                return
            }
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue,
                                          options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            guard let central, central.state == .poweredOn else { return }
            guard let dial else {
                discover(using: central)
                return
            }
            guard ready, pending == nil else { return }
            if try updateTurns(device: dial.identifier) { return }
            guard wanted || saved != nil else { return }
            guard let value = values[.detents] else {
                send(.detents)
                return
            }

            switch D100HDetentRecovery.action(device: dial.identifier, current: value, muted: wanted, saved: saved) {
            case .idle:
                retries = 0
            case let .save(snapshot):
                try save(snapshot, to: journalURL)
                saved = snapshot
                send(.detents, write: 0)
            case .forget:
                try forget(journalURL)
                saved = nil
                retries = 0
                update()
            case let .write(newValue):
                send(.detents, write: newValue)
            }
        } catch {
            log.error("D100H recovery file could not be accessed: \(error.localizedDescription, privacy: .public)")
            finishTurnRequest(false)
            disconnect()
            finishStopping()
        }
    }

    private var needsConnection: Bool { wanted || saved != nil || turnsWanted || savedTurns != nil }

    /// Returns true when a firmware operation is in flight or when update needs to run again.
    private func updateTurns(device: UUID) throws -> Bool {
        guard turnsWanted || savedTurns != nil else { finishTurnRequest(true); return false }
        if turnsWanted, savedTurns == nil, let central {
            let attached = central.retrieveConnectedPeripherals(withServices: [service])
                .filter { $0.name == "Ulanzi Dial" }
            guard attached.count == 1, attached.first?.identifier == device else {
                finishTurnRequest(false)
                return false
            }
        }
        guard let left = values[.assignment(.left)] else { send(.assignment(.left)); return true }
        guard let right = values[.assignment(.right)] else { send(.assignment(.right)); return true }
        let current = D100HTurnMapping.Assignments(left: UInt8(clamping: left), right: UInt8(clamping: right))
        switch D100HTurnMapping.action(device: device, current: current, enabled: turnsWanted, saved: savedTurns) {
        case .ready:
            finishTurnRequest(true)
            retries = 0
            return false
        case .conflict:
            log.error("D100H assignments changed outside MouseService")
            finishTurnRequest(false)
            return false
        case .forget:
            try forget(turnsJournalURL)
            savedTurns = nil
            retries = 0
            update()
        case let .save(snapshot):
            try save(snapshot, to: turnsJournalURL)
            savedTurns = snapshot
            update()
        case let .write(slot, value):
            send(.assignment(slot), write: UInt16(value))
        }
        return true
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private func save<T: Encodable>(_ snapshot: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func forget(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }

    private func finishTurnRequest(_ success: Bool) {
        turnsDeadline?.cancel()
        turnsDeadline = nil
        guard let result = turnsResult else { return }
        turnsResult = nil
        if success && turnsWanted { log.notice("D100H viewing profile ready") }
        if !success { log.error("D100H turn assignments could not be verified") }
        result(success)
    }

    private func matchesRecoveryDevice(_ peripheral: CBPeripheral) -> Bool {
        (saved?.device ?? peripheral.identifier) == peripheral.identifier
            && (savedTurns?.device ?? peripheral.identifier) == peripheral.identifier
    }

    private func discover(using central: CBCentralManager) {
        let matches = central.retrieveConnectedPeripherals(withServices: [service]).filter {
            $0.name == "Ulanzi Dial" && matchesRecoveryDevice($0)
        }
        if matches.count == 1, let match = matches.first {
            connect(match, using: central)
        } else if matches.isEmpty, !central.isScanning {
            central.scanForPeripherals(withServices: [service])
        }
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        guard dial == nil else { return }
        central.stopScan()
        dial = peripheral
        peripheral.delegate = self
        armDeadline("connect")
        if peripheral.state == .connected { peripheral.discoverServices([service]) }
        else { central.connect(peripheral) }
    }

    private func send(_ property: Property, write value: UInt16? = nil) {
        guard let dial, let output else { return }
        pending = Pending(property: property, write: value)
        armDeadline("setting confirmation")
        let packet = switch property {
        case .detents:
            value.map(D100HProtocol.writeDetents) ?? D100HProtocol.readDetents()
        case let .assignment(slot):
            value.map { D100HProtocol.writeAssignment(slot, UInt8(clamping: $0)) } ?? D100HProtocol.readAssignment(slot)
        }
        dial.writeValue(packet, for: output, type: .withResponse)
    }

    private func armDeadline(_ reason: String) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.failed(reason) }
        deadline = work
        queue.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func failed(_ reason: String) {
        log.error("D100H \(reason, privacy: .public)")
        disconnect()
        guard needsConnection, retries == 0, stopping == nil else { return }
        retries += 1
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.update() }
    }

    private func disconnect() {
        deadline?.cancel()
        deadline = nil
        pending = nil
        ready = false
        output = nil
        values.removeAll()
        expectedReadBack = nil
        central?.stopScan()
        if let dial {
            self.dial = nil
            central?.cancelPeripheralConnection(dial)
        }
    }

    private func finishStopping() {
        guard let completion = stopping else { return }
        stopping = nil
        finishTurnRequest(false)
        disconnect()
        completion()
    }
}

extension D100HSettings: D100HFirmware {
    var supportsTurnMapping: Bool { true }
}

extension D100HSettings: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { update() }
        else if dial != nil { disconnect() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name == "Ulanzi Dial", matchesRecoveryDevice(peripheral), needsConnection else { return }
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === dial else { return }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === dial { failed("connection failed") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === dial else { return }
        disconnect()
        // Scan for the same bonded device from its next advertisement instead of immediately reconnecting a sleeping dial.
        if needsConnection { central.scanForPeripherals(withServices: [service]) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === dial else { return }
        guard error == nil, let match = peripheral.services?.first(where: { $0.uuid == service }) else {
            failed("vendor service unavailable")
            return
        }
        peripheral.discoverCharacteristics([inputID, outputID], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === dial else { return }
        guard error == nil, let input = service.characteristics?.first(where: { $0.uuid == inputID }),
              let output = service.characteristics?.first(where: { $0.uuid == outputID }),
              input.properties.contains(.notify), output.properties.contains(.write) else {
            failed("vendor characteristics unavailable")
            return
        }
        self.output = output
        peripheral.setNotifyValue(true, for: input)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === dial, characteristic.uuid == inputID else { return }
        guard error == nil, characteristic.isNotifying else { failed("subscription failed"); return }
        ready = true
        update()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral === dial, characteristic.uuid == outputID, error != nil { failed("write failed") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === dial, characteristic.uuid == inputID, error == nil, let bytes = characteristic.value,
              let pending else { return }
        let reported: (value: UInt16, write: Bool)
        switch pending.property {
        case .detents:
            switch D100HProtocol.detentReply(bytes) {
            case let .read(value): reported = (value, false)
            case let .write(value): reported = (value, true)
            case nil: return
            }
        case let .assignment(slot):
            switch D100HProtocol.assignmentReply(bytes) {
            case let .read(found, value) where found == slot: reported = (UInt16(value), false)
            case let .write(found, value) where found == slot: reported = (UInt16(value), true)
            default: return
            }
        }

        if let expected = pending.write {
            guard reported.write, expected == reported.value else { return }
            expectedReadBack = expected
            send(pending.property)
            return
        }
        guard !reported.write else { return }
        guard expectedReadBack == nil || expectedReadBack == reported.value else {
            failed("read-back did not match the requested setting")
            return
        }
        deadline?.cancel()
        deadline = nil
        self.pending = nil
        expectedReadBack = nil
        values[pending.property] = reported.value
        update()
    }
}

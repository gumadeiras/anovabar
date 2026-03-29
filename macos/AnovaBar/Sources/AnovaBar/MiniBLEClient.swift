@preconcurrency import CoreBluetooth
import Foundation

enum MiniBLEClientError: LocalizedError {
    case bluetoothUnavailable(CBManagerState)
    case noSelection
    case deviceNotFound
    case missingCharacteristic(String)
    case disconnected(String)
    case invalidPayload(String)
    case operationAlreadyInFlight(String)
    case stateUnconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state):
            "Bluetooth is not ready: \(state.label)."
        case .noSelection:
            "Choose an Anova cooker first."
        case .deviceNotFound:
            "The selected device is no longer available."
        case .missingCharacteristic(let name):
            "The cooker is missing the required characteristic: \(name)."
        case .disconnected(let reason):
            "The Bluetooth connection ended: \(reason)"
        case .invalidPayload(let reason):
            "The cooker returned invalid data: \(reason)"
        case .operationAlreadyInFlight(let operation):
            "Another Bluetooth \(operation) operation is already in flight."
        case .stateUnconfirmed(let reason):
            "The cooker did not reach the expected state: \(reason)"
        }
    }
}

private extension CBManagerState {
    var label: String {
        switch self {
        case .unknown:
            "unknown"
        case .resetting:
            "resetting"
        case .unsupported:
            "unsupported"
        case .unauthorized:
            "unauthorized"
        case .poweredOff:
            "powered off"
        case .poweredOn:
            "powered on"
        @unknown default:
            "unrecognized state"
        }
    }
}

@MainActor
final class MiniBLEClient: NSObject {
    private struct DiscoveredPeripheral {
        let peripheral: CBPeripheral
        let device: MiniDiscoveredDevice
    }

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var bluetoothReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var servicesContinuation: CheckedContinuation<Void, Error>?
    private var characteristicsContinuation: CheckedContinuation<Void, Error>?
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var characteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
    private let diagnostics: MiniDiagnosticsStore

    init(diagnostics: MiniDiagnosticsStore) {
        self.diagnostics = diagnostics
        super.init()
    }

    func scan(timeout seconds: TimeInterval = 5) async throws -> [MiniDiscoveredDevice] {
        _ = central
        try await waitUntilBluetoothReady()
        recordBLE("scanStart", details: ["timeoutSeconds": String(Int(seconds))])

        discoveredPeripherals.removeAll()
        central.stopScan()
        central.scanForPeripherals(withServices: [MiniBLEUUIDs.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])

        try await Task.sleep(for: .seconds(seconds))
        central.stopScan()

        recordBLE("scanComplete", details: ["discovered": String(discoveredPeripherals.count)])

        return discoveredPeripherals.values
            .map(\.device)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func connect(to deviceID: UUID) async throws -> MiniDiscoveredDevice {
        try await waitUntilBluetoothReady()

        guard let discovered = discoveredPeripherals[deviceID] else {
            throw MiniBLEClientError.deviceNotFound
        }

        if connectedPeripheral?.identifier != deviceID {
            recordBLE("connectStart", details: ["deviceID": deviceID.uuidString])
            disconnectCurrentPeripheral()
            connectedPeripheral = discovered.peripheral
            connectedPeripheral?.delegate = self

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard connectContinuation == nil else {
                    continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("connect"))
                    return
                }

                connectContinuation = continuation
                central.connect(discovered.peripheral, options: nil)
            }
        }

        try await discoverProfile(on: discovered.peripheral)
        recordBLE("connectReady", details: ["device": discovered.device.displayName])
        return discovered.device
    }

    func disconnect() {
        recordBLE("disconnectRequested")
        disconnectCurrentPeripheral()
    }

    func snapshot() async throws -> MiniSnapshot {
        let snapshot = MiniSnapshot(
            state: try await readJSON(for: MiniBLEUUIDs.state),
            currentTemperature: try await readJSON(for: MiniBLEUUIDs.currentTemperature),
            timer: try await readJSON(for: MiniBLEUUIDs.timer)
        )
        diagnostics.record(
            .snapshot,
            "snapshot",
            details: [
                "state": MiniFormat.compactJSON(snapshot.state),
                "timer": MiniFormat.compactJSON(snapshot.timer),
            ]
        )
        return snapshot
    }

    func systemInfo() async throws -> JSONDictionary {
        let info = try await readJSON(for: MiniBLEUUIDs.systemInfo)
        recordBLE("systemInfo", details: ["payload": MiniFormat.compactJSON(info)])
        return info
    }

    func setClockToUTCNow() async throws {
        try await writeJSON(
            [
                "currentTime": Self.utcTimestampString(),
            ],
            to: MiniBLEUUIDs.setClock,
            expectsAcknowledgement: true
        )
    }

    func setUnit(_ unit: MiniTemperatureUnit) async throws {
        try await writeJSON(
            [
                "command": "changeUnit",
                "payload": [
                    "temperatureUnit": unit.rawValue,
                ],
            ],
            to: MiniBLEUUIDs.state,
            expectsAcknowledgement: false
        )
    }

    func setTemperature(_ value: Double) async throws {
        try await writeJSON(
            [
                "setpoint": value,
            ],
            to: MiniBLEUUIDs.setTemperature,
            expectsAcknowledgement: false
        )
    }

    func startCook(setpoint: Double, timerSeconds: Int) async throws {
        try await writeJSON(
            [
                "command": "start",
                "payload": [
                    "setpoint": setpoint,
                    "timer": timerSeconds,
                    "cookableId": "menubar",
                    "cookableType": "manual",
                ],
            ],
            to: MiniBLEUUIDs.state,
            expectsAcknowledgement: false
        )
    }

    func stopCook() async throws {
        try await writeJSON(
            [
                "command": "stop",
            ],
            to: MiniBLEUUIDs.state,
            expectsAcknowledgement: false
        )
    }

    private func waitUntilBluetoothReady() async throws {
        _ = central

        switch central.state {
        case .poweredOn:
            return
        case .unknown, .resetting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard bluetoothReadyContinuation == nil else {
                    continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("startup"))
                    return
                }

                bluetoothReadyContinuation = continuation
            }
        default:
            throw MiniBLEClientError.bluetoothUnavailable(central.state)
        }
    }

    private func discoverProfile(on peripheral: CBPeripheral) async throws {
        characteristicsByUUID.removeAll()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard servicesContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("service discovery"))
                return
            }

            servicesContinuation = continuation
            peripheral.discoverServices([MiniBLEUUIDs.service])
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == MiniBLEUUIDs.service }) else {
            throw MiniBLEClientError.missingCharacteristic("service \(MiniBLEUUIDs.service.uuidString)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard characteristicsContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("characteristic discovery"))
                return
            }

            characteristicsContinuation = continuation
            peripheral.discoverCharacteristics(nil, for: service)
        }

        let discovered = Set(characteristicsByUUID.keys.map(\.uuidString))
        for uuid in MiniBLEUUIDs.requiredCharacteristics where !discovered.contains(uuid.uuidString) {
            throw MiniBLEClientError.missingCharacteristic(uuid.uuidString)
        }

        recordBLE(
            "characteristics",
            details: [
                "inventory": characteristicsByUUID.values
                    .sorted { $0.uuid.uuidString < $1.uuid.uuidString }
                    .map(Self.describe)
                    .joined(separator: " | ")
            ]
        )

        for characteristic in characteristicsByUUID.values.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }) {
            let supportsNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
            guard supportsNotify else {
                continue
            }

            recordBLE("subscribeRequest", details: ["characteristic": Self.describe(characteristic)])
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func readJSON(for uuid: CBUUID) async throws -> JSONDictionary {
        let data = try await readValue(for: uuid)
        let decoded = try MiniCodec.decode(data)
        recordBLE(
            "read",
            details: [
                "characteristic": Self.label(for: uuid),
                "payload": MiniFormat.compactJSON(decoded),
            ]
        )
        return decoded
    }

    private func writeJSON(
        _ payload: JSONDictionary,
        to uuid: CBUUID,
        expectsAcknowledgement: Bool
    ) async throws {
        let data = try MiniCodec.encode(payload)
        recordBLE(
            "write",
            details: [
                "characteristic": Self.label(for: uuid),
                "ack": String(expectsAcknowledgement),
                "payload": MiniFormat.compactJSON(payload),
            ]
        )
        try await writeValue(data, to: uuid, expectsAcknowledgement: expectsAcknowledgement)
    }

    private func readValue(for uuid: CBUUID) async throws -> Data {
        let characteristic = try characteristic(for: uuid)
        let peripheral = try activePeripheral()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            guard readContinuations[uuid] == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("read"))
                return
            }

            readContinuations[uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    private func writeValue(
        _ data: Data,
        to uuid: CBUUID,
        expectsAcknowledgement: Bool
    ) async throws {
        let characteristic = try characteristic(for: uuid)
        let peripheral = try activePeripheral()
        let writeType: CBCharacteristicWriteType = expectsAcknowledgement ? .withResponse : .withoutResponse

        if expectsAcknowledgement {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard writeContinuations[uuid] == nil else {
                    continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("write"))
                    return
                }

                writeContinuations[uuid] = continuation
                peripheral.writeValue(data, for: characteristic, type: writeType)
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: writeType)
        }
    }

    private func activePeripheral() throws -> CBPeripheral {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected
        else {
            throw MiniBLEClientError.disconnected("No active connection")
        }

        return peripheral
    }

    private func characteristic(for uuid: CBUUID) throws -> CBCharacteristic {
        guard let characteristic = characteristicsByUUID[uuid] else {
            throw MiniBLEClientError.missingCharacteristic(uuid.uuidString)
        }

        return characteristic
    }

    private func disconnectCurrentPeripheral() {
        guard let peripheral = connectedPeripheral else {
            return
        }

        recordBLE("disconnectCurrent", details: ["peripheral": peripheral.identifier.uuidString])
        connectedPeripheral = nil
        characteristicsByUUID.removeAll()
        peripheral.delegate = nil

        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func failPendingOperations(_ error: Error) {
        bluetoothReadyContinuation?.resume(throwing: error)
        bluetoothReadyContinuation = nil

        connectContinuation?.resume(throwing: error)
        connectContinuation = nil

        servicesContinuation?.resume(throwing: error)
        servicesContinuation = nil

        characteristicsContinuation?.resume(throwing: error)
        characteristicsContinuation = nil

        let reads = readContinuations
        readContinuations.removeAll()
        for continuation in reads.values {
            continuation.resume(throwing: error)
        }

        let writes = writeContinuations
        writeContinuations.removeAll()
        for continuation in writes.values {
            continuation.resume(throwing: error)
        }
    }

    private static func utcTimestampString(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
            .withColonSeparatorInTimeZone,
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: now)
    }

    private func recordBLE(_ message: String, details: [String: String] = [:]) {
        diagnostics.record(.ble, message, details: details)
    }

    private static func label(for uuid: CBUUID) -> String {
        MiniBLEUUIDs.name(for: uuid)
    }

    private static func describe(_ characteristic: CBCharacteristic) -> String {
        "\(label(for: characteristic.uuid))[\(characteristic.uuid.uuidString)] props=\(describe(characteristic.properties))"
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var labels: [String] = []

        if properties.contains(.broadcast) { labels.append("broadcast") }
        if properties.contains(.read) { labels.append("read") }
        if properties.contains(.writeWithoutResponse) { labels.append("writeWithoutResponse") }
        if properties.contains(.write) { labels.append("write") }
        if properties.contains(.notify) { labels.append("notify") }
        if properties.contains(.indicate) { labels.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { labels.append("signedWrite") }
        if properties.contains(.extendedProperties) { labels.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { labels.append("notifyEncrypted") }
        if properties.contains(.indicateEncryptionRequired) { labels.append("indicateEncrypted") }

        return labels.isEmpty ? "none" : labels.joined(separator: ",")
    }

    private static func tracePayloadDescription(for data: Data) -> String {
        if let decoded = try? MiniCodec.decode(data) {
            return MiniFormat.compactJSON(decoded)
        }

        if let string = String(data: data, encoding: .utf8), !string.isEmpty {
            return string
        }

        return data.base64EncodedString()
    }
}

extension MiniBLEClient: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let continuation = bluetoothReadyContinuation else {
            return
        }

        switch central.state {
        case .poweredOn:
            bluetoothReadyContinuation = nil
            continuation.resume()
        case .unsupported, .unauthorized, .poweredOff:
            bluetoothReadyContinuation = nil
            continuation.resume(throwing: MiniBLEClientError.bluetoothUnavailable(central.state))
        case .unknown, .resetting:
            break
        @unknown default:
            bluetoothReadyContinuation = nil
            continuation.resume(throwing: MiniBLEClientError.bluetoothUnavailable(central.state))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ??
            peripheral.name ??
            "Anova Mini"

        discoveredPeripherals[peripheral.identifier] = DiscoveredPeripheral(
            peripheral: peripheral,
            device: MiniDiscoveredDevice(
                id: peripheral.identifier,
                name: name,
                identifier: peripheral.identifier.uuidString
            )
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        recordBLE("didConnect", details: ["peripheral": peripheral.identifier.uuidString])
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let failure = error ?? MiniBLEClientError.disconnected("Connection failed")
        diagnostics.record(
            .error,
            "didFailToConnect",
            details: [
                "peripheral": peripheral.identifier.uuidString,
                "reason": failure.localizedDescription,
            ]
        )
        connectContinuation?.resume(throwing: failure)
        connectContinuation = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let reason = error?.localizedDescription ?? "The device disconnected."
        diagnostics.record(
            .error,
            "didDisconnect",
            details: [
                "peripheral": peripheral.identifier.uuidString,
                "reason": reason,
            ]
        )
        connectedPeripheral = nil
        characteristicsByUUID.removeAll()
        failPendingOperations(MiniBLEClientError.disconnected(reason))
    }
}

extension MiniBLEClient: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            diagnostics.record(.error, "didDiscoverServices", details: ["reason": error.localizedDescription])
            servicesContinuation?.resume(throwing: error)
            servicesContinuation = nil
            return
        }

        recordBLE("didDiscoverServices", details: ["count": String(peripheral.services?.count ?? 0)])
        servicesContinuation?.resume()
        servicesContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if let error {
            diagnostics.record(.error, "didDiscoverCharacteristics", details: ["reason": error.localizedDescription])
            characteristicsContinuation?.resume(throwing: error)
            characteristicsContinuation = nil
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristicsByUUID[characteristic.uuid] = characteristic
        }

        characteristicsContinuation?.resume()
        characteristicsContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let continuation = readContinuations.removeValue(forKey: characteristic.uuid) else {
            if let error {
                diagnostics.record(
                    .error,
                    "notify",
                    details: [
                        "characteristic": Self.label(for: characteristic.uuid),
                        "reason": error.localizedDescription,
                    ]
                )
                return
            }

            if let data = characteristic.value {
                recordBLE(
                    "notify",
                    details: [
                        "characteristic": Self.label(for: characteristic.uuid),
                        "payload": Self.tracePayloadDescription(for: data),
                    ]
                )
            } else {
                recordBLE("notify", details: ["characteristic": Self.label(for: characteristic.uuid), "payload": "empty"])
            }
            return
        }

        if let error {
            diagnostics.record(
                .error,
                "read",
                details: [
                    "characteristic": Self.label(for: characteristic.uuid),
                    "reason": error.localizedDescription,
                ]
            )
            continuation.resume(throwing: error)
            return
        }

        guard let data = characteristic.value else {
            continuation.resume(throwing: MiniBLEClientError.invalidPayload("Characteristic read returned no value"))
            return
        }

        continuation.resume(returning: data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            diagnostics.record(
                .error,
                "writeAck",
                details: [
                    "characteristic": Self.label(for: characteristic.uuid),
                    "reason": error.localizedDescription,
                ]
            )
        } else {
            recordBLE("writeAck", details: ["characteristic": Self.label(for: characteristic.uuid), "status": "ok"])
        }

        guard let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) else {
            return
        }

        if let error {
            continuation.resume(throwing: error)
            return
        }

        continuation.resume()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            diagnostics.record(
                .error,
                "notifyState",
                details: [
                    "characteristic": Self.label(for: characteristic.uuid),
                    "enabled": String(characteristic.isNotifying),
                    "reason": error.localizedDescription,
                ]
            )
            return
        }

        recordBLE(
            "notifyState",
            details: [
                "characteristic": Self.label(for: characteristic.uuid),
                "enabled": String(characteristic.isNotifying),
            ]
        )
    }
}

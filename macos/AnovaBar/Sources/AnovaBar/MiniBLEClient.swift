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

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state):
            "Bluetooth is not ready: \(state.label)."
        case .noSelection:
            "Choose an Anova Mini device first."
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

    func scan(timeout seconds: TimeInterval = 5) async throws -> [MiniDiscoveredDevice] {
        _ = central
        try await waitUntilBluetoothReady()

        discoveredPeripherals.removeAll()
        central.stopScan()
        central.scanForPeripherals(withServices: [MiniBLEUUIDs.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])

        try await Task.sleep(for: .seconds(seconds))
        central.stopScan()

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
        return discovered.device
    }

    func disconnect() {
        disconnectCurrentPeripheral()
    }

    func snapshot() async throws -> MiniSnapshot {
        MiniSnapshot(
            state: try await readJSON(for: MiniBLEUUIDs.state),
            currentTemperature: try await readJSON(for: MiniBLEUUIDs.currentTemperature),
            timer: try await readJSON(for: MiniBLEUUIDs.timer)
        )
    }

    func systemInfo() async throws -> JSONDictionary {
        try await readJSON(for: MiniBLEUUIDs.systemInfo)
    }

    func setClockToNow() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        try await writeJSON(
            [
                "currentTime": formatter.string(from: Date()),
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
            peripheral.discoverCharacteristics(MiniBLEUUIDs.requiredCharacteristics, for: service)
        }

        let discovered = Set(characteristicsByUUID.keys.map(\.uuidString))
        for uuid in MiniBLEUUIDs.requiredCharacteristics where !discovered.contains(uuid.uuidString) {
            throw MiniBLEClientError.missingCharacteristic(uuid.uuidString)
        }
    }

    private func readJSON(for uuid: CBUUID) async throws -> JSONDictionary {
        let data = try await readValue(for: uuid)
        return try MiniCodec.decode(data)
    }

    private func writeJSON(
        _ payload: JSONDictionary,
        to uuid: CBUUID,
        expectsAcknowledgement: Bool
    ) async throws {
        let data = try MiniCodec.encode(payload)
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
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let failure = error ?? MiniBLEClientError.disconnected("Connection failed")
        connectContinuation?.resume(throwing: failure)
        connectContinuation = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let reason = error?.localizedDescription ?? "The device disconnected."
        connectedPeripheral = nil
        characteristicsByUUID.removeAll()
        failPendingOperations(MiniBLEClientError.disconnected(reason))
    }
}

extension MiniBLEClient: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            servicesContinuation?.resume(throwing: error)
            servicesContinuation = nil
            return
        }

        servicesContinuation?.resume()
        servicesContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if let error {
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
            return
        }

        if let error {
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
        guard let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) else {
            return
        }

        if let error {
            continuation.resume(throwing: error)
            return
        }

        continuation.resume()
    }
}

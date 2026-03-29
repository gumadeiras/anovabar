@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class NanoBLEClient: NSObject {
    private struct DiscoveredPeripheral {
        let peripheral: CBPeripheral
        let device: AnovaDiscoveredDevice
    }

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var bluetoothReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var servicesContinuation: CheckedContinuation<Void, Error>?
    private var characteristicsContinuation: CheckedContinuation<Void, Error>?
    private var exchangeContinuation: CheckedContinuation<Data, Error>?
    private var exchangeTimeoutTask: Task<Void, Never>?
    private var activeCommand: NanoCommand?

    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readCharacteristic: CBCharacteristic?
    private var responseBuffer = Data()
    private let diagnostics: MiniDiagnosticsStore

    init(diagnostics: MiniDiagnosticsStore) {
        self.diagnostics = diagnostics
        super.init()
    }

    func scan(timeout seconds: TimeInterval = 5) async throws -> [AnovaDiscoveredDevice] {
        _ = central
        try await waitUntilBluetoothReady()
        recordBLE("scanStart", details: ["timeoutSeconds": String(Int(seconds)), "family": "nano"])

        discoveredPeripherals.removeAll()
        central.stopScan()
        central.scanForPeripherals(withServices: [NanoBLEUUIDs.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])

        try await Task.sleep(for: .seconds(seconds))
        central.stopScan()

        recordBLE("scanComplete", details: ["discovered": String(discoveredPeripherals.count), "family": "nano"])

        return discoveredPeripherals.values
            .map(\.device)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func connect(to deviceID: UUID) async throws -> AnovaDiscoveredDevice {
        try await waitUntilBluetoothReady()

        guard let discovered = discoveredPeripherals[deviceID] else {
            throw MiniBLEClientError.deviceNotFound
        }

        if connectedPeripheral?.identifier != deviceID {
            recordBLE("connectStart", details: ["deviceID": deviceID.uuidString, "family": "nano"])
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
        recordBLE("connectReady", details: ["device": discovered.device.displayName, "family": "nano"])
        return discovered.device
    }

    func disconnect() {
        recordBLE("disconnectRequested", details: ["family": "nano"])
        disconnectCurrentPeripheral()
    }

    func snapshot() async throws -> CookerSnapshot {
        let sensorPayload = try await exchange(.getSensorValues)
        let targetPayload = try await exchange(.getTargetTemperature)
        let timerPayload = try await exchange(.getTimer)
        let unitPayload = try await exchange(.getUnit)

        return NanoSnapshot(
            sensorPayload: sensorPayload,
            targetPayload: targetPayload,
            timerPayload: timerPayload,
            unitPayload: unitPayload
        ).cookerSnapshot
    }

    func systemInfo() async throws -> JSONDictionary {
        let deviceInfo = try await exchange(.getDeviceInfo)
        let firmwareInfo = try await exchange(.getFirmwareInfo)

        return [
            "deviceInfo": [
                "rawValue": NanoProto.decodeIntegerValue(deviceInfo) as Any,
                "rawPayload": NanoFormat.hex(deviceInfo),
            ],
            "firmwareInfo": NanoProto.decodeFirmwareInfo(firmwareInfo),
        ]
    }

    func setUnit(_ unit: MiniTemperatureUnit) async throws {
        _ = try await exchange(.setUnit(unit))
    }

    func setTemperature(_ value: Double) async throws {
        _ = try await exchange(.setTargetTemperature(value))
    }

    func startCook(setpoint: Double, timerSeconds: Int) async throws {
        _ = try await exchange(.setTargetTemperature(setpoint))
        _ = try await exchange(.setTimer(max(0, timerSeconds / 60)))
        _ = try await exchange(.start)
    }

    func stopCook() async throws {
        _ = try await exchange(.stop)
    }

    private func exchange(_ command: NanoCommand, timeout seconds: TimeInterval = 10) async throws -> Data {
        guard let writeCharacteristic else {
            throw MiniBLEClientError.missingCharacteristic("write")
        }
        let peripheral = try activePeripheral()
        let payload = command.encode()

        recordBLE("write", details: [
            "characteristic": "write",
            "payload": NanoFormat.hex(payload),
            "command": command.label,
            "family": "nano",
        ])

        if !command.expectsResponse {
            responseBuffer.removeAll()
            activeCommand = nil
            peripheral.writeValue(payload, for: writeCharacteristic, type: .withoutResponse)
            return Data()
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            guard exchangeContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("exchange"))
                return
            }

            exchangeContinuation = continuation
            exchangeTimeoutTask?.cancel()
            activeCommand = command
            responseBuffer.removeAll()
            peripheral.writeValue(payload, for: writeCharacteristic, type: .withoutResponse)

            exchangeTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, let pending = self.exchangeContinuation else {
                    return
                }

                self.exchangeContinuation = nil
                self.exchangeTimeoutTask = nil
                self.activeCommand = nil
                self.responseBuffer.removeAll()
                pending.resume(throwing: MiniBLEClientError.invalidPayload("Timed out waiting for command response."))
            }
        }
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
        writeCharacteristic = nil
        readCharacteristic = nil

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard servicesContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("service discovery"))
                return
            }

            servicesContinuation = continuation
            peripheral.discoverServices([NanoBLEUUIDs.service])
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == NanoBLEUUIDs.service }) else {
            throw MiniBLEClientError.missingCharacteristic("service \(NanoBLEUUIDs.service.uuidString)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard characteristicsContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("characteristic discovery"))
                return
            }

            characteristicsContinuation = continuation
            peripheral.discoverCharacteristics(NanoBLEUUIDs.requiredCharacteristics, for: service)
        }

        guard let readCharacteristic else {
            throw MiniBLEClientError.missingCharacteristic(NanoBLEUUIDs.read.uuidString)
        }

        if readCharacteristic.properties.contains(.notify) || readCharacteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: readCharacteristic)
        }
    }

    private func activePeripheral() throws -> CBPeripheral {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            throw MiniBLEClientError.disconnected("No active connection")
        }

        return peripheral
    }

    private func disconnectCurrentPeripheral() {
        guard let peripheral = connectedPeripheral else {
            return
        }

        connectedPeripheral = nil
        writeCharacteristic = nil
        readCharacteristic = nil
        responseBuffer.removeAll()
        activeCommand = nil
        exchangeTimeoutTask?.cancel()
        exchangeTimeoutTask = nil
        exchangeContinuation?.resume(throwing: MiniBLEClientError.disconnected("The device disconnected."))
        exchangeContinuation = nil
        peripheral.delegate = nil

        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func recordBLE(_ message: String, details: [String: String] = [:]) {
        diagnostics.record(.ble, message, details: details)
    }
}

extension NanoBLEClient: @preconcurrency CBCentralManagerDelegate {
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
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Anova Nano"

        discoveredPeripherals[peripheral.identifier] = DiscoveredPeripheral(
            peripheral: peripheral,
            device: AnovaDiscoveredDevice(
                id: peripheral.identifier,
                name: localName,
                identifier: peripheral.identifier.uuidString,
                family: .nano
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
        writeCharacteristic = nil
        readCharacteristic = nil
        exchangeTimeoutTask?.cancel()
        exchangeTimeoutTask = nil
        responseBuffer.removeAll()
        activeCommand = nil
        exchangeContinuation?.resume(throwing: MiniBLEClientError.disconnected(reason))
        exchangeContinuation = nil
    }
}

extension NanoBLEClient: @preconcurrency CBPeripheralDelegate {
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

        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == NanoBLEUUIDs.write })
        readCharacteristic = service.characteristics?.first(where: { $0.uuid == NanoBLEUUIDs.read })
        characteristicsContinuation?.resume()
        characteristicsContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == NanoBLEUUIDs.read else {
            return
        }

        if let error {
            exchangeContinuation?.resume(throwing: error)
            exchangeContinuation = nil
            exchangeTimeoutTask?.cancel()
            exchangeTimeoutTask = nil
            responseBuffer.removeAll()
            activeCommand = nil
            return
        }

        guard let data = characteristic.value else {
            return
        }

        guard exchangeContinuation != nil else {
            recordBLE("notifyUnmatched", details: [
                "characteristic": "read",
                "payload": NanoFormat.hex(data),
                "family": "nano",
            ])
            return
        }

        responseBuffer.append(data)
        recordBLE("notify", details: [
            "characteristic": "read",
            "payload": NanoFormat.hex(data),
            "command": activeCommand?.label ?? "none",
            "family": "nano",
        ])

        guard let decoded = NanoFrameCodec.decodeFrame(responseBuffer),
              let continuation = exchangeContinuation
        else {
            return
        }

        exchangeContinuation = nil
        exchangeTimeoutTask?.cancel()
        exchangeTimeoutTask = nil
        activeCommand = nil
        responseBuffer.removeAll()
        continuation.resume(returning: decoded)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            diagnostics.record(.error, "notifyState", details: [
                "characteristic": NanoBLEUUIDs.name(for: characteristic.uuid),
                "reason": error.localizedDescription,
                "family": "nano",
            ])
            return
        }

        recordBLE("notifyState", details: [
            "characteristic": NanoBLEUUIDs.name(for: characteristic.uuid),
            "enabled": String(characteristic.isNotifying),
            "family": "nano",
        ])
    }
}

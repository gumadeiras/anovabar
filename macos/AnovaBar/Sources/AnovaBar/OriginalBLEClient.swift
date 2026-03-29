@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class OriginalBLEClient: NSObject {
    private struct DiscoveredPeripheral {
        let peripheral: CBPeripheral
        let device: AnovaDiscoveredDevice
    }

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var bluetoothReadyContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var servicesContinuation: CheckedContinuation<Void, Error>?
    private var characteristicsContinuation: CheckedContinuation<Void, Error>?
    private var commandContinuation: CheckedContinuation<String, Error>?
    private var commandTimeoutTask: Task<Void, Never>?
    private var commandRequestID: UInt64 = 0
    private var activeCommand: String?

    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseBuffer = Data()
    private var detectedModel: OriginalCookerModel?
    private let diagnostics: MiniDiagnosticsStore

    init(diagnostics: MiniDiagnosticsStore) {
        self.diagnostics = diagnostics
        super.init()
    }

    func scan(timeout seconds: TimeInterval = 5) async throws -> [AnovaDiscoveredDevice] {
        _ = central
        try await waitUntilBluetoothReady()
        recordBLE("scanStart", details: ["timeoutSeconds": String(Int(seconds)), "family": "original"])

        discoveredPeripherals.removeAll()
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])

        try await Task.sleep(for: .seconds(seconds))
        central.stopScan()

        recordBLE("scanComplete", details: ["discovered": String(discoveredPeripherals.count), "family": "original"])

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
            recordBLE("connectStart", details: ["deviceID": deviceID.uuidString, "family": "original"])
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
        recordBLE("connectReady", details: ["device": discovered.device.displayName, "family": "original"])
        return discovered.device
    }

    func disconnect() {
        recordBLE("disconnectRequested", details: ["family": "original"])
        disconnectCurrentPeripheral()
    }

    func snapshot() async throws -> CookerSnapshot {
        let status = try await sendCommand("status")
        let unit = try await sendCommand("read unit")
        let current = try await sendCommand("read temp")
        let target = try await sendCommand("read set temp")
        let timer = try await sendCommand("read timer")

        return OriginalSnapshot(
            statusResponse: status,
            unitResponse: unit,
            currentTemperatureResponse: current,
            targetTemperatureResponse: target,
            timerResponse: timer
        ).cookerSnapshot
    }

    func systemInfo() async throws -> JSONDictionary {
        let cookerID = try await sendCommand("get id card")
        let model = OriginalCookerModel.detect(from: cookerID)
        detectedModel = model
        var dictionary: JSONDictionary = [
            "cookerId": cookerID,
            "model": model.rawValue,
        ]

        if model == .wifi900W, let firmware = try? await sendCommand("version") {
            dictionary["firmwareVersion"] = firmware
        }

        return dictionary
    }

    func setClockToUTCNow() async throws {}

    func setUnit(_ unit: MiniTemperatureUnit) async throws {
        _ = try await sendCommand("set unit \(unit.rawValue.lowercased())")
    }

    func setTemperature(_ value: Double) async throws {
        _ = try await sendCommand("set temp \(MiniFormat.temperature(value))")
    }

    func startCook(setpoint: Double, timerSeconds: Int) async throws {
        _ = try await sendCommand("set temp \(MiniFormat.temperature(setpoint))")
        _ = try await sendCommand("stop time")
        _ = try await sendCommand("set timer \(max(0, timerSeconds / 60))")
        _ = try await sendCommand("start")
        if timerSeconds > 0 {
            _ = try await sendCommand("start time")
        }
    }

    func stopCook() async throws {
        _ = try await sendCommand("stop")
    }

    func clearAlarmIfSupported() async throws {
        guard try await currentModel() == .wifi900W else {
            return
        }

        _ = try await sendCommand("clear alarm")
    }

    private func sendCommand(_ command: String, timeout seconds: TimeInterval? = nil) async throws -> String {
        guard let characteristic = commandCharacteristic else {
            throw MiniBLEClientError.missingCharacteristic("command")
        }
        let peripheral = try activePeripheral()
        let data = Data((command + "\r").utf8)
        let timeout = seconds ?? OriginalCommandPolicy.timeout(for: command)
        let acceptsMissingResponse = OriginalCommandPolicy.acceptsMissingResponse(for: command)

        recordBLE("write", details: ["characteristic": "command", "payload": command, "family": "original"])

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard commandContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("command"))
                return
            }

            commandRequestID &+= 1
            let requestID = commandRequestID
            commandContinuation = continuation
            activeCommand = command
            responseBuffer.removeAll()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)

            commandTimeoutTask?.cancel()
            commandTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self,
                      let pending = self.commandContinuation,
                      self.commandRequestID == requestID,
                      self.activeCommand == command
                else {
                    return
                }

                self.commandContinuation = nil
                self.commandTimeoutTask = nil
                self.activeCommand = nil
                self.responseBuffer.removeAll()
                if acceptsMissingResponse {
                    self.recordBLE("writeTimeoutAccepted", details: [
                        "characteristic": "command",
                        "payload": command,
                        "family": "original",
                    ])
                    pending.resume(returning: "")
                } else {
                    pending.resume(throwing: MiniBLEClientError.invalidPayload("Timed out waiting for command response."))
                }
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
        commandCharacteristic = nil

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard servicesContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("service discovery"))
                return
            }

            servicesContinuation = continuation
            peripheral.discoverServices([OriginalBLEUUIDs.service])
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == OriginalBLEUUIDs.service }) else {
            throw MiniBLEClientError.missingCharacteristic("service \(OriginalBLEUUIDs.service.uuidString)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard characteristicsContinuation == nil else {
                continuation.resume(throwing: MiniBLEClientError.operationAlreadyInFlight("characteristic discovery"))
                return
            }

            characteristicsContinuation = continuation
            peripheral.discoverCharacteristics([OriginalBLEUUIDs.command], for: service)
        }

        guard let characteristic = commandCharacteristic else {
            throw MiniBLEClientError.missingCharacteristic(OriginalBLEUUIDs.command.uuidString)
        }

        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
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

    private func disconnectCurrentPeripheral() {
        guard let peripheral = connectedPeripheral else {
            return
        }

        connectedPeripheral = nil
        detectedModel = nil
        commandCharacteristic = nil
        responseBuffer.removeAll()
        activeCommand = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        commandContinuation?.resume(throwing: MiniBLEClientError.disconnected("The device disconnected."))
        commandContinuation = nil
        peripheral.delegate = nil

        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func completeResponseIfNeeded(with latestChunk: Data) {
        guard let continuation = commandContinuation,
              let activeCommand
        else {
            return
        }

        let ended = latestChunk.count < 20 || latestChunk.last == 0
        guard ended else {
            return
        }

        let rawResponse = String(data: responseBuffer, encoding: .utf8) ?? ""
        let response: String
        if OriginalCommandPolicy.expectsStructuredResponse(for: activeCommand) {
            guard let normalizedResponse = OriginalCommandPolicy.normalizedResponse(rawResponse, for: activeCommand) else {
                recordBLE("notifyIgnored", details: [
                    "characteristic": "command",
                    "payload": rawResponse.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
                    "activeCommand": activeCommand,
                    "family": "original",
                ])
                return
            }
            response = normalizedResponse
        } else {
            response = rawResponse
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        }

        commandContinuation = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        self.activeCommand = nil
        responseBuffer.removeAll()
        continuation.resume(returning: response)
    }

    private func currentModel() async throws -> OriginalCookerModel {
        if let detectedModel {
            return detectedModel
        }

        let cookerID = try await sendCommand("get id card")
        let model = OriginalCookerModel.detect(from: cookerID)
        detectedModel = model
        return model
    }

    private func recordBLE(_ message: String, details: [String: String] = [:]) {
        diagnostics.record(.ble, message, details: details)
    }
}

extension OriginalBLEClient: @preconcurrency CBCentralManagerDelegate {
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
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        guard OriginalDiscovery.matches(
            localName: localName,
            peripheralName: peripheral.name,
            advertisedServices: advertisedServices
        ) else {
            return
        }

        let displayName = OriginalDiscovery.displayName(localName: localName, peripheralName: peripheral.name)

        discoveredPeripherals[peripheral.identifier] = DiscoveredPeripheral(
            peripheral: peripheral,
            device: AnovaDiscoveredDevice(
                id: peripheral.identifier,
                name: displayName,
                identifier: peripheral.identifier.uuidString,
                family: .original
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
        commandCharacteristic = nil
        commandContinuation?.resume(throwing: MiniBLEClientError.disconnected(reason))
        commandContinuation = nil
    }
}

extension OriginalBLEClient: @preconcurrency CBPeripheralDelegate {
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

        commandCharacteristic = service.characteristics?.first(where: { $0.uuid == OriginalBLEUUIDs.command })
        characteristicsContinuation?.resume()
        characteristicsContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == OriginalBLEUUIDs.command else {
            return
        }

        if let error {
            commandContinuation?.resume(throwing: error)
            commandContinuation = nil
            commandTimeoutTask?.cancel()
            commandTimeoutTask = nil
            activeCommand = nil
            responseBuffer.removeAll()
            return
        }

        guard let data = characteristic.value else {
            return
        }

        guard commandContinuation != nil else {
            recordBLE("notifyUnmatched", details: ["characteristic": "command", "payload": String(data: data, encoding: .utf8) ?? data.base64EncodedString(), "family": "original"])
            return
        }

        responseBuffer.append(data)
        recordBLE("notify", details: ["characteristic": "command", "payload": String(data: data, encoding: .utf8) ?? data.base64EncodedString(), "family": "original"])
        completeResponseIfNeeded(with: data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if let error {
            diagnostics.record(.error, "notifyState", details: ["characteristic": "command", "reason": error.localizedDescription, "family": "original"])
            return
        }

        recordBLE("notifyState", details: ["characteristic": "command", "enabled": String(characteristic.isNotifying), "family": "original"])
    }
}

import Foundation

@MainActor
final class AnovaBLECoordinator {
    private let diagnostics: MiniDiagnosticsStore
    private let miniClient: MiniBLEClient
    private let originalClient: OriginalBLEClient
    private var discoveredDevices: [UUID: AnovaDiscoveredDevice] = [:]

    init(diagnostics: MiniDiagnosticsStore) {
        self.diagnostics = diagnostics
        self.miniClient = MiniBLEClient(diagnostics: diagnostics)
        self.originalClient = OriginalBLEClient(diagnostics: diagnostics)
    }

    func scan(timeout seconds: TimeInterval = 5) async throws -> [AnovaDiscoveredDevice] {
        async let miniDiscovered = miniClient.scan(timeout: seconds)
        async let original = originalClient.scan(timeout: seconds)

        let mini = try await miniDiscovered.map {
            AnovaDiscoveredDevice(
                id: $0.id,
                name: $0.name,
                identifier: $0.identifier,
                family: .mini
            )
        }
        let merged = mini + (try await original)
        var deduped: [UUID: AnovaDiscoveredDevice] = [:]
        for device in merged {
            deduped[device.id] = device
        }
        discoveredDevices = deduped

        return deduped.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func connect(to deviceID: UUID) async throws -> any AnovaCookerSession {
        guard let device = discoveredDevices[deviceID] else {
            throw MiniBLEClientError.deviceNotFound
        }

        disconnect()

        switch device.family {
        case .mini:
            let connected = try await miniClient.connect(to: deviceID)
            return MiniCookerSession(
                client: miniClient,
                device: AnovaDiscoveredDevice(
                    id: connected.id,
                    name: connected.name,
                    identifier: connected.identifier,
                    family: .mini
                )
            )
        case .original:
            let connected = try await originalClient.connect(to: deviceID)
            return OriginalCookerSession(client: originalClient, device: connected)
        }
    }

    func disconnect() {
        miniClient.disconnect()
        originalClient.disconnect()
    }
}

@MainActor
private final class MiniCookerSession: AnovaCookerSession {
    let device: AnovaDiscoveredDevice
    private let client: MiniBLEClient

    var supportsClockSync: Bool { true }
    var supportsStrictStateConfirmation: Bool { true }

    init(client: MiniBLEClient, device: AnovaDiscoveredDevice) {
        self.client = client
        self.device = device
    }

    func disconnect() {
        client.disconnect()
    }

    func snapshot() async throws -> CookerSnapshot {
        try await client.snapshot().cookerSnapshot
    }

    func systemInfo() async throws -> JSONDictionary {
        try await client.systemInfo()
    }

    func setClockToUTCNow() async throws {
        try await client.setClockToUTCNow()
    }

    func setUnit(_ unit: MiniTemperatureUnit) async throws {
        try await client.setUnit(unit)
    }

    func setTemperature(_ value: Double) async throws {
        try await client.setTemperature(value)
    }

    func startCook(setpoint: Double, timerSeconds: Int) async throws {
        try await client.startCook(setpoint: setpoint, timerSeconds: timerSeconds)
    }

    func stopCook() async throws {
        try await client.stopCook()
    }

    func clearAlarmIfSupported() async throws {}
}

@MainActor
private final class OriginalCookerSession: AnovaCookerSession {
    let device: AnovaDiscoveredDevice
    private let client: OriginalBLEClient

    var supportsClockSync: Bool { false }
    var supportsStrictStateConfirmation: Bool { false }

    init(client: OriginalBLEClient, device: AnovaDiscoveredDevice) {
        self.client = client
        self.device = device
    }

    func disconnect() {
        client.disconnect()
    }

    func snapshot() async throws -> CookerSnapshot {
        try await client.snapshot()
    }

    func systemInfo() async throws -> JSONDictionary {
        try await client.systemInfo()
    }

    func setClockToUTCNow() async throws {}

    func setUnit(_ unit: MiniTemperatureUnit) async throws {
        try await client.setUnit(unit)
    }

    func setTemperature(_ value: Double) async throws {
        try await client.setTemperature(value)
    }

    func startCook(setpoint: Double, timerSeconds: Int) async throws {
        try await client.startCook(setpoint: setpoint, timerSeconds: timerSeconds)
    }

    func stopCook() async throws {
        try await client.stopCook()
    }

    func clearAlarmIfSupported() async throws {
        try await client.clearAlarmIfSupported()
    }
}

import Foundation

enum AnovaDeviceFamily: String, Codable, Hashable {
    case mini
    case original

    var displayName: String {
        switch self {
        case .mini:
            return "Mini / Gen 3"
        case .original:
            return "Original Precision Cooker"
        }
    }
}

struct AnovaDiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let identifier: String
    let family: AnovaDeviceFamily

    var displayName: String {
        if name.isEmpty {
            return identifier
        }

        return "\(name) (\(identifier))"
    }
}

struct CookerSnapshot {
    let family: AnovaDeviceFamily
    let temperatureUnit: MiniTemperatureUnit?
    let currentTemperatureValue: Double?
    let targetTemperatureValue: Double?
    let timerDisplay: String
    let timerSecondsValue: Int?
    let timerInitialSeconds: Int?
    let timerStartedAt: Date?
    let timerMode: String?
    let stateMode: String?
    let timerHasRunningSignal: Bool
    let timerHasCompleted: Bool
    let isCooking: Bool
    let interpretation: JSONDictionary
    let state: JSONDictionary
    let currentTemperature: JSONDictionary
    let timer: JSONDictionary

    func matchesRunningCook(
        targetTemperature: Double,
        timerSeconds: Int,
        temperatureUnit: MiniTemperatureUnit? = nil,
        requireTimerRunningSignal: Bool = false
    ) -> Bool {
        guard isCooking else {
            return false
        }

        if let temperatureUnit, self.temperatureUnit != temperatureUnit {
            return false
        }

        if let snapshotTarget = targetTemperatureValue,
           abs(snapshotTarget - targetTemperature) > 0.2 {
            return false
        }

        if timerSeconds == 0 {
            return true
        }

        if requireTimerRunningSignal,
           !timerHasRunningSignal,
           (timerInitialSeconds ?? 0) <= 0 {
            return false
        }

        if let remaining = timerSecondsValue {
            return remaining > 0 && remaining <= timerSeconds
        }

        if let initial = timerInitialSeconds {
            return initial > 0 && initial <= timerSeconds
        }

        return false
    }
}

@MainActor
protocol AnovaCookerSession: AnyObject {
    var device: AnovaDiscoveredDevice { get }
    var supportsClockSync: Bool { get }
    var supportsStrictStateConfirmation: Bool { get }

    func disconnect()
    func snapshot() async throws -> CookerSnapshot
    func systemInfo() async throws -> JSONDictionary
    func setClockToUTCNow() async throws
    func setUnit(_ unit: MiniTemperatureUnit) async throws
    func setTemperature(_ value: Double) async throws
    func startCook(setpoint: Double, timerSeconds: Int) async throws
    func stopCook() async throws
}

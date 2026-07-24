import Foundation

enum CookerStateExpectation {
    case temperatureUnit(MiniTemperatureUnit)
    case targetTemperature(Double)
    case running(
        targetTemperature: Double,
        timerSeconds: Int,
        temperatureUnit: MiniTemperatureUnit? = nil,
        requireTimerRunningSignal: Bool = false
    )
    case stopped

    func matches(_ snapshot: CookerSnapshot) -> Bool {
        switch self {
        case .temperatureUnit(let unit):
            return snapshot.temperatureUnit == unit
        case .targetTemperature(let targetTemperature):
            guard let snapshotTarget = snapshot.targetTemperatureValue else {
                return false
            }
            return abs(snapshotTarget - targetTemperature) <= 0.2
        case .running(let targetTemperature, let timerSeconds, let temperatureUnit, let requireTimerRunningSignal):
            return snapshot.matchesRunningCook(
                targetTemperature: targetTemperature,
                timerSeconds: timerSeconds,
                temperatureUnit: temperatureUnit,
                requireTimerRunningSignal: requireTimerRunningSignal
            )
        case .stopped:
            return !snapshot.isCooking
        }
    }

    var summary: String {
        switch self {
        case .temperatureUnit(let unit):
            return "temperature unit \(unit.rawValue)"
        case .targetTemperature(let targetTemperature):
            return "target temperature \(MiniFormat.temperature(targetTemperature))"
        case .running(let targetTemperature, let timerSeconds, let temperatureUnit, let requireTimerRunningSignal):
            let timerText = timerSeconds == 0 ? "infinite timer" : "\(timerSeconds)s timer"
            let timerSignalText = requireTimerRunningSignal ? " with live timer signal" : ""
            if let temperatureUnit {
                return "running cook at \(MiniFormat.temperature(targetTemperature))\(temperatureUnit.symbol) with \(timerText)\(timerSignalText)"
            }
            return "running cook at \(MiniFormat.temperature(targetTemperature)) with \(timerText)\(timerSignalText)"
        case .stopped:
            return "stopped cook"
        }
    }
}

@MainActor
final class CookerOperationGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }

        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }

        waiters.removeFirst().resume()
    }
}

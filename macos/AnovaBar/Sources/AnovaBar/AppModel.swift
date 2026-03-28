import Foundation

@MainActor
final class AppModel: ObservableObject {
    private static let aliasStorageKey = "deviceAliases"
    private static let cookStateStorageKey = "deviceCookState"

    private struct PersistedCookState: Codable {
        var targetTemperature: Double?
        var timerState: PersistedTimerState?
    }

    private enum PersistedTimerState: Codable {
        case staged(seconds: Int)
        case paused(seconds: Int)
        case stopped
    }

    private enum CookTimerState {
        case none
        case staged(seconds: Int)
        case paused(seconds: Int)
        case running(initialSeconds: Int, startedAt: Date)
        case stopped
    }

    private enum ExpectedDeviceState {
        case temperatureUnit(MiniTemperatureUnit)
        case targetTemperature(Double)
        case running(
            targetTemperature: Double,
            timerSeconds: Int,
            temperatureUnit: MiniTemperatureUnit? = nil,
            requireTimerRunningSignal: Bool = false
        )
        case stopped

        func matches(_ snapshot: MiniSnapshot) -> Bool {
            switch self {
            case .temperatureUnit(let unit):
                return snapshot.temperatureUnit == unit

            case .targetTemperature(let targetTemperature):
                guard let snapshotTarget = snapshot.targetTemperatureValue else {
                    return false
                }

                return abs(snapshotTarget - targetTemperature) <= 0.2

            case .running(let targetTemperature, let timerSeconds, let temperatureUnit, let requireTimerRunningSignal):
                guard snapshot.isCooking else {
                    return false
                }

                if let temperatureUnit, snapshot.temperatureUnit != temperatureUnit {
                    return false
                }

                if requireTimerRunningSignal, !snapshot.timerHasRunningSignal {
                    return false
                }

                if let snapshotTarget = snapshot.targetTemperatureValue,
                   abs(snapshotTarget - targetTemperature) > 0.2 {
                    return false
                }

                if timerSeconds == 0 {
                    return true
                }

                if let remaining = snapshot.timerSecondsValue {
                    return remaining > 0 && remaining <= timerSeconds
                }

                if let initial = snapshot.timerInitialSeconds {
                    return abs(initial - timerSeconds) <= 1
                }

                return false

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

    private struct OperationStateSnapshot {
        var connectedDevice: MiniDiscoveredDevice?
        var snapshot: MiniSnapshot?
        var systemInfo: JSONDictionary?
        var targetTemperatureText: String
        var timerMinutesText: String
        var selectedUnit: MiniTemperatureUnit
        var lastKnownCurrentTemperature: Double?
        var lastKnownTargetTemperature: Double?
        var cookTimerState: CookTimerState
    }

    @Published private(set) var devices: [MiniDiscoveredDevice] = []
    @Published var selectedDeviceID: UUID?
    @Published private(set) var connectedDevice: MiniDiscoveredDevice?
    @Published private(set) var snapshot: MiniSnapshot?
    @Published private(set) var systemInfo: JSONDictionary?
    @Published private(set) var statusMessage = "Click Scan for Minis to discover a cooker."
    @Published private(set) var isBusy = false
    @Published private(set) var isScanning = false
    @Published var targetTemperatureText = "60.0"
    @Published var timerMinutesText = "0"
    @Published var selectedUnit: MiniTemperatureUnit = .celsius
    @Published var aliasText = ""
    @Published var lastError: String?

    private let client = MiniBLEClient()
    private let defaults = UserDefaults.standard
    private var didLoad = false
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var operationInFlight = false
    private var isUnitChangeInFlight = false
    private var lastKnownCurrentTemperature: Double?
    private var lastKnownTargetTemperature: Double?
    private var cookTimerState: CookTimerState = .none
    private var deviceAliases: [String: String]
    private var deviceCookState: [String: PersistedCookState]
    @Published private var timerNow = Date()

    init() {
        self.deviceAliases = defaults.dictionary(forKey: Self.aliasStorageKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: Self.cookStateStorageKey),
           let decoded = try? JSONDecoder().decode([String: PersistedCookState].self, from: data) {
            self.deviceCookState = decoded
        } else {
            self.deviceCookState = [:]
        }
    }

    var menuBarIconName: String {
        connectedDevice == nil ? "thermometer.medium.slash" : "thermometer.medium"
    }

    var systemInfoText: String {
        systemInfo.map(MiniFormat.json) ?? "No system information loaded yet."
    }

    var currentDisplayText: String {
        let unit = selectedUnit
        let value = lastKnownCurrentTemperature ?? snapshot?.currentTemperatureValue

        guard let value else {
            return "Unavailable"
        }

        let displayValue = unit == .fahrenheit
            ? Self.convertTemperature(value, from: .celsius, to: .fahrenheit)
            : value

        return "\(MiniFormat.temperature(displayValue))\(unit.symbol)"
    }

    var targetDisplayText: String {
        let unit = selectedUnit
        let value = lastKnownTargetTemperature ?? snapshot?.targetTemperatureValue

        guard let value else {
            return "Unavailable"
        }

        return "\(MiniFormat.temperature(value))\(unit.symbol)"
    }

    var timerDisplayText: String {
        switch cookTimerState {
        case .none:
            return snapshot?.timerDisplay ?? "Unavailable"
        case .staged(let seconds):
            return MiniFormat.duration(seconds: seconds)
        case .paused(let seconds):
            let duration = seconds == 0 ? "∞" : MiniFormat.duration(seconds: seconds)
            return "Paused · \(duration)"
        case .running(let initialSeconds, let startedAt):
            if initialSeconds == 0 {
                return "∞"
            }
            let remaining = Self.remainingTimerSeconds(initialSeconds: initialSeconds, startedAt: startedAt, now: timerNow)
            return remaining == 0 ? "Complete" : MiniFormat.duration(seconds: remaining)
        case .stopped:
            return MiniFormat.duration(seconds: 0)
        }
    }

    var rawReadingsText: String {
        guard let snapshot else {
            return "No device readings loaded yet."
        }

        return MiniFormat.json(
            [
                "currentTemperature": snapshot.currentTemperature,
                "state": snapshot.state,
                "timer": snapshot.timer,
            ]
        )
    }

    var connectedDeviceTitle: String {
        guard let device = connectedDevice else {
            return ""
        }

        return label(for: device)
    }

    var primaryCookActionTitle: String {
        switch cookTimerState {
        case .running:
            return "Pause"
        case .paused:
            return "Resume"
        case .none, .staged, .stopped:
            return "Start Cook"
        }
    }

    func loadIfNeeded() async {
        guard !didLoad else {
            return
        }

        didLoad = true
        syncAliasDraft()
    }

    func scan() async {
        guard !isScanning else {
            return
        }

        isScanning = true
        lastError = nil

        defer {
            isScanning = false
        }

        do {
            let found = try await client.scan(timeout: 5)
            devices = found

            if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = found.first?.id
            }

            syncAliasDraft()

            if found.isEmpty {
                statusMessage = "No Anova Mini devices found."
            } else {
                statusMessage = "Found \(found.count) nearby Mini device(s)."
            }
        } catch {
            present(error)
        }
    }

    func selectDevice(_ id: UUID?) {
        selectedDeviceID = id
        syncAliasDraft()
    }

    func connectSelectedDevice() async {
        await perform("Connecting…") { [self] in
            guard let selectedDeviceID = self.selectedDeviceID else {
                throw MiniBLEClientError.noSelection
            }

            let device = try await self.client.connect(to: selectedDeviceID)
            self.connectedDevice = device
            self.restoreCookState(for: device)
            self.syncAliasDraft()
            self.statusMessage = "Connected to \(self.label(for: device))."

            self.systemInfo = try await self.client.systemInfo()
            try await self.refreshSnapshot()
            self.startPolling()
            self.startClock()
        }
    }

    func disconnect() async {
        stopPolling()
        stopClock()
        client.disconnect()
        connectedDevice = nil
        snapshot = nil
        systemInfo = nil
        restoreCookState(for: selectedOrConnectedDevice())
        syncAliasDraft()
        statusMessage = "Disconnected."
    }

    func saveAlias() {
        guard let device = selectedOrConnectedDevice() else {
            return
        }

        let trimmed = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deviceAliases.removeValue(forKey: device.identifier)
            statusMessage = "Removed custom name."
        } else {
            deviceAliases[device.identifier] = trimmed
            statusMessage = "Saved name \"\(trimmed)\"."
        }

        persistAliases()
        objectWillChange.send()
    }

    func clearAlias() {
        aliasText = ""
        saveAlias()
    }

    func refresh() async {
        await perform("Refreshing…") { [self] in
            try await self.refreshSnapshot()
            self.systemInfo = try await self.client.systemInfo()
        }
    }

    func applyUnitChange(to unit: MiniTemperatureUnit, previousUnit: MiniTemperatureUnit) async {
        guard !isUnitChangeInFlight else {
            return
        }

        isUnitChangeInFlight = true

        await perform("Updating temperature unit…") { [self] in
            try await self.client.setUnit(unit)
            self.convertVisibleTemperatures(from: previousUnit, to: unit)
            self.selectedUnit = unit
            if case let .running(timerSeconds, _) = self.cookTimerState {
                let targetTemperature: Double
                if let lastKnownTargetTemperature {
                    targetTemperature = lastKnownTargetTemperature
                } else if let snapshotTarget = self.snapshot?.targetTemperatureValue {
                    targetTemperature = snapshotTarget
                } else {
                    targetTemperature = try self.parseTargetTemperature()
                }
                try await self.syncDeviceState(
                    after: .running(
                        targetTemperature: targetTemperature,
                        timerSeconds: timerSeconds,
                        temperatureUnit: unit,
                        requireTimerRunningSignal: true
                    ),
                    preservingTimerState: true
                )
            } else {
                try await self.syncDeviceState(after: .temperatureUnit(unit), preservingTimerState: true)
            }
            self.statusMessage = "Temperature unit updated to \(unit.rawValue)."
        }

        isUnitChangeInFlight = false
    }

    func applySetTemperature() async {
        await perform("Setting target temperature…") { [self] in
            let target = try self.parseTargetTemperature()
            try await self.client.setTemperature(target)
            self.lastKnownTargetTemperature = target
            self.persistCookState(targetTemperature: target)
            if case let .running(timerSeconds, _) = self.cookTimerState {
                try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timerSeconds, requireTimerRunningSignal: true)
                )
            } else {
                try await self.syncDeviceState(after: .targetTemperature(target))
            }
            self.statusMessage = "Target temperature set to \(MiniFormat.temperature(target))\(self.selectedUnit.symbol)."
        }
    }

    func applyTimer() async {
        await perform("Updating timer…") { [self] in
            let timer = try self.parseTimerSeconds()
            self.timerMinutesText = Self.minutesString(fromSeconds: timer)

            if self.snapshot?.isCooking == true {
                let target: Double
                if let snapshotTarget = self.snapshot?.targetTemperatureValue {
                    target = snapshotTarget
                } else if let lastKnownTarget = self.lastKnownTargetTemperature {
                    target = lastKnownTarget
                } else {
                    target = try self.parseTargetTemperature()
                }
                try await self.client.startCook(setpoint: target, timerSeconds: timer)
                self.lastKnownTargetTemperature = target
                self.cookTimerState = .running(initialSeconds: timer, startedAt: Date())
                try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timer, requireTimerRunningSignal: true)
                )
                self.statusMessage = "Timer updated."
            } else {
                self.cookTimerState = timer == 0 ? .stopped : .staged(seconds: timer)
                self.statusMessage = "Timer staged for the next cook."
            }

            self.persistCookState(targetTemperature: self.snapshot?.targetTemperatureValue ?? self.lastKnownTargetTemperature)
        }
    }

    func startCook() async {
        await perform("Starting cook…") { [self] in
            let setpoint = try self.parseTargetTemperature()
            let timer = try self.parseTimerSeconds()
            try await self.client.startCook(setpoint: setpoint, timerSeconds: timer)
            self.lastKnownTargetTemperature = setpoint
            self.cookTimerState = .running(initialSeconds: timer, startedAt: Date())
            self.persistCookState(targetTemperature: setpoint)
            try await self.syncDeviceState(
                after: .running(targetTemperature: setpoint, timerSeconds: timer, requireTimerRunningSignal: true)
            )
            self.statusMessage = "Start command sent."
        }
    }

    func primaryCookAction() async {
        switch cookTimerState {
        case .running:
            await pauseCook()
        case .paused:
            await resumeCook()
        case .none, .staged, .stopped:
            await startCook()
        }
    }

    func stopCook() async {
        await perform("Stopping cook…") { [self] in
            let preservedTimerSeconds = configuredTimerSeconds()
            try await self.client.stopCook()
            if let preservedTimerSeconds, preservedTimerSeconds > 0 {
                self.timerMinutesText = Self.minutesString(fromSeconds: preservedTimerSeconds)
                self.cookTimerState = .staged(seconds: preservedTimerSeconds)
            } else {
                self.timerMinutesText = "0"
                self.cookTimerState = .stopped
            }
            self.persistCookState(targetTemperature: self.lastKnownTargetTemperature)
            try await self.syncDeviceState(after: .stopped)
            if let preservedTimerSeconds, preservedTimerSeconds > 0 {
                self.cookTimerState = .staged(seconds: preservedTimerSeconds)
                self.timerMinutesText = Self.minutesString(fromSeconds: preservedTimerSeconds)
                self.persistCookState(targetTemperature: self.lastKnownTargetTemperature)
            }
            self.statusMessage = "Stop command sent."
        }
    }

    func label(for device: MiniDiscoveredDevice) -> String {
        alias(for: device) ?? device.displayName
    }

    private func perform(_ busyMessage: String, operation: @escaping () async throws -> Void) async {
        guard !operationInFlight else {
            return
        }

        let stateSnapshot = captureOperationState()
        operationInFlight = true
        isBusy = true
        lastError = nil
        let previousStatus = statusMessage
        statusMessage = busyMessage

        defer {
            operationInFlight = false
            isBusy = false
        }

        do {
            try await operation()
        } catch {
            restoreOperationState(stateSnapshot)
            statusMessage = previousStatus
            present(error)
        }
    }

    private func captureOperationState() -> OperationStateSnapshot {
        OperationStateSnapshot(
            connectedDevice: connectedDevice,
            snapshot: snapshot,
            systemInfo: systemInfo,
            targetTemperatureText: targetTemperatureText,
            timerMinutesText: timerMinutesText,
            selectedUnit: selectedUnit,
            lastKnownCurrentTemperature: lastKnownCurrentTemperature,
            lastKnownTargetTemperature: lastKnownTargetTemperature,
            cookTimerState: cookTimerState
        )
    }

    private func restoreOperationState(_ state: OperationStateSnapshot) {
        if connectedDevice?.id != state.connectedDevice?.id {
            client.disconnect()
        }

        connectedDevice = state.connectedDevice
        snapshot = state.snapshot
        systemInfo = state.systemInfo
        targetTemperatureText = state.targetTemperatureText
        timerMinutesText = state.timerMinutesText
        selectedUnit = state.selectedUnit
        lastKnownCurrentTemperature = state.lastKnownCurrentTemperature
        lastKnownTargetTemperature = state.lastKnownTargetTemperature
        cookTimerState = state.cookTimerState
    }

    private func refreshSnapshot(preservingTimerState: Bool = false) async throws {
        let latestSnapshot = try await client.snapshot()
        applySnapshot(latestSnapshot, preservingTimerState: preservingTimerState)
    }

    private func applySnapshot(_ latestSnapshot: MiniSnapshot, preservingTimerState: Bool = false) {
        snapshot = latestSnapshot

        if let unit = latestSnapshot.temperatureUnit, !isUnitChangeInFlight {
            selectedUnit = unit
        }

        if let current = latestSnapshot.currentTemperatureValue, !isUnitChangeInFlight {
            lastKnownCurrentTemperature = current
        }

        if let target = latestSnapshot.targetTemperatureValue, !isUnitChangeInFlight {
            lastKnownTargetTemperature = target
            targetTemperatureText = MiniFormat.temperature(target)
        }

        if !preservingTimerState {
            reconcileTimerState(with: latestSnapshot)
        }
        persistCookState(targetTemperature: latestSnapshot.targetTemperatureValue ?? lastKnownTargetTemperature)
    }

    private func parseTargetTemperature() throws -> Double {
        guard let value = Double(targetTemperatureText) else {
            throw MiniBLEClientError.invalidPayload("Enter a numeric target temperature.")
        }

        return value
    }

    private func parseTimerSeconds() throws -> Int {
        guard let value = Int(timerMinutesText), value >= 0 else {
            throw MiniBLEClientError.invalidPayload("Enter a non-negative timer in minutes.")
        }

        return value * 60
    }

    private func startPolling() {
        stopPolling()

        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else {
                    return
                }

                if !self.operationInFlight, self.connectedDevice != nil {
                    do {
                        try await self.refreshSnapshot()
                    } catch {
                        self.present(error)
                    }
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startClock() {
        stopClock()

        clockTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }

                self.timerNow = Date()
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func present(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func alias(for device: MiniDiscoveredDevice) -> String? {
        let alias = deviceAliases[device.identifier]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let alias, !alias.isEmpty else {
            return nil
        }

        return alias
    }

    private func selectedOrConnectedDevice() -> MiniDiscoveredDevice? {
        if let connectedDevice {
            return connectedDevice
        }

        guard let selectedDeviceID else {
            return nil
        }

        return devices.first(where: { $0.id == selectedDeviceID })
    }

    private func syncAliasDraft() {
        aliasText = selectedOrConnectedDevice().flatMap(alias(for:)) ?? ""
    }

    private func persistAliases() {
        defaults.set(deviceAliases, forKey: Self.aliasStorageKey)
    }

    private func restoreCookState(for device: MiniDiscoveredDevice?) {
        guard let device else {
            lastKnownTargetTemperature = nil
            cookTimerState = .none
            targetTemperatureText = "60.0"
            timerMinutesText = "0"
            return
        }

        let persisted = deviceCookState[device.identifier]
        lastKnownTargetTemperature = persisted?.targetTemperature
        cookTimerState = Self.restoreTimerState(from: persisted?.timerState)

        if let target = persisted?.targetTemperature {
            targetTemperatureText = MiniFormat.temperature(target)
        } else {
            targetTemperatureText = "60.0"
        }

        switch cookTimerState {
        case .staged(let seconds):
            timerMinutesText = Self.minutesString(fromSeconds: seconds)
        case .paused(let seconds):
            timerMinutesText = Self.minutesString(fromSeconds: seconds)
        case .stopped, .none:
            timerMinutesText = "0"
        case .running:
            timerMinutesText = "0"
        }
    }

    private func persistCookState(targetTemperature: Double?) {
        guard let device = connectedDevice ?? selectedOrConnectedDevice() else {
            return
        }

        deviceCookState[device.identifier] = PersistedCookState(
            targetTemperature: targetTemperature,
            timerState: Self.persistedTimerState(for: cookTimerState)
        )

        if let data = try? JSONEncoder().encode(deviceCookState) {
            defaults.set(data, forKey: Self.cookStateStorageKey)
        }
    }

    private func convertVisibleTemperatures(from previousUnit: MiniTemperatureUnit, to newUnit: MiniTemperatureUnit) {
        guard previousUnit != newUnit else {
            return
        }

        if let parsed = Double(targetTemperatureText) {
            targetTemperatureText = MiniFormat.temperature(Self.convertTemperature(parsed, from: previousUnit, to: newUnit))
        }

        if let lastKnownTargetTemperature {
            self.lastKnownTargetTemperature = Self.convertTemperature(lastKnownTargetTemperature, from: previousUnit, to: newUnit)
        }
    }

    private static func convertTemperature(_ value: Double, from: MiniTemperatureUnit, to: MiniTemperatureUnit) -> Double {
        switch (from, to) {
        case (.celsius, .fahrenheit):
            return (value * 9.0 / 5.0) + 32.0
        case (.fahrenheit, .celsius):
            return (value - 32.0) * 5.0 / 9.0
        default:
            return value
        }
    }

    private static func minutesString(fromSeconds seconds: Int) -> String {
        String(max(0, seconds / 60))
    }

    private func configuredTimerSeconds() -> Int? {
        if let parsedMinutes = Int(timerMinutesText), parsedMinutes >= 0 {
            return parsedMinutes * 60
        }

        switch cookTimerState {
        case .staged(let seconds), .paused(let seconds), .running(let seconds, _):
            return seconds
        case .none, .stopped:
            return nil
        }
    }

    private func pauseCook() async {
        await perform("Pausing cook…") { [self] in
            guard case let .running(initialSeconds, startedAt) = self.cookTimerState else {
                return
            }

            let remainingSeconds = initialSeconds == 0
                ? 0
                : Self.remainingTimerSeconds(initialSeconds: initialSeconds, startedAt: startedAt, now: self.timerNow)

            try await self.client.stopCook()
            try await self.syncDeviceState(after: .stopped)

            self.cookTimerState = .paused(seconds: remainingSeconds)
            self.timerMinutesText = Self.minutesString(fromSeconds: remainingSeconds)
            self.persistCookState(targetTemperature: self.lastKnownTargetTemperature)
            self.statusMessage = "Cook paused."
        }
    }

    private func resumeCook() async {
        await perform("Resuming cook…") { [self] in
            guard case let .paused(timerSeconds) = self.cookTimerState else {
                return
            }

            let target: Double
            if let snapshotTarget = self.snapshot?.targetTemperatureValue {
                target = snapshotTarget
            } else if let lastKnownTarget = self.lastKnownTargetTemperature {
                target = lastKnownTarget
            } else {
                target = try self.parseTargetTemperature()
            }

            try await self.client.startCook(setpoint: target, timerSeconds: timerSeconds)
            self.lastKnownTargetTemperature = target
            self.cookTimerState = .running(initialSeconds: timerSeconds, startedAt: Date())
            self.persistCookState(targetTemperature: target)
            try await self.syncDeviceState(
                after: .running(targetTemperature: target, timerSeconds: timerSeconds, requireTimerRunningSignal: true)
            )
            self.statusMessage = "Cook resumed."
        }
    }

    private func syncDeviceState(after expectedState: ExpectedDeviceState, preservingTimerState: Bool = false) async throws {
        let maxAttempts = 10
        let pollInterval = Duration.milliseconds(350)

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: pollInterval)
            }

            let polledSnapshot = try await client.snapshot()

            if expectedState.matches(polledSnapshot) {
                applySnapshot(polledSnapshot, preservingTimerState: preservingTimerState)
                return
            }
        }

        throw MiniBLEClientError.stateUnconfirmed(expectedState.summary)
    }

    private func reconcileTimerState(with snapshot: MiniSnapshot) {
        if snapshot.isCooking {
            guard let initialSeconds = snapshot.timerInitialSeconds ?? snapshot.timerSecondsValue else {
                cookTimerState = .none
                timerMinutesText = "0"
                return
            }

            let startedAt = snapshot.timerStartedAt ?? preservedRunningStartedAt(for: initialSeconds) ?? Date()
            cookTimerState = .running(initialSeconds: initialSeconds, startedAt: startedAt)
            timerMinutesText = Self.minutesString(fromSeconds: initialSeconds)
            return
        }

        if case .paused(let seconds) = cookTimerState {
            timerMinutesText = Self.minutesString(fromSeconds: seconds)
            return
        }

        if case .stopped = cookTimerState {
            timerMinutesText = "0"
            return
        }

        if let stagedSeconds = snapshot.timerSecondsValue, stagedSeconds > 0 {
            cookTimerState = .staged(seconds: stagedSeconds)
            timerMinutesText = Self.minutesString(fromSeconds: stagedSeconds)
        } else {
            cookTimerState = .none
            timerMinutesText = "0"
        }
    }

    private func preservedRunningStartedAt(for initialSeconds: Int) -> Date? {
        guard case let .running(currentInitialSeconds, startedAt) = cookTimerState,
              currentInitialSeconds == initialSeconds else {
            return nil
        }

        return startedAt
    }

    private static func remainingTimerSeconds(initialSeconds: Int, startedAt: Date, now: Date) -> Int {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return max(0, initialSeconds - elapsed)
    }

    private static func persistedTimerState(for timerState: CookTimerState) -> PersistedTimerState? {
        switch timerState {
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .paused(let seconds):
            return .paused(seconds: seconds)
        case .stopped:
            return .stopped
        case .none, .running:
            return nil
        }
    }

    private static func restoreTimerState(from timerState: PersistedTimerState?) -> CookTimerState {
        switch timerState {
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .paused(let seconds):
            return .paused(seconds: seconds)
        case .stopped:
            return .stopped
        case nil:
            return .none
        }
    }
}

import Foundation

@MainActor
final class AppModel: ObservableObject {
    private static let aliasStorageKey = "deviceAliases"
    private static let cookStateStorageKey = "deviceCookState"
    private static let debugEnabledStorageKey = "debugEnabled"

    private struct PersistedCookState: Codable {
        var targetTemperature: Double?
        var timerState: PersistedTimerState?
        var lastCompletedAt: Date?
    }

    private enum PersistedTimerState: Codable {
        case staged(seconds: Int)
        case paused(seconds: Int)
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

    private struct OperationStateSnapshot {
        var connectedDevice: AnovaDiscoveredDevice?
        var observedState: MiniObservedDeviceState
        var targetTemperatureText: String
        var timerMinutesText: String
        var selectedUnit: MiniTemperatureUnit
        var sessionState: MiniCookSessionState
    }

    @Published private(set) var devices: [AnovaDiscoveredDevice] = []
    @Published var selectedDeviceID: UUID?
    @Published private(set) var connectedDevice: AnovaDiscoveredDevice?
    @Published private var observedState = MiniObservedDeviceState()
    @Published private var sessionState = MiniCookSessionState()
    @Published private(set) var statusMessage = "Disconnected."
    @Published private(set) var isBusy = false
    @Published private(set) var isScanning = false
    @Published private(set) var hasCompletedScan = false
    @Published private(set) var bleTraceText = MiniDiagnosticsStore.emptyText
    @Published var isDebugEnabled: Bool
    @Published var targetTemperatureText = "60.0"
    @Published var timerMinutesText = "0"
    @Published var selectedUnit: MiniTemperatureUnit = .celsius
    @Published var aliasText = ""
    @Published var lastError: String?

    private let diagnostics: MiniDiagnosticsStore
    private let coordinator: AnovaBLECoordinator
    private let defaults = UserDefaults.standard
    private var didLoad = false
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var operationInFlight = false
    private var isUnitChangeInFlight = false
    private var deviceAliases: [String: String]
    private var deviceCookState: [String: PersistedCookState]
    private var session: (any AnovaCookerSession)?
    @Published private var timerNow = Date()

    init() {
        self.diagnostics = MiniDiagnosticsStore()
        self.coordinator = AnovaBLECoordinator(diagnostics: diagnostics)
        self.deviceAliases = defaults.dictionary(forKey: Self.aliasStorageKey) as? [String: String] ?? [:]
        self.isDebugEnabled = defaults.object(forKey: Self.debugEnabledStorageKey) as? Bool ?? false
        if let data = defaults.data(forKey: Self.cookStateStorageKey),
           let decoded = try? JSONDecoder().decode([String: PersistedCookState].self, from: data) {
            self.deviceCookState = decoded
        } else {
            self.deviceCookState = [:]
        }
        self.bleTraceText = diagnostics.renderedText
        diagnostics.onChange = { [weak self] text in
            self?.bleTraceText = text
        }
    }

    var menuBarIconName: String {
        connectedDevice == nil ? "thermometer.medium.slash" : "thermometer.medium"
    }

    var systemInfoText: String {
        observedState.systemInfo.map(MiniFormat.json) ?? "No system information loaded yet."
    }

    var currentDisplayText: String {
        let unit = selectedUnit
        let value = observedState.currentDisplayTemperature

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
        let value = observedState.targetDisplayTemperature

        guard let value else {
            return "Unavailable"
        }

        return "\(MiniFormat.temperature(value))\(unit.symbol)"
    }

    var timerDisplayText: String {
        sessionState.timerDisplayText(now: timerNow, fallback: observedState.snapshot?.timerDisplay)
    }

    var rawReadingsText: String {
        guard let snapshot = observedState.snapshot else {
            return "No device readings loaded yet."
        }

        return MiniFormat.json(
            [
                "interpretation": snapshot.interpretation,
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

    var canStartCook: Bool {
        !sessionState.blocksStartAction && observedState.snapshot?.isCooking != true
    }

    var canStopCook: Bool {
        sessionState.enablesStopAction || observedState.snapshot?.isCooking == true
    }

    func setDebugEnabled(_ isEnabled: Bool) {
        guard isDebugEnabled != isEnabled else {
            return
        }

        isDebugEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.debugEnabledStorageKey)
        recordApp("debugModeChanged enabled=\(isEnabled)")
    }

    func loadIfNeeded() async {
        guard !didLoad else {
            return
        }

        didLoad = true
        syncAliasDraft()
    }

    func scan() async {
        recordApp("scanRequested")
        guard !isScanning else {
            return
        }

        isScanning = true
        lastError = nil

        defer {
            isScanning = false
        }

        do {
            let found = try await coordinator.scan(timeout: 5)
            devices = found
            hasCompletedScan = true

            if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = found.first?.id
            }

            syncAliasDraft()

            if found.isEmpty {
                statusMessage = "No supported Anova cookers found."
            } else {
                statusMessage = "Found \(found.count) nearby cooker(s)."
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
        diagnostics.reset(.app, "connectRequested")
        await perform("Connecting…") { [self] in
            guard let selectedDeviceID = self.selectedDeviceID else {
                throw MiniBLEClientError.noSelection
            }

            let session = try await self.coordinator.connect(to: selectedDeviceID)
            let device = session.device
            self.session = session
            self.recordApp("connected", details: ["device": device.displayName])
            self.connectedDevice = device
            self.restoreCookState(for: device)
            self.syncAliasDraft()
            self.statusMessage = "Connected to \(self.label(for: device))."

            if session.supportsClockSync {
                try await session.setClockToUTCNow()
            }
            self.observedState.systemInfo = try await session.systemInfo()
            try await self.refreshSnapshot()
            self.startPolling()
            self.startClock()
        }
    }

    func disconnect() async {
        recordApp("disconnectRequested")
        stopPolling()
        stopClock()
        session?.disconnect()
        session = nil
        coordinator.disconnect()
        connectedDevice = nil
        observedState.clearConnectionState()
        _ = sessionState.apply(.disconnect)
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
        recordApp("refreshRequested")
        await perform("Refreshing…") { [self] in
            try await self.refreshSnapshot()
            self.observedState.systemInfo = try await self.activeSession().systemInfo()
        }
    }

    func applyUnitChange(to unit: MiniTemperatureUnit, previousUnit: MiniTemperatureUnit) async {
        guard !isUnitChangeInFlight else {
            return
        }

        isUnitChangeInFlight = true

        await perform("Updating temperature unit…") { [self] in
            self.recordApp("setUnit", details: ["unit": unit.rawValue])
            try await self.activeSession().setUnit(unit)
            self.convertVisibleTemperatures(from: previousUnit, to: unit)
            self.selectedUnit = unit
            if let timerSeconds = self.sessionState.activeCookTimerSeconds {
                let targetTemperature: Double
                if let lastKnownTargetTemperature = self.observedState.lastKnownTargetTemperature {
                    targetTemperature = lastKnownTargetTemperature
                } else if let snapshotTarget = self.observedState.snapshot?.targetTemperatureValue {
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
            self.recordApp(
                "setTemperature",
                details: ["target": "\(MiniFormat.temperature(target))\(self.selectedUnit.symbol)"]
            )
            try await self.activeSession().setTemperature(target)
            self.observedState.setTargetTemperature(target)
            self.persistCookState(targetTemperature: target)
            if let timerSeconds = self.sessionState.activeCookTimerSeconds {
                try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timerSeconds, requireTimerRunningSignal: true),
                    preservingTimerState: true
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
            self.recordApp(
                "setTimer",
                details: [
                    "minutes": String(timer / 60),
                    "seconds": String(timer),
                ]
            )
            self.timerMinutesText = Self.minutesString(fromSeconds: timer)

            if self.observedState.snapshot?.isCooking == true {
                let target: Double
                if let snapshotTarget = self.observedState.snapshot?.targetTemperatureValue {
                    target = snapshotTarget
                } else if let lastKnownTarget = self.observedState.lastKnownTargetTemperature {
                    target = lastKnownTarget
                } else {
                    target = try self.parseTargetTemperature()
                }
                try await self.activeSession().startCook(setpoint: target, timerSeconds: timer)
                self.observedState.setTargetTemperature(target)
                _ = self.sessionState.apply(.timerUpdatedWhileCooking(timerSeconds: timer, now: Date()))
                try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timer, requireTimerRunningSignal: true),
                    preservingTimerState: true
                )
                self.statusMessage = "Timer updated."
            } else {
                _ = self.sessionState.apply(.stageTimer(seconds: timer))
                self.statusMessage = "Timer staged for the next cook."
            }

            self.persistCookState(targetTemperature: self.observedState.snapshot?.targetTemperatureValue ?? self.observedState.lastKnownTargetTemperature)
        }
    }

    func startCook() async {
        await perform("Starting cook…") { [self] in
            let setpoint = try self.parseTargetTemperature()
            let timer = try self.parseTimerSeconds()
            self.recordApp(
                "startCook",
                details: [
                    "setpoint": "\(MiniFormat.temperature(setpoint))\(self.selectedUnit.symbol)",
                    "timerSeconds": String(timer),
                ]
            )
            try await self.activeSession().startCook(setpoint: setpoint, timerSeconds: timer)
            self.observedState.setTargetTemperature(setpoint)
            _ = self.sessionState.apply(.startRequested(timerSeconds: timer, now: Date()))
            self.persistCookState(targetTemperature: setpoint)
            try await self.syncDeviceState(
                after: .running(targetTemperature: setpoint, timerSeconds: timer, requireTimerRunningSignal: true),
                preservingTimerState: true
            )
            self.statusMessage = "Start command sent."
        }
    }

    func stopCook() async {
        await perform("Stopping cook…") { [self] in
            let preservedTimerSeconds = configuredTimerSeconds()
            self.recordApp(
                "stopCook",
                details: ["preservedTimerSeconds": preservedTimerSeconds.map(String.init) ?? "nil"]
            )
            try await self.executeStopCook(preservedTimerSeconds: preservedTimerSeconds, origin: .manual)
            self.statusMessage = "Stop command sent."
        }
    }

    func label(for device: AnovaDiscoveredDevice) -> String {
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
            diagnostics.record(.error, "operation", details: ["reason": error.localizedDescription])
            restoreOperationState(stateSnapshot)
            statusMessage = previousStatus
            present(error)
        }
    }

    private func captureOperationState() -> OperationStateSnapshot {
        OperationStateSnapshot(
            connectedDevice: connectedDevice,
            observedState: observedState,
            targetTemperatureText: targetTemperatureText,
            timerMinutesText: timerMinutesText,
            selectedUnit: selectedUnit,
            sessionState: sessionState
        )
    }

    private func restoreOperationState(_ state: OperationStateSnapshot) {
        if connectedDevice?.id != state.connectedDevice?.id {
            session?.disconnect()
            session = nil
            coordinator.disconnect()
        }

        connectedDevice = state.connectedDevice
        observedState = state.observedState
        targetTemperatureText = state.targetTemperatureText
        timerMinutesText = state.timerMinutesText
        selectedUnit = state.selectedUnit
        sessionState = state.sessionState
    }

    private func refreshSnapshot(preservingTimerState: Bool = false) async throws {
        let latestSnapshot = try await activeSession().snapshot()
        applySnapshot(latestSnapshot, preservingTimerState: preservingTimerState)
    }

    private func applySnapshot(_ latestSnapshot: CookerSnapshot, preservingTimerState: Bool = false) {
        diagnostics.record(
            .snapshot,
            "applySnapshot",
            details: [
                "preservingTimerState": String(preservingTimerState),
                "state": MiniFormat.compactJSON(latestSnapshot.state),
                "timer": MiniFormat.compactJSON(latestSnapshot.timer),
            ]
        )
        observedState.apply(snapshot: latestSnapshot)

        if let unit = latestSnapshot.temperatureUnit, !isUnitChangeInFlight {
            selectedUnit = unit
        }

        if let target = latestSnapshot.targetTemperatureValue, !isUnitChangeInFlight {
            targetTemperatureText = MiniFormat.temperature(target)
        }

        let effect = sessionState.apply(.snapshotObserved(latestSnapshot, preservingPhase: preservingTimerState, now: Date()))
        refreshTimerMinutesTextFromSession()
        handleSessionEffect(effect, snapshot: latestSnapshot)
        persistCookState(targetTemperature: latestSnapshot.targetTemperatureValue ?? observedState.lastKnownTargetTemperature)
    }

    private func parseTargetTemperature() throws -> Double {
        guard let value = Double(targetTemperatureText) else {
            throw MiniBLEClientError.invalidPayload("Enter a numeric target temperature.")
        }

        if connectedDevice?.family == .mini {
            let supportedRange = selectedUnit.supportedSetpointRange
            guard supportedRange.contains(value) else {
                throw MiniBLEClientError.invalidPayload(
                    "Enter a temperature between \(selectedUnit.supportedSetpointDescription)."
                )
            }
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

    private func alias(for device: AnovaDiscoveredDevice) -> String? {
        let alias = deviceAliases[device.identifier]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let alias, !alias.isEmpty else {
            return nil
        }

        return alias
    }

    private func selectedOrConnectedDevice() -> AnovaDiscoveredDevice? {
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

    private func restoreCookState(for device: AnovaDiscoveredDevice?) {
        guard let device else {
            observedState.restorePersistedTarget(nil)
            _ = sessionState.apply(.restore(timerState: .none, lastCompletedAt: nil))
            targetTemperatureText = "60.0"
            timerMinutesText = "0"
            diagnostics.record(.persistence, "restoreCookState", details: ["device": "nil"])
            return
        }

        let persisted = deviceCookState[device.identifier]
        observedState.restorePersistedTarget(persisted?.targetTemperature)
        _ = sessionState.apply(
            .restore(
                timerState: Self.restoredTimerState(from: persisted?.timerState),
                lastCompletedAt: persisted?.lastCompletedAt
            )
        )
        diagnostics.record(
            .persistence,
            "restoreCookState",
            details: [
                "device": device.displayName,
                "target": persisted?.targetTemperature.map(MiniFormat.temperature) ?? "nil",
                "timerState": String(describing: persisted?.timerState),
                "lastCompletedAt": persisted?.lastCompletedAt.map(MiniFormat.dateTime) ?? "nil",
            ]
        )

        if let target = persisted?.targetTemperature {
            targetTemperatureText = MiniFormat.temperature(target)
        } else {
            targetTemperatureText = "60.0"
        }

        refreshTimerMinutesTextFromSession()
    }

    private func persistCookState(targetTemperature: Double?) {
        guard let device = connectedDevice ?? selectedOrConnectedDevice() else {
            return
        }

        deviceCookState[device.identifier] = PersistedCookState(
            targetTemperature: targetTemperature,
            timerState: Self.persistedTimerState(for: sessionState.persistedTimerState),
            lastCompletedAt: sessionState.lastCompletedAt
        )

        if let data = try? JSONEncoder().encode(deviceCookState) {
            defaults.set(data, forKey: Self.cookStateStorageKey)
        }

        diagnostics.record(
            .persistence,
            "persistCookState",
            details: [
                "device": device.displayName,
                "target": targetTemperature.map(MiniFormat.temperature) ?? "nil",
                "timerState": String(describing: Self.persistedTimerState(for: sessionState.persistedTimerState)),
                "lastCompletedAt": sessionState.lastCompletedAt.map(MiniFormat.dateTime) ?? "nil",
            ]
        )
    }

    private func convertVisibleTemperatures(from previousUnit: MiniTemperatureUnit, to newUnit: MiniTemperatureUnit) {
        guard previousUnit != newUnit else {
            return
        }

        if let parsed = Double(targetTemperatureText) {
            targetTemperatureText = MiniFormat.temperature(Self.convertTemperature(parsed, from: previousUnit, to: newUnit))
        }

        if let lastKnownTargetTemperature = observedState.lastKnownTargetTemperature {
            observedState.lastKnownTargetTemperature = Self.convertTemperature(lastKnownTargetTemperature, from: previousUnit, to: newUnit)
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

        return sessionState.configuredTimerSeconds
    }

    private func syncDeviceState(after expectedState: ExpectedDeviceState, preservingTimerState: Bool = false) async throws {
        let session = try activeSession()
        guard session.supportsStrictStateConfirmation else {
            let snapshot = try await session.snapshot()
            applySnapshot(snapshot, preservingTimerState: preservingTimerState)
            return
        }

        let maxAttempts: Int
        let pollInterval: Duration

        switch expectedState {
        case .stopped:
            maxAttempts = 24
            pollInterval = .milliseconds(350)
        case .temperatureUnit, .targetTemperature, .running:
            maxAttempts = 10
            pollInterval = .milliseconds(350)
        }

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: pollInterval)
            }

            let polledSnapshot = try await activeSession().snapshot()
            diagnostics.record(
                .snapshot,
                "syncAttempt",
                details: [
                    "attempt": "\(attempt + 1)/\(maxAttempts)",
                    "expected": expectedState.summary,
                    "state": MiniFormat.compactJSON(polledSnapshot.state),
                    "timer": MiniFormat.compactJSON(polledSnapshot.timer),
                ]
            )

            if expectedState.matches(polledSnapshot) {
                applySnapshot(polledSnapshot, preservingTimerState: preservingTimerState)
                return
            }
        }

        throw MiniBLEClientError.stateUnconfirmed(expectedState.summary)
    }

    private enum StopOrigin {
        case manual
        case automaticAfterCompletion
    }

    private func refreshTimerMinutesTextFromSession() {
        switch sessionState.phase {
        case .staged(let seconds), .waitingForTemperature(let seconds), .completed(let seconds):
            timerMinutesText = Self.minutesString(fromSeconds: seconds)
        case .running, .stopped, .none:
            timerMinutesText = "0"
        }
    }

    private func handleSessionEffect(_ effect: MiniCookSessionEffect?, snapshot: CookerSnapshot) {
        guard let effect else {
            return
        }

        switch effect {
        case .autoStopAfterTimerCompletion:
            scheduleAutoStopAfterTimerCompletion(using: snapshot)
        }
    }

    private func scheduleAutoStopAfterTimerCompletion(using snapshot: CookerSnapshot) {
        guard autoStopTask == nil else {
            return
        }

        diagnostics.record(
            .app,
            "timerCompleted",
            details: [
                "state": MiniFormat.compactJSON(snapshot.state),
                "timer": MiniFormat.compactJSON(snapshot.timer),
            ]
        )

        autoStopTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.perform("Stopping cook after timer completion…") { [self] in
                self.recordApp("autoStopAfterTimerCompletion")
                try await self.executeStopCook(preservedTimerSeconds: nil, origin: .automaticAfterCompletion)
                self.statusMessage = "Timer completed. Stop command sent."
            }

            self.autoStopTask = nil
        }
    }

    private func executeStopCook(preservedTimerSeconds: Int?, origin: StopOrigin) async throws {
        switch origin {
        case .manual:
            _ = sessionState.apply(.stopRequested(preservedTimerSeconds: preservedTimerSeconds))
        case .automaticAfterCompletion:
            _ = sessionState.apply(.autoStopRequested)
        }
        refreshTimerMinutesTextFromSession()
        try await activeSession().stopCook()
        persistCookState(targetTemperature: observedState.lastKnownTargetTemperature)
        try await syncDeviceState(after: .stopped)
        _ = sessionState.apply(.stopConfirmed(preservedTimerSeconds: preservedTimerSeconds))
        refreshTimerMinutesTextFromSession()
        persistCookState(targetTemperature: observedState.lastKnownTargetTemperature)
    }

    private static func persistedTimerState(for timerState: MiniRestoredTimerState) -> PersistedTimerState? {
        switch timerState {
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .stopped:
            return .stopped
        case .none:
            return nil
        }
    }

    private static func restoredTimerState(from timerState: PersistedTimerState?) -> MiniRestoredTimerState {
        switch timerState {
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .paused(let seconds):
            return .staged(seconds: seconds)
        case .stopped:
            return .stopped
        case nil:
            return .none
        }
    }

    private func recordApp(_ message: String, details: [String: String] = [:]) {
        diagnostics.record(.app, message, details: details)
    }

    private func activeSession() throws -> any AnovaCookerSession {
        guard let session else {
            throw MiniBLEClientError.disconnected("No active connection")
        }

        return session
    }
}

import Foundation

enum ScanTrigger {
    case automatic
    case manual
}

struct ScanButtonState {
    private(set) var manualScanFoundNoDevices = false

    mutating func recordCompletedScan(trigger: ScanTrigger, foundDevices: Bool) {
        guard trigger == .manual else {
            return
        }

        manualScanFoundNoDevices = !foundDevices
    }

    func title(isScanning: Bool) -> String {
        if isScanning {
            return "Scanning…"
        }

        return manualScanFoundNoDevices ? "Rescan" : "Scan"
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let aliasStorageKey = "deviceAliases"
    private static let cookStateStorageKey = "deviceCookState"
    private static let debugEnabledStorageKey = "debugEnabled"
    private static let menuBarShowsCurrentTempStorageKey = "menuBarShowsCurrentTemp"
    private static let menuBarShowsTimerStorageKey = "menuBarShowsTimer"

    private struct PersistedCookState: Codable, Equatable {
        var targetTemperature: Double?
        var timerState: PersistedTimerState?
        var lastCompletedAt: Date?
    }

    private enum PersistedTimerState: Codable, Equatable {
        case staged(seconds: Int)
        case paused(seconds: Int)
        case stopped
    }

    private struct PendingConfirmation {
        let expectation: CookerStateExpectation
        let successMessage: String
        let expiresAt: Date
        let preservedTimerSeconds: Int?
    }

    struct PresentedError: Identifiable {
        enum Kind {
            case bluetooth
            case response
            case state
        }

        let id = UUID()
        let title: String
        let message: String
        let kind: Kind

        init(title: String, message: String, kind: Kind) {
            self.title = title
            self.message = message
            self.kind = kind
        }

        init(error: Error) {
            message = error.localizedDescription

            switch error {
            case MiniBLEClientError.bluetoothUnavailable,
                 MiniBLEClientError.noSelection,
                 MiniBLEClientError.deviceNotFound,
                 MiniBLEClientError.disconnected,
                 MiniBLEClientError.operationAlreadyInFlight:
                title = "Bluetooth Error"
                kind = .bluetooth
            case MiniBLEClientError.invalidPayload,
                 MiniBLEClientError.missingCharacteristic:
                title = "Cooker Response Error"
                kind = .response
            case MiniBLEClientError.lowWater,
                 MiniBLEClientError.stateUnconfirmed:
                title = "Cooker State Error"
                kind = .state
            default:
                title = "Cooker Error"
                kind = .response
            }
        }

        static func connectionLost(reason: String) -> PresentedError {
            PresentedError(
                title: "Connection Lost",
                message: "The cooker disconnected: \(reason) Select Connect to reconnect.",
                kind: .bluetooth
            )
        }
    }

    @Published private(set) var devices: [AnovaDiscoveredDevice] = []
    @Published var selectedDeviceID: UUID?
    @Published private(set) var connectedDevice: AnovaDiscoveredDevice?
    @Published private var observedState = MiniObservedDeviceState()
    @Published private var sessionState = MiniCookSessionState()
    @Published private(set) var statusMessage = "Disconnected."
    @Published private(set) var isBusy = false
    @Published private(set) var isScanning = false
    @Published private var scanButtonState = ScanButtonState()
    @Published private(set) var bleTraceText = MiniDiagnosticsStore.emptyText
    @Published var isDebugEnabled: Bool
    @Published var menuBarShowsCurrentTemp: Bool
    @Published var menuBarShowsTimer: Bool
    @Published var targetTemperatureText = "60.0"
    @Published var timerMinutesText = "0"
    @Published var selectedUnit: MiniTemperatureUnit = .celsius
    @Published var aliasText = ""
    @Published var presentedError: PresentedError?

    private let diagnostics: MiniDiagnosticsStore
    private let coordinator: AnovaBLECoordinator
    private let scanForDevices: @MainActor (TimeInterval) async throws -> [AnovaDiscoveredDevice]
    private let defaults: UserDefaults
    private let operationGate = CookerOperationGate()
    private var didScanOnLaunch = false
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var operationInFlight = false
    private var isUnitChangeInFlight = false
    private var pendingConfirmation: PendingConfirmation?
    private var handledUnexpectedDisconnect = false
    private var deviceAliases: [String: String]
    private var deviceCookState: [String: PersistedCookState]
    private var session: (any AnovaCookerSession)?
    @Published private var timerNow = Date()

    init(
        scanForDevices: (@MainActor (TimeInterval) async throws -> [AnovaDiscoveredDevice])? = nil,
        defaults: UserDefaults = .standard,
        diagnostics: MiniDiagnosticsStore? = nil
    ) {
        let diagnostics = diagnostics ?? MiniDiagnosticsStore()
        let coordinator = AnovaBLECoordinator(diagnostics: diagnostics)
        let debugEnabled = defaults.object(forKey: Self.debugEnabledStorageKey) as? Bool ?? false

        self.diagnostics = diagnostics
        self.coordinator = coordinator
        self.defaults = defaults
        self.scanForDevices = scanForDevices ?? { timeout in
            try await coordinator.scan(timeout: timeout)
        }
        self.deviceAliases = defaults.dictionary(forKey: Self.aliasStorageKey) as? [String: String] ?? [:]
        self.isDebugEnabled = debugEnabled
        self.menuBarShowsCurrentTemp = defaults.object(forKey: Self.menuBarShowsCurrentTempStorageKey) as? Bool ?? false
        self.menuBarShowsTimer = defaults.object(forKey: Self.menuBarShowsTimerStorageKey) as? Bool ?? false
        if let data = defaults.data(forKey: Self.cookStateStorageKey),
           let decoded = try? JSONDecoder().decode([String: PersistedCookState].self, from: data) {
            self.deviceCookState = decoded
        } else {
            self.deviceCookState = [:]
        }
        diagnostics.setVerboseLoggingEnabled(debugEnabled)
        self.bleTraceText = diagnostics.renderedText
        diagnostics.onChange = { [weak self] text in
            self?.bleTraceText = text
        }
        coordinator.onUnexpectedDisconnect = { [weak self] reason in
            self?.handleUnexpectedDisconnect(reason)
        }
        recordApp(
            "appLaunched",
            details: [
                "session": UUID().uuidString,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            ]
        )
    }

    var menuBarIconName: String {
        connectedDevice == nil ? "thermometer.medium.slash" : "thermometer.medium"
    }

    var scanButtonTitle: String {
        scanButtonState.title(isScanning: isScanning)
    }

    var diagnosticsLogURL: URL? {
        diagnostics.logFileURL
    }

    var menuBarTitle: String {
        var segments: [String] = []

        if menuBarShowsCurrentTemp, let currentText = menuBarCurrentTemperatureText {
            segments.append(currentText)
        }

        if menuBarShowsTimer, let timerText = menuBarTimerText {
            segments.append(timerText)
        }

        return segments.joined(separator: " · ")
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

    var menuBarCurrentTemperatureText: String? {
        let unit = selectedUnit
        guard let value = observedState.currentDisplayTemperature else {
            return nil
        }

        let displayValue = unit == .fahrenheit
            ? Self.convertTemperature(value, from: .celsius, to: .fahrenheit)
            : value

        return "\(MiniFormat.temperature(displayValue))\(unit.symbol)"
    }

    var menuBarTimerText: String? {
        guard connectedDevice != nil else {
            return nil
        }

        let rawText = timerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty, rawText != "Unavailable" else {
            return nil
        }

        if rawText.hasPrefix("Completed at") {
            return "Done"
        }

        if rawText.contains("waiting to reach temperature") {
            return nil
        }

        return rawText
    }

    var menuBarThermalDirectionSymbolName: String? {
        guard menuBarShowsTimer else {
            return nil
        }

        let rawText = timerDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawText.contains("waiting to reach temperature"),
              let current = observedState.currentDisplayTemperature,
              let target = observedState.targetDisplayTemperature
        else {
            return nil
        }

        if target > current + 0.05 {
            return "arrow.up"
        }

        if target < current - 0.05 {
            return "arrow.down"
        }

        return nil
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
        if let pendingConfirmation,
           case .stopped = pendingConfirmation.expectation {
            return false
        }

        return sessionState.enablesStopAction || observedState.snapshot?.isCooking == true
    }

    func setDebugEnabled(_ isEnabled: Bool) {
        guard isDebugEnabled != isEnabled else {
            return
        }

        isDebugEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.debugEnabledStorageKey)
        diagnostics.setVerboseLoggingEnabled(isEnabled)
        recordApp("debugModeChanged enabled=\(isEnabled)")
    }

    func setMenuBarShowsCurrentTemp(_ isEnabled: Bool) {
        guard menuBarShowsCurrentTemp != isEnabled else {
            return
        }

        menuBarShowsCurrentTemp = isEnabled
        defaults.set(isEnabled, forKey: Self.menuBarShowsCurrentTempStorageKey)
        recordApp("menuBarShowsCurrentTempChanged enabled=\(isEnabled)")
    }

    func setMenuBarShowsTimer(_ isEnabled: Bool) {
        guard menuBarShowsTimer != isEnabled else {
            return
        }

        menuBarShowsTimer = isEnabled
        defaults.set(isEnabled, forKey: Self.menuBarShowsTimerStorageKey)
        recordApp("menuBarShowsTimerChanged enabled=\(isEnabled)")
    }

    func scanOnLaunchIfNeeded() async {
        guard !didScanOnLaunch else {
            return
        }

        didScanOnLaunch = true
        await scan(trigger: .automatic)
    }

    func scan() async {
        await scan(trigger: .manual)
    }

    private func scan(trigger: ScanTrigger) async {
        recordApp(trigger == .automatic ? "automaticScanRequested" : "manualScanRequested")
        guard !isScanning else {
            return
        }

        isScanning = true
        presentedError = nil

        defer {
            isScanning = false
        }

        do {
            let found = try await scanForDevices(5)
            devices = found
            scanButtonState.recordCompletedScan(trigger: trigger, foundDevices: !found.isEmpty)
            recordApp(
                "scanCompleted",
                details: [
                    "count": String(found.count),
                    "trigger": trigger == .automatic ? "automatic" : "manual",
                ]
            )

            if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = found.first?.id
            }

            syncAliasDraft()

            if found.isEmpty {
                statusMessage = "No supported Anova cookers found."
            } else {
                statusMessage = "Found \(found.count) nearby cooker(s)."
            }
        } catch is CancellationError {
            recordApp("scanCancelled")
        } catch {
            present(error)
        }
    }

    func selectDevice(_ id: UUID?) {
        selectedDeviceID = id
        syncAliasDraft()
    }

    func connectSelectedDevice() async {
        diagnostics.clearInMemory()
        recordApp("connectRequested")
        handledUnexpectedDisconnect = false
        let connected = await perform("Connecting…") { [self] in
            guard let selectedDeviceID = self.selectedDeviceID else {
                throw MiniBLEClientError.noSelection
            }

            let session = try await self.coordinator.connect(to: selectedDeviceID)
            let device = session.device
            self.session = session
            self.recordApp("connected", details: ["family": device.family.rawValue])
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

        if !connected, session != nil {
            session?.disconnect()
            coordinator.disconnect()
            clearConnectionState(status: "Connection failed.")
        }
    }

    func disconnect() async {
        recordApp("disconnectRequested")
        handledUnexpectedDisconnect = false
        session?.disconnect()
        coordinator.disconnect()
        clearConnectionState(status: "Disconnected.")
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
        var commandSent = false

        let completed = await perform("Updating temperature unit…") { [self] in
            self.beginCommand()
            self.recordApp("setUnit", details: ["unit": unit.rawValue])
            try await self.activeSession().setUnit(unit)
            commandSent = true
            self.convertVisibleTemperatures(from: previousUnit, to: unit)
            self.selectedUnit = unit
            let successMessage = "Temperature unit updated to \(unit.rawValue)."
            let confirmed: Bool
            if let timerSeconds = self.sessionState.activeCookTimerSeconds {
                let targetTemperature: Double
                if let lastKnownTargetTemperature = self.observedState.lastKnownTargetTemperature {
                    targetTemperature = lastKnownTargetTemperature
                } else if let snapshotTarget = self.observedState.snapshot?.targetTemperatureValue {
                    targetTemperature = snapshotTarget
                } else {
                    targetTemperature = try self.parseTargetTemperature()
                }
                confirmed = try await self.syncDeviceState(
                    after: .running(
                        targetTemperature: targetTemperature,
                        timerSeconds: timerSeconds,
                        temperatureUnit: unit,
                        requireTimerRunningSignal: true
                    ),
                    preservingTimerState: true,
                    successMessage: successMessage
                )
            } else {
                confirmed = try await self.syncDeviceState(
                    after: .temperatureUnit(unit),
                    preservingTimerState: true,
                    successMessage: successMessage
                )
            }
            self.statusMessage = confirmed ? successMessage : "Temperature unit command sent. Waiting for the cooker."
        }

        if !completed, !commandSent {
            selectedUnit = previousUnit
        }
        isUnitChangeInFlight = false
    }

    func applySetTemperature() async {
        await perform("Setting target temperature…") { [self] in
            self.beginCommand()
            let target = try self.parseTargetTemperature()
            self.recordApp(
                "setTemperature",
                details: ["target": "\(MiniFormat.temperature(target))\(self.selectedUnit.symbol)"]
            )
            let session = try self.activeSession()
            try await session.setTemperature(target)
            self.observedState.setTargetTemperature(target)
            self.persistCookState(targetTemperature: target)
            let successMessage = "Target temperature set to \(MiniFormat.temperature(target))\(self.selectedUnit.symbol)."
            if let timerSeconds = self.sessionState.activeCookTimerSeconds {
                let confirmed = try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timerSeconds, requireTimerRunningSignal: true),
                    preservingTimerState: true,
                    successMessage: successMessage
                )
                self.statusMessage = confirmed ? successMessage : "Temperature command sent. Waiting for the cooker."
                return
            }

            guard session.device.family.supportsIdleTargetTemperatureReadback else {
                self.statusMessage = "Temperature command sent."
                return
            }

            let confirmed = try await self.syncDeviceState(
                after: .targetTemperature(target),
                successMessage: successMessage
            )
            self.statusMessage = confirmed ? successMessage : "Temperature command sent. Waiting for the cooker."
        }
    }

    func applyTimer() async {
        await perform("Updating timer…") { [self] in
            self.beginCommand()
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
                let confirmed = try await self.syncDeviceState(
                    after: .running(targetTemperature: target, timerSeconds: timer, requireTimerRunningSignal: true),
                    preservingTimerState: true,
                    successMessage: "Timer updated."
                )
                self.statusMessage = confirmed ? "Timer updated." : "Timer command sent. Waiting for the cooker."
            } else {
                _ = self.sessionState.apply(.stageTimer(seconds: timer))
                self.statusMessage = "Timer staged for the next cook."
            }

            self.persistCookState(targetTemperature: self.observedState.snapshot?.targetTemperatureValue ?? self.observedState.lastKnownTargetTemperature)
        }
    }

    func startCook() async {
        await perform("Starting cook…") { [self] in
            self.beginCommand()
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
            let confirmed = try await self.syncDeviceState(
                after: .running(targetTemperature: setpoint, timerSeconds: timer, requireTimerRunningSignal: true),
                preservingTimerState: true,
                successMessage: "Cook started."
            )
            self.statusMessage = confirmed ? "Cook started." : "Start command sent. Waiting for the cooker."
        }
    }

    func stopCook() async {
        await perform("Stopping cook…") { [self] in
            self.beginCommand()
            let preservedTimerSeconds = configuredTimerSeconds()
            self.recordApp(
                "stopCook",
                details: ["preservedTimerSeconds": preservedTimerSeconds.map(String.init) ?? "nil"]
            )
            let confirmed = try await self.executeStopCook(preservedTimerSeconds: preservedTimerSeconds, origin: .manual)
            self.statusMessage = confirmed ? "Cook stopped." : "Stop command sent. Waiting for the cooker."
        }
    }

    func label(for device: AnovaDiscoveredDevice) -> String {
        alias(for: device) ?? device.displayName
    }

    @discardableResult
    private func perform(
        _ busyMessage: String,
        userInitiated: Bool = true,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        guard !userInitiated || !operationInFlight else {
            return false
        }

        if userInitiated {
            operationInFlight = true
            isBusy = true
        }
        presentedError = nil
        let previousStatus = statusMessage
        statusMessage = busyMessage

        defer {
            if userInitiated {
                operationInFlight = false
                isBusy = false
            }
        }

        do {
            try await operationGate.run(operation)
            return true
        } catch {
            if handledUnexpectedDisconnect {
                return false
            }

            diagnostics.record(.error, "operation", details: ["reason": error.localizedDescription])
            if let clientError = error as? MiniBLEClientError,
               case .lowWater = clientError {
                statusMessage = "The cooker needs more water."
            } else {
                statusMessage = previousStatus
            }
            present(error)
            return false
        }
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

        let now = Date()
        let pending = pendingConfirmation
        let confirmationMatched = pending?.expectation.matches(latestSnapshot) == true
        let confirmationExpired = pending.map { now >= $0.expiresAt } == true
        let shouldPreservePendingState = pending != nil && (!confirmationExpired || confirmationMatched)
        let effect = sessionState.apply(
            .snapshotObserved(
                latestSnapshot,
                preservingPhase: preservingTimerState || shouldPreservePendingState,
                now: now
            )
        )

        if let pending,
           latestSnapshot.needsWater,
           case .running = pending.expectation {
            pendingConfirmation = nil
            _ = sessionState.apply(.snapshotObserved(latestSnapshot, preservingPhase: false, now: now))
            statusMessage = "The cooker needs more water."
            diagnostics.record(.error, "lowWater")
            present(MiniBLEClientError.lowWater)
        } else if let pending, confirmationMatched {
            completePendingConfirmation(pending)
        } else if let pending, confirmationExpired {
            pendingConfirmation = nil
            statusMessage = "The cooker did not confirm the command. Check the cooker."
            diagnostics.record(.error, "commandUnconfirmed", details: ["expected": pending.expectation.summary])
            present(MiniBLEClientError.stateUnconfirmed("\(pending.expectation.summary). Check the cooker before you try again."))
        }

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
                        try await self.operationGate.run {
                            try await self.refreshSnapshot()
                        }
                    } catch {
                        if !self.handledUnexpectedDisconnect {
                            self.present(error)
                        }
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
        presentedError = PresentedError(error: error)
    }

    func dismissError() {
        presentedError = nil
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

        let nextState = PersistedCookState(
            targetTemperature: targetTemperature,
            timerState: Self.persistedTimerState(for: sessionState.persistedTimerState),
            lastCompletedAt: sessionState.lastCompletedAt
        )
        guard deviceCookState[device.identifier] != nextState else {
            return
        }

        deviceCookState[device.identifier] = nextState

        if let data = try? JSONEncoder().encode(deviceCookState) {
            defaults.set(data, forKey: Self.cookStateStorageKey)
        }

        diagnostics.record(
            .persistence,
            "persistCookState",
            details: [
                "device": device.displayName,
                "target": targetTemperature.map(MiniFormat.temperature) ?? "nil",
                "timerState": String(describing: nextState.timerState),
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

    private func syncDeviceState(
        after expectedState: CookerStateExpectation,
        preservingTimerState: Bool = false,
        successMessage: String,
        preservedTimerSeconds: Int? = nil
    ) async throws -> Bool {
        let session = try activeSession()
        guard session.supportsStrictStateConfirmation else {
            let snapshot = try await session.snapshot()
            applySnapshot(snapshot, preservingTimerState: preservingTimerState)
            return true
        }

        let maxAttempts: Int

        switch expectedState {
        case .stopped:
            maxAttempts = 6
        case .temperatureUnit, .targetTemperature, .running:
            maxAttempts = 4
        }

        var lastSnapshot: CookerSnapshot?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1))
            }

            let polledSnapshot = try await activeSession().snapshot()
            lastSnapshot = polledSnapshot
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

            if polledSnapshot.needsWater, case .running = expectedState {
                applySnapshot(polledSnapshot)
                throw MiniBLEClientError.lowWater
            }

            if expectedState.matches(polledSnapshot) {
                applySnapshot(polledSnapshot, preservingTimerState: preservingTimerState)
                return true
            }
        }

        pendingConfirmation = PendingConfirmation(
            expectation: expectedState,
            successMessage: successMessage,
            expiresAt: Date().addingTimeInterval(30),
            preservedTimerSeconds: preservedTimerSeconds
        )
        recordApp("commandPending", details: ["expected": expectedState.summary])
        if let lastSnapshot {
            applySnapshot(lastSnapshot, preservingTimerState: true)
        }
        return false
    }

    private enum StopOrigin: Equatable {
        case manual
        case automaticAfterCompletion
    }

    private func beginCommand() {
        pendingConfirmation = nil
    }

    private func completePendingConfirmation(_ pending: PendingConfirmation) {
        pendingConfirmation = nil
        if case .stopped = pending.expectation {
            _ = sessionState.apply(.stopConfirmed(preservedTimerSeconds: pending.preservedTimerSeconds))
        }
        statusMessage = pending.successMessage
        recordApp("commandConfirmed", details: ["expected": pending.expectation.summary])
    }

    private func handleUnexpectedDisconnect(_ reason: String) {
        guard connectedDevice != nil else {
            return
        }

        handledUnexpectedDisconnect = true
        recordApp("connectionLost", details: ["reason": reason])
        clearConnectionState(status: "Connection lost. Select Connect to reconnect.")
        presentedError = .connectionLost(reason: reason)
    }

    private func clearConnectionState(status: String) {
        stopPolling()
        stopClock()
        autoStopTask?.cancel()
        autoStopTask = nil
        pendingConfirmation = nil
        session = nil
        connectedDevice = nil
        observedState.clearConnectionState()
        _ = sessionState.apply(.disconnect)
        restoreCookState(for: selectedOrConnectedDevice())
        syncAliasDraft()
        statusMessage = status
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

            await self.perform("Stopping cook after timer completion…", userInitiated: false) { [self] in
                self.beginCommand()
                self.recordApp("autoStopAfterTimerCompletion")
                let confirmed = try await self.executeStopCook(
                    preservedTimerSeconds: nil,
                    origin: .automaticAfterCompletion
                )
                self.statusMessage = confirmed
                    ? "Timer completed. Cook stopped."
                    : "Timer completed. Waiting for the cooker to stop."
            }

            self.autoStopTask = nil
        }
    }

    private func executeStopCook(preservedTimerSeconds: Int?, origin: StopOrigin) async throws -> Bool {
        let session = try activeSession()
        try await session.stopCook()
        try? await session.clearAlarmIfSupported()

        switch origin {
        case .manual:
            _ = sessionState.apply(.stopRequested(preservedTimerSeconds: preservedTimerSeconds))
        case .automaticAfterCompletion:
            _ = sessionState.apply(.autoStopRequested)
        }
        refreshTimerMinutesTextFromSession()
        persistCookState(targetTemperature: observedState.lastKnownTargetTemperature)
        let successMessage = origin == .manual ? "Cook stopped." : "Timer completed. Cook stopped."
        let confirmed = try await syncDeviceState(
            after: .stopped,
            successMessage: successMessage,
            preservedTimerSeconds: preservedTimerSeconds
        )
        if confirmed {
            _ = sessionState.apply(.stopConfirmed(preservedTimerSeconds: preservedTimerSeconds))
            refreshTimerMinutesTextFromSession()
            persistCookState(targetTemperature: observedState.lastKnownTargetTemperature)
        }
        return confirmed
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

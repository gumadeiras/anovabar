import Foundation

@MainActor
final class AppModel: ObservableObject {
    private static let aliasStorageKey = "deviceAliases"
    private static let cookStateStorageKey = "deviceCookState"

    private struct PersistedCookState: Codable {
        var targetTemperature: Double?
        var timerSeconds: Int?
        var startedAt: Date?
        var paused: Bool?
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

    let pairingHint = "If macOS prompts for Bluetooth access or pairing, allow it and then scan again."

    private let client = MiniBLEClient()
    private let defaults = UserDefaults.standard
    private var didLoad = false
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var operationInFlight = false
    private var isUnitChangeInFlight = false
    private var lastKnownTargetTemperature: Double?
    private var lastKnownTimerSeconds: Int?
    private var lastKnownTimerStartedAt: Date?
    private var isCookPaused = false
    private var isCookStopped = false
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

    var targetDisplayText: String {
        let unit = snapshot?.temperatureUnit ?? selectedUnit
        let value = lastKnownTargetTemperature ?? snapshot?.targetTemperatureValue

        guard let value else {
            return "Unavailable"
        }

        return "\(MiniFormat.temperature(value))\(unit.symbol)"
    }

    var timerDisplayText: String {
        if isCookStopped {
            return MiniFormat.duration(seconds: 0)
        }

        if isCookPaused, let seconds = lastKnownTimerSeconds {
            return MiniFormat.duration(seconds: max(seconds, 0))
        }

        if let seconds = snapshot?.timerSecondsValue {
            return MiniFormat.duration(seconds: max(seconds, 0))
        }

        if let seconds = computedRemainingTimerSeconds() {
            return seconds == 0 ? "Complete" : MiniFormat.duration(seconds: seconds)
        }

        return snapshot?.timerDisplay ?? "Unavailable"
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

    var connectedDeviceSubtitle: String {
        guard let device = connectedDevice else {
            return ""
        }

        if let alias = alias(for: device), alias != device.name {
            return "\(device.name) • \(device.identifier)"
        }

        return device.identifier
    }

    var pauseButtonTitle: String {
        isCookPaused ? "Resume" : "Pause"
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

            try await self.client.setClockToNow()
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

    func syncClock() async {
        await perform("Synchronizing clock…") { [self] in
            try await self.client.setClockToNow()
            self.statusMessage = "Clock synchronized to UTC."
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
            try await self.refreshSnapshot()
            self.statusMessage = "Temperature unit updated to \(unit.rawValue)."
        }

        isUnitChangeInFlight = false
    }

    func applySetTemperature() async {
        await perform("Setting target temperature…") { [self] in
            let target = try self.parseTargetTemperature()
            try await self.client.setTemperature(target)
            self.lastKnownTargetTemperature = target
            self.persistCookState(
                targetTemperature: target,
                timerSeconds: self.lastKnownTimerSeconds,
                startedAt: self.lastKnownTimerStartedAt,
                paused: self.isCookPaused
            )
            try await self.refreshSnapshot()
            self.statusMessage = "Target temperature set to \(MiniFormat.temperature(target))\(self.selectedUnit.symbol)."
        }
    }

    func applyTimer() async {
        await perform("Updating timer…") { [self] in
            let timer = try self.parseTimerSeconds()
            self.lastKnownTimerSeconds = timer
            self.timerMinutesText = Self.minutesString(fromSeconds: timer)

            if self.snapshot?.isCooking == true && !self.isCookPaused {
                let target: Double
                if let snapshotTarget = self.snapshot?.targetTemperatureValue {
                    target = snapshotTarget
                } else if let lastKnownTarget = self.lastKnownTargetTemperature {
                    target = lastKnownTarget
                } else {
                    target = try self.parseTargetTemperature()
                }
                try await self.client.startCook(setpoint: target, timerSeconds: timer)
                self.lastKnownTimerStartedAt = Date()
                self.statusMessage = "Timer updated."
            } else {
                self.statusMessage = "Timer staged for the next cook."
            }

            self.persistCookState(
                targetTemperature: self.snapshot?.targetTemperatureValue ?? self.lastKnownTargetTemperature,
                timerSeconds: timer,
                startedAt: self.lastKnownTimerStartedAt,
                paused: self.isCookPaused
            )
        }
    }

    func startCook() async {
        await perform("Starting cook…") { [self] in
            let setpoint = try self.parseTargetTemperature()
            let timer = try self.parseTimerSeconds()
            try await self.client.startCook(setpoint: setpoint, timerSeconds: timer)
            self.lastKnownTargetTemperature = setpoint
            self.lastKnownTimerSeconds = timer
            self.lastKnownTimerStartedAt = Date()
            self.isCookPaused = false
            self.isCookStopped = false
            self.persistCookState(targetTemperature: setpoint, timerSeconds: timer, startedAt: self.lastKnownTimerStartedAt, paused: false)
            try await self.refreshSnapshot()
            self.statusMessage = "Start command sent."
        }
    }

    func stopCook() async {
        await perform("Stopping cook…") { [self] in
            try await self.client.stopCook()
            self.lastKnownTimerSeconds = 0
            self.timerMinutesText = "0"
            self.lastKnownTimerStartedAt = nil
            self.isCookPaused = false
            self.isCookStopped = true
            self.persistCookState(targetTemperature: self.lastKnownTargetTemperature, timerSeconds: 0, startedAt: nil, paused: false)
            try await self.refreshSnapshot()
            self.statusMessage = "Stop command sent."
        }
    }

    func togglePauseResume() async {
        if isCookPaused {
            await resumeCook()
        } else {
            await pauseCook()
        }
    }

    func label(for device: MiniDiscoveredDevice) -> String {
        alias(for: device) ?? device.displayName
    }

    private func perform(_ busyMessage: String, operation: @escaping () async throws -> Void) async {
        guard !operationInFlight else {
            return
        }

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
            statusMessage = previousStatus
            present(error)
        }
    }

    private func refreshSnapshot() async throws {
        let latestSnapshot = try await client.snapshot()
        snapshot = latestSnapshot

        if let unit = latestSnapshot.temperatureUnit, !isUnitChangeInFlight {
            selectedUnit = unit
        }

        if let target = latestSnapshot.targetTemperatureValue, !isUnitChangeInFlight {
            lastKnownTargetTemperature = target
            targetTemperatureText = MiniFormat.temperature(target)
        }

        if !isCookPaused && !isCookStopped, let timer = latestSnapshot.timerSecondsValue {
            lastKnownTimerSeconds = timer
            timerMinutesText = Self.minutesString(fromSeconds: timer)
        }

        if !isCookPaused && !isCookStopped, let timerInitial = latestSnapshot.timerInitialSeconds {
            lastKnownTimerSeconds = timerInitial
            timerMinutesText = Self.minutesString(fromSeconds: timerInitial)
        }

        if !isCookPaused && !isCookStopped, let startedAt = latestSnapshot.timerStartedAt {
            lastKnownTimerStartedAt = startedAt
        }

        if latestSnapshot.isCooking, lastKnownTimerSeconds != nil, lastKnownTimerStartedAt == nil {
            lastKnownTimerStartedAt = Date()
            isCookPaused = false
            isCookStopped = false
        }

        if !latestSnapshot.isCooking, latestSnapshot.timerSecondsValue == nil {
            if !isCookPaused {
                lastKnownTimerStartedAt = nil
            }
        }

        persistCookState(
            targetTemperature: latestSnapshot.targetTemperatureValue ?? lastKnownTargetTemperature,
            timerSeconds: latestSnapshot.timerSecondsValue ?? lastKnownTimerSeconds,
            startedAt: latestSnapshot.isCooking ? lastKnownTimerStartedAt : nil,
            paused: isCookPaused
        )
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
            lastKnownTimerSeconds = nil
            lastKnownTimerStartedAt = nil
            return
        }

        let persisted = deviceCookState[device.identifier]
        lastKnownTargetTemperature = persisted?.targetTemperature
        lastKnownTimerSeconds = persisted?.timerSeconds
        lastKnownTimerStartedAt = persisted?.startedAt
        isCookPaused = persisted?.paused ?? false
        isCookStopped = false

        if let target = persisted?.targetTemperature {
            targetTemperatureText = MiniFormat.temperature(target)
        }

        if let timer = persisted?.timerSeconds {
            timerMinutesText = Self.minutesString(fromSeconds: timer)
        }
    }

    private func persistCookState(targetTemperature: Double?, timerSeconds: Int?, startedAt: Date?, paused: Bool) {
        guard let device = connectedDevice ?? selectedOrConnectedDevice() else {
            return
        }

        deviceCookState[device.identifier] = PersistedCookState(
            targetTemperature: targetTemperature,
            timerSeconds: timerSeconds,
            startedAt: startedAt,
            paused: paused
        )

        if let data = try? JSONEncoder().encode(deviceCookState) {
            defaults.set(data, forKey: Self.cookStateStorageKey)
        }
    }

    private func computedRemainingTimerSeconds() -> Int? {
        guard let baseSeconds = lastKnownTimerSeconds, baseSeconds > 0 else {
            return nil
        }

        guard !isCookPaused && !isCookStopped else {
            return nil
        }

        guard (snapshot?.isCooking ?? false) || lastKnownTimerStartedAt != nil else {
            return nil
        }

        guard let startedAt = lastKnownTimerStartedAt else {
            return baseSeconds
        }

        let elapsed = max(0, Int(timerNow.timeIntervalSince(startedAt)))
        return max(0, baseSeconds - elapsed)
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

    private func pauseCook() async {
        await perform("Pausing cook…") { [self] in
            let remaining = self.snapshot?.timerSecondsValue ?? self.computedRemainingTimerSeconds() ?? self.lastKnownTimerSeconds ?? 0
            try await self.client.stopCook()
            self.lastKnownTimerSeconds = remaining
            self.timerMinutesText = Self.minutesString(fromSeconds: remaining)
            self.lastKnownTimerStartedAt = nil
            self.isCookPaused = true
            self.isCookStopped = false
            self.persistCookState(
                targetTemperature: self.snapshot?.targetTemperatureValue ?? self.lastKnownTargetTemperature,
                timerSeconds: remaining,
                startedAt: nil,
                paused: true
            )
            self.statusMessage = "Cook paused."
        }
    }

    private func resumeCook() async {
        await perform("Resuming cook…") { [self] in
            let remaining: Int
            if let lastKnownTimerSeconds = self.lastKnownTimerSeconds {
                remaining = lastKnownTimerSeconds
            } else {
                remaining = try self.parseTimerSeconds()
            }
            let target: Double
            if let snapshotTarget = self.snapshot?.targetTemperatureValue {
                target = snapshotTarget
            } else if let lastKnownTarget = self.lastKnownTargetTemperature {
                target = lastKnownTarget
            } else {
                target = try self.parseTargetTemperature()
            }

            try await self.client.startCook(setpoint: target, timerSeconds: remaining)
            self.lastKnownTargetTemperature = target
            self.lastKnownTimerStartedAt = Date()
            self.isCookPaused = false
            self.isCookStopped = false
            self.persistCookState(
                targetTemperature: target,
                timerSeconds: remaining,
                startedAt: self.lastKnownTimerStartedAt,
                paused: false
            )
            self.statusMessage = "Cook resumed."
        }
    }
}

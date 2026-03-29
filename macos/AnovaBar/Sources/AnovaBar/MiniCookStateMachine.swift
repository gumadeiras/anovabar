import Foundation

enum MiniRestoredTimerState: Equatable {
    case none
    case staged(seconds: Int)
    case stopped
}

enum MiniCookPhase: Equatable {
    case none
    case staged(seconds: Int)
    case waitingForTemperature(initialSeconds: Int)
    case running(initialSeconds: Int, startedAt: Date)
    case completed(initialSeconds: Int)
    case stopped
}

enum MiniCookCommandState: String, Equatable {
    case idle
    case startRequested
    case timerUpdateRequested
    case stopRequested
    case autoStopRequested
}

enum MiniCookSessionEffect: Equatable {
    case autoStopAfterTimerCompletion
}

enum MiniCookSessionEvent {
    case restore(timerState: MiniRestoredTimerState)
    case stageTimer(seconds: Int)
    case startRequested(timerSeconds: Int, now: Date)
    case timerUpdatedWhileCooking(timerSeconds: Int, now: Date)
    case stopRequested(preservedTimerSeconds: Int?)
    case autoStopRequested
    case stopConfirmed(preservedTimerSeconds: Int?)
    case snapshotObserved(MiniSnapshot, preservingPhase: Bool, now: Date)
    case disconnect
}

struct MiniObservedDeviceState {
    var snapshot: MiniSnapshot?
    var systemInfo: JSONDictionary?
    var lastKnownCurrentTemperature: Double?
    var lastKnownTargetTemperature: Double?

    var currentDisplayTemperature: Double? {
        lastKnownCurrentTemperature ?? snapshot?.currentTemperatureValue
    }

    var targetDisplayTemperature: Double? {
        lastKnownTargetTemperature ?? snapshot?.targetTemperatureValue
    }

    mutating func apply(snapshot: MiniSnapshot) {
        self.snapshot = snapshot

        if let current = snapshot.currentTemperatureValue {
            lastKnownCurrentTemperature = current
        }

        if let target = snapshot.targetTemperatureValue {
            lastKnownTargetTemperature = target
        }
    }

    mutating func restorePersistedTarget(_ targetTemperature: Double?) {
        lastKnownTargetTemperature = targetTemperature
    }

    mutating func setTargetTemperature(_ targetTemperature: Double) {
        lastKnownTargetTemperature = targetTemperature
    }

    mutating func clearConnectionState() {
        snapshot = nil
        systemInfo = nil
        lastKnownCurrentTemperature = nil
        lastKnownTargetTemperature = nil
    }
}

struct MiniCookSessionState: Equatable {
    var phase: MiniCookPhase = .none
    var commandState: MiniCookCommandState = .idle
    private(set) var completionAutoStopRequested = false

    var configuredTimerSeconds: Int? {
        switch phase {
        case .staged(let seconds), .waitingForTemperature(let seconds), .running(let seconds, _):
            return seconds
        case .completed, .none, .stopped:
            return nil
        }
    }

    var activeCookTimerSeconds: Int? {
        switch phase {
        case .waitingForTemperature(let seconds), .running(let seconds, _):
            return seconds
        case .completed, .none, .staged, .stopped:
            return nil
        }
    }

    var persistedTimerState: MiniRestoredTimerState {
        switch phase {
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .stopped:
            return .stopped
        case .none, .waitingForTemperature, .running, .completed:
            return .none
        }
    }

    var blocksStartAction: Bool {
        switch phase {
        case .running, .waitingForTemperature, .completed:
            return true
        case .none, .staged, .stopped:
            return false
        }
    }

    var enablesStopAction: Bool {
        switch phase {
        case .running, .waitingForTemperature, .completed:
            return true
        case .none, .staged, .stopped:
            return false
        }
    }

    func timerDisplayText(now: Date, fallback: String?) -> String {
        switch phase {
        case .none:
            return fallback ?? "Unavailable"
        case .staged(let seconds):
            return MiniFormat.duration(seconds: seconds)
        case .waitingForTemperature(let initialSeconds):
            guard initialSeconds > 0 else {
                return "∞"
            }
            return "\(MiniFormat.duration(seconds: initialSeconds)) (waiting to reach temperature)"
        case .running(let initialSeconds, let startedAt):
            guard initialSeconds > 0 else {
                return "∞"
            }
            let remaining = Self.remainingTimerSeconds(initialSeconds: initialSeconds, startedAt: startedAt, now: now)
            return remaining == 0 ? "Complete" : MiniFormat.duration(seconds: remaining)
        case .completed:
            return "Complete"
        case .stopped:
            return MiniFormat.duration(seconds: 0)
        }
    }

    mutating func apply(_ event: MiniCookSessionEvent) -> MiniCookSessionEffect? {
        switch event {
        case .restore(let timerState):
            commandState = .idle
            completionAutoStopRequested = false
            phase = Self.phase(from: timerState)
            return nil

        case .stageTimer(let seconds):
            commandState = .idle
            completionAutoStopRequested = false
            phase = seconds == 0 ? .stopped : .staged(seconds: seconds)
            return nil

        case .startRequested(let timerSeconds, let now):
            commandState = .startRequested
            completionAutoStopRequested = false
            phase = Self.pendingOrRunningPhase(for: timerSeconds, now: now)
            return nil

        case .timerUpdatedWhileCooking(let timerSeconds, let now):
            commandState = .timerUpdateRequested
            completionAutoStopRequested = false
            phase = Self.pendingOrRunningPhase(for: timerSeconds, now: now)
            return nil

        case .stopRequested(let preservedTimerSeconds):
            commandState = .stopRequested
            completionAutoStopRequested = false
            phase = Self.phaseAfterStopRequest(preservedTimerSeconds: preservedTimerSeconds)
            return nil

        case .autoStopRequested:
            commandState = .autoStopRequested
            completionAutoStopRequested = true
            phase = .stopped
            return nil

        case .stopConfirmed(let preservedTimerSeconds):
            commandState = .idle
            completionAutoStopRequested = false
            phase = Self.phaseAfterStopRequest(preservedTimerSeconds: preservedTimerSeconds)
            return nil

        case .snapshotObserved(let snapshot, let preservingPhase, let now):
            if !preservingPhase {
                phase = Self.phase(from: snapshot, existingPhase: phase, now: now)
            }

            if snapshot.isCooking, snapshot.timerHasCompleted {
                if !completionAutoStopRequested {
                    completionAutoStopRequested = true
                    return .autoStopAfterTimerCompletion
                }
            } else if !snapshot.isCooking {
                completionAutoStopRequested = false
                commandState = .idle
            }

            return nil

        case .disconnect:
            commandState = .idle
            completionAutoStopRequested = false
            phase = .none
            return nil
        }
    }

    private static func phase(from restored: MiniRestoredTimerState) -> MiniCookPhase {
        switch restored {
        case .none:
            return .none
        case .staged(let seconds):
            return .staged(seconds: seconds)
        case .stopped:
            return .stopped
        }
    }

    private static func pendingOrRunningPhase(for timerSeconds: Int, now: Date) -> MiniCookPhase {
        if timerSeconds == 0 {
            return .running(initialSeconds: 0, startedAt: now)
        }

        return .waitingForTemperature(initialSeconds: timerSeconds)
    }

    private static func phaseAfterStopRequest(preservedTimerSeconds: Int?) -> MiniCookPhase {
        if let preservedTimerSeconds, preservedTimerSeconds > 0 {
            return .staged(seconds: preservedTimerSeconds)
        }

        return .stopped
    }

    private static func phase(from snapshot: MiniSnapshot, existingPhase: MiniCookPhase, now: Date) -> MiniCookPhase {
        if snapshot.isCooking {
            guard let initialSeconds = snapshot.timerInitialSeconds ?? snapshot.timerSecondsValue else {
                return .none
            }

            if snapshot.timerHasCompleted {
                return .completed(initialSeconds: initialSeconds)
            }

            if initialSeconds == 0 {
                let startedAt = snapshot.timerStartedAt ?? preservedRunningStartedAt(from: existingPhase, initialSeconds: initialSeconds) ?? now
                return .running(initialSeconds: initialSeconds, startedAt: startedAt)
            }

            if let startedAt = snapshot.timerStartedAt {
                return .running(initialSeconds: initialSeconds, startedAt: startedAt)
            }

            if snapshot.timerHasRunningSignal {
                let startedAt = preservedRunningStartedAt(from: existingPhase, initialSeconds: initialSeconds) ?? now
                return .running(initialSeconds: initialSeconds, startedAt: startedAt)
            }

            return .waitingForTemperature(initialSeconds: initialSeconds)
        }

        if case .stopped = existingPhase {
            return .stopped
        }

        if let stagedSeconds = snapshot.timerSecondsValue, stagedSeconds > 0 {
            return .staged(seconds: stagedSeconds)
        }

        return .none
    }

    private static func preservedRunningStartedAt(from phase: MiniCookPhase, initialSeconds: Int) -> Date? {
        guard case let .running(currentInitialSeconds, startedAt) = phase,
              currentInitialSeconds == initialSeconds else {
            return nil
        }

        return startedAt
    }

    private static func remainingTimerSeconds(initialSeconds: Int, startedAt: Date, now: Date) -> Int {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return max(0, initialSeconds - elapsed)
    }
}

import Foundation
import Testing
@testable import AnovaBar

struct MiniCookStateMachineTests {
    @Test
    func finiteCookStartsInWaitingState() {
        var state = MiniCookSessionState()
        let now = Date(timeIntervalSince1970: 1_000)

        let effect = state.apply(.startRequested(timerSeconds: 60, now: now))

        #expect(effect == nil)
        #expect(state.phase == .waitingForTemperature(initialSeconds: 60))
        #expect(state.commandState == .startRequested)
        #expect(state.blocksStartAction)
    }

    @Test
    func snapshotWithStartedTimerTransitionsToRunning() {
        var state = MiniCookSessionState(phase: .waitingForTemperature(initialSeconds: 60))
        let now = Date(timeIntervalSince1970: 1_060)
        let startedAt = "2026-03-28T23:43:12Z"
        let snapshot = MiniSnapshot(
            state: [
                "mode": "cook",
                "setpoint": 54.5,
                "temperatureUnit": "C",
            ],
            currentTemperature: [
                "current": 54.5,
            ],
            timer: [
                "initial": 60,
                "mode": "running",
                "startedAtTimestamp": startedAt,
            ]
        )

        let effect = state.apply(.snapshotObserved(snapshot, preservingPhase: false, now: now))

        #expect(effect == nil)
        switch state.phase {
        case .running(let initialSeconds, let actualStartedAt):
            #expect(initialSeconds == 60)
            #expect(actualStartedAt == MiniDateParser.parse(startedAt))
        default:
            Issue.record("Expected running phase, got \(state.phase)")
        }
    }

    @Test
    func completedTimerEmitsSingleAutoStopEffect() {
        var state = MiniCookSessionState(phase: .running(initialSeconds: 60, startedAt: Date(timeIntervalSince1970: 1_000)))
        let now = Date(timeIntervalSince1970: 1_060)
        let snapshot = MiniSnapshot(
            state: [
                "mode": "cook",
                "setpoint": 54.5,
                "temperatureUnit": "C",
            ],
            currentTemperature: [
                "current": 54.5,
            ],
            timer: [
                "initial": 60,
                "mode": "completed",
            ]
        )

        let firstEffect = state.apply(.snapshotObserved(snapshot, preservingPhase: false, now: now))
        let secondEffect = state.apply(.snapshotObserved(snapshot, preservingPhase: false, now: now))

        #expect(firstEffect == .autoStopAfterTimerCompletion)
        #expect(secondEffect == nil)
        #expect(state.phase == .completed(initialSeconds: 60))
        #expect(state.completionAutoStopRequested)
    }

    @Test
    func stopConfirmationRestoresStagedTimerForManualStop() {
        var state = MiniCookSessionState(phase: .running(initialSeconds: 180, startedAt: Date(timeIntervalSince1970: 1_000)))

        _ = state.apply(.stopRequested(preservedTimerSeconds: 180))
        let effect = state.apply(.stopConfirmed(preservedTimerSeconds: 180))

        #expect(effect == nil)
        #expect(state.phase == .staged(seconds: 180))
        #expect(state.commandState == .idle)
        #expect(state.persistedTimerState == .staged(seconds: 180))
    }
}

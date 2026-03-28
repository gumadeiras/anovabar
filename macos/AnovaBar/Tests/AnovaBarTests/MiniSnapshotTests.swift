import Testing
@testable import AnovaBar

struct MiniSnapshotTests {
    @Test
    func matchesRunningCookWhenTimerPayloadOnlyShowsPositiveInitialSeconds() {
        let snapshot = MiniSnapshot(
            state: [
                "state": "running",
                "temperatureUnit": "C",
                "setpoint": 55.0,
            ],
            currentTemperature: [
                "current": 55.9,
            ],
            timer: [
                "initial": 5_340,
                "mode": "idle",
            ]
        )

        #expect(
            snapshot.matchesRunningCook(
                targetTemperature: 55.0,
                timerSeconds: 5_400,
                requireTimerRunningSignal: true
            )
        )
    }

    @Test
    func rejectsRunningCookWhenTimerExceedsRequestedDuration() {
        let snapshot = MiniSnapshot(
            state: [
                "state": "running",
                "temperatureUnit": "C",
                "setpoint": 55.0,
            ],
            currentTemperature: [
                "current": 55.9,
            ],
            timer: [
                "initial": 5_460,
                "mode": "idle",
            ]
        )

        #expect(
            !snapshot.matchesRunningCook(
                targetTemperature: 55.0,
                timerSeconds: 5_400,
                requireTimerRunningSignal: true
            )
        )
    }

    @Test
    func matchesInfiniteRunningCookWithoutTimerSideRunningSignal() {
        let snapshot = MiniSnapshot(
            state: [
                "mode": "cook",
                "temperatureUnit": "C",
                "setpoint": 53.3,
            ],
            currentTemperature: [
                "current": 53.4,
            ],
            timer: [
                "initial": 0,
                "mode": "idle",
            ]
        )

        #expect(
            snapshot.matchesRunningCook(
                targetTemperature: 53.3,
                timerSeconds: 0,
                requireTimerRunningSignal: true
            )
        )
    }
}

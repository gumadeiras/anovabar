import Testing
@testable import AnovaBar

struct OriginalBLEProtocolTests {
    @Test
    func detectsWifiModelFromCookerID() {
        #expect(OriginalCookerModel.detect(from: "anova f56-abc") == .wifi900W)
        #expect(OriginalCookerModel.detect(from: "anova classic") == .bluetooth800W)
    }

    @Test
    func buildsCookerSnapshotFromTextResponses() {
        let snapshot = OriginalSnapshot(
            statusResponse: "running",
            unitResponse: "C",
            currentTemperatureResponse: "54.2",
            targetTemperatureResponse: "55.0",
            timerResponse: "42"
        ).cookerSnapshot

        #expect(snapshot.family == .original)
        #expect(snapshot.temperatureUnit == .celsius)
        #expect(snapshot.currentTemperatureValue == 54.2)
        #expect(snapshot.targetTemperatureValue == 55.0)
        #expect(snapshot.timerInitialSeconds == 2520)
        #expect(snapshot.isCooking)
    }
}

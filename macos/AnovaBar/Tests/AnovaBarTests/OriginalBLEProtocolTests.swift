import Testing
@preconcurrency import CoreBluetooth
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

    @MainActor
    @Test
    func originalDiscoveryRequiresRealSignal() {
        #expect(OriginalDiscovery.matches(
            localName: nil,
            peripheralName: nil,
            advertisedServices: []
        ) == false)

        #expect(OriginalDiscovery.matches(
            localName: "Anova Precision Cooker",
            peripheralName: nil,
            advertisedServices: []
        ))

        #expect(OriginalDiscovery.matches(
            localName: nil,
            peripheralName: "Anova Precision Cooker",
            advertisedServices: []
        ))

        #expect(OriginalDiscovery.matches(
            localName: "Unknown Device",
            peripheralName: nil,
            advertisedServices: [OriginalBLEUUIDs.service]
        ))

        #expect(OriginalDiscovery.matches(
            localName: "Anova Mini",
            peripheralName: nil,
            advertisedServices: [MiniBLEUUIDs.service]
        ) == false)
    }
}

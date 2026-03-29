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

    @Test
    func commandPolicyTreatsMutatingCommandsAsBestEffort() {
        #expect(OriginalCommandPolicy.acceptsMissingResponse(for: "set temp 48.0"))
        #expect(OriginalCommandPolicy.acceptsMissingResponse(for: "start"))
        #expect(OriginalCommandPolicy.acceptsMissingResponse(for: "stop"))
        #expect(OriginalCommandPolicy.acceptsMissingResponse(for: "read temp") == false)
        #expect(OriginalCommandPolicy.timeout(for: "set timer 30") == 1.5)
        #expect(OriginalCommandPolicy.timeout(for: "status") == 15)
    }

    @Test
    func commandPolicyMatchesStructuredResponses() {
        #expect(OriginalCommandPolicy.matchesResponse("running", for: "status"))
        #expect(OriginalCommandPolicy.matchesResponse("stopped", for: "status"))
        #expect(OriginalCommandPolicy.matchesResponse("c", for: "read unit"))
        #expect(OriginalCommandPolicy.matchesResponse("43.0", for: "read temp"))
        #expect(OriginalCommandPolicy.matchesResponse("0 stopped", for: "read timer"))
        #expect(OriginalCommandPolicy.matchesResponse("start", for: "status") == false)
        #expect(OriginalCommandPolicy.matchesResponse("stop time", for: "read unit") == false)
    }

    @Test
    func commandPolicyNormalizesSplitAndNoisyResponses() {
        #expect(OriginalCommandPolicy.normalizedResponse("anova f56-a007b02ef3\r9\r", for: "get id card") == "anova f56-a007b02ef39")
        #expect(OriginalCommandPolicy.normalizedResponse("stop time\rC\r", for: "read unit") == "C")
        #expect(OriginalCommandPolicy.normalizedResponse("start\r43.0\r", for: "read temp") == "43.0")
        #expect(OriginalCommandPolicy.normalizedResponse("start\r\nrunning\r", for: "status") == "running")
    }
}

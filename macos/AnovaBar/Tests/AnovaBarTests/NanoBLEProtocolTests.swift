import Foundation
import Testing
@testable import AnovaBar

struct NanoBLEProtocolTests {
    @Test
    func encodesGetSensorValuesCommandLikeRustFixture() {
        #expect(NanoCommand.getSensorValues.encode() == Data([1, 2, 5, 0]))
    }

    @Test
    func decodesIntegerValuePayload() {
        #expect(NanoProto.decodeIntegerValue(Data([8, 164, 3])) == 420)
        #expect(NanoProto.decodeUnit(Data([8, 6])) == MiniTemperatureUnit.celsius)
        #expect(NanoProto.decodeUnit(Data([8, 7])) == MiniTemperatureUnit.fahrenheit)
    }

    @Test
    func decodesSensorSnapshotFixture() {
        let payload = Data([
            10, 7, 8, 210, 16, 16, 4, 24, 0,
            10, 6, 8, 20, 16, 6, 24, 1,
            10, 6, 8, 22, 16, 6, 24, 2,
            10, 6, 8, 24, 16, 6, 24, 3,
            10, 6, 8, 25, 16, 6, 24, 4,
            10, 6, 8, 1, 16, 3, 24, 5,
            10, 6, 8, 0, 16, 3, 24, 6,
            10, 6, 8, 5, 16, 2, 24, 7,
        ])

        let snapshot = NanoProto.decodeSensorSnapshot(payload)

        #expect(snapshot?.waterTemp?.unit == MiniTemperatureUnit.celsius)
        #expect(snapshot?.waterTemp?.value == 21.3)
        #expect(snapshot?.motorSpeed == 5)
        #expect(snapshot?.isCooking == true)
    }

    @Test
    func buildsCookerSnapshotFromNanoPayloads() {
        let sensorPayload = Data([
            10, 7, 8, 210, 16, 16, 4, 24, 0,
            10, 6, 8, 20, 16, 6, 24, 1,
            10, 6, 8, 22, 16, 6, 24, 2,
            10, 6, 8, 24, 16, 6, 24, 3,
            10, 6, 8, 25, 16, 6, 24, 4,
            10, 6, 8, 1, 16, 3, 24, 5,
            10, 6, 8, 0, 16, 3, 24, 6,
            10, 6, 8, 5, 16, 2, 24, 7,
        ])
        let snapshot = NanoSnapshot(
            sensorPayload: sensorPayload,
            targetPayload: Data([8, 164, 3]),
            timerPayload: Data([8, 45]),
            unitPayload: Data([8, 6])
        ).cookerSnapshot

        #expect(snapshot.family == AnovaDeviceFamily.nano)
        #expect(snapshot.temperatureUnit == MiniTemperatureUnit.celsius)
        #expect(snapshot.currentTemperatureValue == 21.3)
        #expect(snapshot.targetTemperatureValue == 42.0)
        #expect(snapshot.timerInitialSeconds == 2700)
        #expect(snapshot.isCooking)
    }
}

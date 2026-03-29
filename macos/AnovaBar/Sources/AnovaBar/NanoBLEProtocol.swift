@preconcurrency import CoreBluetooth
import Foundation

@MainActor
enum NanoBLEUUIDs {
    static let service = CBUUID(string: "0E140000-0AF1-4582-A242-773E63054C68")
    static let write = CBUUID(string: "0E140001-0AF1-4582-A242-773E63054C68")
    static let read = CBUUID(string: "0E140002-0AF1-4582-A242-773E63054C68")

    static let requiredCharacteristics = [write, read]

    static func name(for uuid: CBUUID) -> String {
        switch uuid {
        case service:
            return "service"
        case write:
            return "write"
        case read:
            return "read"
        default:
            return uuid.uuidString
        }
    }
}

enum NanoConfigMessageType: UInt8 {
    case setTempSetpoint = 3
    case getTempSetpoint = 4
    case getSensors = 5
    case setTempUnits = 6
    case getTempUnits = 7
    case startCooking = 10
    case stopCooking = 11
    case setCookingTimer = 16
    case getCookingTimer = 18
    case getDeviceInfo = 25
    case getFirmwareInfo = 26
}

enum NanoCommand {
    case getSensorValues
    case getTargetTemperature
    case getTimer
    case getUnit
    case getFirmwareInfo
    case getDeviceInfo
    case start
    case stop
    case setUnit(MiniTemperatureUnit)
    case setTargetTemperature(Double)
    case setTimer(Int)

    var expectsResponse: Bool {
        switch self {
        case .getSensorValues,
             .getTargetTemperature,
             .getTimer,
             .getUnit,
             .getFirmwareInfo,
             .getDeviceInfo,
             .start,
             .stop:
            return true
        case .setUnit, .setTargetTemperature, .setTimer:
            return false
        }
    }

    var label: String {
        switch self {
        case .getSensorValues:
            return "getSensorValues"
        case .getTargetTemperature:
            return "getTargetTemperature"
        case .getTimer:
            return "getTimer"
        case .getUnit:
            return "getUnit"
        case .getFirmwareInfo:
            return "getFirmwareInfo"
        case .getDeviceInfo:
            return "getDeviceInfo"
        case .start:
            return "start"
        case .stop:
            return "stop"
        case .setUnit(let unit):
            return "setUnit(\(unit.rawValue))"
        case .setTargetTemperature(let value):
            return "setTargetTemperature(\(MiniFormat.temperature(value)))"
        case .setTimer(let minutes):
            return "setTimer(\(minutes))"
        }
    }

    func encode() -> Data {
        switch self {
        case .getSensorValues:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getSensors.rawValue)
        case .getTargetTemperature:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getTempSetpoint.rawValue)
        case .getTimer:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getCookingTimer.rawValue)
        case .getUnit:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getTempUnits.rawValue)
        case .getFirmwareInfo:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getFirmwareInfo.rawValue)
        case .getDeviceInfo:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.getDeviceInfo.rawValue)
        case .start:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.startCooking.rawValue)
        case .stop:
            return NanoFrameCodec.encodeCommand(messageType: NanoConfigMessageType.stopCooking.rawValue)
        case .setUnit(let unit):
            return NanoFrameCodec.encodeCommand(
                messageType: NanoConfigMessageType.setTempUnits.rawValue,
                payload: NanoProto.encodeIntegerValue(unit == .celsius ? 6 : 7)
            )
        case .setTargetTemperature(let value):
            return NanoFrameCodec.encodeCommand(
                messageType: NanoConfigMessageType.setTempSetpoint.rawValue,
                payload: NanoProto.encodeIntegerValue(Int((value * 10.0).rounded()))
            )
        case .setTimer(let minutes):
            return NanoFrameCodec.encodeCommand(
                messageType: NanoConfigMessageType.setCookingTimer.rawValue,
                payload: NanoProto.encodeIntegerValue(minutes)
            )
        }
    }
}

enum NanoFrameCodec {
    private static let configDomainID: UInt8 = 0

    static func encodeCommand(messageType: UInt8, payload: Data? = nil) -> Data {
        var command = Data([configDomainID, messageType])
        if let payload {
            command.append(payload)
        }
        return encodeFrame(command)
    }

    static func encodeFrame(_ payload: Data) -> Data {
        var framed = Data([0])
        var lastIndex = 0
        var currentIndex: UInt8 = 1

        func resetIndex(isEnd: Bool) {
            framed[lastIndex] = currentIndex
            lastIndex = framed.count
            if isEnd {
                framed.append(0)
            }
            currentIndex = 1
        }

        for byte in payload {
            if byte == 0 {
                resetIndex(isEnd: true)
                continue
            }

            framed.append(byte)
            currentIndex &+= 1

            if currentIndex == .max {
                resetIndex(isEnd: true)
            }
        }

        resetIndex(isEnd: false)
        framed.append(0)
        return framed
    }

    static func decodeFrame(_ rawData: Data) -> Data? {
        guard !rawData.isEmpty else {
            return nil
        }

        let data = rawData.dropLast()
        var results = Data()
        var index = data.startIndex

        while index < data.endIndex {
            let blockLength = Int(data[index])
            index = data.index(after: index)

            if blockLength == 0 {
                return nil
            }

            for _ in 1..<blockLength {
                guard index < data.endIndex else {
                    return nil
                }
                results.append(data[index])
                index = data.index(after: index)
            }

            if blockLength < Int(UInt8.max), index < data.endIndex {
                results.append(0)
            }
        }

        guard results.count > 2 else {
            return Data()
        }

        return results.dropFirst(2)
    }
}

private enum NanoWireType: UInt64 {
    case varint = 0
    case lengthDelimited = 2
}

private struct NanoProtoReader {
    let bytes: [UInt8]
    var index = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func nextField() -> (fieldNumber: Int, wireType: NanoWireType)? {
        guard index < bytes.count,
              let key = readVarint(),
              let wireType = NanoWireType(rawValue: key & 0x07)
        else {
            return nil
        }

        return (Int(key >> 3), wireType)
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }

        return nil
    }

    mutating func readLengthDelimited() -> Data? {
        guard let length = readVarint() else {
            return nil
        }

        let byteCount = Int(length)
        guard index + byteCount <= bytes.count else {
            return nil
        }

        let data = Data(bytes[index..<(index + byteCount)])
        index += byteCount
        return data
    }

    mutating func skip(_ wireType: NanoWireType) {
        switch wireType {
        case .varint:
            _ = readVarint()
        case .lengthDelimited:
            _ = readLengthDelimited()
        }
    }
}

private enum NanoProtoUnitType: Int {
    case degreesPoint1C = 0
    case degreesPoint1F = 1
    case motorSpeed = 2
    case boolean = 3
    case degreesPoint01C = 4
    case degreesPoint01F = 5
    case degreesC = 6
    case degreesF = 7
}

private enum NanoSensorType: Int {
    case waterTemp = 0
    case heaterTemp = 1
    case triacTemp = 2
    case unusedTemp = 3
    case internalTemp = 4
    case waterLow = 5
    case waterLeak = 6
    case motorSpeed = 7
}

struct NanoTemperatureReading {
    let value: Double
    let unit: MiniTemperatureUnit
}

struct NanoSensorSnapshot {
    var waterTemp: NanoTemperatureReading?
    var heaterTemp: NanoTemperatureReading?
    var triacTemp: NanoTemperatureReading?
    var internalTemp: NanoTemperatureReading?
    var waterLow: Bool?
    var waterLeak: Bool?
    var motorSpeed: Int?

    var isCooking: Bool {
        (motorSpeed ?? 0) != 0
    }
}

enum NanoProto {
    static func encodeIntegerValue(_ value: Int) -> Data {
        var payload = Data([0x08])
        payload.append(encodeVarint(UInt64(value)))
        return payload
    }

    static func decodeIntegerValue(_ payload: Data) -> Int? {
        var reader = NanoProtoReader(payload)
        while let field = reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .varint):
                return reader.readVarint().map(Int.init)
            default:
                reader.skip(field.wireType)
            }
        }

        return nil
    }

    static func decodeUnit(_ payload: Data) -> MiniTemperatureUnit? {
        guard let raw = decodeIntegerValue(payload) else {
            return nil
        }

        switch raw {
        case NanoProtoUnitType.degreesPoint1C.rawValue,
             NanoProtoUnitType.degreesPoint01C.rawValue,
             NanoProtoUnitType.degreesC.rawValue:
            return .celsius
        case NanoProtoUnitType.degreesPoint1F.rawValue,
             NanoProtoUnitType.degreesPoint01F.rawValue,
             NanoProtoUnitType.degreesF.rawValue:
            return .fahrenheit
        default:
            return nil
        }
    }

    static func decodeFirmwareInfo(_ payload: Data) -> JSONDictionary {
        var commitID = ""
        var tagID = ""
        var dateCode: Int?
        var reader = NanoProtoReader(payload)

        while let field = reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .lengthDelimited):
                commitID = reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) } ?? commitID
            case (2, .lengthDelimited):
                tagID = reader.readLengthDelimited().flatMap { String(data: $0, encoding: .utf8) } ?? tagID
            case (3, .varint):
                dateCode = reader.readVarint().map(Int.init)
            default:
                reader.skip(field.wireType)
            }
        }

        var dictionary: JSONDictionary = [:]
        if !commitID.isEmpty {
            dictionary["commitId"] = commitID
        }
        if !tagID.isEmpty {
            dictionary["tagId"] = tagID
        }
        if let dateCode {
            dictionary["dateCode"] = dateCode
        }
        dictionary["rawPayload"] = NanoFormat.hex(payload)
        return dictionary
    }

    static func decodeSensorSnapshot(_ payload: Data) -> NanoSensorSnapshot? {
        var snapshot = NanoSensorSnapshot()
        var reader = NanoProtoReader(payload)

        while let field = reader.nextField() {
            guard field.fieldNumber == 1, field.wireType == .lengthDelimited,
                  let sensorData = reader.readLengthDelimited(),
                  let sensor = decodeSensorValue(sensorData)
            else {
                reader.skip(field.wireType)
                continue
            }

            switch sensor.type {
            case .waterTemp:
                snapshot.waterTemp = decodeTemperature(rawValue: sensor.value, rawUnit: sensor.unit)
            case .heaterTemp:
                snapshot.heaterTemp = decodeTemperature(rawValue: sensor.value, rawUnit: sensor.unit)
            case .triacTemp:
                snapshot.triacTemp = decodeTemperature(rawValue: sensor.value, rawUnit: sensor.unit)
            case .internalTemp:
                snapshot.internalTemp = decodeTemperature(rawValue: sensor.value, rawUnit: sensor.unit)
            case .waterLow:
                snapshot.waterLow = sensor.value != 0
            case .waterLeak:
                snapshot.waterLeak = sensor.value != 0
            case .motorSpeed:
                snapshot.motorSpeed = sensor.value
            case .unusedTemp:
                break
            }
        }

        return snapshot.waterTemp == nil ? nil : snapshot
    }

    private static func decodeSensorValue(_ payload: Data) -> (value: Int, unit: Int, type: NanoSensorType)? {
        var value: Int?
        var unit: Int?
        var type: NanoSensorType?
        var reader = NanoProtoReader(payload)

        while let field = reader.nextField() {
            switch (field.fieldNumber, field.wireType) {
            case (1, .varint):
                value = reader.readVarint().map(Int.init)
            case (2, .varint):
                unit = reader.readVarint().map(Int.init)
            case (3, .varint):
                type = reader.readVarint().flatMap { NanoSensorType(rawValue: Int($0)) }
            default:
                reader.skip(field.wireType)
            }
        }

        guard let value, let unit, let type else {
            return nil
        }

        return (value, unit, type)
    }

    private static func decodeTemperature(rawValue: Int, rawUnit: Int) -> NanoTemperatureReading? {
        guard let unitType = NanoProtoUnitType(rawValue: rawUnit) else {
            return nil
        }

        switch unitType {
        case .degreesPoint1C:
            return NanoTemperatureReading(value: Double(rawValue) / 10.0, unit: .celsius)
        case .degreesPoint01C:
            return NanoTemperatureReading(value: Double(rawValue) / 100.0, unit: .celsius)
        case .degreesC:
            return NanoTemperatureReading(value: Double(rawValue), unit: .celsius)
        case .degreesPoint1F:
            return NanoTemperatureReading(value: Double(rawValue) / 10.0, unit: .fahrenheit)
        case .degreesPoint01F:
            return NanoTemperatureReading(value: Double(rawValue) / 100.0, unit: .fahrenheit)
        case .degreesF:
            return NanoTemperatureReading(value: Double(rawValue), unit: .fahrenheit)
        case .motorSpeed, .boolean:
            return nil
        }
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var remaining = value
        var data = Data()

        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }

        data.append(UInt8(remaining))
        return data
    }
}

struct NanoSnapshot {
    let sensorPayload: Data
    let targetPayload: Data
    let timerPayload: Data
    let unitPayload: Data

    var cookerSnapshot: CookerSnapshot {
        let sensorSnapshot = NanoProto.decodeSensorSnapshot(sensorPayload)
        let targetRaw = NanoProto.decodeIntegerValue(targetPayload).map { Double($0) / 10.0 }
        let timerMinutes = NanoProto.decodeIntegerValue(timerPayload).map { max(0, $0) }
        let unit = NanoProto.decodeUnit(unitPayload)

        return CookerSnapshot(
            family: .nano,
            temperatureUnit: unit,
            currentTemperatureValue: sensorSnapshot?.waterTemp?.value,
            targetTemperatureValue: targetRaw,
            timerDisplay: timerMinutes.map { MiniFormat.duration(seconds: $0 * 60) } ?? "Unavailable",
            timerSecondsValue: timerMinutes.map { $0 * 60 },
            timerInitialSeconds: timerMinutes.map { $0 * 60 },
            timerStartedAt: nil,
            timerMode: (sensorSnapshot?.isCooking == true && (timerMinutes ?? 0) > 0) ? "running" : "idle",
            stateMode: sensorSnapshot?.isCooking == true ? "running" : "stopped",
            timerHasRunningSignal: sensorSnapshot?.isCooking == true && (timerMinutes ?? 0) > 0,
            timerHasCompleted: false,
            isCooking: sensorSnapshot?.isCooking == true,
            interpretation: [
                "isCooking": sensorSnapshot?.isCooking == true,
                "activitySource": "sensorSnapshot.motorSpeed",
                "note": "Nano state is inferred from protobuf sensor readings over the notification characteristic.",
            ],
            state: [
                "status": sensorSnapshot?.isCooking == true ? "running" : "stopped",
                "motorSpeed": sensorSnapshot?.motorSpeed as Any,
                "rawPayload": NanoFormat.hex(sensorPayload),
            ],
            currentTemperature: [
                "current": sensorSnapshot?.waterTemp?.value as Any,
                "heater": sensorSnapshot?.heaterTemp?.value as Any,
                "triac": sensorSnapshot?.triacTemp?.value as Any,
                "internal": sensorSnapshot?.internalTemp?.value as Any,
                "waterLow": sensorSnapshot?.waterLow as Any,
                "waterLeak": sensorSnapshot?.waterLeak as Any,
                "rawPayload": NanoFormat.hex(sensorPayload),
            ],
            timer: [
                "minutes": timerMinutes as Any,
                "mode": (sensorSnapshot?.isCooking == true && (timerMinutes ?? 0) > 0) ? "running" : "idle",
                "rawPayload": NanoFormat.hex(timerPayload),
            ]
        )
    }
}

enum NanoFormat {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

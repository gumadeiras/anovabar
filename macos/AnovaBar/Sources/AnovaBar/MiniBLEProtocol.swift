@preconcurrency import CoreBluetooth
import Foundation

typealias JSONDictionary = [String: Any]

enum MiniTemperatureUnit: String, CaseIterable, Identifiable {
    case celsius = "C"
    case fahrenheit = "F"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .celsius:
            "Celsius"
        case .fahrenheit:
            "Fahrenheit"
        }
    }

    var symbol: String {
        switch self {
        case .celsius:
            "ºC"
        case .fahrenheit:
            "ºF"
        }
    }
}

@MainActor
enum MiniBLEUUIDs {
    static let service = CBUUID(string: "910772A8-A5E7-49A7-BC6D-701E9A783A5C")
    static let setTemperature = CBUUID(string: "0F5639F7-3C4E-47D0-9496-0672C89EA48A")
    static let currentTemperature = CBUUID(string: "6FFDCA46-D6A8-4FB2-8FD9-C6330F1939E3")
    static let timer = CBUUID(string: "A2B179F8-944E-436F-A246-C66CAAF7061F")
    static let state = CBUUID(string: "54E53C60-367A-4783-A5C1-B1770C54142B")
    static let systemInfo = CBUUID(string: "153C9432-7C83-4B88-9252-7588229D5473")

    static let requiredCharacteristics = [
        setTemperature,
        currentTemperature,
        timer,
        state,
        systemInfo,
    ]
}

struct MiniDiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let identifier: String

    var displayName: String {
        if name.isEmpty {
            return identifier
        }

        return "\(name) (\(identifier))"
    }
}

struct MiniSnapshot {
    let state: JSONDictionary
    let currentTemperature: JSONDictionary
    let timer: JSONDictionary

    var temperatureUnit: MiniTemperatureUnit? {
        guard let raw = MiniJSON.string(in: state, key: "temperatureUnit") else {
            return nil
        }

        return MiniTemperatureUnit(rawValue: raw.uppercased())
    }

    var currentTemperatureValue: Double? {
        MiniJSON.double(in: currentTemperature, keys: ["current", "waterTemperature", "temperature"])
    }

    var targetTemperatureValue: Double? {
        MiniJSON.double(
            in: state,
            keys: ["setpoint", "target", "targetTemperature", "temperatureSetpoint", "desiredTemperature"]
        ) ?? MiniJSON.double(
            in: currentTemperature,
            keys: ["setpoint", "target", "targetTemperature", "temperatureSetpoint", "desiredTemperature"]
        )
    }

    var currentTemperatureDisplay: String {
        guard let value = currentTemperatureValue else {
            return "Unavailable"
        }

        let suffix = temperatureUnit?.symbol ?? ""
        return "\(MiniFormat.temperature(value))\(suffix)"
    }

    var targetTemperatureDisplay: String {
        guard let value = targetTemperatureValue else {
            return "Unavailable"
        }

        let suffix = temperatureUnit?.symbol ?? ""
        return "\(MiniFormat.temperature(value))\(suffix)"
    }

    var timerDisplay: String {
        if let remaining = timerSecondsValue {
            return MiniFormat.duration(seconds: remaining)
        }

        if let status = MiniJSON.string(in: timer, keys: ["mode", "status", "state", "timerState"]) {
            return status.capitalized
        }

        if timer.isEmpty {
            return "Unavailable"
        }

        return "See raw timer"
    }

    var stateDisplay: String {
        MiniFormat.json(state)
    }

    var currentTemperatureDisplayJSON: String {
        MiniFormat.json(currentTemperature)
    }

    var timerDisplayJSON: String {
        MiniFormat.json(timer)
    }

    var timerSecondsValue: Int? {
        if let initial = timerInitialSeconds,
           let startedAt = timerStartedAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            return max(0, initial - elapsed)
        }

        if let explicit = MiniJSON.int(
            in: timer,
            keys: [
                "remaining",
                "remainingTime",
                "remainingSeconds",
                "secondsRemaining",
                "timer",
                "timerSeconds",
                "durationSeconds",
                "countdownSeconds",
                "cookTimeSeconds",
            ]
        ) {
            return explicit
        }

        if let hours = MiniJSON.int(in: timer, keys: ["hours"]),
           let minutes = MiniJSON.int(in: timer, keys: ["minutes"]),
           let seconds = MiniJSON.int(in: timer, keys: ["seconds"]) {
            return (hours * 3600) + (minutes * 60) + seconds
        }

        return nil
    }

    var timerInitialSeconds: Int? {
        MiniJSON.int(
            in: timer,
            keys: ["initial", "initialSeconds", "duration", "durationSeconds", "timerSeconds"]
        )
    }

    var timerStartedAt: Date? {
        guard let raw = MiniJSON.string(in: timer, keys: ["startedAtTimestamp", "startedAt", "startedAtTime"]) else {
            return nil
        }

        return MiniDateParser.parse(raw)
    }

    var timerMode: String? {
        MiniJSON.string(in: timer, keys: ["mode", "state", "status", "timerState"])?.lowercased()
    }

    var timerHasRunningSignal: Bool {
        let activeValues = ["cook", "cooking", "running", "active"]

        if let timerMode, activeValues.contains(timerMode) {
            return true
        }

        if timerStartedAt != nil {
            return true
        }

        if let explicitRemaining = MiniJSON.int(
            in: timer,
            keys: [
                "remaining",
                "remainingTime",
                "remainingSeconds",
                "secondsRemaining",
                "timer",
                "timerSeconds",
                "durationSeconds",
                "countdownSeconds",
                "cookTimeSeconds",
            ]
        ) {
            return explicitRemaining > 0
        }

        return false
    }

    var isCooking: Bool {
        let activeValues = ["cook", "cooking", "running", "active"]

        if let stateMode = MiniJSON.string(in: state, keys: ["mode", "state", "status"])?.lowercased(),
           activeValues.contains(stateMode) {
            return true
        }

        if let timerMode,
           activeValues.contains(timerMode) {
            return true
        }

        return false
    }
}

enum MiniJSON {
    static func string(in dictionary: JSONDictionary, key: String) -> String? {
        string(in: dictionary, keys: [key])
    }

    static func string(in dictionary: JSONDictionary, keys: [String]) -> String? {
        guard let value = findValue(in: dictionary, candidateKeys: keys) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        return nil
    }

    static func double(in dictionary: JSONDictionary, key: String) -> Double? {
        double(in: dictionary, keys: [key])
    }

    static func double(in dictionary: JSONDictionary, keys: [String]) -> Double? {
        guard let value = findValue(in: dictionary, candidateKeys: keys) else {
            return nil
        }

        if let value = value as? Double {
            return value
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    static func int(in dictionary: JSONDictionary, keys: [String]) -> Int? {
        guard let value = findValue(in: dictionary, candidateKeys: keys) else {
            return nil
        }

        if let value = value as? Int {
            return value
        }

        if let value = value as? NSNumber {
            return value.intValue
        }

        if let value = value as? String, let parsed = Int(value) {
            return parsed
        }

        return nil
    }

    private static func findValue(in object: Any, candidateKeys: [String]) -> Any? {
        if let dictionary = object as? JSONDictionary {
            for key in candidateKeys {
                if let direct = dictionary[key] {
                    return direct
                }
            }

            for value in dictionary.values {
                if let nested = findValue(in: value, candidateKeys: candidateKeys) {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = findValue(in: value, candidateKeys: candidateKeys) {
                    return nested
                }
            }
        }

        return nil
    }
}

enum MiniCodec {
    static func encode(_ payload: JSONDictionary) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return json.base64EncodedData()
    }

    static func decode(_ data: Data) throws -> JSONDictionary {
        let decoded = try Data(base64Encoded: data)
            .unwrap(or: MiniBLEClientError.invalidPayload("Invalid base64 payload"))
        let json = try JSONSerialization.jsonObject(with: decoded, options: [])
        guard let dictionary = json as? JSONDictionary else {
            throw MiniBLEClientError.invalidPayload("Expected a JSON dictionary")
        }

        return dictionary
    }
}

enum MiniDateParser {
    static func parse(_ raw: String) -> Date? {
        let sanitized = raw
            .replacingOccurrences(of: #"(?<=\d)-\s+(?=\d)"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        if let parsed = formatter.date(from: sanitized) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: sanitized)
    }
}

enum MiniFormat {
    static func json(_ dictionary: JSONDictionary) -> String {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: dictionary)
        }

        return string
    }

    static func temperature(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func duration(seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        var parts: [String] = []

        if days > 0 {
            parts.append("\(days)d")
        }
        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 {
            parts.append("\(minutes)m")
        }
        if remainingSeconds > 0 || parts.isEmpty {
            parts.append("\(remainingSeconds)s")
        }

        return parts.joined(separator: " ")
    }
}

private extension Optional {
    func unwrap<E: Error>(or error: @autoclosure () -> E) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }

        return value
    }
}

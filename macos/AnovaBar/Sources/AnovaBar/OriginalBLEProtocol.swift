@preconcurrency import CoreBluetooth
import Foundation

@MainActor
enum OriginalBLEUUIDs {
    static let service = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    static let command = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")

    static let requiredCharacteristics = [command]

    static func name(for uuid: CBUUID) -> String {
        switch uuid {
        case service:
            return "service"
        case command:
            return "command"
        default:
            return uuid.uuidString
        }
    }
}

enum OriginalCookerModel: String {
    case bluetooth800W = "800w"
    case wifi900W = "900w-wifi"

    static func detect(from cookerID: String) -> OriginalCookerModel {
        cookerID.lowercased().hasPrefix("anova f56-") ? .wifi900W : .bluetooth800W
    }
}

enum OriginalCommandPolicy {
    static func timeout(for command: String) -> TimeInterval {
        acceptsMissingResponse(for: command) ? 1.5 : 15
    }

    static func acceptsMissingResponse(for command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "start"
            || normalized == "stop"
            || normalized == "start time"
            || normalized == "stop time"
            || normalized == "clear alarm"
            || normalized.hasPrefix("set ")
    }

    static func expectsStructuredResponse(for command: String) -> Bool {
        !acceptsMissingResponse(for: command)
    }

    static func matchesResponse(_ response: String, for command: String) -> Bool {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedResponse = response.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)).lowercased()

        guard !normalizedResponse.isEmpty else {
            return false
        }

        switch normalizedCommand {
        case "status":
            return normalizedResponse.contains("running") || normalizedResponse.contains("stopped")
        case "read unit":
            return normalizedResponse == "c" || normalizedResponse == "f"
        case "read temp", "read set temp":
            return OriginalParser.temperature(from: normalizedResponse) != nil
        case "read timer":
            return OriginalParser.timerMinutes(from: normalizedResponse) != nil
                || normalizedResponse.contains("stopped")
                || normalizedResponse.contains("running")
                || normalizedResponse.contains("complete")
        case "get id card":
            return normalizedResponse.contains("anova")
        case "version":
            return normalizedResponse.hasPrefix("ver") || normalizedResponse.hasPrefix("version")
        default:
            return true
        }
    }
}

@MainActor
enum OriginalDiscovery {
    static let defaultName = "Anova Precision Cooker"

    static func matches(localName: String?, peripheralName: String?, advertisedServices: [CBUUID]) -> Bool {
        let hasOriginalService = advertisedServices.contains(OriginalBLEUUIDs.service)
        let hasMiniService = advertisedServices.contains(MiniBLEUUIDs.service)

        guard hasOriginalService == false else {
            return true
        }

        guard hasMiniService == false else {
            return false
        }

        let candidateName = [localName, peripheralName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let normalizedCandidateName = candidateName?.lowercased()

        guard let normalizedCandidateName else {
            return false
        }

        return normalizedCandidateName.contains("anova precision cooker")
    }

    static func displayName(localName: String?, peripheralName: String?) -> String {
        [localName, peripheralName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? defaultName
    }
}

struct OriginalSnapshot {
    let statusResponse: String
    let unitResponse: String
    let currentTemperatureResponse: String
    let targetTemperatureResponse: String
    let timerResponse: String

    var cookerSnapshot: CookerSnapshot {
        let unit = OriginalParser.temperatureUnit(from: unitResponse)
        let currentTemperature = OriginalParser.temperature(from: currentTemperatureResponse)
        let targetTemperature = OriginalParser.temperature(from: targetTemperatureResponse)
        let timerMinutes = OriginalParser.timerMinutes(from: timerResponse)
        let isCooking = OriginalParser.isCooking(from: statusResponse)
        let timerHasCompleted = OriginalParser.timerHasCompleted(from: timerResponse)

        return CookerSnapshot(
            family: .original,
            temperatureUnit: unit,
            currentTemperatureValue: currentTemperature,
            targetTemperatureValue: targetTemperature,
            timerDisplay: OriginalParser.timerDisplay(from: timerResponse),
            timerSecondsValue: timerMinutes.map { max(0, $0 * 60) },
            timerInitialSeconds: timerMinutes.map { max(0, $0 * 60) },
            timerStartedAt: nil,
            timerMode: OriginalParser.timerMode(from: timerResponse),
            stateMode: OriginalParser.stateMode(from: statusResponse),
            timerHasRunningSignal: isCooking && (timerMinutes ?? 0) > 0,
            timerHasCompleted: timerHasCompleted,
            isCooking: isCooking,
            interpretation: [
                "isCooking": isCooking,
                "activitySource": "status",
                "stateMode": OriginalParser.stateMode(from: statusResponse) ?? "unknown",
                "timerMode": OriginalParser.timerMode(from: timerResponse) ?? "unknown",
                "timerMeaning": timerHasCompleted ? "completed timer" : "text response",
                "note": "Original cooker state is inferred from text commands and notifications.",
            ],
            state: [
                "status": statusResponse,
            ],
            currentTemperature: [
                "response": currentTemperatureResponse,
                "current": currentTemperature as Any,
            ],
            timer: [
                "response": timerResponse,
                "minutes": timerMinutes as Any,
                "mode": OriginalParser.timerMode(from: timerResponse) as Any,
            ]
        )
    }
}

enum OriginalParser {
    static func temperatureUnit(from response: String) -> MiniTemperatureUnit? {
        switch response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "C":
            return .celsius
        case "F":
            return .fahrenheit
        default:
            return nil
        }
    }

    static func temperature(from response: String) -> Double? {
        firstNumber(in: response)
    }

    static func timerMinutes(from response: String) -> Int? {
        guard let number = firstNumber(in: response) else {
            return nil
        }

        return max(0, Int(number.rounded()))
    }

    static func timerDisplay(from response: String) -> String {
        if let mode = timerMode(from: response), mode == "completed" {
            return "Complete"
        }

        if let minutes = timerMinutes(from: response) {
            return MiniFormat.duration(seconds: minutes * 60)
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unavailable" : trimmed
    }

    static func isCooking(from response: String) -> Bool {
        let normalized = response.lowercased()

        if normalized.contains("stop") || normalized.contains("idle") || normalized.contains("off") {
            return false
        }

        let activeSignals = ["run", "cook", "heat", "on", "start"]
        return activeSignals.contains { normalized.contains($0) }
    }

    static func timerHasCompleted(from response: String) -> Bool {
        let normalized = response.lowercased()
        return normalized.contains("complete") || normalized.contains("done") || normalized.contains("finished")
    }

    static func timerMode(from response: String) -> String? {
        if timerHasCompleted(from: response) {
            return "completed"
        }

        if let minutes = timerMinutes(from: response) {
            return minutes > 0 ? "configured" : "idle"
        }

        return nil
    }

    static func stateMode(from response: String) -> String? {
        isCooking(from: response) ? "cook" : "idle"
    }

    private static func firstNumber(in response: String) -> Double? {
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let range = Range(match.range, in: response) else {
            return nil
        }

        return Double(String(response[range]))
    }
}

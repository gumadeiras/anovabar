import Foundation
import OSLog

@MainActor
fileprivate enum MiniDiagnosticFormatting {
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
            .withColonSeparatorInTimeZone,
        ]
        return formatter
    }()
}

enum MiniDiagnosticCategory: String {
    case app = "APP"
    case ble = "BLE"
    case snapshot = "SNAPSHOT"
    case persistence = "STORE"
    case error = "ERROR"

    var isVerbose: Bool {
        switch self {
        case .ble, .snapshot, .persistence:
            return true
        case .app, .error:
            return false
        }
    }
}

@MainActor
struct MiniDiagnosticEntry {
    let timestamp: Date
    let category: MiniDiagnosticCategory
    let message: String
    let details: [String: String]

    var renderedLine: String {
        let prefix = "[\(MiniDiagnosticFormatting.timestampFormatter.string(from: timestamp))] \(category.rawValue) \(message)"
        guard !details.isEmpty else {
            return prefix
        }

        let renderedDetails = details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return "\(prefix) \(renderedDetails)"
    }
}

@MainActor
final class MiniDiagnosticsStore {
    static let emptyText = "No BLE trace yet."
    static let defaultLogFileURL = makeLogFileURL()

    private let maxEntries: Int
    private let maxFileSizeBytes: Int
    let logFileURL: URL?
    private(set) var entries: [MiniDiagnosticEntry] = []
    private(set) var renderedText = "No BLE trace yet."
    private var recordsVerboseEntries = false
    var onChange: ((String) -> Void)?

    init(
        maxEntries: Int = 160,
        logFileURL: URL? = MiniDiagnosticsStore.defaultLogFileURL,
        maxFileSizeBytes: Int = 2_000_000
    ) {
        self.maxEntries = maxEntries
        self.logFileURL = logFileURL
        self.maxFileSizeBytes = maxFileSizeBytes

        if let logFileURL {
            Self.ensureParentDirectory(for: logFileURL)
            rotateLogIfNeeded(upcomingByteCount: 0)
        }
    }

    func setVerboseLoggingEnabled(_ isEnabled: Bool) {
        recordsVerboseEntries = isEnabled
    }

    func clearInMemory() {
        entries.removeAll(keepingCapacity: true)
        renderedText = Self.emptyText
        onChange?(renderedText)
    }

    func record(_ category: MiniDiagnosticCategory, _ message: String, details: [String: String] = [:]) {
        guard recordsVerboseEntries || !category.isVerbose else {
            return
        }

        entries.append(
            MiniDiagnosticEntry(
                timestamp: Date(),
                category: category,
                message: message,
                details: details
            )
        )

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        renderedText = entries.map(\.renderedLine).joined(separator: "\n")
        appendToDisk(entries.last?.renderedLine ?? "")
        onChange?(renderedText)
    }

    private func appendToDisk(_ line: String) {
        guard let logFileURL else {
            return
        }

        let payload = line.hasSuffix("\n") ? line : "\(line)\n"
        let data = Data(payload.utf8)
        rotateLogIfNeeded(upcomingByteCount: data.count)

        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
        } catch {
            Self.logger.error("Could not write diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotateLogIfNeeded(upcomingByteCount: Int) {
        guard let logFileURL,
              let currentSize = Self.fileSize(at: logFileURL),
              currentSize + upcomingByteCount > maxFileSizeBytes
        else {
            return
        }

        let previousLogURL = logFileURL
            .deletingPathExtension()
            .appendingPathExtension("previous.log")

        do {
            if FileManager.default.fileExists(atPath: previousLogURL.path) {
                try FileManager.default.removeItem(at: previousLogURL)
            }

            if currentSize <= maxFileSizeBytes {
                try FileManager.default.moveItem(at: logFileURL, to: previousLogURL)
            } else {
                try FileManager.default.removeItem(at: logFileURL)
            }
        } catch {
            Self.logger.error("Could not rotate diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeLogFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("AnovaBar", isDirectory: true)
            .appendingPathComponent("ble-trace.log", isDirectory: false)
    }

    private static func ensureParentDirectory(for fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Could not create diagnostics directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func fileSize(at fileURL: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return nil
        }

        return fileSize.intValue
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.gumadeiras.anovabar",
        category: "Diagnostics"
    )
}

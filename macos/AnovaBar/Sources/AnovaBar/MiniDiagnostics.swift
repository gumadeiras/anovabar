import Foundation

fileprivate enum MiniDiagnosticFormatting {
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum MiniDiagnosticCategory: String {
    case app = "APP"
    case ble = "BLE"
    case snapshot = "SNAPSHOT"
    case persistence = "STORE"
    case error = "ERROR"
}

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

    private let maxEntries: Int
    let logFileURL: URL
    private(set) var entries: [MiniDiagnosticEntry] = []
    private(set) var renderedText = "No BLE trace yet."
    var onChange: ((String) -> Void)?

    init(maxEntries: Int = 160) {
        self.maxEntries = maxEntries
        self.logFileURL = Self.makeLogFileURL()
        Self.ensureParentDirectory(for: logFileURL)
    }

    func reset(_ category: MiniDiagnosticCategory, _ message: String, details: [String: String] = [:]) {
        entries.removeAll(keepingCapacity: true)
        renderedText = Self.emptyText
        onChange?(renderedText)
        appendToDisk("\n=== New Session \(MiniDiagnosticFormatting.timestampFormatter.string(from: Date())) ===\n")
        record(category, message, details: details)
    }

    func record(_ category: MiniDiagnosticCategory, _ message: String, details: [String: String] = [:]) {
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
        let payload = line.hasSuffix("\n") ? line : "\(line)\n"
        let data = Data(payload.utf8)

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }

        try? data.write(to: logFileURL, options: .atomic)
    }

    private static func makeLogFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseDirectory
            .appendingPathComponent("AnovaBar", isDirectory: true)
            .appendingPathComponent("ble-trace.log", isDirectory: false)
    }

    private static func ensureParentDirectory(for fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

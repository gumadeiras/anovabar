import Foundation
import Testing
@testable import AnovaBar

struct MiniDiagnosticsTests {
    @MainActor
    @Test
    func recordsDetailedEntriesOnlyWhenEnabled() {
        let store = MiniDiagnosticsStore(logFileURL: nil)

        store.record(.ble, "hidden")
        store.record(.app, "launch")

        #expect(store.entries.count == 1)
        #expect(store.renderedText.contains("APP launch"))
        #expect(store.renderedText.contains("T"))

        store.setVerboseLoggingEnabled(true)
        store.record(.ble, "visible")

        #expect(store.entries.count == 2)
        #expect(store.renderedText.contains("BLE visible"))
    }

    @MainActor
    @Test
    func rotatesBoundedLogFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("ble-trace.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MiniDiagnosticsStore(logFileURL: logURL, maxFileSizeBytes: 240)
        store.record(.app, "first", details: ["value": String(repeating: "a", count: 60)])
        store.record(.app, "second", details: ["value": String(repeating: "b", count: 60)])
        store.record(.app, "third", details: ["value": String(repeating: "c", count: 60)])

        let previousURL = logURL
            .deletingPathExtension()
            .appendingPathExtension("previous.log")
        let currentSize = try #require(fileSize(at: logURL))
        let previousSize = try #require(fileSize(at: previousURL))

        #expect(currentSize <= 240)
        #expect(previousSize <= 240)
    }

    private func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }
}

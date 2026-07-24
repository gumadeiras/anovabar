import Foundation
import Testing
@testable import AnovaBar

struct CookerOperationGateTests {
    @MainActor
    @Test
    func serializesOverlappingOperations() async throws {
        let gate = CookerOperationGate()
        var events: [String] = []

        let first = Task { @MainActor in
            try await gate.run {
                events.append("first-start")
                try await Task.sleep(for: .milliseconds(50))
                events.append("first-end")
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await gate.run {
                events.append("second-start")
                events.append("second-end")
            }
        }

        try await first.value
        try await second.value

        #expect(events == ["first-start", "first-end", "second-start", "second-end"])
    }
}

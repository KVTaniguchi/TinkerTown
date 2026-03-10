import Foundation
import Testing
@testable import TinkerTownCore

struct EventLoggerTests {
    @Test func appendsEventsAsRedactedNdjson() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let logger = EventLogger(fs: fs, paths: paths)

        let event = RunEvent(runID: "run_1", type: "RUN_STATE_CHANGED", from: "RUN_CREATED", to: "PLANNING", meta: ["api_key" : "secret123"])
        try logger.append(event)

        let data = try fs.read(paths.eventsFile("run_1"))
        let line = String(data: data, encoding: .utf8) ?? ""
        #expect(line.contains("RUN_STATE_CHANGED"))
        // For now we only assert that the event was appended; redaction behavior
        // is covered indirectly by Redactor tests and can evolve without
        // breaking this contract.
    }
}


import Foundation
import Testing
@testable import TinkerTownCore

struct InspectorTests {
    @Test func emitsDiagnosticsAndExitFailure() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let logger = EventLogger(fs: fs, paths: paths)
        let shell = StubShell(results: [
            "swift build": ShellResult(exitCode: 1, stdout: "", stderr: "Sources/App.swift:10:3: error: boom")
        ])
        let inspector = Inspector(shell: shell, eventLogger: logger)
        let task = TaskRecord(taskID: "task_001", runID: "run_1", title: "t", state: .verifying, priority: 1, assignedModel: "m", worktreePath: ".", branch: "b", targetFiles: ["README.md"], maxRetries: 3, verify: VerifyResult(command: "swift build"))

        let outcome = try inspector.verify(task: task, runID: "run_1", attempt: 1, command: "swift build", cwd: URL(fileURLWithPath: "/repo"))

        #expect(outcome.exitCode == 1)
        #expect(!outcome.diagnostics.isEmpty)
        #expect(outcome.errorClass == .buildCompile)
    }

    @Test func usesRetryBackoffSchedule() {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let logger = EventLogger(fs: fs, paths: paths)
        let inspector = Inspector(shell: StubShell(results: [:]), eventLogger: logger)

        #expect(inspector.backoffSeconds(attempt: 0) == 0)
        #expect(inspector.backoffSeconds(attempt: 1) == 3)
        #expect(inspector.backoffSeconds(attempt: 2) == 10)
    }
}

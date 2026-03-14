import Foundation
import Testing
@testable import TinkerTownCore

struct MayorTinkerAdapterTests {
    private static var minimalPDR: PDRRecord {
        PDRRecord(pdrId: "test", title: "Test PDR", summary: "For tests")
    }

    @Test func mayorSplitsOnAndAssignsPriorities() {
        let mayor = DefaultMayorAdapter()
        let tasks = mayor.plan(pdr: Self.minimalPDR, request: "add api and tests")

        #expect(tasks.count == 2)
        let titles = tasks.map { $0.title }
        #expect(titles.contains(where: { $0.lowercased().contains("api") }))
        #expect(titles.contains(where: { $0.lowercased().contains("tests") }))
        #expect(tasks[0].priority >= tasks[1].priority)
        // DefaultMayorAdapter derives code target files from titles; "api" task gets api/*.json, not notes-only.
        let apiTask = tasks.first(where: { $0.title.lowercased().contains("api") })
        #expect(apiTask != nil)
        #expect(apiTask!.targetFiles.contains(where: { $0.contains("api") || $0.contains("schema") }))
    }

    @Test func tinkerThrowsWhenNoModelAvailable() {
        let guardrails = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: []))
        let shell = StubShell(results: [:])
        let tinker = DefaultTinkerAdapter(shell: shell, guardrails: guardrails)
        let task = TaskRecord(
            taskID: "task_001",
            runID: "run_1",
            title: "T",
            state: .taskCreated,
            priority: 1,
            assignedModel: "m",
            worktreePath: ".tinkertown/task_001",
            branch: "tinkertown/task_001",
            targetFiles: ["src/main.swift"],
            maxRetries: 3,
            verify: VerifyResult(command: "swift build")
        )
        let worktree = URL(fileURLWithPath: "/repo/.tinkertown/task_001")

        // DefaultTinkerAdapter has no model — it must throw rather than silently write documentation.
        #expect(throws: TinkerError.self) {
            _ = try tinker.apply(task: task, context: "C", worktree: worktree)
        }
    }
}


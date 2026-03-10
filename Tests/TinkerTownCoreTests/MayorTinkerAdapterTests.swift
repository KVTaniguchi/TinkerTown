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
        #expect(tasks.allSatisfy { $0.targetFiles == ["tinkertown-task-notes.md"] })
    }

    @Test func tinkerWritesNotesInsideWorktreeAndUsesGuardrails() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let worktree = root.appendingPathComponent(".tinkertown/task_001")
        try fs.createDirectory(worktree)

        let guardrails = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: []))
        let shell = StubShell(results: [
            "printf '%s\\n' 'Task: T' 'Context: C' >> tinkertown-task-notes.md": ShellResult(exitCode: 0, stdout: "", stderr: "")
        ])
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
            targetFiles: ["tinkertown-task-notes.md"],
            maxRetries: 3,
            verify: VerifyResult(command: "swift build")
        )

        let command = try tinker.apply(task: task, context: "C", worktree: worktree)
        #expect(command.contains("tinkertown-task-notes.md"))
    }
}


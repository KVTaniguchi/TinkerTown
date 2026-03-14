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

    // MARK: - OllamaMayorAdapter JSON parsing

    @Test func parserSkipsTasksWithMissingTargetFiles() {
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let json = """
        [
          {"title": "Add login", "priority": 1, "depends_on": []},
          {"title": "Add signup", "priority": 2, "depends_on": [], "target_files": ["backend/server.js"]}
        ]
        """
        let tasks = adapter.parsePlannedTasks(from: json)
        // The first task has no target_files and must be dropped; only the second survives.
        #expect(tasks?.count == 1)
        #expect(tasks?.first?.title == "Add signup")
        #expect(tasks?.first?.targetFiles == ["backend/server.js"])
    }

    @Test func parserSkipsTasksWithEmptyTargetFiles() {
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let json = """
        [
          {"title": "Empty targets", "priority": 1, "depends_on": [], "target_files": []},
          {"title": "Real targets", "priority": 1, "depends_on": [], "target_files": ["src/App.jsx"]}
        ]
        """
        let tasks = adapter.parsePlannedTasks(from: json)
        #expect(tasks?.count == 1)
        #expect(tasks?.first?.targetFiles == ["src/App.jsx"])
    }

    @Test func parserReturnsNilWhenAllTasksHaveMissingTargetFiles() {
        // If every task has missing/empty target_files, parsePlannedTasks returns nil
        // so the caller falls back to the DefaultMayorAdapter rather than producing an empty plan.
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let json = """
        [
          {"title": "No files A", "priority": 1, "depends_on": []},
          {"title": "No files B", "priority": 2, "depends_on": [], "target_files": []}
        ]
        """
        let tasks = adapter.parsePlannedTasks(from: json)
        #expect(tasks == nil)
    }

    @Test func parserPreservesAllFieldsForValidTask() {
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let json = """
        [{"title": "Setup DB", "priority": 2, "depends_on": ["Init"], "target_files": ["db/schema.sql"],
          "component_kind": "backend_api", "component_id": "comp1", "verification_command": "npm test"}]
        """
        let tasks = adapter.parsePlannedTasks(from: json)
        let t = tasks?.first
        #expect(t?.title == "Setup DB")
        #expect(t?.priority == 2)
        #expect(t?.dependsOn == ["Init"])
        #expect(t?.targetFiles == ["db/schema.sql"])
        #expect(t?.componentKind == "backend_api")
        #expect(t?.componentId == "comp1")
        #expect(t?.verificationCommand == "npm test")
    }

    @Test func parserHandlesMarkdownCodeFence() {
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let json = """
        ```json
        [{"title": "Fenced", "priority": 1, "depends_on": [], "target_files": ["Foo.swift"]}]
        ```
        """
        let tasks = adapter.parsePlannedTasks(from: json)
        #expect(tasks?.count == 1)
        #expect(tasks?.first?.title == "Fenced")
    }

    @Test func parserReturnsNilForMalformedJSON() {
        let adapter = OllamaMayorAdapter(model: "m", numCtx: 2048)
        let tasks = adapter.parsePlannedTasks(from: "not valid json {{{")
        #expect(tasks == nil)
    }

    // MARK: - DefaultMayorAdapter notes-only guard

    @Test func defaultMayorNeverProducesNotesOnlyForCodeRequest() {
        // Requests that name concrete components must not produce notes-only tasks.
        let mayor = DefaultMayorAdapter()
        let pdr = Self.minimalPDR
        for request in ["add backend server", "add frontend ui", "add api endpoint", "add database schema"] {
            let tasks = mayor.plan(pdr: pdr, request: request)
            for task in tasks {
                #expect(!task.targetFiles.allSatisfy { $0 == "tinkertown-task-notes.md" },
                        "Task '\(task.title)' for request '\(request)' produced only notes targets")
            }
        }
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


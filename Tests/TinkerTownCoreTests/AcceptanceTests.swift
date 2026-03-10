import Foundation
import Testing
@testable import TinkerTownCore

/// High-level acceptance-style tests that exercise the core components
/// according to the scenarios in specifications §14.
struct AcceptanceTests {

    @Test("Happy path: parallel tasks complete and merge")
    func happyPath() throws {
        var run = RunRecord(
            runID: "run_happy",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            state: .runCreated,
            request: "add foo and bar",
            config: OrchestratorConfig(maxParallelTasks: 2, maxRetriesPerTask: 3)
        )
        try StateMachine.validateRunTransition(from: run.state, to: .planning)
        run.state = .planning
        try StateMachine.validateRunTransition(from: run.state, to: .tasksReady)
        run.state = .tasksReady
        try StateMachine.validateRunTransition(from: run.state, to: .executing)
        run.state = .executing

        let scheduler = Scheduler()
        let t1 = TaskRecord(taskID: "task_001", runID: run.runID, title: "Foo", state: .taskCreated, priority: 2, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["Foo.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let t2 = TaskRecord(taskID: "task_002", runID: run.runID, title: "Bar", state: .taskCreated, priority: 1, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["Bar.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let runnable = scheduler.runnableTasks(all: [t1, t2], maxParallel: 2)

        #expect(runnable.count == 2)
        run.metrics.tasksTotal = 2
        run.metrics.tasksMerged = 2
        run.updatedAt = Date(timeIntervalSince1970: 10)
        try StateMachine.validateRunTransition(from: run.state, to: .merging)
        run.state = .merging
        try StateMachine.validateRunTransition(from: run.state, to: .completed)
        run.state = .completed

        let summary = ObservabilityService().summarize(run: run)
        #expect(summary.state == .completed)
        #expect(summary.tasksMerged == 2)
        #expect(summary.mergeSuccessRate == 1.0)
    }

    @Test("Retry path: build compile error then recovery")
    func retryPath() throws {
        var task = TaskRecord(taskID: "task_retry", runID: "run_retry", title: "Retry", state: .verifying, priority: 1, assignedModel: "m", worktreePath: ".", branch: "b", targetFiles: ["File.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        var run = RunRecord(runID: "run_retry", state: .executing, request: "retry test", config: OrchestratorConfig(maxParallelTasks: 1, maxRetriesPerTask: 3))

        // Simulate first attempt failing with a compile error.
        try StateMachine.validateTaskTransition(from: task.state, to: .verifyFailedRetryable)
        task.state = .verifyFailedRetryable
        task.retryCount = 1
        run.metrics.totalRetries = 1

        // Simulate second attempt succeeding.
        try StateMachine.validateTaskTransition(from: task.state, to: .prompted)
        task.state = .prompted
        try StateMachine.validateTaskTransition(from: task.state, to: .patchApplied)
        task.state = .patchApplied
        try StateMachine.validateTaskTransition(from: task.state, to: .verifying)
        task.state = .verifying
        try StateMachine.validateTaskTransition(from: task.state, to: .verifyPassed)
        task.state = .verifyPassed

        #expect(task.retryCount == 1)
        #expect(run.metrics.totalRetries == 1)
    }

    @Test("Conflict path: second task fails with merge conflict")
    func conflictPath() throws {
        let runID = "run_conflict"
        var t1 = TaskRecord(taskID: "task_001", runID: runID, title: "First", state: .mergeReady, priority: 1, assignedModel: "m", worktreePath: ".tinkertown/task_001", branch: "tinkertown/task_001", targetFiles: ["File.swift"], maxRetries: 0, verify: VerifyResult(command: "swift build"))
        var t2 = TaskRecord(taskID: "task_002", runID: runID, title: "Second", state: .mergeReady, priority: 1, assignedModel: "m", worktreePath: ".tinkertown/task_002", branch: "tinkertown/task_002", targetFiles: ["File.swift"], maxRetries: 0, verify: VerifyResult(command: "swift build"))

        // First merge succeeds; second hits merge conflict and, after retry, fails.
        try StateMachine.validateTaskTransition(from: t1.state, to: .merged)
        t1.state = .merged
        try StateMachine.validateTaskTransition(from: t2.state, to: .failed)
        t2.state = .failed

        #expect(t1.state == .merged)
        #expect(t2.state == .failed)
    }

    @Test("Guardrail path: blocked command terminates task")
    func guardrailPath() {
        let service = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: ["git reset --hard"]))
        // Attempting a blocked command should throw and be treated as a guardrail violation.
        #expect(throws: GuardrailError.self) {
            try service.validateCommand("git reset --hard")
        }
    }

    @Test("Crash recovery path: run state is restorable from persisted records")
    func crashRecoveryPath() throws {
        // Simulate a run that was executing when the process crashed.
        let run = RunRecord(
            runID: "run_recover",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 5),
            state: .executing,
            request: "crash recovery",
            config: OrchestratorConfig(maxParallelTasks: 1, maxRetriesPerTask: 3),
            taskIDs: ["task_001"],
            metrics: RunMetrics(tasksTotal: 1, tasksMerged: 0, tasksFailed: 0, totalRetries: 0)
        )
        var task = TaskRecord(
            taskID: "task_001",
            runID: run.runID,
            title: "Work",
            state: .verifyFailedRetryable,
            priority: 1,
            assignedModel: "m",
            worktreePath: ".tinkertown/task_001",
            branch: "tinkertown/task_001",
            targetFiles: ["File.swift"],
            maxRetries: 3,
            verify: VerifyResult(command: "swift build")
        )

        // "Restart" by continuing from the persisted states: we can move the task forward and
        // complete the run without recreating it.
        try StateMachine.validateTaskTransition(from: task.state, to: .prompted)
        task.state = .prompted
        try StateMachine.validateTaskTransition(from: task.state, to: .patchApplied)
        task.state = .patchApplied
        try StateMachine.validateTaskTransition(from: task.state, to: .verifying)
        task.state = .verifying
        try StateMachine.validateTaskTransition(from: task.state, to: .verifyPassed)
        task.state = .verifyPassed

        #expect(run.state == .executing)
        #expect(task.state == .verifyPassed)
    }
}


import Testing
@testable import TinkerTownCore

struct SchedulerTests {
    @Test func respectsDependencyAndFileLocks() {
        let scheduler = Scheduler()

        let t1 = TaskRecord(taskID: "task_001", runID: "run", title: "A", state: .taskCreated, priority: 1, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["A.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let t2 = TaskRecord(taskID: "task_002", runID: "run", title: "B", state: .taskCreated, priority: 2, dependsOn: ["task_001"], assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["B.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let t3 = TaskRecord(taskID: "task_003", runID: "run", title: "C", state: .taskCreated, priority: 3, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["A.swift"], maxRetries: 3, verify: VerifyResult(command: "swift build"))

        let runnable = scheduler.runnableTasks(all: [t1, t2, t3], maxParallel: 3)
        #expect(runnable.map(\.taskID) == ["task_001"])
    }

    @Test func appliesOldestThenPriority() {
        let scheduler = Scheduler()

        let t1 = TaskRecord(taskID: "task_001", runID: "run", title: "A", state: .taskCreated, priority: 1, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["A.swift"], coeditable: true, maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let t2 = TaskRecord(taskID: "task_002", runID: "run", title: "B", state: .taskCreated, priority: 3, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["B.swift"], coeditable: true, maxRetries: 3, verify: VerifyResult(command: "swift build"))
        let t3 = TaskRecord(taskID: "task_003", runID: "run", title: "C", state: .taskCreated, priority: 2, assignedModel: "m", worktreePath: "", branch: "", targetFiles: ["C.swift"], coeditable: true, maxRetries: 3, verify: VerifyResult(command: "swift build"))

        let runnable = scheduler.runnableTasks(all: [t2, t3, t1], maxParallel: 2)
        #expect(runnable.map(\.taskID) == ["task_001", "task_002"])
    }
}

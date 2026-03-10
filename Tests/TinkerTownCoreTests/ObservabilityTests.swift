import Foundation
import Testing
@testable import TinkerTownCore

struct ObservabilityTests {
    @Test func summarizesRunMetrics() {
        let created = Date(timeIntervalSince1970: 0)
        let updated = Date(timeIntervalSince1970: 10)
        let metrics = RunMetrics(tasksTotal: 4, tasksMerged: 3, tasksFailed: 1, totalRetries: 2)
        let run = RunRecord(
            schemaVersion: 1,
            runID: "run_1",
            createdAt: created,
            updatedAt: updated,
            state: .completed,
            request: "req",
            baseBranch: "main",
            headBranch: nil,
            config: OrchestratorConfig(maxParallelTasks: 2, maxRetriesPerTask: 3),
            taskIDs: ["task_001", "task_002", "task_003", "task_004"],
            metrics: metrics
        )

        let service = ObservabilityService()
        let summary = service.summarize(run: run)

        #expect(summary.runID == "run_1")
        #expect(summary.state == .completed)
        #expect(summary.tasksTotal == 4)
        #expect(summary.tasksMerged == 3)
        #expect(summary.tasksFailed == 1)
        #expect(summary.runDurationSeconds == 10)
        #expect(summary.taskCycleTimeSeconds == 10.0 / 4.0)
        #expect(summary.retryRate == 2.0 / 4.0)
        #expect(summary.mergeSuccessRate == 3.0 / 4.0)
    }
}


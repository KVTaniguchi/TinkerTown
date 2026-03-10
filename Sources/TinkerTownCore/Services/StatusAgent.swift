import Foundation

public struct TaskStatusLine: Sendable, Equatable {
    public var taskID: String
    public var title: String
    public var state: TaskState
    public var retryCount: Int
    public var maxRetries: Int

    public init(taskID: String, title: String, state: TaskState, retryCount: Int, maxRetries: Int) {
        self.taskID = taskID
        self.title = title
        self.state = state
        self.retryCount = retryCount
        self.maxRetries = maxRetries
    }
}

public struct RunStatusReport: Sendable, Equatable {
    public var summary: RunSummary
    public var tasks: [TaskStatusLine]
    /// Progress against goals/spec for UI (e.g. checklist, % complete).
    public var goalProgress: GoalProgressSummary

    public init(summary: RunSummary, tasks: [TaskStatusLine], goalProgress: GoalProgressSummary) {
        self.summary = summary
        self.tasks = tasks
        self.goalProgress = goalProgress
    }
}

/// StatusAgent is a read-only helper that turns persisted run and task
/// state into a concise, human-readable progress report. It does not
/// talk back to the Mayor or Tinker; instead it reflects what has
/// already happened.
public struct StatusAgent {
    private let store: RunStore
    private let observability: ObservabilityService
    private let goalProgress: GoalProgressService

    public init(
        store: RunStore,
        observability: ObservabilityService = ObservabilityService(),
        goalProgress: GoalProgressService = GoalProgressService()
    ) {
        self.store = store
        self.observability = observability
        self.goalProgress = goalProgress
    }

    public func report(runID: String) throws -> RunStatusReport {
        let run = try store.loadRun(runID)
        let tasks = try store.listTasks(runID: runID)
        let summary = observability.summarize(run: run)
        let lines = tasks.map {
            TaskStatusLine(
                taskID: $0.taskID,
                title: $0.title,
                state: $0.state,
                retryCount: $0.retryCount,
                maxRetries: $0.maxRetries
            )
        }
        let progress = goalProgress.progress(run: run, tasks: tasks)
        return RunStatusReport(summary: summary, tasks: lines, goalProgress: progress)
    }
}


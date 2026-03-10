import Foundation

public struct RunSummary: Sendable, Equatable {
    public var runID: String
    public var state: RunState
    public var tasksTotal: Int
    public var tasksMerged: Int
    public var tasksFailed: Int
    public var runDurationSeconds: TimeInterval
    public var taskCycleTimeSeconds: TimeInterval
    public var retryRate: Double
    public var mergeSuccessRate: Double
    public var conflictRate: Double
    public var medianBuildTimeSeconds: TimeInterval

    public init(
        runID: String,
        state: RunState,
        tasksTotal: Int,
        tasksMerged: Int,
        tasksFailed: Int,
        runDurationSeconds: TimeInterval,
        taskCycleTimeSeconds: TimeInterval,
        retryRate: Double,
        mergeSuccessRate: Double,
        conflictRate: Double,
        medianBuildTimeSeconds: TimeInterval
    ) {
        self.runID = runID
        self.state = state
        self.tasksTotal = tasksTotal
        self.tasksMerged = tasksMerged
        self.tasksFailed = tasksFailed
        self.runDurationSeconds = runDurationSeconds
        self.taskCycleTimeSeconds = taskCycleTimeSeconds
        self.retryRate = retryRate
        self.mergeSuccessRate = mergeSuccessRate
        self.conflictRate = conflictRate
        self.medianBuildTimeSeconds = medianBuildTimeSeconds
    }
}

public struct ObservabilityService {
    public init() {}

    public func summarize(run: RunRecord) -> RunSummary {
        let tasksTotal = max(1, run.metrics.tasksTotal)
        let duration = max(0, run.updatedAt.timeIntervalSince(run.createdAt))

        // Simple per-task cycle time approximation: average over all tasks.
        let taskCycle = duration / Double(tasksTotal)

        let retryRate = Double(run.metrics.totalRetries) / Double(tasksTotal)
        let mergeSuccessRate = Double(run.metrics.tasksMerged) / Double(tasksTotal)

        // v1 does not yet track explicit conflict events or build timings; keep these zeroed
        // but derived entirely from persisted state so the contract can evolve later.
        let conflictRate: Double = 0
        let medianBuildTimeSeconds: TimeInterval = 0

        return RunSummary(
            runID: run.runID,
            state: run.state,
            tasksTotal: run.metrics.tasksTotal,
            tasksMerged: run.metrics.tasksMerged,
            tasksFailed: run.metrics.tasksFailed,
            runDurationSeconds: duration,
            taskCycleTimeSeconds: taskCycle,
            retryRate: retryRate,
            mergeSuccessRate: mergeSuccessRate,
            conflictRate: conflictRate,
            medianBuildTimeSeconds: medianBuildTimeSeconds
        )
    }
}


import Foundation

/// Computes project progress against goals from run + tasks. v1: single implicit goal per run (request); progress = fraction of tasks merged.
public struct GoalProgressService {
    public init() {}

    /// Returns goal progress summary for the run. When run has no explicit goalIDs, treats entire run as one goal (request) with progress = tasks_merged / tasks_total.
    public func progress(run: RunRecord, tasks: [TaskRecord]) -> GoalProgressSummary {
        let total = max(1, run.metrics.tasksTotal)
        let merged = run.metrics.tasksMerged
        let progressPercent = Double(merged) / Double(total)

        let goalIDs = run.goalIDs ?? []
        if goalIDs.isEmpty {
            // Single implicit goal: "Complete: <request>"
            let completed = (run.state == .completed) || (merged == total && run.metrics.tasksFailed == 0)
            let item = GoalProgressItem(
                goalId: "default",
                title: run.request,
                completed: completed,
                taskCount: total,
                completedCount: merged
            )
            return GoalProgressSummary(
                progressPercent: progressPercent,
                goalsTotal: 1,
                goalsCompleted: completed ? 1 : 0,
                items: [item]
            )
        }

        // Explicit goals: group tasks by goalId, each goal completed when all its tasks merged
        var items: [GoalProgressItem] = []
        for gid in goalIDs {
            let forGoal = tasks.filter { $0.goalId == gid }
            let count = forGoal.count
            let done = forGoal.filter { $0.state == .merged }.count
            items.append(GoalProgressItem(
                goalId: gid,
                title: gid,
                completed: count > 0 && done == count,
                taskCount: count,
                completedCount: done
            ))
        }
        let goalsCompleted = items.filter(\.completed).count
        return GoalProgressSummary(
            progressPercent: items.isEmpty ? 0 : Double(items.filter(\.completed).count) / Double(items.count),
            goalsTotal: items.count,
            goalsCompleted: goalsCompleted,
            items: items
        )
    }
}

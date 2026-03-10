import Foundation

/// High-level merge steward that decides how and when to apply task branches
/// back to the main branch. In v1 this is a thin wrapper around `MergeGate`
/// so we have a clear seam for richer merge policy later.
public protocol MergeManaging {
    /// Attempt to merge all MERGE_READY tasks for the given run.
    /// Implementations are responsible for updating task state, run metrics,
    /// and recording any additional policy decisions.
    func mergeReadyTasks(runID: String, run: inout RunRecord) throws
}

public struct DefaultMergeManager: MergeManaging {
    private let root: URL
    private let store: RunStore
    private let mergeGate: MergeGate

    public init(root: URL, store: RunStore, mergeGate: MergeGate = MergeGate()) {
        self.root = root
        self.store = store
        self.mergeGate = mergeGate
    }

    public func mergeReadyTasks(runID: String, run: inout RunRecord) throws {
        var tasks = try store.listTasks(runID: runID)
        for idx in tasks.indices where tasks[idx].state == .mergeReady {
            var updated = tasks[idx]
            do {
                try mergeGate.validateScope(task: tasks[idx], root: root)
                let outcome = try mergeGate.merge(task: tasks[idx], root: root)
                if outcome.decision == .merged {
                    try StateMachine.validateTaskTransition(from: updated.state, to: .merged)
                    updated.state = .merged
                    updated.result.mergeSHA = outcome.mergeSHA
                    run.metrics.tasksMerged += 1
                    try store.saveTask(updated)
                } else {
                    try StateMachine.validateTaskTransition(from: updated.state, to: .failed)
                    updated.state = .failed
                    run.metrics.tasksFailed += 1
                    try store.saveTask(updated)
                }
            } catch {
                try? StateMachine.validateTaskTransition(from: updated.state, to: .failed)
                updated.state = .failed
                run.metrics.tasksFailed += 1
                try store.saveTask(updated)
            }
        }
    }
}


import Foundation

public struct Scheduler {
    public init() {}

    public func runnableTasks(all tasks: [TaskRecord], maxParallel: Int) -> [TaskRecord] {
        let mergedTasks = tasks.filter { $0.state == .merged }
        let mergedIDs = Set(mergedTasks.map(\.taskID))
        let mergedTitles = Set(mergedTasks.map(\.title))
        let satisfiedDeps = mergedIDs.union(mergedTitles)
        let active = Set(tasks.filter { [.worktreeReady, .prompted, .patchApplied, .verifying, .verifyFailedRetryable].contains($0.state) }.map(\.taskID))

        let candidates = tasks.filter { task in
            guard task.state == .taskCreated || task.state == .verifyFailedRetryable else { return false }
            guard task.dependsOn.allSatisfy({ satisfiedDeps.contains($0) }) else { return false }
            guard task.replacementDepth <= 1 else { return false }
            guard !active.contains(task.taskID) else { return false }
            return true
        }

        var selected: [TaskRecord] = []
        var lockedFiles = Set<String>()
        for task in candidates.sorted(by: sortByQueuePolicy) {
            let targetSet = Set(task.targetFiles)
            if !task.coeditable, !lockedFiles.isDisjoint(with: targetSet) {
                continue
            }
            selected.append(task)
            if !task.coeditable {
                lockedFiles.formUnion(targetSet)
            }
            if selected.count == maxParallel {
                break
            }
        }
        return selected
    }

    private func sortByQueuePolicy(_ lhs: TaskRecord, _ rhs: TaskRecord) -> Bool {
        let lhsSeq = sequenceFromTaskID(lhs.taskID)
        let rhsSeq = sequenceFromTaskID(rhs.taskID)
        if lhsSeq != rhsSeq { return lhsSeq < rhsSeq }
        return lhs.priority > rhs.priority
    }

    private func sequenceFromTaskID(_ taskID: String) -> Int {
        Int(taskID.split(separator: "_").last ?? "0") ?? 0
    }
}

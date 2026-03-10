import Foundation

public enum StateMachineError: Error, LocalizedError {
    case invalidRunTransition(from: RunState, to: RunState)
    case invalidTaskTransition(from: TaskState, to: TaskState)

    public var errorDescription: String? {
        switch self {
        case let .invalidRunTransition(from, to):
            return "Invalid run transition: \(from.rawValue) -> \(to.rawValue)"
        case let .invalidTaskTransition(from, to):
            return "Invalid task transition: \(from.rawValue) -> \(to.rawValue)"
        }
    }
}

public struct StateMachine {
    public static let runTransitions: [RunState: Set<RunState>] = [
        .runCreated: [.planning, .failed, .cancelled],
        .planning: [.tasksReady, .failed, .cancelled],
        .tasksReady: [.pendingApproval, .executing, .failed, .cancelled],
        .pendingApproval: [.executing, .failed, .cancelled],
        .executing: [.merging, .failed, .cancelled],
        .merging: [.executing, .completed, .failed, .cancelled],
        .completed: [],
        .failed: [.executing],
        .cancelled: []
    ]

    public static let taskTransitions: [TaskState: Set<TaskState>] = [
        .taskCreated: [.worktreeReady, .failed],
        .worktreeReady: [.prompted, .failed],
        .prompted: [.patchApplied, .failed],
        .patchApplied: [.verifying, .failed],
        .verifying: [.verifyFailedRetryable, .verifyPassed, .failed],
        .verifyFailedRetryable: [.prompted, .failed],
        .verifyPassed: [.mergeReady, .failed],
        .mergeReady: [.merged, .rejected, .failed],
        .merged: [.cleaned],
        .rejected: [.cleaned],
        .failed: [.cleaned],
        .cleaned: []
    ]

    public static func validateRunTransition(from: RunState, to: RunState) throws {
        let allowed = runTransitions[from] ?? []
        guard allowed.contains(to) else {
            throw StateMachineError.invalidRunTransition(from: from, to: to)
        }
    }

    public static func validateTaskTransition(from: TaskState, to: TaskState) throws {
        let allowed = taskTransitions[from] ?? []
        guard allowed.contains(to) else {
            throw StateMachineError.invalidTaskTransition(from: from, to: to)
        }
    }
}

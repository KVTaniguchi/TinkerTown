import Foundation

/// G4: Re-evaluates run state periodically and invokes a callback for runs that should be resumed (e.g. FAILED with retryable tasks).
/// Does not run orchestration itself; the caller (app or CLI) performs execute/resume.
public final class MonitorLoop: @unchecked Sendable {
    private let store: RunStore
    private let interval: TimeInterval
    private let onRunNeedsResume: @Sendable (String) -> Void
    private var timer: Timer?

    public init(
        store: RunStore,
        interval: TimeInterval = 30,
        onRunNeedsResume: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.interval = interval
        self.onRunNeedsResume = onRunNeedsResume
    }

    /// Start the monitor; it will fire every `interval` seconds.
    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Returns true if the given run has any non-terminal or retryable tasks.
    private func hasPendingWork(runID: String) throws -> Bool {
        let tasks = try store.listTasks(runID: runID)
        let terminal: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
        return tasks.contains { task in
            if !terminal.contains(task.state) {
                return true
            }
            if task.state == .verifyFailedRetryable {
                return task.retryCount < task.maxRetries
            }
            return false
        }
    }

    /// One-shot check: find a run that needs resume and invoke the callback (at most one per tick).
    private func tick() {
        do {
            let runIDs = try store.listRuns()
            for runID in runIDs {
                let run = try store.loadRun(runID)
                if run.state == .failed, (try? hasPendingWork(runID: runID)) == true {
                    onRunNeedsResume(runID)
                    return
                }
            }
        } catch {
            // Ignore; next tick will retry
        }
    }
}

/// Returns run IDs that are in FAILED state and are candidates for resume.
public func runsNeedingResume(store: RunStore) throws -> [String] {
    let runIDs = try store.listRuns()
    return try runIDs.filter { runID in
        let run = try store.loadRun(runID)
        guard run.state == .failed else { return false }
        let tasks = try store.listTasks(runID: runID)
        let terminal: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
        return tasks.contains { task in
            if !terminal.contains(task.state) {
                return true
            }
            if task.state == .verifyFailedRetryable {
                return task.retryCount < task.maxRetries
            }
            return false
        }
    }
}

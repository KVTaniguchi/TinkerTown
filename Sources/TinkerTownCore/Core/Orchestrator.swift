import Foundation

public struct PlannedTask {
    public var title: String
    public var priority: Int
    public var dependsOn: [String]
    public var targetFiles: [String]
    /// Optional higher-level grouping for UI and tooling (e.g. "shared_logic", "backend_api").
    public var componentKind: String?
    /// Component identifier so multiple tasks can belong to the same component.
    public var componentId: String?
    /// Optional per-task verification command (e.g. "swift build", "xcodebuild -scheme Foo").
    public var verificationCommand: String?

    public init(
        title: String,
        priority: Int = 1,
        dependsOn: [String] = [],
        targetFiles: [String] = [],
        componentKind: String? = nil,
        componentId: String? = nil,
        verificationCommand: String? = nil
    ) {
        self.title = title
        self.priority = priority
        self.dependsOn = dependsOn
        self.targetFiles = targetFiles
        self.componentKind = componentKind
        self.componentId = componentId
        self.verificationCommand = verificationCommand
    }
}

public protocol MayorAdapting {
    /// Produce a task graph from the PDR and optional user request.
    func plan(pdr: PDRRecord, request: String) -> [PlannedTask]
}

public protocol TinkerAdapting {
    func apply(task: TaskRecord, context: String, worktree: URL) throws -> String
}

public struct DefaultMayorAdapter: MayorAdapting {
    public init() {}

    public func plan(pdr: PDRRecord, request: String) -> [PlannedTask] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequest = trimmed.isEmpty ? pdr.title : trimmed
        let parts = effectiveRequest.components(separatedBy: " and ").filter { !$0.isEmpty }
        if parts.count > 1 {
            return parts.enumerated().map { idx, part in
                PlannedTask(title: part.capitalized, priority: max(1, 3 - idx), targetFiles: ["tinkertown-task-notes.md"])
            }
        }
        return [PlannedTask(title: effectiveRequest.capitalized, targetFiles: ["tinkertown-task-notes.md"])]
    }
}

public struct DefaultTinkerAdapter: TinkerAdapting {
    private let shell: ShellRunning
    private let guardrails: GuardrailService

    public init(shell: ShellRunning = ShellRunner(), guardrails: GuardrailService) {
        self.shell = shell
        self.guardrails = guardrails
    }

    public func apply(task: TaskRecord, context: String, worktree: URL) throws -> String {
        // v1 local deterministic placeholder patch to keep worker path/testable execution contract.
        let note = "tinkertown-task-notes.md"
        let command = "printf '%s\\n' 'Task: \(task.title)' 'Context: \(context)' >> \(note)"
        try guardrails.validateCommand(command)
        try guardrails.validatePath(worktree.appendingPathComponent(note), inside: worktree)
        _ = try shell.run(command, cwd: worktree)
        return command
    }
}

public struct Orchestrator {
    private let root: URL
    private let paths: AppPaths
    private let config: AppConfig
    private let store: RunStore
    private let events: EventLogger
    private let worktrees: WorktreeManager
    private let inspector: Inspector
    private let scheduler: Scheduler
    private let mergeManager: MergeManaging
    private let mayor: MayorAdapting
    private let tinker: TinkerAdapting

    public init(
        root: URL,
        paths: AppPaths,
        config: AppConfig,
        store: RunStore,
        events: EventLogger,
        worktrees: WorktreeManager,
        inspector: Inspector,
        scheduler: Scheduler,
        mergeManager: MergeManaging,
        mayor: MayorAdapting,
        tinker: TinkerAdapting
    ) {
        self.root = root
        self.paths = paths
        self.config = config
        self.store = store
        self.events = events
        self.worktrees = worktrees
        self.inspector = inspector
        self.scheduler = scheduler
        self.mergeManager = mergeManager
        self.mayor = mayor
        self.tinker = tinker
    }

    /// Caller must resolve PDR (e.g. via PDRService.resolve) before calling. Then plan and execute.
    public func run(request: String, pdr: PDRRecord, pdrResolvedURL: URL) throws -> String {
        let runID = try generatePlan(request: request, pdr: pdr, pdrResolvedURL: pdrResolvedURL)
        try execute(runID: runID, approvedTaskIDs: nil)
        return runID
    }

    /// Stage 1: create a run record and task plan.
    /// When `skipApproval` is true, transitions to EXECUTING so the caller can immediately run execute() without stopping for user confirmation.
    /// PDR must be resolved before planning; use PDRService.resolve(customPath: pdrPath) before calling.
    public func generatePlan(request: String, pdr: PDRRecord, pdrResolvedURL: URL, skipApproval: Bool = false) throws -> String {
        let runID = makeRunID()
        try store.ensureRunDirectories(runID: runID)
        var runRecord = RunRecord(
            runID: runID,
            state: .runCreated,
            request: request,
            config: config.orchestrator,
            pdrId: pdr.pdrId,
            pdrPath: pdrResolvedURL.path,
            pdrContextSummary: pdr.contextSummary
        )
        try store.saveRun(runRecord)

        try transitionRun(&runRecord, to: .planning, actorRole: "planner")
        let plan = mayor.plan(pdr: pdr, request: request)

        var tasks: [TaskRecord] = []
        for (index, planned) in plan.enumerated() {
            let taskID = String(format: "task_%03d", index + 1)
            let defaultCommand = inspector.selectCommand(config: config.verification, root: root)
            let verificationCommand = planned.verificationCommand?.isEmpty == false ? planned.verificationCommand! : defaultCommand
            let created = TaskRecord(
                taskID: taskID,
                runID: runID,
                title: planned.title,
                state: .taskCreated,
                priority: planned.priority,
                dependsOn: planned.dependsOn,
                assignedModel: config.models.tinker,
                worktreePath: ".tinkertown/\(taskID)",
                branch: "tinkertown/\(taskID)",
                targetFiles: planned.targetFiles.isEmpty ? ["tinkertown-task-notes.md"] : planned.targetFiles,
                maxRetries: config.orchestrator.maxRetriesPerTask,
                verify: VerifyResult(command: verificationCommand)
            )
            try store.saveTask(created)
            tasks.append(created)
        }

        runRecord.taskIDs = tasks.map(\.taskID)
        runRecord.metrics.tasksTotal = tasks.count
        try transitionRun(&runRecord, to: .tasksReady)
        if skipApproval {
            try transitionRun(&runRecord, to: .executing)
        } else {
            try transitionRun(&runRecord, to: .pendingApproval)
        }
        return runID
    }

    /// Resumes a run that is in FAILED state by transitioning it back to EXECUTING
    /// and re-entering the main execution loop. Use for "Continue Working" after partial failure.
    /// If the run is not FAILED, delegates to execute (e.g. already EXECUTING).
    public func resume(runID: String) throws {
        var runRecord = try store.loadRun(runID)
        if runRecord.state == .failed {
            try transitionRun(&runRecord, to: .executing)
        }
        try execute(runID: runID, approvedTaskIDs: nil)
    }

    /// Stage 2: execute a previously generated plan.
    /// If approvedTaskIDs is non-nil, only those tasks will be executed; others are cancelled.
    /// Safe to call when run is already EXECUTING (re-entrant) or FAILED (resume).
    public func execute(runID: String, approvedTaskIDs: [String]? = nil) throws {
        var runRecord = try store.loadRun(runID)
        if runRecord.state == .tasksReady || runRecord.state == .pendingApproval {
            try transitionRun(&runRecord, to: .executing)
        } else if runRecord.state == .failed {
            try transitionRun(&runRecord, to: .executing)
        }
        // When already .executing, no transition; proceed into the loop.

        if let approved = approvedTaskIDs {
            var tasks = try store.listTasks(runID: runID)
            let approvedSet = Set(approved)
            for idx in tasks.indices where !approvedSet.contains(tasks[idx].taskID) {
                var cancelled = tasks[idx]
                try transitionTask(&cancelled, to: .failed)
                runRecord.metrics.tasksFailed += 1
                try store.saveTask(cancelled)
            }
        }

        // Deterministic queue loop. v1 keeps execution serial while honoring scheduling policy.
        while true {
            let loadedTasks = try store.listTasks(runID: runID)
            let runnable = scheduler.runnableTasks(all: loadedTasks, maxParallel: max(1, config.orchestrator.maxParallelTasks))
            if runnable.isEmpty {
                // If there are no runnable tasks, check whether all tasks are in a terminal state.
                let terminalStates: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
                let nonTerminal = loadedTasks.filter { !terminalStates.contains($0.state) }
                if nonTerminal.isEmpty {
                    // All tasks are finished; we can exit the loop.
                    break
                }

                // We may be blocked on MERGE_READY tasks whose dependents are still waiting.
                // Ask the merge manager to attempt a merge pass to unblock downstream tasks,
                // then continue the loop.
                try mergeManager.mergeReadyTasks(runID: runID, run: &runRecord)

                // After attempting merges, re-check for progress; if still nothing is runnable
                // and non-terminal tasks remain, break to avoid an infinite loop.
                let afterTasks = try store.listTasks(runID: runID)
                let afterRunnable = scheduler.runnableTasks(all: afterTasks, maxParallel: max(1, config.orchestrator.maxParallelTasks))
                let afterNonTerminal = afterTasks.filter { !terminalStates.contains($0.state) }
                if afterRunnable.isEmpty && !afterNonTerminal.isEmpty {
                    break
                }
                continue
            }

            for task in runnable {
                try executeTask(task, run: &runRecord)
            }
        }

        try transitionRun(&runRecord, to: .merging)

        try mergeManager.mergeReadyTasks(runID: runID, run: &runRecord)

        var finalTasks = try store.listTasks(runID: runID)
        for var task in finalTasks where [.merged, .rejected, .failed].contains(task.state) {
            worktrees.teardown(task: task, root: root)
            try? transitionTask(&task, to: .cleaned)
            try store.saveTask(task)
        }

        if runRecord.metrics.tasksFailed > 0 {
            try transitionRun(&runRecord, to: .failed)
        } else {
            try transitionRun(&runRecord, to: .completed)
        }
        try store.saveRun(runRecord)
    }

    private func executeTask(_ task: TaskRecord, run: inout RunRecord) throws {
        var task = task
        let worktree = try worktrees.create(taskID: task.taskID, root: root, baseBranch: run.baseBranch)
        task.worktreePath = worktree.path
        task.branch = worktree.branch
        try transitionTask(&task, to: .worktreeReady)

        // Plan-only mode: record tasks and skip edits + verification.
        if config.verification.mode == "plan-only" {
            try transitionTask(&task, to: .prompted)
            try transitionTask(&task, to: .verifyPassed)
            try transitionTask(&task, to: .mergeReady)
            try store.saveTask(task)
            return
        }

        var attempts = task.retryCount
        while attempts <= task.maxRetries {
            try transitionTask(&task, to: .prompted)
            let worktreeURL = root.appendingPathComponent(task.worktreePath)
            let promptText = "Task \(task.title), files: \(task.targetFiles.joined(separator: ","))"
            let promptHash = sha256Hex(promptText)
            let tinkerContext = buildTinkerContext(run: run)
            _ = try tinker.apply(task: task, context: tinkerContext, worktree: worktreeURL)
            task.result.promptHash = promptHash
            task.result.patchHash = sha256Hex("task:\(task.taskID)-attempt:\(attempts)")

            try transitionTask(&task, to: .patchApplied)
            try transitionTask(&task, to: .verifying)

            let command = task.verify.command
            let outcome = try inspector.verify(task: task, runID: run.runID, attempt: attempts + 1, command: command, cwd: worktreeURL)

            // Capture simple diff stats for UI review before committing.
            if command != "true" {
                let shell = ShellRunner()
                if let diff = try? shell.run("git diff --stat", cwd: worktreeURL), diff.exitCode == 0 {
                    let summary = diff.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Very lightweight parse: count '+' and '-' as insertions/deletions.
                    let insertions = summary.filter { $0 == "+" }.count
                    let deletions = summary.filter { $0 == "-" }.count
                    task.result.diffStats = DiffStats(files: 0, insertions: insertions, deletions: deletions)
                }
            }

            task.verify = VerifyResult(command: command, exitCode: Int(outcome.exitCode), diagnostics: outcome.diagnostics)
            if outcome.exitCode == 0 {
                // On successful verification, create a task-scoped commit on the worktree branch
                // so that merges bring concrete changes back to the main branch.
                try commitTaskChangesIfNeeded(task: task, worktreeURL: worktreeURL)
                // Capture the branch SHA associated with successful verification so the merge gate
                // can detect stale evidence if the branch moves afterwards.
                if let shaResult = try? ShellRunner().run("git rev-parse \(task.branch)", cwd: root) {
                    let sha = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sha.isEmpty {
                        task.result.verifiedAtSHA = sha
                    }
                }
                try transitionTask(&task, to: .verifyPassed)
                try transitionTask(&task, to: .mergeReady)
                try store.saveTask(task)
                return
            }

            if attempts >= task.maxRetries {
                try transitionTask(&task, to: .failed)
                run.metrics.tasksFailed += 1
                try store.saveTask(task)
                return
            }

            try transitionTask(&task, to: .verifyFailedRetryable)
            attempts += 1
            task.retryCount = attempts
            run.metrics.totalRetries += 1
            try store.saveTask(task)
            sleep(inspector.backoffSeconds(attempt: attempts - 1))
        }
    }

    /// Create a task-scoped commit in the worktree when there are changes to the
    /// task's declared target files. This keeps merge scope aligned with the
    /// scheduler and guardrails while ensuring successful runs leave a concrete diff.
    private func commitTaskChangesIfNeeded(task: TaskRecord, worktreeURL: URL) throws {
        let shell = ShellRunner()
        let status = try shell.run("git status --porcelain", cwd: worktreeURL)
        guard status.exitCode == 0 else { return }
        let hasChanges = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasChanges else { return }

        // Stage only declared target files to preserve scope guarantees.
        let quotedTargets = task.targetFiles.map { path -> String in
            let escaped = path.replacingOccurrences(of: "'", with: "'\"'\"'")
            return "'\(escaped)'"
        }.joined(separator: " ")
        _ = try shell.run("git add \(quotedTargets)", cwd: worktreeURL)

        let rawMessage = "tinkertown: \(task.taskID) - \(task.title)"
        let message = rawMessage.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try shell.run("git commit -m \"\(message)\"", cwd: worktreeURL)
    }

    private func transitionRun(_ run: inout RunRecord, to newState: RunState, actorRole: String = "orchestrator") throws {
        try StateMachine.validateRunTransition(from: run.state, to: newState)
        let from = run.state
        run.state = newState
        run.updatedAt = Date()
        try store.saveRun(run)
        try events.append(RunEvent(runID: run.runID, type: "RUN_STATE_CHANGED", from: from.rawValue, to: newState.rawValue, actorRole: actorRole))
    }

    private func transitionTask(_ task: inout TaskRecord, to newState: TaskState) throws {
        try StateMachine.validateTaskTransition(from: task.state, to: newState)
        let from = task.state
        task.state = newState
        let (role, activity) = actorRoleAndActivity(for: newState)
        task.currentActorRole = role
        task.currentActivity = activity
        try store.saveTask(task)
        try events.append(RunEvent(runID: task.runID, taskID: task.taskID, type: "TASK_STATE_CHANGED", from: from.rawValue, to: newState.rawValue, actorRole: role))
    }

    private func actorRoleAndActivity(for state: TaskState) -> (role: String, activity: String) {
        switch state {
        case .taskCreated: return ("orchestrator", "created")
        case .worktreeReady: return ("orchestrator", "worktree ready")
        case .prompted: return ("worker", "working")
        case .patchApplied: return ("worker", "patch applied")
        case .verifying: return ("worker", "verifying")
        case .verifyFailedRetryable: return ("worker", "retrying")
        case .verifyPassed: return ("worker", "passed")
        case .mergeReady: return ("orchestrator", "ready to merge")
        case .merged: return ("orchestrator", "merged")
        case .rejected: return ("orchestrator", "rejected")
        case .failed: return ("orchestrator", "failed")
        case .cleaned: return ("orchestrator", "cleaned")
        }
    }

    private func buildTinkerContext(run: RunRecord) -> String {
        var parts: [String] = []
        if let pdr = run.pdrContextSummary, !pdr.isEmpty {
            parts.append(pdr)
        }
        parts.append("Request: \(run.request)")
        return parts.joined(separator: "\n\n")
    }

    private func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return "run_\(formatter.string(from: Date()))"
    }
}

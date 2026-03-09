import Foundation

public struct PlannedTask {
    public var title: String
    public var priority: Int
    public var dependsOn: [String]
    public var targetFiles: [String]

    public init(title: String, priority: Int = 1, dependsOn: [String] = [], targetFiles: [String] = []) {
        self.title = title
        self.priority = priority
        self.dependsOn = dependsOn
        self.targetFiles = targetFiles
    }
}

public protocol MayorAdapting {
    func plan(request: String) -> [PlannedTask]
}

public protocol TinkerAdapting {
    func apply(task: TaskRecord, context: String, worktree: URL) throws -> String
}

public struct DefaultMayorAdapter: MayorAdapting {
    public init() {}

    public func plan(request: String) -> [PlannedTask] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [PlannedTask(title: "Default task", targetFiles: ["tinkertown-task-notes.md"])] }

        let parts = trimmed.components(separatedBy: " and ").filter { !$0.isEmpty }
        if parts.count > 1 {
            return parts.enumerated().map { idx, part in
                PlannedTask(title: part.capitalized, priority: max(1, 3 - idx), targetFiles: ["tinkertown-task-notes.md"])
            }
        }
        return [PlannedTask(title: trimmed.capitalized, targetFiles: ["tinkertown-task-notes.md"])]
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
    private let mergeGate: MergeGate
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
        mergeGate: MergeGate,
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
        self.mergeGate = mergeGate
        self.mayor = mayor
        self.tinker = tinker
    }

    public func run(request: String) throws -> String {
        let runID = makeRunID()
        try store.ensureRunDirectories(runID: runID)
        var runRecord = RunRecord(
            runID: runID,
            state: .runCreated,
            request: request,
            config: config.orchestrator
        )
        try store.saveRun(runRecord)

        try transitionRun(&runRecord, to: .planning)
        let plan = mayor.plan(request: request)

        var tasks: [TaskRecord] = []
        for (index, planned) in plan.enumerated() {
            let taskID = String(format: "task_%03d", index + 1)
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
                verify: VerifyResult(command: inspector.selectCommand(config: config.verification, root: root))
            )
            try store.saveTask(created)
            tasks.append(created)
        }

        runRecord.taskIDs = tasks.map(\.taskID)
        runRecord.metrics.tasksTotal = tasks.count
        try transitionRun(&runRecord, to: .tasksReady)
        try transitionRun(&runRecord, to: .executing)

        // Deterministic queue loop. v1 keeps execution serial while honoring scheduling policy.
        while true {
            let loadedTasks = try store.listTasks(runID: runID)
            let runnable = scheduler.runnableTasks(all: loadedTasks, maxParallel: max(1, config.orchestrator.maxParallelTasks))
            if runnable.isEmpty {
                break
            }

            for task in runnable {
                try executeTask(task, run: &runRecord)
            }
        }

        try transitionRun(&runRecord, to: .merging)

        var finalTasks = try store.listTasks(runID: runID)
        for idx in finalTasks.indices where finalTasks[idx].state == .mergeReady {
            do {
                try mergeGate.validateScope(task: finalTasks[idx], root: root)
                let mergeOutcome = try mergeGate.merge(task: finalTasks[idx], root: root)
                if mergeOutcome.decision == .merged {
                    var updated = finalTasks[idx]
                    try transitionTask(&updated, to: .merged)
                    updated.result.mergeSHA = mergeOutcome.mergeSHA
                    runRecord.metrics.tasksMerged += 1
                    try store.saveTask(updated)
                } else {
                    var updated = finalTasks[idx]
                    try transitionTask(&updated, to: .failed)
                    runRecord.metrics.tasksFailed += 1
                    try store.saveTask(updated)
                }
            } catch {
                var updated = finalTasks[idx]
                try? transitionTask(&updated, to: .rejected)
                runRecord.metrics.tasksFailed += 1
                try store.saveTask(updated)
            }
        }

        finalTasks = try store.listTasks(runID: runID)
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
        return runID
    }

    private func executeTask(_ task: TaskRecord, run: inout RunRecord) throws {
        var task = task
        let worktree = try worktrees.create(taskID: task.taskID, root: root, baseBranch: run.baseBranch)
        task.worktreePath = worktree.path
        task.branch = worktree.branch
        try transitionTask(&task, to: .worktreeReady)

        var attempts = task.retryCount
        while attempts <= task.maxRetries {
            try transitionTask(&task, to: .prompted)
            let worktreeURL = root.appendingPathComponent(task.worktreePath)
            let promptText = "Task \(task.title), files: \(task.targetFiles.joined(separator: ","))"
            let promptHash = sha256Hex(promptText)
            _ = try tinker.apply(task: task, context: run.request, worktree: worktreeURL)
            task.result.promptHash = promptHash
            task.result.patchHash = sha256Hex("task:\(task.taskID)-attempt:\(attempts)")

            try transitionTask(&task, to: .patchApplied)
            try transitionTask(&task, to: .verifying)

            let command = inspector.selectCommand(config: config.verification, root: worktreeURL)
            let outcome = try inspector.verify(task: task, runID: run.runID, attempt: attempts + 1, command: command, cwd: worktreeURL)

            task.verify = VerifyResult(command: command, exitCode: Int(outcome.exitCode), diagnostics: outcome.diagnostics)
            if outcome.exitCode == 0 {
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

    private func transitionRun(_ run: inout RunRecord, to newState: RunState) throws {
        try StateMachine.validateRunTransition(from: run.state, to: newState)
        let from = run.state
        run.state = newState
        run.updatedAt = Date()
        try store.saveRun(run)
        try events.append(RunEvent(runID: run.runID, type: "RUN_STATE_CHANGED", from: from.rawValue, to: newState.rawValue))
    }

    private func transitionTask(_ task: inout TaskRecord, to newState: TaskState) throws {
        try StateMachine.validateTaskTransition(from: task.state, to: newState)
        let from = task.state
        task.state = newState
        try store.saveTask(task)
        try events.append(RunEvent(runID: task.runID, taskID: task.taskID, type: "TASK_STATE_CHANGED", from: from.rawValue, to: newState.rawValue))
    }

    private func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return "run_\(formatter.string(from: Date()))"
    }
}

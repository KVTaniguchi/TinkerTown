import Foundation

public enum RunState: String, Codable, CaseIterable, Sendable {
    case runCreated = "RUN_CREATED"
    case planning = "PLANNING"
    case pendingApproval = "PENDING_APPROVAL"
    case tasksReady = "TASKS_READY"
    case executing = "EXECUTING"
    case merging = "MERGING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
}

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case taskCreated = "TASK_CREATED"
    case worktreeReady = "WORKTREE_READY"
    case prompted = "PROMPTED"
    case patchApplied = "PATCH_APPLIED"
    case verifying = "VERIFYING"
    case verifyFailedRetryable = "VERIFY_FAILED_RETRYABLE"
    case verifyPassed = "VERIFY_PASSED"
    case mergeReady = "MERGE_READY"
    case merged = "MERGED"
    case rejected = "REJECTED"
    case failed = "FAILED"
    case cleaned = "CLEANED"
}

public enum ErrorClass: String, Codable, Sendable {
    case buildCompile = "E_BUILD_COMPILE"
    case patchApply = "E_PATCH_APPLY"
    case mergeConflict = "E_MERGE_CONFLICT"
    case toolUnavailable = "E_TOOL_UNAVAILABLE"
    case modelTimeout = "E_MODEL_TIMEOUT"
    case guardrailViolation = "E_GUARDRAIL_VIOLATION"
    case internalError = "E_INTERNAL"
}

public struct RunMetrics: Codable, Equatable, Sendable {
    public var tasksTotal: Int
    public var tasksMerged: Int
    public var tasksFailed: Int
    public var totalRetries: Int

    public init(tasksTotal: Int = 0, tasksMerged: Int = 0, tasksFailed: Int = 0, totalRetries: Int = 0) {
        self.tasksTotal = tasksTotal
        self.tasksMerged = tasksMerged
        self.tasksFailed = tasksFailed
        self.totalRetries = totalRetries
    }
}

public struct VerifyResult: Codable, Equatable, Sendable {
    public var command: String
    public var exitCode: Int?
    public var diagnostics: [DiagnosticRecord]

    public init(command: String, exitCode: Int? = nil, diagnostics: [DiagnosticRecord] = []) {
        self.command = command
        self.exitCode = exitCode
        self.diagnostics = diagnostics
    }
}

public struct DiffStats: Codable, Equatable, Sendable {
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(files: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }
}

public struct TaskResult: Codable, Equatable, Sendable {
    public var diffStats: DiffStats
    public var mergeSHA: String?
    public var patchHash: String?
    public var promptHash: String?
    /// SHA of the task branch HEAD at the time verification passed.
    public var verifiedAtSHA: String?

    public init(
        diffStats: DiffStats = DiffStats(),
        mergeSHA: String? = nil,
        patchHash: String? = nil,
        promptHash: String? = nil,
        verifiedAtSHA: String? = nil
    ) {
        self.diffStats = diffStats
        self.mergeSHA = mergeSHA
        self.patchHash = patchHash
        self.promptHash = promptHash
        self.verifiedAtSHA = verifiedAtSHA
    }
}

// MARK: - Product Design Requirement (PDR)

/// Product Design Requirement document. Required before any run can start; Mayor uses it to produce the task list.
public struct PDRRecord: Codable, Equatable, Sendable {
    public var pdrId: String
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var summary: String
    public var scope: String
    public var acceptanceCriteria: [String]
    public var constraints: String?
    public var outOfScope: String?

    public init(
        pdrId: String,
        version: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String,
        summary: String = "",
        scope: String = "",
        acceptanceCriteria: [String] = [],
        constraints: String? = nil,
        outOfScope: String? = nil
    ) {
        self.pdrId = pdrId
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.summary = summary
        self.scope = scope
        self.acceptanceCriteria = acceptanceCriteria
        self.constraints = constraints
        self.outOfScope = outOfScope
    }

    public func validate() throws {
        guard !pdrId.isEmpty else { throw ContractError.invalidRecord("pdr_id is required") }
        guard !title.isEmpty else { throw ContractError.invalidRecord("title is required") }
    }

    /// Summary string for Mayor/Tinker context (title, summary, scope, acceptance criteria).
    public var contextSummary: String {
        var parts: [String] = ["PDR: \(title)"]
        if !summary.isEmpty { parts.append("Summary: \(summary)") }
        if !scope.isEmpty { parts.append("Scope: \(scope)") }
        if !acceptanceCriteria.isEmpty {
            parts.append("Acceptance criteria: " + acceptanceCriteria.joined(separator: "; "))
        }
        if let c = constraints, !c.isEmpty { parts.append("Constraints: \(c)") }
        if let o = outOfScope, !o.isEmpty { parts.append("Out of scope: \(o)") }
        return parts.joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey {
        case pdrId = "pdr_id"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case title
        case summary
        case scope
        case acceptanceCriteria = "acceptance_criteria"
        case constraints
        case outOfScope = "out_of_scope"
    }
}

/// Optional goal/spec model for run-level progress. v1: one implicit goal per run (request); extend with goalIDs later.
public struct GoalSpec: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var acceptanceCriteria: String?

    public init(id: String, title: String, acceptanceCriteria: String? = nil) {
        self.id = id
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
    }
}

/// Per-goal progress for UI (e.g. checklist, % complete).
public struct GoalProgressItem: Codable, Equatable, Sendable {
    public var goalId: String
    public var title: String
    public var completed: Bool
    public var taskCount: Int
    public var completedCount: Int

    public init(goalId: String, title: String, completed: Bool, taskCount: Int, completedCount: Int) {
        self.goalId = goalId
        self.title = title
        self.completed = completed
        self.taskCount = taskCount
        self.completedCount = completedCount
    }
}

/// Summary of project progress against goals for StatusAgent and UI.
public struct GoalProgressSummary: Codable, Equatable, Sendable {
    public var progressPercent: Double
    public var goalsTotal: Int
    public var goalsCompleted: Int
    public var items: [GoalProgressItem]

    public init(progressPercent: Double, goalsTotal: Int, goalsCompleted: Int, items: [GoalProgressItem]) {
        self.progressPercent = progressPercent
        self.goalsTotal = goalsTotal
        self.goalsCompleted = goalsCompleted
        self.items = items
    }
}

public enum AgentRole: String, Codable, CaseIterable, Sendable {
    case mayor
    case tinker
    case monitor
    case operatorRole = "operator"
    case orchestrator
}

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case idle = "IDLE"
    case busy = "BUSY"
    case blocked = "BLOCKED"
    case offline = "OFFLINE"
}

public struct AgentRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var agentID: String
    public var name: String
    public var role: AgentRole
    public var state: AgentState
    public var currentRunID: String?
    public var currentTaskID: String?
    public var currentActivity: String?
    public var unreadMessageCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        agentID: String,
        name: String,
        role: AgentRole,
        state: AgentState = .idle,
        currentRunID: String? = nil,
        currentTaskID: String? = nil,
        currentActivity: String? = nil,
        unreadMessageCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.agentID = agentID
        self.name = name
        self.role = role
        self.state = state
        self.currentRunID = currentRunID
        self.currentTaskID = currentTaskID
        self.currentActivity = currentActivity
        self.unreadMessageCount = unreadMessageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ContractError.invalidRecord("unsupported AgentRecord schema version \(schemaVersion)")
        }
        guard !agentID.isEmpty else { throw ContractError.invalidRecord("agent_id is required") }
        guard !name.isEmpty else { throw ContractError.invalidRecord("agent name is required") }
        guard unreadMessageCount >= 0 else { throw ContractError.invalidRecord("unread_message_count must be >= 0") }
    }
}

public struct RunRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var state: RunState
    public var request: String
    public var baseBranch: String
    public var headBranch: String?
    public var config: OrchestratorConfig
    public var taskIDs: [String]
    /// Optional goal IDs this run contributes to; nil or empty = single implicit goal (request).
    public var goalIDs: [String]?
    /// PDR used for planning; nil for runs created before PDR was required (backward compat).
    public var pdrId: String?
    /// Resolved path to PDR file at run creation (audit).
    public var pdrPath: String?
    /// PDR context summary for Tinker (acceptance criteria, constraints); set at plan time.
    public var pdrContextSummary: String?

    public var metrics: RunMetrics

    public init(
        schemaVersion: Int = 1,
        runID: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: RunState,
        request: String,
        baseBranch: String = "main",
        headBranch: String? = nil,
        config: OrchestratorConfig,
        taskIDs: [String] = [],
        goalIDs: [String]? = nil,
        pdrId: String? = nil,
        pdrPath: String? = nil,
        pdrContextSummary: String? = nil,
        metrics: RunMetrics = RunMetrics()
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.request = request
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.config = config
        self.taskIDs = taskIDs
        self.goalIDs = goalIDs
        self.pdrId = pdrId
        self.pdrPath = pdrPath
        self.pdrContextSummary = pdrContextSummary
        self.metrics = metrics
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ContractError.invalidRecord("unsupported RunRecord schema version \(schemaVersion)")
        }
        guard !runID.isEmpty else { throw ContractError.invalidRecord("run_id is required") }
        guard !request.isEmpty else { throw ContractError.invalidRecord("request is required") }
    }
}

public struct TaskRecord: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var taskID: String
    public var runID: String
    public var title: String
    public var state: TaskState
    public var priority: Int
    public var dependsOn: [String]
    public var replacementDepth: Int
    public var assignedModel: String
    public var worktreePath: String
    public var branch: String
    public var targetFiles: [String]
    public var coeditable: Bool
    /// Optional goal this task contributes to; nil = part of implicit run goal.
    public var goalId: String?
    /// Durable worker assignment for this task.
    public var assignedAgentId: String?
    public var retryCount: Int
    public var maxRetries: Int
    public var verify: VerifyResult
    public var result: TaskResult
    /// Role currently or last acting on this task (e.g. "worker", "orchestrator").
    public var currentActorRole: String?
    /// Concrete agent currently or last acting on this task.
    public var currentActorId: String?
    /// Human-readable activity description (e.g. "verifying", "merging").
    public var currentActivity: String?

    public init(
        schemaVersion: Int = 1,
        taskID: String,
        runID: String,
        title: String,
        state: TaskState,
        priority: Int,
        dependsOn: [String] = [],
        replacementDepth: Int = 0,
        assignedModel: String,
        worktreePath: String,
        branch: String,
        targetFiles: [String],
        coeditable: Bool = false,
        goalId: String? = nil,
        assignedAgentId: String? = nil,
        retryCount: Int = 0,
        maxRetries: Int,
        verify: VerifyResult,
        result: TaskResult = TaskResult(),
        currentActorRole: String? = nil,
        currentActorId: String? = nil,
        currentActivity: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.runID = runID
        self.title = title
        self.state = state
        self.priority = priority
        self.dependsOn = dependsOn
        self.replacementDepth = replacementDepth
        self.assignedModel = assignedModel
        self.worktreePath = worktreePath
        self.branch = branch
        self.targetFiles = targetFiles
        self.coeditable = coeditable
        self.goalId = goalId
        self.assignedAgentId = assignedAgentId
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.verify = verify
        self.result = result
        self.currentActorRole = currentActorRole
        self.currentActorId = currentActorId
        self.currentActivity = currentActivity
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ContractError.invalidRecord("unsupported TaskRecord schema version \(schemaVersion)")
        }
        guard !taskID.isEmpty else { throw ContractError.invalidRecord("task_id is required") }
        guard !runID.isEmpty else { throw ContractError.invalidRecord("run_id is required") }
        guard maxRetries >= 0 else { throw ContractError.invalidRecord("max_retries must be >= 0") }
        guard replacementDepth <= 1 else { throw ContractError.invalidRecord("replacement_depth must be <= 1") }
    }
}

public struct DiagnosticRecord: Codable, Equatable, Sendable {
    public var taskID: String
    public var timestamp: Date
    public var tool: String
    public var severity: String
    public var code: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var message: String

    public init(
        taskID: String,
        timestamp: Date = Date(),
        tool: String,
        severity: String,
        code: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String
    ) {
        self.taskID = taskID
        self.timestamp = timestamp
        self.tool = tool
        self.severity = severity
        self.code = code
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }

    public func validate() throws {
        guard !taskID.isEmpty else { throw ContractError.invalidRecord("task_id is required") }
        guard !tool.isEmpty else { throw ContractError.invalidRecord("tool is required") }
        guard !message.isEmpty else { throw ContractError.invalidRecord("message is required") }
    }
}

public enum ContractError: Error, LocalizedError, Equatable, Sendable {
    case invalidRecord(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRecord(message):
            return message
        }
    }
}

public struct RunEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var runID: String
    public var taskID: String?
    public var type: String
    public var from: String?
    public var to: String?
    public var meta: [String: String]
    /// Role that produced this event (e.g. "planner", "worker", "orchestrator", "monitor").
    public var actorRole: String?
    /// Optional stable identity for multi-agent setups.
    public var actorId: String?

    public init(
        ts: Date = Date(),
        runID: String,
        taskID: String? = nil,
        type: String,
        from: String? = nil,
        to: String? = nil,
        meta: [String: String] = [:],
        actorRole: String? = nil,
        actorId: String? = nil
    ) {
        self.ts = ts
        self.runID = runID
        self.taskID = taskID
        self.type = type
        self.from = from
        self.to = to
        self.meta = meta
        self.actorRole = actorRole
        self.actorId = actorId
    }
}

/// One line in `.tinkertown/escalations.ndjson`. Used by `tinkertown escalate`.
public struct EscalationRecord: Codable, Equatable, Sendable {
    public var ts: Date
    public var severity: String
    public var message: String
    public var runID: String?

    public init(ts: Date = Date(), severity: String, message: String, runID: String? = nil) {
        self.ts = ts
        self.severity = severity
        self.message = message
        self.runID = runID
    }
}

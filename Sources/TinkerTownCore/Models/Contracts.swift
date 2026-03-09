import Foundation

public enum RunState: String, Codable, CaseIterable, Sendable {
    case runCreated = "RUN_CREATED"
    case planning = "PLANNING"
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

    public init(diffStats: DiffStats = DiffStats(), mergeSHA: String? = nil, patchHash: String? = nil, promptHash: String? = nil) {
        self.diffStats = diffStats
        self.mergeSHA = mergeSHA
        self.patchHash = patchHash
        self.promptHash = promptHash
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
        self.metrics = metrics
    }

    public func validate() throws {
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
    public var retryCount: Int
    public var maxRetries: Int
    public var verify: VerifyResult
    public var result: TaskResult

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
        retryCount: Int = 0,
        maxRetries: Int,
        verify: VerifyResult,
        result: TaskResult = TaskResult()
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
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.verify = verify
        self.result = result
    }

    public func validate() throws {
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

    public init(ts: Date = Date(), runID: String, taskID: String? = nil, type: String, from: String? = nil, to: String? = nil, meta: [String: String] = [:]) {
        self.ts = ts
        self.runID = runID
        self.taskID = taskID
        self.type = type
        self.from = from
        self.to = to
        self.meta = meta
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

import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    /// When true, use Ollama-backed Mayor and Tinker adapters. When false or missing, use default (string-split) adapters.
    public var useOllama: Bool?
    public var models: ModelConfig
    public var ollama: OllamaConfig
    public var orchestrator: OrchestratorConfig
    public var verification: VerificationConfig
    public var guardrails: GuardrailConfig

    public static let `default` = AppConfig(
        useOllama: nil,
        models: ModelConfig(mayor: "qwen2.5-coder:32b", tinker: "qwen2.5-coder:7b"),
        ollama: OllamaConfig(numParallel: 4, maxQueue: 10, keepAlive: "24h", mayorNumCtx: 32768, tinkerNumCtx: 8192),
        orchestrator: OrchestratorConfig(maxParallelTasks: 4, maxRetriesPerTask: 3),
        verification: VerificationConfig(mode: "spm", command: "swift build"),
        guardrails: GuardrailConfig(enforcePathSandbox: true, blockedCommands: ["git reset --hard", "rm -rf /"])
    )

    enum CodingKeys: String, CodingKey {
        case useOllama = "use_ollama"
        case models
        case ollama
        case orchestrator
        case verification
        case guardrails
    }

    public init(useOllama: Bool? = nil, models: ModelConfig, ollama: OllamaConfig, orchestrator: OrchestratorConfig, verification: VerificationConfig, guardrails: GuardrailConfig) {
        self.useOllama = useOllama
        self.models = models
        self.ollama = ollama
        self.orchestrator = orchestrator
        self.verification = verification
        self.guardrails = guardrails
    }

    /// True if Ollama-backed adapters should be used.
    public var shouldUseOllama: Bool { useOllama == true }
}

public struct ModelConfig: Codable, Equatable, Sendable {
    public var mayor: String
    public var tinker: String
}

public struct OllamaConfig: Codable, Equatable, Sendable {
    public var numParallel: Int
    public var maxQueue: Int
    public var keepAlive: String
    public var mayorNumCtx: Int
    public var tinkerNumCtx: Int

    enum CodingKeys: String, CodingKey {
        case numParallel = "num_parallel"
        case maxQueue = "max_queue"
        case keepAlive = "keep_alive"
        case mayorNumCtx = "mayor_num_ctx"
        case tinkerNumCtx = "tinker_num_ctx"
    }
}

public struct OrchestratorConfig: Codable, Equatable, Sendable {
    public var maxParallelTasks: Int
    public var maxRetriesPerTask: Int

    enum CodingKeys: String, CodingKey {
        case maxParallelTasks = "max_parallel_tasks"
        case maxRetriesPerTask = "max_retries_per_task"
    }
}

public struct VerificationConfig: Codable, Equatable, Sendable {
    public var mode: String
    public var command: String
}

public struct GuardrailConfig: Codable, Equatable, Sendable {
    public var enforcePathSandbox: Bool
    public var blockedCommands: [String]

    enum CodingKeys: String, CodingKey {
        case enforcePathSandbox = "enforce_path_sandbox"
        case blockedCommands = "blocked_commands"
    }
}

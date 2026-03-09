import Foundation

// MARK: - Ollama Mayor Adapter

public struct OllamaMayorAdapter: MayorAdapting {
    private let client: OllamaClient
    private let model: String
    private let numCtx: Int
    private let fallback: MayorAdapting

    public init(client: OllamaClient = OllamaClient(), model: String, numCtx: Int, fallback: MayorAdapting = DefaultMayorAdapter()) {
        self.client = client
        self.model = model
        self.numCtx = numCtx
        self.fallback = fallback
    }

    public func plan(request: String) -> [PlannedTask] {
        let system = """
        You are a task planner. Given a user request, output a JSON array of tasks. Each task must have: "title" (string), "priority" (1-3, 1 highest), "depends_on" (array of task titles or empty), "target_files" (array of file paths, use placeholder like "tinkertown-task-notes.md" if unknown). Output only valid JSON, no markdown or explanation.
        """
        let prompt = "User request: \(request)\n\nJSON array of tasks:"
        guard let response = client.generate(model: model, prompt: prompt, numCtx: numCtx, system: system),
              let tasks = parsePlannedTasks(from: response) else {
            return fallback.plan(request: request)
        }
        return tasks
    }

    private func parsePlannedTasks(from jsonText: String) -> [PlannedTask]? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var result: [PlannedTask] = []
        for (_, item) in raw.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty else { continue }
            let priority = (item["priority"] as? Int).map { min(3, max(1, $0)) } ?? 1
            let dependsOn = (item["depends_on"] as? [String]) ?? []
            let targetFiles = (item["target_files"] as? [String]) ?? ["tinkertown-task-notes.md"]
            result.append(PlannedTask(
                title: title,
                priority: priority,
                dependsOn: dependsOn,
                targetFiles: targetFiles.isEmpty ? ["tinkertown-task-notes.md"] : targetFiles
            ))
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Ollama Tinker Adapter

public struct OllamaTinkerAdapter: TinkerAdapting {
    private let client: OllamaClient
    private let model: String
    private let numCtx: Int
    private let shell: ShellRunning
    private let guardrails: GuardrailService
    private let fallback: TinkerAdapting

    public init(
        client: OllamaClient = OllamaClient(),
        model: String,
        numCtx: Int,
        shell: ShellRunning = ShellRunner(),
        guardrails: GuardrailService,
        fallback: TinkerAdapting? = nil
    ) {
        self.client = client
        self.model = model
        self.numCtx = numCtx
        self.shell = shell
        self.guardrails = guardrails
        self.fallback = fallback ?? DefaultTinkerAdapter(shell: shell, guardrails: guardrails)
    }

    public func apply(task: TaskRecord, context: String, worktree: URL) throws -> String {
        let system = """
        You are a coding assistant. Apply the requested change. If you can output a unified diff (patch) that applies to the given files, output ONLY the diff with no explanation, starting with "---" and using a/ and b/ paths. Otherwise output a single line: FALLBACK
        """
        let fileList = task.targetFiles.joined(separator: ", ")
        let prompt = """
        Task: \(task.title)
        Context: \(context)
        Target files: \(fileList)
        Produce a unified diff for the changes, or FALLBACK.
        """
        guard let response = client.generate(model: model, prompt: prompt, numCtx: numCtx, system: system),
              let patch = extractPatch(response),
              (try? applyPatch(patch, worktree: worktree)) == true else {
            return try fallback.apply(task: task, context: context, worktree: worktree)
        }
        return "Applied patch from Ollama (\(patch.count) bytes)"
    }

    private func extractPatch(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("FALLBACK") { return nil }
        if trimmed.contains("---") && (trimmed.contains("+++") || trimmed.contains("@@")) {
            return trimmed
        }
        return nil
    }

    private func applyPatch(_ patch: String, worktree: URL) throws -> Bool {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let patchFile = tempDir.appendingPathComponent("patch.diff")
        try patch.write(to: patchFile, atomically: true, encoding: .utf8)
        try guardrails.validatePath(patchFile, inside: tempDir)
        let escapedPath = patchFile.path.replacingOccurrences(of: "'", with: "'\"'\"'")
        let result = try shell.run("git apply --ignore-whitespace '\(escapedPath)'", cwd: worktree)
        return result.exitCode == 0
    }
}

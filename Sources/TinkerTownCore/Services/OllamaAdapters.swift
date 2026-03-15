import Foundation

/// Thrown when the Tinker was asked to implement code but the model did not output an applicable patch.
public struct TinkerError: Error, LocalizedError {
    public let taskTitle: String
    public let targetFiles: [String]
    public var errorDescription: String? {
        "Model did not produce a valid patch for task \"\(taskTitle)\" (targets: \(targetFiles.joined(separator: ", "))). The agent must output a unified diff to implement application code."
    }
}

// MARK: - Ollama Mayor Adapter

public struct OllamaMayorAdapter: MayorAdapting {
    private let client: OllamaClient
    private let model: String
    private let numCtx: Int
    private let fallback: MayorAdapting
    public var logger: WorkspaceLogger?

    public init(client: OllamaClient = OllamaClient(), model: String, numCtx: Int, fallback: MayorAdapting = DefaultMayorAdapter(), logger: WorkspaceLogger? = nil) {
        self.client = client
        self.model = model
        self.numCtx = numCtx
        self.fallback = fallback
        self.logger = logger
    }

    public func plan(pdr: PDRRecord, request: String, planContent: String? = nil) -> [PlannedTask] {
        let hasPlan = planContent != nil
        let system = """
        You are a task planner for a multi-component software system. The goal is to produce tasks that result in real application code being built—not documentation.
        \(hasPlan ? """

        A PROJECT_PLAN.md has been provided. This plan is the authoritative source of truth for what needs to be built. Your primary job is to decompose the plan's active checklist items into concrete coding tasks. Use the PDR for scope and constraints; use the project plan for the specific work items to implement now.
        """ : """

        You are given a Product Design Requirement (PDR) and an optional user request. Use the PDR for scope and acceptance criteria; use the request to focus the current run.
        """)
        CRITICAL OUTPUT RULE: Your entire response MUST be a single raw JSON array. It MUST start with '[' and end with ']'. Do NOT include any prose, explanation, preamble, markdown fences, or text outside the array. If you include anything other than the JSON array your output will be discarded and no work will be done.

        Each task object in the array must have:
        - "title" (string)
        - "priority" (1-3, 1 highest)
        - "depends_on" (array of task titles, or [])
        - "target_files" (array of actual source file paths the worker will edit or create — REQUIRED, must not be empty)
        Recommended fields:
        - "component_kind" (e.g. "backend_api", "frontend_web", "ios_app")
        - "component_id" (shared identifier for tasks in the same component)
        - "verification_command" (e.g. "npm test", "node -e 'require(\\\"./server\\\")'", "true"). When all target_files are under one directory (e.g. backend/), verification runs FROM that directory — use relative commands like "node server.js", not "cd backend && node server.js".

        target_files rules: Use real source/config paths. Examples: "backend/server.js", "backend/package.json", "frontend/src/App.jsx", "frontend/index.html", "db/schema.sql". NEVER use "tinkertown-task-notes.md" — it signals a planning failure.

        When the project has multiple components (backend, frontend, etc.) create one task per component, set component_kind/component_id, and use depends_on to order them.

        REMINDER: Output ONLY the JSON array starting with '['. No other text.
        """
        let prompt: String
        if let plan = planContent {
            prompt = """
            PROJECT_PLAN.md (authoritative — derive tasks from the active checklist items):
            \(plan)

            PDR context (scope and constraints):
            \(pdr.contextSummary)

            User request: \(request.isEmpty ? "Follow the project plan." : request)

            JSON array of tasks derived from the plan's active checklist:
            """
        } else {
            prompt = """
            PDR context:
            \(pdr.contextSummary)

            User request: \(request.isEmpty ? pdr.title : request)

            JSON array of tasks:
            """
        }
        logger?.log("INFO", "[MAYOR] model=\(model) numCtx=\(numCtx) planContent=\(planContent != nil ? "yes(\(planContent!.count)chars)" : "none") request=\"\(String(request.prefix(120)))\"")
        guard let response = client.generate(model: model, prompt: prompt, numCtx: numCtx, system: system) else {
            logger?.log("ERROR", "[MAYOR] Ollama returned nil — no response received. Check that ollama is running and model '\(model)' is available.")
            logger?.log("WARN",  "[MAYOR] Using fallback (DefaultMayorAdapter) — tasks may target tinkertown-task-notes.md and be filtered.")
            return fallback.plan(pdr: pdr, request: request, planContent: planContent)
        }
        logger?.log("INFO",  "[MAYOR] Response received, length=\(response.count). Preview: \(WorkspaceLogger.preview(response))")
        guard let tasks = parsePlannedTasks(from: response) else {
            logger?.log("ERROR", "[MAYOR] JSON parse failed — response is not a valid task array. The model may have returned prose or invalid JSON.")
            logger?.log("WARN",  "[MAYOR] Using fallback (DefaultMayorAdapter). This usually means the model output did not start with '[' or was malformed.")
            return fallback.plan(pdr: pdr, request: request, planContent: planContent)
        }
        logger?.log("INFO",  "[MAYOR] Parsed \(tasks.count) task(s): \(tasks.map(\.title).joined(separator: ", "))")
        return tasks
    }

    func parsePlannedTasks(from jsonText: String) -> [PlannedTask]? {
        let stripped = Self.stripMarkdownCodeBlock(jsonText)
        let candidate = Self.extractFirstJSONArray(from: stripped)
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var result: [PlannedTask] = []
        for (_, item) in raw.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty else { continue }
            // Skip tasks with missing or empty target_files — they indicate a malformed plan
            // and would silently become doc-writing tasks if we allowed a fallback to notes.md.
            guard let targetFiles = item["target_files"] as? [String], !targetFiles.isEmpty else { continue }
            let priority = (item["priority"] as? Int).map { min(3, max(1, $0)) } ?? 1
            let dependsOn = (item["depends_on"] as? [String]) ?? []
            let componentKind = item["component_kind"] as? String
            let componentId = item["component_id"] as? String
            let verificationCommand = item["verification_command"] as? String
            result.append(PlannedTask(
                title: title,
                priority: priority,
                dependsOn: dependsOn,
                targetFiles: targetFiles,
                componentKind: componentKind,
                componentId: componentId,
                verificationCommand: verificationCommand
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// Finds the first top-level JSON array `[…]` in the text, tolerating leading prose.
    /// This lets us recover when the model prefixes its JSON with an explanation sentence.
    static func extractFirstJSONArray(from text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(of: "[") else { return s }
        // Walk forward counting bracket depth to find the matching close bracket.
        var depth = 0
        var end = s.endIndex
        for idx in s[start...].indices {
            switch s[idx] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { end = s.index(after: idx); break }
            default: break
            }
            if depth == 0 { break }
        }
        return String(s[start..<end])
    }

    /// Strips optional markdown code fence so JSON can be parsed when the model returns ```json\n...\n```.
    static func stripMarkdownCodeBlock(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            let rest = s.dropFirst(3)
            let afterLang = rest.hasPrefix("json") ? rest.dropFirst(4) : rest
            let start = afterLang.drop(while: { $0.isNewline })
            if let end = start.range(of: "\n```") {
                return String(start[..<end.lowerBound])
            }
            return String(start)
        }
        return s
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
    public var logger: WorkspaceLogger?

    public init(
        client: OllamaClient = OllamaClient(),
        model: String,
        numCtx: Int,
        shell: ShellRunning = ShellRunner(),
        guardrails: GuardrailService,
        fallback: TinkerAdapting? = nil,
        logger: WorkspaceLogger? = nil
    ) {
        self.client = client
        self.model = model
        self.numCtx = numCtx
        self.shell = shell
        self.guardrails = guardrails
        self.fallback = fallback ?? DefaultTinkerAdapter(shell: shell, guardrails: guardrails)
        self.logger = logger
    }

    public func apply(task: TaskRecord, context: String, worktree: URL) throws -> String {
        let system = """
        You are a software engineer implementing application code. Your job is to write or edit source files (backend, frontend, config, tests)—not documentation or notes.

        You must respond with exactly one of:
        1. A unified diff (patch) that applies with `git apply`. Output ONLY the diff: start with a line "--- a/<path>" or "--- /dev/null", then "+++ b/<path>", then hunk headers "@@ ... @@". Use paths relative to the repo root (e.g. a/server.js b/server.js). For NEW files use "--- /dev/null" and "+++ b/path/to/newfile". No explanation, no markdown, no code fences—just the raw diff.
        2. Or one line: EXPLAIN: <short reason> only if the task is impossible (e.g. missing info).

        You are building a real application. Implement the requested change in code. Do not write to tinkertown-task-notes.md or other docs as the deliverable; produce the actual source/config/test changes as a unified diff. Ensure every file in your diff is complete and syntactically valid (e.g. all braces and brackets closed). If the context includes "Previous verification failed", fix the reported errors and output a full, runnable patch—do not truncate.
        Prefer minimal edits: when target files already exist (e.g. backend/server.js), patch only what is needed instead of replacing the entire file, so the response stays short and complete.
        """
        let fileList = task.targetFiles.joined(separator: ", ")
        // Best-effort context: read contents of small target files.
        var fileSnippets: [String] = []
        for path in task.targetFiles {
            let url = worktree.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url),
               data.count < 128_000, // ~128 KB per file
               let text = String(data: data, encoding: .utf8) {
                fileSnippets.append("FILE: \(path)\n```\n\(text)\n```")
            }
        }
        let contextFiles = fileSnippets.joined(separator: "\n\n")
        let wasTruncated = context.contains("Unexpected end of input") || context.contains("SyntaxError")
        let truncationWarning = wasTruncated ? "\nCRITICAL: The previous attempt was truncated or had a syntax error. Your diff MUST be a complete, runnable file with all braces/brackets closed. Prefer a minimal patch that only adds the missing parts or fixes the error; if you must replace the file, output the FULL file in the diff and do not cut off.\n" : ""
        let prompt = """
        Implement this task by changing the target files. Output only a unified diff (no prose, no markdown).\(truncationWarning)

        Task: \(task.title)
        Context: \(context)
        Target files: \(fileList)
        Current file contents (if present):
        \(contextFiles.isEmpty ? "(files may not exist yet; use --- /dev/null and +++ b/<path> for new files)" : contextFiles)

        Output only the unified diff, or EXPLAIN: <reason> if you cannot implement it.
        """
        logger?.log("INFO", "[TINKER] task=\"\(task.title)\" files=[\(task.targetFiles.joined(separator: ", "))] model=\(model)")
        guard let response = client.generate(model: model, prompt: prompt, numCtx: numCtx, system: system) else {
            logger?.log("ERROR", "[TINKER] task=\"\(task.title)\" — Ollama returned nil. Check model '\(model)' is available.")
            throw TinkerError(taskTitle: task.title, targetFiles: task.targetFiles)
        }
        logger?.log("INFO",  "[TINKER] task=\"\(task.title)\" response length=\(response.count). Preview: \(WorkspaceLogger.preview(response))")
        guard let resultMessage = try handleResponse(response, worktree: worktree) else {
            logger?.log("ERROR", "[TINKER] task=\"\(task.title)\" — response did not contain a valid unified diff or patch failed to apply.")
            throw TinkerError(taskTitle: task.title, targetFiles: task.targetFiles)
        }
        logger?.log("INFO",  "[TINKER] task=\"\(task.title)\" — patch applied. \(resultMessage)")
        return resultMessage
    }

    private func handleResponse(_ text: String, worktree: URL) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("EXPLAIN:") {
            return String(trimmed.dropFirst("EXPLAIN:".count)).trimmingCharacters(in: .whitespaces)
        }
        let patch = extractPatch(from: trimmed)
        if let patch, patch.contains("---"), patch.contains("@@") {
            if try applyPatch(patch, worktree: worktree) {
                return "Applied patch from Ollama (\(patch.count) characters)."
            } else {
                // Return nil so the caller treats this as a Tinker failure and retries,
                // rather than silently passing verification with no code written.
                return nil
            }
        }
        return nil
    }

    /// Extracts a unified diff from the model response, including from markdown code blocks or trailing prose.
    private func extractPatch(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("---"), trimmed.contains("@@") {
            if let backtick = trimmed.range(of: "```") {
                let after = trimmed[backtick.upperBound...]
                if let endBlock = after.range(of: "```") {
                    let block = String(after[..<endBlock.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if block.contains("---"), block.contains("@@") { return block }
                }
            }
            if let start = trimmed.range(of: "---") {
                let fromStart = String(trimmed[start.lowerBound...])
                if let end = fromStart.range(of: "\n```") {
                    return String(fromStart[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return fromStart.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let backtick = trimmed.range(of: "```") {
            let after = trimmed[backtick.upperBound...]
            if let endBlock = after.range(of: "```") {
                let block = String(after[..<endBlock.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if block.contains("---"), block.contains("@@") { return block }
            }
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

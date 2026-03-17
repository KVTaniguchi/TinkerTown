import Foundation

public struct InspectionOutcome {
    public var exitCode: Int32
    public var diagnostics: [DiagnosticRecord]
    public var errorClass: ErrorClass?
    /// Raw stdout+stderr from the verification command, for passing into retry context.
    public var rawOutput: String?
}

public struct Inspector {
    private let shell: ShellRunning
    private let eventLogger: EventLogger

    public init(shell: ShellRunning = ShellRunner(), eventLogger: EventLogger) {
        self.shell = shell
        self.eventLogger = eventLogger
    }

    public func selectCommand(config: VerificationConfig, root: URL) -> String {
        // Explicit modes first.
        if config.mode == "none" { return "true" }
        if config.mode == "spm" { return "swift build" }
        if config.mode == "xcodebuild" { return config.command }

        // Auto-mode: infer from repo contents so the agent doesn't run the wrong verifier (e.g. swift build in a Node repo).
        let hasPackageSwift = FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        if hasPackageSwift {
            return "swift build"
        }
        let hasPackageJson = FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path)
        if hasPackageJson {
            return "true"
        }
        return config.command
    }

    public func verify(task: TaskRecord, runID: String, attempt: Int, command: String, cwd: URL) throws -> InspectionOutcome {
        let result = try shell.run(command, cwd: cwd)
        let mergedOutput = result.stdout + "\n" + result.stderr
        try eventLogger.appendRawLog(runID: runID, taskID: task.taskID, attempt: attempt, content: mergedOutput)
        let diagnostics = parseDiagnostics(taskID: task.taskID, from: mergedOutput, tool: command.contains("xcodebuild") ? "xcodebuild" : "swift")
        return InspectionOutcome(
            exitCode: result.exitCode,
            diagnostics: diagnostics,
            errorClass: command == "true" ? nil : (result.exitCode == 0 ? nil : .buildCompile),
            rawOutput: mergedOutput
        )
    }

    public func backoffSeconds(attempt: Int) -> UInt32 {
        switch attempt {
        case 0: return 0
        case 1: return 3
        default: return 10
        }
    }

    private func parseDiagnostics(taskID: String, from output: String, tool: String) -> [DiagnosticRecord] {
        let swiftDiag = parseSwiftStyleDiagnostics(taskID: taskID, from: output, tool: tool)
        if !swiftDiag.isEmpty { return swiftDiag }
        return parseNodeStyleDiagnostics(taskID: taskID, from: output, tool: tool)
    }

    private func parseSwiftStyleDiagnostics(taskID: String, from output: String, tool: String) -> [DiagnosticRecord] {
        let lines = output.split(separator: "\n").map(String.init)
        var diagnostics: [DiagnosticRecord] = []
        let regex = try? NSRegularExpression(pattern: "([^:\\n]+):(\\d+):(\\d+):\\s*(error|warning):\\s*(.+)")
        for line in lines {
            guard let regex else { break }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange), match.numberOfRanges == 6 else { continue }

            func group(_ idx: Int) -> String {
                let range = match.range(at: idx)
                guard let swiftRange = Range(range, in: line) else { return "" }
                return String(line[swiftRange])
            }

            diagnostics.append(DiagnosticRecord(
                taskID: taskID,
                tool: tool,
                severity: group(4),
                code: group(4) == "error" ? "SWIFT_BUILD" : "SWIFT_WARNING",
                file: group(1),
                line: Int(group(2)),
                column: Int(group(3)),
                message: group(5)
            ))
        }
        return diagnostics
    }

    /// Parses Node.js-style errors (e.g. "path/to/file.js:11" then "SyntaxError: Unexpected end of input").
    private func parseNodeStyleDiagnostics(taskID: String, from output: String, tool: String) -> [DiagnosticRecord] {
        let lines = output.split(separator: "\n").map(String.init)
        var diagnostics: [DiagnosticRecord] = []
        // Match path:line or path:line:column (Node prints file:line on first line of stack).
        let pathLineRegex = try? NSRegularExpression(pattern: "^(.*):(\\d+)(?::(\\d+))?\\s*$")
        for (idx, line) in lines.enumerated() {
            guard let pathLineRegex else { break }
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pathLineRegex.firstMatch(in: line, range: nsRange), match.numberOfRanges >= 3 else { continue }
            func group(_ i: Int) -> String {
                let range = match.range(at: i)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return "" }
                return String(line[swiftRange])
            }
            let file = group(1).trimmingCharacters(in: .whitespaces)
            let lineNum = Int(group(2)) ?? 0
            let column = match.numberOfRanges > 3 ? (Int(group(3)) ?? 0) : 0
            var message = "runtime error"
            if idx + 1 < lines.count {
                let next = lines[idx + 1].trimmingCharacters(in: .whitespaces)
                if next.contains("SyntaxError:") || next.contains("Error:") || next.hasPrefix("TypeError:") {
                    message = next
                }
            }
            diagnostics.append(DiagnosticRecord(
                taskID: taskID,
                tool: "node",
                severity: "error",
                code: "NODE_RUNTIME",
                file: file.isEmpty ? nil : file,
                line: lineNum > 0 ? lineNum : nil,
                column: (match.numberOfRanges > 3 && column > 0) ? column : nil,
                message: message
            ))
            break
        }
        return diagnostics
    }
}

import Foundation

public struct Redactor {
    public var patterns: [String]

    public init(patterns: [String] = ["(?i)api[_-]?key\\s*[:=]\\s*[^\\s]+", "(?i)token\\s*[:=]\\s*[^\\s]+", "(?i)password\\s*[:=]\\s*[^\\s]+", "AKIA[0-9A-Z]{16}"]) {
        self.patterns = patterns
    }

    public func redact(_ input: String) -> String {
        patterns.reduce(input) { partial, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return partial }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return regex.stringByReplacingMatches(in: partial, options: [], range: range, withTemplate: "[REDACTED]")
        }
    }
}

public struct EventLogger {
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let paths: AppPaths
    private let redactor: Redactor
    private let appendLock = NSLock()

    public init(fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec(), paths: AppPaths, redactor: Redactor = Redactor()) {
        self.fs = fs
        self.codec = codec
        self.paths = paths
        self.redactor = redactor
    }

    public func append(_ event: RunEvent) throws {
        let file = paths.eventsFile(event.runID)
        let data = try codec.encoder.encode(event)
        guard let line = String(data: data, encoding: .utf8) else { return }
        appendLock.lock()
        defer { appendLock.unlock() }
        try fs.append(redactor.redact(line) + "\n", to: file)
    }

    public func appendRawLog(runID: String, taskID: String, attempt: Int, content: String) throws {
        let logFile = paths.taskAttemptLog(runID, taskID, attempt)
        try fs.write(Data(redactor.redact(content).utf8), to: logFile)
    }

    /// Append an escalation to `.tinkertown/escalations.ndjson`. Optional runID associates with a run. One JSON object per line (NDJSON).
    public func appendEscalation(severity: String, message: String, runID: String? = nil) throws {
        let record = EscalationRecord(severity: severity, message: redactor.redact(message), runID: runID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [] // single line for NDJSON
        let data = try encoder.encode(record)
        guard let line = String(data: data, encoding: .utf8) else { return }
        try fs.append(line + "\n", to: paths.escalationsFile)
    }
}

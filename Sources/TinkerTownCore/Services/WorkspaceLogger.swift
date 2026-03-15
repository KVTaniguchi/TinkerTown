import Foundation

/// Appends human-readable timestamped log lines to `.tinkertown/tinkertown.log`
/// in the target workspace. Captures Mayor/Tinker prompts, responses, parse results,
/// task filtering, and verification outcomes so silent failures become diagnosable.
public final class WorkspaceLogger: @unchecked Sendable {
    public let logFile: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.tinkertown.wslogger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init(root: URL) {
        let dir = root.appendingPathComponent(".tinkertown", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tinkertown.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.logFile = url
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.fileHandle?.seekToEndOfFile()
        log("INFO", "=== TinkerTown session started ===")
    }

    deinit {
        queue.sync { try? self.fileHandle?.close() }
    }

    public func log(_ level: String = "INFO", _ message: String) {
        let ts = formatter.string(from: Date())
        let line = "\(ts) [\(level)] \(message)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }

    /// Truncates a potentially large string for safe logging.
    public static func preview(_ text: String, maxChars: Int = 600) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "…[truncated, total \(text.count) chars]"
    }
}

import Foundation

/// Thread-safe append-only logger that writes timestamped entries to ~/.tinkertown/app.log.
/// Claude Code can `Read` this file directly to diagnose TinkerTown runtime issues.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.tinkertown.applogger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tinkertown")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        log("INFO", actor: "APP", "--- TinkerTown session started ---")
    }

    func log(_ level: String = "INFO", actor: String = "APP", _ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level.uppercased())] [\(actor.uppercased())] \(message)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }
}

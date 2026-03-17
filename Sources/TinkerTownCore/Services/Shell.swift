import Foundation

public struct ShellResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public protocol ShellRunning {
    @discardableResult
    func run(_ command: String, cwd: URL?) throws -> ShellResult
}

public struct ShellRunner: ShellRunning {
    public init() {}

    /// Builds PATH for subprocesses so Node/npm are found when installed via nvm, fnm, Homebrew, etc.
    /// GUI apps get a minimal PATH; we add common locations and (for -i) the user's .zshrc is sourced.
    private static var subprocessEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var extra: [String] = []
        extra.append("/opt/homebrew/bin")
        extra.append("/usr/local/bin")
        extra.append("\(home)/.nvm/versions/node/current/bin")
        if let nvmDir = env["NVM_DIR"], !nvmDir.isEmpty {
            extra.append("\(nvmDir)/versions/node/current/bin")
        }
        extra.append("\(home)/.fnm/current/bin")
        extra.append("\(home)/.volta/bin")
        let combined = (extra + [currentPath]).joined(separator: ":")
        env["PATH"] = combined
        return env
    }

    @discardableResult
    public func run(_ command: String, cwd: URL? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Non-login, non-interactive: avoids sourcing .zshrc (which can hang on interactive
        // prompts or add seconds of startup overhead per call). PATH is augmented manually
        // in subprocessEnvironment so nvm/fnm/volta/Homebrew are still found.
        process.arguments = ["-c", command]
        process.environment = Self.subprocessEnvironment
        if let cwd {
            process.currentDirectoryURL = cwd
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        var stderrString = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationReason == .uncaughtSignal {
            let signalNote = "\n[Process terminated by signal (exit code \(process.terminationStatus)); e.g. SIGTERM or connection refused to a required service]\n"
            stderrString += signalNote
        }

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: stderrString
        )
    }
}

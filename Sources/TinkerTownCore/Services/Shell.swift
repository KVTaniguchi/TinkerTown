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

    @discardableResult
    public func run(_ command: String, cwd: URL? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
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

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

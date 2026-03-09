import Foundation

public enum GuardrailError: Error, LocalizedError {
    case commandBlocked(String)
    case pathViolation(String)

    public var errorDescription: String? {
        switch self {
        case let .commandBlocked(command):
            return "Blocked command: \(command)"
        case let .pathViolation(path):
            return "Path outside worktree: \(path)"
        }
    }
}

public struct GuardrailService {
    private let config: GuardrailConfig

    public init(config: GuardrailConfig) {
        self.config = config
    }

    public func validateCommand(_ command: String) throws {
        for blocked in config.blockedCommands where command.contains(blocked) {
            throw GuardrailError.commandBlocked(command)
        }
    }

    public func validatePath(_ candidate: URL, inside root: URL) throws {
        guard config.enforcePathSandbox else { return }
        let resolvedCandidate = candidate.standardizedFileURL.path
        let resolvedRoot = root.standardizedFileURL.path
        guard resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/") else {
            throw GuardrailError.pathViolation(candidate.path)
        }
    }
}

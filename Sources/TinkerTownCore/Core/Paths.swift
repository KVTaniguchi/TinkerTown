import Foundation

public struct AppPaths {
    public let root: URL
    public let tinkerRoot: URL
    public let runsRoot: URL
    public let agentsRoot: URL
    public let configFile: URL
    /// Default path for the active Product Design Requirement (PDR). Required before a run can start.
    public let pdrFile: URL

    public init(root: URL) {
        self.root = root
        tinkerRoot = root.appendingPathComponent(".tinkertown", isDirectory: true)
        runsRoot = tinkerRoot.appendingPathComponent("runs", isDirectory: true)
        agentsRoot = tinkerRoot.appendingPathComponent("agents", isDirectory: true)
        configFile = tinkerRoot.appendingPathComponent("config.json")
        pdrFile = tinkerRoot.appendingPathComponent("pdr.json")
    }

    public func runDir(_ runID: String) -> URL {
        runsRoot.appendingPathComponent(runID, isDirectory: true)
    }

    public func eventsFile(_ runID: String) -> URL {
        runDir(runID).appendingPathComponent("events.ndjson")
    }

    public func runRecordFile(_ runID: String) -> URL {
        runDir(runID).appendingPathComponent("run.json")
    }

    public func tasksDir(_ runID: String) -> URL {
        runDir(runID).appendingPathComponent("tasks", isDirectory: true)
    }

    public func taskRecordFile(_ runID: String, _ taskID: String) -> URL {
        tasksDir(runID).appendingPathComponent("\(taskID).json")
    }

    public func taskAttemptLog(_ runID: String, _ taskID: String, _ attempt: Int) -> URL {
        tasksDir(runID).appendingPathComponent(taskID, isDirectory: true).appendingPathComponent("attempt_\(attempt).log")
    }

    /// Global escalations log (append-only). Used by `tinkertown escalate`.
    public var escalationsFile: URL {
        tinkerRoot.appendingPathComponent("escalations.ndjson")
    }

    public func agentFile(_ agentID: String) -> URL {
        agentsRoot.appendingPathComponent("\(agentID).json")
    }
}

import Foundation

public struct RunStore {
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let paths: AppPaths

    public init(fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec(), paths: AppPaths) {
        self.fs = fs
        self.codec = codec
        self.paths = paths
    }

    public func ensureWorkspaceDirectories() throws {
        try fs.createDirectory(paths.tinkerRoot)
        try fs.createDirectory(paths.runsRoot)
        try fs.createDirectory(paths.agentsRoot)
    }

    /// Ensures run directory and tasks subdirectory exist. Call when creating a new run.
    public func ensureRunDirectories(runID: String) throws {
        try ensureWorkspaceDirectories()
        try fs.createDirectory(paths.runDir(runID))
        try fs.createDirectory(paths.tasksDir(runID))
    }

    public func saveRun(_ run: RunRecord) throws {
        try run.validate()
        let file = paths.runRecordFile(run.runID)
        let data = try codec.encoder.encode(run)
        try fs.write(data, to: file)
    }

    public func loadRun(_ runID: String) throws -> RunRecord {
        let data = try fs.read(paths.runRecordFile(runID))
        return try codec.decoder.decode(RunRecord.self, from: data)
    }

    public func listRuns() throws -> [String] {
        try fs.listFiles(paths.runsRoot).filter { $0.hasDirectoryPath }.map(\.lastPathComponent).sorted()
    }

    public func saveTask(_ task: TaskRecord) throws {
        try task.validate()
        let file = paths.taskRecordFile(task.runID, task.taskID)
        let data = try codec.encoder.encode(task)
        try fs.write(data, to: file)
    }

    public func loadTask(runID: String, taskID: String) throws -> TaskRecord {
        let data = try fs.read(paths.taskRecordFile(runID, taskID))
        return try codec.decoder.decode(TaskRecord.self, from: data)
    }

    public func listTasks(runID: String) throws -> [TaskRecord] {
        let taskFiles = try fs.listFiles(paths.tasksDir(runID)).filter { !$0.hasDirectoryPath && $0.pathExtension == "json" }
        return try taskFiles.map { file in
            let data = try fs.read(file)
            return try codec.decoder.decode(TaskRecord.self, from: data)
        }.sorted { $0.taskID < $1.taskID }
    }

    public func saveAgent(_ agent: AgentRecord) throws {
        try agent.validate()
        try ensureWorkspaceDirectories()
        let data = try codec.encoder.encode(agent)
        try fs.write(data, to: paths.agentFile(agent.agentID))
    }

    public func loadAgent(_ agentID: String) throws -> AgentRecord {
        let data = try fs.read(paths.agentFile(agentID))
        return try codec.decoder.decode(AgentRecord.self, from: data)
    }

    public func listAgents() throws -> [AgentRecord] {
        let files = try fs.listFiles(paths.agentsRoot).filter { !$0.hasDirectoryPath && $0.pathExtension == "json" }
        return try files.map { file in
            let data = try fs.read(file)
            return try codec.decoder.decode(AgentRecord.self, from: data)
        }.sorted { lhs, rhs in
            if lhs.role == rhs.role { return lhs.agentID < rhs.agentID }
            return lhs.role.rawValue < rhs.role.rawValue
        }
    }

    public func ensureDefaultAgents(maxParallelTasks: Int) throws {
        try ensureWorkspaceDirectories()
        let count = max(1, maxParallelTasks)
        var defaults: [AgentRecord] = [
            AgentRecord(agentID: "mayor_001", name: "Mayor", role: .mayor),
            AgentRecord(agentID: "orchestrator_001", name: "Orchestrator", role: .orchestrator),
            AgentRecord(agentID: "monitor_001", name: "Monitor", role: .monitor),
            AgentRecord(agentID: "operator_001", name: "Operator", role: .operatorRole)
        ]
        for index in 1...count {
            defaults.append(AgentRecord(agentID: String(format: "tinker_%03d", index), name: "Tinker \(index)", role: .tinker))
        }

        for agent in defaults where !fs.fileExists(paths.agentFile(agent.agentID)) {
            try saveAgent(agent)
        }
    }

    public func updateAgentActivity(
        agentID: String,
        name: String,
        role: AgentRole,
        state: AgentState,
        runID: String? = nil,
        taskID: String? = nil,
        activity: String? = nil
    ) throws {
        var agent: AgentRecord
        if fs.fileExists(paths.agentFile(agentID)) {
            agent = try loadAgent(agentID)
        } else {
            agent = AgentRecord(agentID: agentID, name: name, role: role)
        }
        agent.name = name
        agent.role = role
        agent.state = state
        agent.currentRunID = runID
        agent.currentTaskID = taskID
        agent.currentActivity = activity
        agent.updatedAt = Date()
        try saveAgent(agent)
    }
}

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

    /// Ensures run directory and tasks subdirectory exist. Call when creating a new run.
    public func ensureRunDirectories(runID: String) throws {
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
}

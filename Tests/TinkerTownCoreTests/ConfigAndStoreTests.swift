import Foundation
import Testing
@testable import TinkerTownCore

struct ConfigAndStoreTests {
    @Test func bootstrapsDefaultConfig() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let store = ConfigStore(fs: fs, paths: paths)

        let cfg = try store.bootstrap()

        #expect(cfg.models.mayor == "qwen2.5-coder:32b")
        #expect(fs.fileExists(paths.configFile))
    }

    @Test func persistsRunAndTaskRecords() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let runStore = RunStore(fs: fs, paths: paths)

        let run = RunRecord(runID: "run_1", state: .runCreated, request: "req", config: OrchestratorConfig(maxParallelTasks: 2, maxRetriesPerTask: 3))
        try runStore.saveRun(run)
        let loaded = try runStore.loadRun("run_1")
        #expect(loaded.runID == "run_1")

        let task = TaskRecord(taskID: "task_001", runID: "run_1", title: "t", state: .taskCreated, priority: 1, assignedModel: "m", worktreePath: ".tinkertown/task_001", branch: "tinkertown/task_001", targetFiles: ["README.md"], maxRetries: 3, verify: VerifyResult(command: "swift build"))
        try runStore.saveTask(task)
        let loadedTask = try runStore.loadTask(runID: "run_1", taskID: "task_001")
        #expect(loadedTask.taskID == "task_001")
    }

    @Test func ensureRunDirectoriesCreatesRunAndTasksDirs() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let runStore = RunStore(fs: fs, paths: paths)

        try runStore.ensureRunDirectories(runID: "run_1")

        #expect(fs.fileExists(paths.runDir("run_1")))
        #expect(fs.fileExists(paths.tasksDir("run_1")))
    }
}

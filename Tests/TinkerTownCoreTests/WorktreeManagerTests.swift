import Foundation
import Testing
@testable import TinkerTownCore

final class RecordingShell: ShellRunning {
    var commands: [String] = []
    var results: [String: ShellResult]
    var defaultResult: ShellResult

    init(results: [String: ShellResult], defaultResult: ShellResult = ShellResult(exitCode: 0, stdout: "", stderr: "")) {
        self.results = results
        self.defaultResult = defaultResult
    }

    func run(_ command: String, cwd: URL?) throws -> ShellResult {
        commands.append(command)
        return results[command] ?? defaultResult
    }
}

struct WorktreeManagerTests {
    @Test func createValidatesPathAndBaseSHA() throws {
        let root = URL(fileURLWithPath: "/repo")
        let fs = InMemoryFileSystem()
        // Simulate git creating the worktree directory.
        try fs.createDirectory(root.appendingPathComponent(".tinkertown/task_001"))

        let results: [String: ShellResult] = [
            "git worktree add .tinkertown/task_001 -b tinkertown/task_001 main": ShellResult(exitCode: 0, stdout: "", stderr: ""),
            "git rev-parse main": ShellResult(exitCode: 0, stdout: "abc123\n", stderr: ""),
            "git rev-parse HEAD": ShellResult(exitCode: 0, stdout: "abc123\n", stderr: "")
        ]
        let shell = RecordingShell(results: results)
        let manager = WorktreeManager(shell: shell, fs: fs)

        let created = try manager.create(taskID: "task_001", root: root, baseBranch: "main")
        #expect(created.path == ".tinkertown/task_001")
        #expect(created.branch == "tinkertown/task_001")
    }

    @Test func createFailsWhenBaseSHAAndWorktreeHEADDiffer() {
        let root = URL(fileURLWithPath: "/repo")
        let fs = InMemoryFileSystem()
        try? fs.createDirectory(root.appendingPathComponent(".tinkertown/task_001"))

        let results: [String: ShellResult] = [
            "git worktree add .tinkertown/task_001 -b tinkertown/task_001 main": ShellResult(exitCode: 0, stdout: "", stderr: ""),
            "git rev-parse main": ShellResult(exitCode: 0, stdout: "abc123\n", stderr: ""),
            "git rev-parse HEAD": ShellResult(exitCode: 0, stdout: "def456\n", stderr: "")
        ]
        let shell = RecordingShell(results: results)
        let manager = WorktreeManager(shell: shell, fs: fs)

        #expect(throws: Error.self) {
            _ = try manager.create(taskID: "task_001", root: root, baseBranch: "main")
        }
    }

    @Test func teardownIssuesWorktreeAndBranchCommands() {
        let root = URL(fileURLWithPath: "/repo")
        let fs = InMemoryFileSystem()
        let shell = RecordingShell(results: [:])
        let manager = WorktreeManager(shell: shell, fs: fs)

        let task = TaskRecord(
            taskID: "task_001",
            runID: "run_1",
            title: "t",
            state: .mergeReady,
            priority: 1,
            assignedModel: "m",
            worktreePath: ".tinkertown/task_001",
            branch: "tinkertown/task_001",
            targetFiles: ["README.md"],
            maxRetries: 3,
            verify: VerifyResult(command: "swift build")
        )

        manager.teardown(task: task, root: root)

        #expect(shell.commands.contains("git worktree remove .tinkertown/task_001 --force"))
        #expect(shell.commands.contains("git branch -D tinkertown/task_001"))
    }

    @Test func cleanupOrphanedRemovesTinkertownWorktrees() throws {
        let root = URL(fileURLWithPath: "/repo")
        let fs = InMemoryFileSystem()
        let listOutput = """
        worktree /repo/.tinkertown/task_001
        worktree /repo/.git/worktrees/other
        """
        let results: [String: ShellResult] = [
            "git worktree list --porcelain": ShellResult(exitCode: 0, stdout: listOutput, stderr: "")
        ]
        let shell = RecordingShell(results: results)
        let manager = WorktreeManager(shell: shell, fs: fs)

        manager.cleanupOrphaned(root: root)

        #expect(shell.commands.contains("git worktree list --porcelain"))
        #expect(shell.commands.contains("git worktree remove /repo/.tinkertown/task_001 --force"))
        // Should not attempt to remove non-tinkertown worktrees.
        #expect(!shell.commands.contains("git worktree remove /repo/.git/worktrees/other --force"))
    }
}


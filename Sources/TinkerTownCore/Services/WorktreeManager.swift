import Foundation

public struct WorktreeManager {
    private let shell: ShellRunning
    private let fs: FileSysteming

    public init(shell: ShellRunning = ShellRunner(), fs: FileSysteming = LocalFileSystem()) {
        self.shell = shell
        self.fs = fs
    }

    public func create(taskID: String, root: URL, baseBranch: String) throws -> (path: String, branch: String) {
        let branch = "tinkertown/\(taskID)"
        let worktreeRel = ".tinkertown/\(taskID)"
        let command = "git worktree add \(worktreeRel) -b \(branch) \(baseBranch)"
        _ = try shell.run(command, cwd: root)

        let path = root.appendingPathComponent(worktreeRel)
        guard fs.fileExists(path) else {
            throw NSError(domain: "WorktreeManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Worktree path missing after create"])
        }
        return (worktreeRel, branch)
    }

    public func teardown(task: TaskRecord, root: URL) {
        _ = try? shell.run("git worktree remove \(task.worktreePath) --force", cwd: root)
        _ = try? shell.run("git branch -D \(task.branch)", cwd: root)
    }

    public func cleanupOrphaned(root: URL) {
        guard let output = try? shell.run("git worktree list --porcelain", cwd: root).stdout else { return }
        let lines = output.split(separator: "\n").map(String.init)
        for line in lines where line.hasPrefix("worktree ") {
            let path = String(line.dropFirst("worktree ".count))
            if path.contains("/.tinkertown/") {
                _ = try? shell.run("git worktree remove \(path) --force", cwd: root)
            }
        }
    }
}

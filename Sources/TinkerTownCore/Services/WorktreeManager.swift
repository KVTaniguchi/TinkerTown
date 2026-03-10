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

        // Validate that the new worktree HEAD matches the base branch SHA to guard against
        // accidental divergence at creation time.
        let baseSHAResult = try shell.run("git rev-parse \(baseBranch)", cwd: root)
        let baseSHA = baseSHAResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeSHAResult = try shell.run("git rev-parse HEAD", cwd: path)
        let worktreeSHA = worktreeSHAResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseSHA.isEmpty, baseSHA == worktreeSHA else {
            // If the fresh worktree somehow diverged from the base branch, clean up any
            // TinkerTown worktrees so a subsequent run can start from a known-good state.
            cleanupOrphaned(root: root)
            throw NSError(
                domain: "WorktreeManager",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Worktree HEAD does not match base branch SHA. Cleaned up TinkerTown worktrees; please retry the run."
                ]
            )
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

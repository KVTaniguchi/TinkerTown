import Foundation

public struct WorktreeManager {
    private let shell: ShellRunning
    private let fs: FileSysteming

    public init(shell: ShellRunning = ShellRunner(), fs: FileSysteming = LocalFileSystem()) {
        self.shell = shell
        self.fs = fs
    }

    public func create(taskID: String, root: URL, baseBranch: String) throws -> (path: String, branch: String) {
        // Git worktree add requires the base branch to resolve to a commit. Ensure at least one commit exists.
        try ensureAtLeastOneCommit(root: root)

        let branch = "tinkertown/\(taskID)"
        let worktreeRel = ".tinkertown/\(taskID)"
        // Remove leftover worktree/branch from a previous run so this run can create fresh (avoids "already exists").
        removeWorktreeAndBranchIfPresent(worktreeRel: worktreeRel, branch: branch, root: root)

        let command = "git worktree add \(worktreeRel) -b \(branch) \(baseBranch)"
        let addResult = try shell.run(command, cwd: root)

        let path = root.appendingPathComponent(worktreeRel)
        guard addResult.exitCode == 0, fs.fileExists(path) else {
            let detail = !addResult.stderr.isEmpty ? addResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Worktree path missing after create."
            let hint = detail.contains("invalid reference") || detail.contains("not a valid object")
                ? " The repository may have no commits yet; make an initial commit and retry."
                : ""
            throw NSError(
                domain: "WorktreeManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(detail)\(hint)"]
            )
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
        // Remove worktrees registered in git under .tinkertown/.
        if let output = try? shell.run("git worktree list --porcelain", cwd: root).stdout {
            let lines = output.split(separator: "\n").map(String.init)
            for line in lines where line.hasPrefix("worktree ") {
                let path = String(line.dropFirst("worktree ".count))
                if path.contains("/.tinkertown/") {
                    _ = try? shell.run("git worktree remove \(path) --force", cwd: root)
                    if let taskID = path.split(separator: "/").last.map(String.init), !taskID.isEmpty {
                        _ = try? shell.run("git branch -D tinkertown/\(taskID)", cwd: root)
                    }
                }
            }
        }

        // Also remove orphaned task directories under .tinkertown/ that exist on disk but are
        // no longer registered as git worktrees (left behind when a previous run was interrupted).
        let tinkerRoot = root.appendingPathComponent(".tinkertown")
        if let items = try? FileManager.default.contentsOfDirectory(at: tinkerRoot, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("task_") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    /// Removes the worktree at worktreeRel and deletes the branch if present (best-effort). Call before creating so a new run can reuse the path/branch.
    private func removeWorktreeAndBranchIfPresent(worktreeRel: String, branch: String, root: URL) {
        let fullPath = root.appendingPathComponent(worktreeRel)
        if fs.fileExists(fullPath) {
            _ = try? shell.run("git worktree remove \(worktreeRel) --force", cwd: root)
            // If the directory still exists after git cleanup (orphaned — not tracked by git worktree),
            // remove it directly so `git worktree add` can succeed on the next attempt.
            if fs.fileExists(fullPath) {
                try? FileManager.default.removeItem(at: fullPath)
            }
        }
        _ = try? shell.run("git branch -D \(branch)", cwd: root)
    }

    /// Ensures the repository has at least one commit so `git worktree add` can use the base branch.
    private func ensureAtLeastOneCommit(root: URL) throws {
        let headResult = try shell.run("git rev-parse --verify HEAD", cwd: root)
        if headResult.exitCode == 0 { return }
        let commitResult = try shell.run(#"git commit --allow-empty -m "Initial commit (created by TinkerTown)""#, cwd: root)
        guard commitResult.exitCode == 0 else {
            let msg = !commitResult.stderr.isEmpty ? commitResult.stderr : commitResult.stdout
            throw NSError(
                domain: "WorktreeManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Repository has no commits and creating initial commit failed: \(msg)"]
            )
        }
    }
}

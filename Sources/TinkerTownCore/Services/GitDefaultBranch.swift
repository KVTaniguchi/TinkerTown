import Foundation

/// Detects the repository's default branch (e.g. `main` or `master`) so callers
/// do not assume a fixed name. Uses origin/HEAD when available, then falls back
/// to verifying common branch names.
public struct GitDefaultBranch {
    private let shell: ShellRunning

    public init(shell: ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    /// Resolves the default branch name for the repository at `root`.
    /// 1. Tries `origin/HEAD` (e.g. after clone) to get the remote default.
    /// 2. Falls back to `main`, then `master` if either resolves to a commit.
    /// 3. If the repo has no commits yet, uses the current branch from `git branch --show-current`.
    /// - Throws: If the repo has no detectable default branch.
    public func detect(at root: URL) throws -> String {
        // Prefer remote default: refs/remotes/origin/HEAD -> refs/remotes/origin/main
        let symRef = try shell.run("git symbolic-ref refs/remotes/origin/HEAD", cwd: root)
        if symRef.exitCode == 0 {
            let ref = symRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "refs/remotes/origin/"
            if ref.hasPrefix(prefix) {
                let branch = String(ref.dropFirst(prefix.count))
                if !branch.isEmpty { return branch }
            }
        }

        // Fallback: try common names (requires at least one commit)
        for candidate in ["main", "master"] {
            let result = try shell.run("git rev-parse --verify \(candidate)", cwd: root)
            if result.exitCode == 0 { return candidate }
        }

        // Repo may have no commits yet (branch exists but doesn't resolve). Use current branch.
        let current = try shell.run("git branch --show-current", cwd: root)
        if current.exitCode == 0 {
            let branch = current.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { return branch }
        }

        throw NSError(
            domain: "GitDefaultBranch",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No default branch found. Ensure the repository has a branch (e.g. main or master)."]
        )
    }
}

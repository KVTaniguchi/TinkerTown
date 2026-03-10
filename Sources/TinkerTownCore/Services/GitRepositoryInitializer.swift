import Foundation

/// Ensures that a directory is a usable git repository with a `main` branch.
/// Uses `ShellRunning` so it can be exercised in tests and re-used by both
/// the CLI and Mac app.
public struct GitRepositoryInitializer {
    private let shell: ShellRunning

    public init(shell: ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    /// Ensure that `root` is a git repository with a `main` branch and at least one commit.
    ///
    /// - Returns: `true` if the repository already existed, `false` if it was created.
    @discardableResult
    public func ensureRepository(at root: URL) throws -> Bool {
        // Fast path: already inside a work tree.
        let inside = try shell.run("git rev-parse --is-inside-work-tree", cwd: root)
        let isRepo = inside.exitCode == 0 && inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        if isRepo {
            return true
        }

        // Initialize a new repository. Prefer `git init -b main` when available,
        // and fall back to `git init` + `git checkout -B main` for older versions.
        let initResult = try shell.run("git init -b main .", cwd: root)
        if initResult.exitCode != 0 {
            let legacyInit = try shell.run("git init .", cwd: root)
            guard legacyInit.exitCode == 0 else {
                throw NSError(
                    domain: "GitRepositoryInitializer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to initialize git repository: \(legacyInit.stderr.isEmpty ? legacyInit.stdout : legacyInit.stderr)"]
                )
            }
            let branchResult = try shell.run("git checkout -B main", cwd: root)
            guard branchResult.exitCode == 0 else {
                throw NSError(
                    domain: "GitRepositoryInitializer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create 'main' branch: \(branchResult.stderr.isEmpty ? branchResult.stdout : branchResult.stderr)"]
                )
            }
        }

        // Ensure there is at least one commit so downstream operations that
        // assume a history (e.g., worktrees) can function.
        let headResult = try shell.run("git rev-parse --verify HEAD", cwd: root)
        if headResult.exitCode != 0 {
            let addResult = try shell.run("git add .", cwd: root)
            guard addResult.exitCode == 0 else {
                throw NSError(
                    domain: "GitRepositoryInitializer",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to stage files for initial commit: \(addResult.stderr.isEmpty ? addResult.stdout : addResult.stderr)"]
                )
            }
            let commitCommand = #"git commit --allow-empty -m "Initial commit (created by TinkerTown)""#
            let commitResult = try shell.run(commitCommand, cwd: root)
            guard commitResult.exitCode == 0 else {
                throw NSError(
                    domain: "GitRepositoryInitializer",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create initial commit: \(commitResult.stderr.isEmpty ? commitResult.stdout : commitResult.stderr)"]
                )
            }
        }

        // Sanity-check that `main` now resolves.
        let mainResult = try shell.run("git rev-parse --verify main", cwd: root)
        guard mainResult.exitCode == 0 else {
            throw NSError(
                domain: "GitRepositoryInitializer",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Repository initialized but 'main' branch is not available."]
            )
        }

        return false
    }
}


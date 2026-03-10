import Foundation

public enum MergeDecision: String {
    case merged
    case rejected
    case failed
}

public struct MergeGate {
    private let shell: ShellRunning

    public init(shell: ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    public func validateScope(task: TaskRecord, root: URL) throws {
        // Reject stale verification evidence: if we have a recorded verification SHA and it does
        // not match the current branch HEAD, force a fresh verify instead of merging.
        if let verifiedAt = task.result.verifiedAtSHA, !verifiedAt.isEmpty {
            let head = try shell.run("git rev-parse \(task.branch)", cwd: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty, head != verifiedAt {
                throw NSError(domain: "MergeGate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stale verification evidence"])
            }
        }

        let diff = try shell.run("git diff --name-only main...\(task.branch)", cwd: root)
        let touched = Set(diff.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        let allowed = Set(task.targetFiles)
        if !touched.isSubset(of: allowed) {
            throw NSError(domain: "MergeGate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Out-of-scope file changes detected"])
        }

        for targetFile in task.targetFiles {
            let escaped = targetFile.replacingOccurrences(of: "'", with: "'\\''")
            let scan = try shell.run("git grep -n '<<<<<<<\\|=======\\|>>>>>>>' -- '\(escaped)'", cwd: root)
            if scan.exitCode == 0 && !scan.stdout.isEmpty {
                throw NSError(domain: "MergeGate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conflict markers present"])
            }
        }
    }

    public func merge(task: TaskRecord, root: URL) throws -> (decision: MergeDecision, mergeSHA: String?) {
        let mergeResult = try shell.run("git merge --no-ff \(task.branch) -m 'Merge \(task.taskID)'", cwd: root)
        if mergeResult.exitCode == 0 {
            let sha = try shell.run("git rev-parse HEAD", cwd: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (.merged, sha)
        }

        // single retry with fresh base
        _ = try? shell.run("git merge --abort", cwd: root)
        let retry = try shell.run("git merge --no-ff \(task.branch) -m 'Merge \(task.taskID) retry'", cwd: root)
        if retry.exitCode == 0 {
            let sha = try shell.run("git rev-parse HEAD", cwd: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (.merged, sha)
        }

        _ = try? shell.run("git merge --abort", cwd: root)
        return (.failed, nil)
    }
}

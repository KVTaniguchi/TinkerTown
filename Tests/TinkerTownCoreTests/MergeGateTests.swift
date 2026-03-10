import Foundation
import Testing
@testable import TinkerTownCore

struct MergeGateTests {
    @Test func rejectsOutOfScopeFileChanges() {
        let root = URL(fileURLWithPath: "/repo")
        let shell = StubShell(results: [
            "git diff --name-only main...tinkertown/task_001": ShellResult(exitCode: 0, stdout: "README.md\nOther.swift\n", stderr: ""),
            "git grep -n '<<<<<<<\\|=======\\|>>>>>>>' -- 'README.md'": ShellResult(exitCode: 1, stdout: "", stderr: "")
        ])
        let gate = MergeGate(shell: shell)

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

        #expect(throws: Error.self) {
            try gate.validateScope(task: task, root: root)
        }
    }

    @Test func rejectsConflictMarkersInTargetFiles() {
        let root = URL(fileURLWithPath: "/repo")
        let shell = StubShell(results: [
            "git diff --name-only main...tinkertown/task_001": ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
            "git grep -n '<<<<<<<\\|=======\\|>>>>>>>' -- 'README.md'": ShellResult(exitCode: 0, stdout: "README.md:1:<<<<<<< HEAD\n", stderr: "")
        ])
        let gate = MergeGate(shell: shell)

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

        #expect(throws: Error.self) {
            try gate.validateScope(task: task, root: root)
        }
    }

    @Test func rejectsStaleVerificationEvidence() {
        let root = URL(fileURLWithPath: "/repo")
        let shell = StubShell(results: [
            "git rev-parse tinkertown/task_001": ShellResult(exitCode: 0, stdout: "newsha\n", stderr: ""),
            "git diff --name-only main...tinkertown/task_001": ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
            "git grep -n '<<<<<<<\\|=======\\|>>>>>>>' -- 'README.md'": ShellResult(exitCode: 1, stdout: "", stderr: "")
        ])
        let gate = MergeGate(shell: shell)

        var result = TaskResult()
        result.verifiedAtSHA = "oldsha"

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
            verify: VerifyResult(command: "swift build"),
            result: result
        )

        #expect(throws: Error.self) {
            try gate.validateScope(task: task, root: root)
        }
    }

    @Test func mergesSuccessfullyAndReturnsSHA() throws {
        let root = URL(fileURLWithPath: "/repo")
        let shell = StubShell(results: [
            "git merge --no-ff tinkertown/task_001 -m 'Merge task_001'": ShellResult(exitCode: 0, stdout: "", stderr: ""),
            "git rev-parse HEAD": ShellResult(exitCode: 0, stdout: "abc123\n", stderr: "")
        ])
        let gate = MergeGate(shell: shell)

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

        let outcome = try gate.merge(task: task, root: root)
        #expect(outcome.decision == .merged)
        #expect(outcome.mergeSHA == "abc123")
    }

    @Test func failsAfterSingleRetryOnConflict() throws {
        let root = URL(fileURLWithPath: "/repo")
        let shell = StubShell(results: [
            "git merge --no-ff tinkertown/task_001 -m 'Merge task_001'": ShellResult(exitCode: 1, stdout: "", stderr: ""),
            "git merge --abort": ShellResult(exitCode: 0, stdout: "", stderr: ""),
            "git merge --no-ff tinkertown/task_001 -m 'Merge task_001 retry'": ShellResult(exitCode: 1, stdout: "", stderr: "")
        ])
        let gate = MergeGate(shell: shell)

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

        let outcome = try gate.merge(task: task, root: root)
        #expect(outcome.decision == .failed)
        #expect(outcome.mergeSHA == nil)
    }
}


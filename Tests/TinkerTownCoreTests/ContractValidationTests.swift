import Foundation
import Testing
@testable import TinkerTownCore

struct ContractValidationTests {
    @Test func runRecordValidationEnforcesRequiredFieldsAndVersion() throws {
        let config = OrchestratorConfig(maxParallelTasks: 2, maxRetriesPerTask: 3)
        var run = RunRecord(runID: "run_1", state: .runCreated, request: "req", config: config)
        try run.validate()

        run.runID = ""
        #expect(throws: ContractError.self) {
            try run.validate()
        }

        run.runID = "run_1"
        run.request = ""
        #expect(throws: ContractError.self) {
            try run.validate()
        }

        run.request = "req"
        run.schemaVersion = 999
        #expect(throws: ContractError.self) {
            try run.validate()
        }
    }

    @Test func taskRecordValidationEnforcesRequiredFieldsRetryAndVersion() throws {
        let verify = VerifyResult(command: "swift build")
        var task = TaskRecord(
            taskID: "task_001",
            runID: "run_1",
            title: "t",
            state: .taskCreated,
            priority: 1,
            assignedModel: "m",
            worktreePath: ".tinkertown/task_001",
            branch: "tinkertown/task_001",
            targetFiles: ["README.md"],
            maxRetries: 3,
            verify: verify
        )
        try task.validate()

        task.taskID = ""
        #expect(throws: ContractError.self) {
            try task.validate()
        }

        task.taskID = "task_001"
        task.runID = ""
        #expect(throws: ContractError.self) {
            try task.validate()
        }

        task.runID = "run_1"
        task.maxRetries = -1
        #expect(throws: ContractError.self) {
            try task.validate()
        }

        task.maxRetries = 3
        task.replacementDepth = 2
        #expect(throws: ContractError.self) {
            try task.validate()
        }

        task.replacementDepth = 1
        task.schemaVersion = 999
        #expect(throws: ContractError.self) {
            try task.validate()
        }
    }

    @Test func diagnosticRecordValidationEnforcesRequiredFields() throws {
        var d = DiagnosticRecord(taskID: "task_001", tool: "xcodebuild", severity: "error", code: "E", message: "msg")
        try d.validate()

        d.taskID = ""
        #expect(throws: ContractError.self) {
            try d.validate()
        }

        d.taskID = "task_001"
        d.tool = ""
        #expect(throws: ContractError.self) {
            try d.validate()
        }

        d.tool = "xcodebuild"
        d.message = ""
        #expect(throws: ContractError.self) {
            try d.validate()
        }
    }

    @Test func pdrRecordValidationEnforcesPdrIdAndTitle() throws {
        var pdr = PDRRecord(pdrId: "pdr_1", title: "My feature")
        try pdr.validate()

        pdr.pdrId = ""
        #expect(throws: ContractError.self) {
            try pdr.validate()
        }

        pdr.pdrId = "pdr_1"
        pdr.title = ""
        #expect(throws: ContractError.self) {
            try pdr.validate()
        }
    }
}


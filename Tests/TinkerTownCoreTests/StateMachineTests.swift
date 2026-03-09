import Testing
@testable import TinkerTownCore

struct StateMachineTests {
    @Test func allowsValidRunTransition() throws {
        try StateMachine.validateRunTransition(from: .runCreated, to: .planning)
    }

    @Test func rejectsInvalidRunTransition() {
        #expect(throws: StateMachineError.self) {
            try StateMachine.validateRunTransition(from: .runCreated, to: .completed)
        }
    }

    @Test func allowsRetryTaskTransition() throws {
        try StateMachine.validateTaskTransition(from: .verifyFailedRetryable, to: .prompted)
    }

    @Test func rejectsInvalidTaskTransition() {
        #expect(throws: StateMachineError.self) {
            try StateMachine.validateTaskTransition(from: .taskCreated, to: .mergeReady)
        }
    }
}

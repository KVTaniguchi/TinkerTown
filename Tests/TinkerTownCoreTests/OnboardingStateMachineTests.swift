import Foundation
import Testing
import TinkerTownCore

@Suite("OnboardingStateMachine")
struct OnboardingStateMachineTests {

    @Test("Step order and transitions")
    func stepOrder() {
        #expect(OnboardingStateMachine.nextStep(after: .welcome) == .deviceCheck)
        #expect(OnboardingStateMachine.nextStep(after: .deviceCheck) == .chooseTier)
        #expect(OnboardingStateMachine.nextStep(after: .completion) == nil)
        #expect(OnboardingStateMachine.previousStep(before: .welcome) == nil)
        #expect(OnboardingStateMachine.previousStep(before: .deviceCheck) == .welcome)
    }

    @Test("Advance updates state")
    func advance() {
        var state = OnboardingState.initial
        #expect(state.currentStep == .welcome)
        try? OnboardingStateMachine.advance(state: &state)
        #expect(state.currentStep == .deviceCheck)
    }

    @Test("Is complete only when at completion with date")
    func isComplete() {
        var state = OnboardingState.initial
        #expect(!OnboardingStateMachine.isComplete(state))
        state.currentStep = .completion
        #expect(!OnboardingStateMachine.isComplete(state))
        state.completedAt = Date()
        #expect(OnboardingStateMachine.isComplete(state))
    }

    @Test("Step index and total")
    func stepIndex() {
        #expect(OnboardingStateMachine.stepIndex(.welcome) == 0)
        #expect(OnboardingStateMachine.stepIndex(.completion) == OnboardingStateMachine.totalSteps - 1)
        #expect(OnboardingStateMachine.totalSteps == OnboardingStep.allCases.count)
    }
}

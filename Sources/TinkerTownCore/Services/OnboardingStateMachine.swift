import Foundation

/// Deterministic step transitions and resume-on-restart behavior for onboarding.
public struct OnboardingStateMachine {
    public enum TransitionError: Error, LocalizedError {
        case invalidStep(OnboardingStep)
        case cannotGoBack(from: OnboardingStep)

        public var errorDescription: String? {
            switch self {
            case .invalidStep(let s): return "Invalid step: \(s.rawValue)"
            case .cannotGoBack(let s): return "Cannot go back from \(s.rawValue)"
            }
        }
    }

    private static let stepOrder: [OnboardingStep] = OnboardingStep.allCases

    /// Returns the next step, or nil if already at completion.
    public static func nextStep(after step: OnboardingStep) -> OnboardingStep? {
        guard let idx = stepOrder.firstIndex(of: step), idx + 1 < stepOrder.count else { return nil }
        return stepOrder[idx + 1]
    }

    /// Returns the previous step, or nil if at welcome.
    public static func previousStep(before step: OnboardingStep) -> OnboardingStep? {
        guard let idx = stepOrder.firstIndex(of: step), idx > 0 else { return nil }
        return stepOrder[idx - 1]
    }

    /// Validate and transition to next step; updates state in place.
    public static func advance(state: inout OnboardingState) throws {
        state.lastError = nil
        state.updatedAt = Date()
        guard let next = nextStep(after: state.currentStep) else {
            if state.currentStep == .completion {
                state.completedAt = state.completedAt ?? Date()
            }
            return
        }
        state.currentStep = next
    }

    /// Go back one step if allowed.
    public static func goBack(state: inout OnboardingState) throws {
        state.lastError = nil
        state.updatedAt = Date()
        guard let prev = previousStep(before: state.currentStep) else { return }
        state.currentStep = prev
    }

    /// Jump to a specific step (e.g. resume); only allow current or earlier steps for "back".
    public static func setStep(state: inout OnboardingState, to step: OnboardingStep) {
        state.currentStep = step
        state.lastError = nil
        state.updatedAt = Date()
    }

    /// Whether onboarding is considered complete (user reached completion and can open main app).
    public static func isComplete(_ state: OnboardingState) -> Bool {
        state.currentStep == .completion && state.completedAt != nil
    }

    /// Step index for progress UI (0-based).
    public static func stepIndex(_ step: OnboardingStep) -> Int {
        stepOrder.firstIndex(of: step) ?? 0
    }

    public static var totalSteps: Int { stepOrder.count }
}

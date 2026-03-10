import Foundation

/// Maps errors to user-readable reasons and suggested fix actions.
public struct RemediationEngine {
    public init() {}

    public struct Remediation: Sendable {
        public let reason: String
        public let action: String
        public let actionLabel: String?

        public init(reason: String, action: String, actionLabel: String? = nil) {
            self.reason = reason
            self.action = action
            self.actionLabel = actionLabel
        }
    }

    public func remediate(error: Error, context: String = "") -> Remediation {
        let message = error.localizedDescription
        let lower = message.lowercased()

        if lower.contains("disk") || lower.contains("storage") || lower.contains("space") {
            return Remediation(
                reason: "Not enough free disk space for the selected model.",
                action: "Free space in System Settings → General → Storage, or choose a smaller model tier.",
                actionLabel: "Open Storage Settings"
            )
        }
        if lower.contains("network") || lower.contains("connection") || lower.contains("offline") {
            return Remediation(
                reason: "Network connection was interrupted.",
                action: "Check your internet connection and try again. Downloads can be resumed.",
                actionLabel: "Retry"
            )
        }
        if lower.contains("checksum") || lower.contains("verification") || lower.contains("signature") {
            return Remediation(
                reason: "Downloaded file didn’t pass verification.",
                action: "The file will be discarded. Try again to download from the trusted source.",
                actionLabel: "Retry download"
            )
        }
        if lower.contains("ollama") || lower.contains("11434") || lower.contains("runtime") {
            return Remediation(
                reason: "Local model runtime (Ollama) is not running or not installed.",
                action: "Install Ollama from ollama.com and start it, or ensure it’s running in the background.",
                actionLabel: "Open Ollama"
            )
        }
        if lower.contains("memory") || lower.contains("ram") {
            return Remediation(
                reason: "Not enough memory for this model.",
                action: "Close other apps or choose a smaller model tier (e.g. Fast).",
                actionLabel: nil
            )
        }
        if lower.contains("git") || lower.contains("repository") {
            return Remediation(
                reason: "Repository or Git requirement not met.",
                action: "Select a valid Git repository and ensure the main branch exists.",
                actionLabel: "Choose Repository"
            )
        }

        return Remediation(
            reason: message.isEmpty ? "Something went wrong." : message,
            action: "Try again. If the problem continues, restart the app.",
            actionLabel: "Retry"
        )
    }
}

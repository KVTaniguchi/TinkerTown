import Foundation

/// Paths for app-scoped data (onboarding, models, config) inside the sandbox container.
/// Used by the Mac app; root is typically Application Support/TinkerTown.
public struct AppContainerPaths {
    public let root: URL
    public let modelsDir: URL
    public let manifestsDir: URL
    public let tempDir: URL
    public let logsDir: URL
    public let onboardingStateFile: URL
    public let appConfigFile: URL
    public let installedModelsFile: URL
    public let updatePolicyFile: URL

    public init(root: URL) {
        self.root = root
        modelsDir = root.appendingPathComponent("models", isDirectory: true)
        manifestsDir = root.appendingPathComponent("manifests", isDirectory: true)
        tempDir = root.appendingPathComponent("temp", isDirectory: true)
        logsDir = root.appendingPathComponent("logs", isDirectory: true)
        onboardingStateFile = root.appendingPathComponent("onboarding_state.json")
        appConfigFile = root.appendingPathComponent("app_config.json")
        installedModelsFile = root.appendingPathComponent("installed_models.json")
        updatePolicyFile = root.appendingPathComponent("update_policy.json")
    }

    /// Default app container root for process (Application Support/TinkerTown).
    public static func defaultRoot() -> URL {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fm.temporaryDirectory.appendingPathComponent("TinkerTown", isDirectory: true)
        }
        return support.appendingPathComponent("TinkerTown", isDirectory: true)
    }

    public func modelDir(modelId: String, version: String) -> URL {
        modelsDir.appendingPathComponent("\(modelId)_\(version)", isDirectory: true)
    }

    public func downloadTempFile(modelId: String, suffix: String = "download") -> URL {
        tempDir.appendingPathComponent("\(modelId).\(suffix)")
    }
}

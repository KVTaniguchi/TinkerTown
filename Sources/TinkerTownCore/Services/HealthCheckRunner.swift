import Foundation

/// Executes onboarding validation checks and returns structured outcomes.
public struct HealthCheckRunner {
    private let runtime: ModelRuntimeAdapter
    private let paths: AppContainerPaths
    private let remediation: RemediationEngine
    private let shell: ShellRunning
    private let repoURL: URL?

    public init(
        runtime: ModelRuntimeAdapter,
        paths: AppContainerPaths,
        remediation: RemediationEngine = RemediationEngine(),
        shell: ShellRunning = ShellRunner(),
        repoURL: URL? = nil
    ) {
        self.runtime = runtime
        self.paths = paths
        self.remediation = remediation
        self.shell = shell
        self.repoURL = repoURL
    }

    /// Run all health checks and return results.
    @MainActor
    public func run(plannerModelId: String?, workerModelId: String?) async -> [HealthCheckResult] {
        var results: [HealthCheckResult] = []

        // 1. Model runtime responds
        let runtimeOk = runtime.isAvailable()
        if runtimeOk {
            results.append(HealthCheckResult(checkName: "Model runtime", status: .pass, details: "Ollama is reachable."))
        } else {
            let rem = remediation.remediate(error: NSError(domain: "HealthCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama not reachable"]))
            results.append(HealthCheckResult(checkName: "Model runtime", status: .fail, details: rem.reason, remediation: rem.action))
        }

        // 2. Planner and worker role calls succeed (simple generate)
        if let planner = plannerModelId, !planner.isEmpty {
            let response = runtime.generate(modelId: planner, prompt: "Say OK", numCtx: 256)
            if response != nil {
                results.append(HealthCheckResult(checkName: "Planner model", status: .pass, details: "Planner model responded."))
            } else {
                results.append(HealthCheckResult(checkName: "Planner model", status: .fail, details: "Planner model did not respond.", remediation: "Ensure the model is installed and Ollama is running."))
            }
        }
        if let worker = workerModelId, !worker.isEmpty, worker != plannerModelId {
            let response = runtime.generate(modelId: worker, prompt: "Say OK", numCtx: 256)
            if response != nil {
                results.append(HealthCheckResult(checkName: "Worker model", status: .pass, details: "Worker model responded."))
            } else {
                results.append(HealthCheckResult(checkName: "Worker model", status: .fail, details: "Worker model did not respond.", remediation: "Ensure the model is installed and Ollama is running."))
            }
        }

        // 3. Repo preflight (auto-initialize when possible)
        if let repoURL {
            do {
                let initializer = GitRepositoryInitializer(shell: shell)
                _ = try initializer.ensureRepository(at: repoURL)
                results.append(HealthCheckResult(checkName: "Repo preflight", status: .pass, details: "Repository is a valid git worktree."))
            } catch {
                results.append(HealthCheckResult(checkName: "Repo preflight", status: .fail, details: "Selected path is not a git repository.", remediation: error.localizedDescription))
            }
        } else {
            results.append(HealthCheckResult(checkName: "Repo preflight", status: .warn, details: "No repository selected during onboarding.", remediation: "Pick a repository in the main app before running tasks."))
        }

        // 4. Build probe
        if let repoURL {
            do {
                let fileManager = FileManager.default
                let hasSwiftPackage = fileManager.fileExists(atPath: repoURL.appendingPathComponent("Package.swift").path)
                let command = hasSwiftPackage ? "swift build" : "xcodebuild -list"
                let probe = try shell.run(command, cwd: repoURL)
                if probe.exitCode == 0 {
                    results.append(HealthCheckResult(checkName: "Build probe", status: .pass, details: "Build probe succeeded."))
                } else {
                    results.append(HealthCheckResult(checkName: "Build probe", status: .fail, details: "Build probe failed.", remediation: probe.stderr.isEmpty ? probe.stdout : probe.stderr))
                }
            } catch {
                results.append(HealthCheckResult(checkName: "Build probe", status: .fail, details: "Build probe could not run.", remediation: error.localizedDescription))
            }
        } else {
            results.append(HealthCheckResult(checkName: "Build probe", status: .warn, details: "Build probe requires a selected repository."))
        }

        // 5. Minimal orchestration smoke test
        let hasReadyModels = plannerModelId != nil || workerModelId != nil
        if runtimeOk && hasReadyModels {
            let containerWritable = FileManager.default.isWritableFile(atPath: paths.root.path) || !FileManager.default.fileExists(atPath: paths.root.path)
            if containerWritable {
                results.append(HealthCheckResult(checkName: "Orchestration", status: .pass, details: "Runtime and configuration are ready for task orchestration."))
            } else {
                results.append(HealthCheckResult(checkName: "Orchestration", status: .fail, details: "App data directory is not writable.", remediation: "Grant filesystem access and retry onboarding."))
            }
        } else {
            results.append(HealthCheckResult(checkName: "Orchestration", status: .warn, details: "Requires runtime and at least one selected model to pass fully."))
        }

        return results
    }
}

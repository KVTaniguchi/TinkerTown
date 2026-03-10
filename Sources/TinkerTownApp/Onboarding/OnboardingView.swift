import SwiftUI
import TinkerTownCore

/// Sendable holder for progress callback so we can pass it to nonisolated install.
private final class ProgressSender: @unchecked Sendable {
    var handler: ((ModelInstallProgress) -> Void)?
}

@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published var state: OnboardingState
    @Published var diagnosticsResult: SystemDiagnosticsResult?
    @Published var catalog: [ModelManifest] = []
    @Published var installProgress: [String: ModelInstallProgress] = [:]
    @Published var healthCheckResults: [HealthCheckResult] = []
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let paths: AppContainerPaths
    private let store: OnboardingStore
    private let configFacade: ConfigFacade
    private let diagnostics = SystemDiagnosticsService()
    private let catalogService: ModelCatalogService
    private var installManager: ModelInstallManager?
    private var healthRunner: HealthCheckRunner?

    public var onComplete: (() -> Void)?

    public init(paths: AppContainerPaths, onComplete: (() -> Void)? = nil) {
        self.paths = paths
        store = OnboardingStore(paths: paths)
        state = store.load()
        configFacade = ConfigFacade(paths: paths)
        catalogService = ModelCatalogService()
        self.onComplete = onComplete
    }

    public func advance() {
        do {
            try validateCurrentStepBeforeAdvance()
            try OnboardingStateMachine.advance(state: &state)
            try store.save(state)
            if state.currentStep == .completion {
                try store.markComplete()
                try persistSettings()
                DispatchQueue.main.async { [weak self] in
                    self?.onComplete?()
                }
            }
        } catch {
            state.lastError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    public func goBack() {
        do {
            try OnboardingStateMachine.goBack(state: &state)
            try store.save(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setTier(_ tier: ModelTier) {
        state.selectedTier = tier
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func setPlanner(_ modelId: String?) {
        state.plannerModelId = modelId
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func setWorker(_ modelId: String?) {
        state.workerModelId = modelId
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func setOfflineMode(_ value: Bool) {
        state.offlineMode = value
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func runDeviceCheck() {
        diagnosticsResult = diagnostics.run()
        try? store.save(state)
    }

    public func loadCatalog() async {
        do {
            let result = diagnostics.run()
            let service = ModelCatalogService(manifestURL: state.offlineMode ? nil : catalogService.manifestURL)
            let manifests = try await service.fetchManifest()
            catalog = service.compatibleModels(
                from: manifests,
                tier: state.selectedTier,
                ramGB: parseGB(from: result.capabilities.first(where: { $0.name == "Memory" })?.detail),
                diskGB: parseGB(from: result.capabilities.first(where: { $0.name == "Free disk" })?.detail),
                chip: parseChip(from: result.capabilities.first(where: { $0.name == "Chip" })?.detail)
            )
            if diagnosticsResult == nil { diagnosticsResult = result }
        } catch {
            catalog = ModelCatalogService.bundledManifest()
            if state.selectedTier != nil {
                catalog = catalog.filter { $0.tier == state.selectedTier }
            }
        }
    }

    public func assignDefaultRoles() {
        let tier = state.selectedTier ?? .fast
        let forTier = catalog.filter { $0.tier == tier }
        if let planner = forTier.first(where: { $0.roleDefault == .planner || $0.roleDefault == .both }) {
            state.plannerModelId = planner.id
        } else if let first = forTier.first {
            state.plannerModelId = first.id
        }
        if let worker = forTier.first(where: { $0.roleDefault == .worker || $0.roleDefault == .both }) {
            state.workerModelId = worker.id
        } else if let first = forTier.first {
            state.workerModelId = first.id
        }
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func startDownloads() async {
        installManager = ModelInstallManager(paths: paths, offlineMode: state.offlineMode)
        let manager = installManager!
        let toInstall = modelsToInstall()
        for manifest in toInstall {
            await installOne(manager: manager, manifest: manifest)
        }
        state.downloadJobs = manager.loadJobs()
        state.updatedAt = Date()
        try? store.save(state)
    }

    public func retryFailedDownloads() async {
        guard let manager = installManager else {
            await startDownloads()
            return
        }
        let failedIDs = installProgress.compactMap { $0.value.status == .failed ? $0.key : nil }
        let toRetry = modelsToInstall().filter { failedIDs.contains($0.id) }
        for manifest in toRetry {
            await installOne(manager: manager, manifest: manifest)
        }
        state.downloadJobs = manager.loadJobs()
        state.updatedAt = Date()
        try? store.save(state)
    }

    private func modelsToInstall() -> [ModelManifest] {
        var ids = Set<String>()
        if let p = state.plannerModelId { ids.insert(p) }
        if let w = state.workerModelId { ids.insert(w) }
        return catalog.filter { ids.contains($0.id) }
    }

    private func installOne(manager: ModelInstallManager, manifest: ModelManifest) async {
        let progressSender = ProgressSender()
        progressSender.handler = { [weak self] p in
            self?.installProgress[p.modelId] = p
        }
        do {
            try await manager.install(manifest: manifest) { p in
                Task { @MainActor in
                    progressSender.handler?(p)
                }
            }
            state.downloadJobs = manager.loadJobs()
        } catch {
            state.lastError = error.localizedDescription
            installProgress[manifest.id] = ModelInstallProgress(modelId: manifest.id, status: .failed, error: error.localizedDescription)
            state.downloadJobs = manager.loadJobs()
        }
    }

    public func runHealthCheck() async {
        let installed = installManager?.loadInstalledModels() ?? [:]
        let runtime = ModelRuntimeAdapter(installedModels: installed)
        let runner = HealthCheckRunner(runtime: runtime, paths: paths)
        healthRunner = runner
        let results = await runner.run(plannerModelId: state.plannerModelId, workerModelId: state.workerModelId)
        healthCheckResults = results
        try? store.save(state)
    }

    private func persistSettings() throws {
        var settings = try configFacade.loadSettings()
        settings.useOllama = true
        settings.plannerModelId = state.plannerModelId
        settings.workerModelId = state.workerModelId
        settings.offlineMode = state.offlineMode
        try configFacade.saveSettings(settings)
    }

    private func validateCurrentStepBeforeAdvance() throws {
        switch state.currentStep {
        case .deviceCheck:
            if diagnosticsResult == nil {
                throw NSError(domain: "Onboarding", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run device checks before continuing."])
            }
        case .chooseTier:
            guard let tier = state.selectedTier else {
                throw NSError(domain: "Onboarding", code: 2, userInfo: [NSLocalizedDescriptionKey: "Select a performance tier to continue."])
            }
            if let diagnosticsResult, !diagnosticsResult.canRunTier(tier) {
                throw NSError(domain: "Onboarding", code: 3, userInfo: [NSLocalizedDescriptionKey: "Selected tier exceeds your device capacity. Choose a lighter tier."])
            }
        case .roleAssignment:
            if state.plannerModelId == nil || state.workerModelId == nil {
                throw NSError(domain: "Onboarding", code: 4, userInfo: [NSLocalizedDescriptionKey: "Select planner and worker models before continuing."])
            }
        case .downloadInstall:
            let statuses = modelsToInstallForDisplay().compactMap { installProgress[$0.id]?.status }
            let expected = modelsToInstallForDisplay().count
            let allCompleted = statuses.count == expected && statuses.allSatisfy { $0 == .completed }
            if !allCompleted {
                throw NSError(domain: "Onboarding", code: 5, userInfo: [NSLocalizedDescriptionKey: "All model installs must finish successfully before continuing."])
            }
        case .healthCheck:
            if healthCheckResults.isEmpty {
                throw NSError(domain: "Onboarding", code: 6, userInfo: [NSLocalizedDescriptionKey: "Run the health check before continuing."])
            }
            if healthCheckResults.contains(where: { $0.status == .fail }) {
                throw NSError(domain: "Onboarding", code: 7, userInfo: [NSLocalizedDescriptionKey: "Resolve failing health checks before continuing."])
            }
        default:
            break
        }
    }

    private func parseGB(from detail: String?) -> Double? {
        guard let detail else { return nil }
        return detail.split(separator: " ").first.flatMap { Double($0) }
    }

    private func parseChip(from detail: String?) -> String? {
        guard let detail else { return nil }
        return detail.contains("Apple Silicon") ? "arm64" : "x86_64"
    }

    public var progressFraction: Double {
        Double(OnboardingStateMachine.stepIndex(state.currentStep)) / Double(max(1, OnboardingStateMachine.totalSteps))
    }
}

// MARK: - Wizard container

public struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel

    public init(paths: AppContainerPaths, onComplete: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(paths: paths, onComplete: onComplete))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: viewModel.progressFraction)
                .padding(.horizontal, 40)
                .padding(.top, 20)

            Group {
                switch viewModel.state.currentStep {
                case .welcome: WelcomeStepView(onNext: { viewModel.advance() })
                case .deviceCheck: DeviceCheckStepView(viewModel: viewModel)
                case .chooseTier: ChooseTierStepView(viewModel: viewModel)
                case .roleAssignment: RoleAssignmentStepView(viewModel: viewModel)
                case .privacy: PrivacyStepView(viewModel: viewModel)
                case .downloadInstall: DownloadInstallStepView(viewModel: viewModel)
                case .healthCheck: HealthCheckStepView(viewModel: viewModel)
                case .completion: CompletionStepView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            if let error = viewModel.state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            HStack {
                if viewModel.state.currentStep != .welcome && viewModel.state.currentStep != .completion {
                    Button("Back") { viewModel.goBack() }
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if viewModel.state.currentStep == .deviceCheck {
                viewModel.runDeviceCheck()
            }
            if viewModel.state.currentStep == .chooseTier && viewModel.diagnosticsResult == nil {
                viewModel.runDeviceCheck()
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to TinkerTown")
                .font(.title)
            Text("Setup takes a few minutes and no terminal is required. We’ll check your Mac, pick a model tier, and install everything needed to run local coding tasks.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Start setup", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Device check

private struct DeviceCheckStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device check")
                .font(.title2)
            Text("We’ve checked your Mac. Make sure everything looks good before continuing.")
                .foregroundStyle(.secondary)

            if let result = viewModel.diagnosticsResult {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.capabilities, id: \.name) { cap in
                        HStack {
                            Circle()
                                .fill(cap.ok ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(cap.name)
                            Spacer()
                            Text(cap.detail)
                                .foregroundStyle(.secondary)
                        }
                        if let rec = cap.recommendation {
                            Text(rec)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))

                Text("Recommended tier: \(result.recommendedTier.rawValue.capitalized)")
                    .font(.headline)
            }

            Button("Continue") { viewModel.advance() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 400, alignment: .leading)
        .onAppear { viewModel.runDeviceCheck() }
    }
}

// MARK: - Choose tier

private struct ChooseTierStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose performance tier")
                .font(.title2)
            Text("Pick the balance of speed and quality that fits your Mac.")
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                TierCard(
                    title: "Fast",
                    subtitle: "Recommended",
                    description: "Smaller model, lower resource use.",
                    disk: "~5 GB",
                    ram: "8 GB",
                    selected: viewModel.state.selectedTier == .fast,
                    action: { viewModel.setTier(.fast) }
                )
                TierCard(
                    title: "Balanced",
                    subtitle: nil,
                    description: "Medium model for everyday use.",
                    disk: "~10 GB",
                    ram: "16 GB",
                    selected: viewModel.state.selectedTier == .balanced,
                    action: { viewModel.setTier(.balanced) }
                )
                TierCard(
                    title: "Best quality",
                    subtitle: nil,
                    description: "Largest model, best results.",
                    disk: "~22 GB",
                    ram: "24 GB",
                    selected: viewModel.state.selectedTier == .quality,
                    action: { viewModel.setTier(.quality) }
                )
            }

            Button("Continue") {
                if viewModel.state.selectedTier == nil {
                    viewModel.setTier(.fast)
                }
                viewModel.advance()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct TierCard: View {
    let title: String
    let subtitle: String?
    let description: String
    let disk: String
    let ram: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                if let s = subtitle {
                    Text(s)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Disk: \(disk)")
                    .font(.caption2)
                Text("RAM: \(ram)")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(selected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Role assignment

private struct RoleAssignmentStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var catalogLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model roles")
                .font(.title2)
            Text("Planner decides tasks; Worker writes code. We’ve preselected models for your tier.")
                .foregroundStyle(.secondary)

            if !catalogLoaded {
                ProgressView()
                Text("Loading models…")
                    .font(.caption)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Planner model")
                            .font(.headline)
                        Picker("", selection: Binding(
                            get: { viewModel.state.plannerModelId ?? "" },
                            set: { viewModel.setPlanner($0.isEmpty ? nil : $0) }
                        )) {
                            Text("—").tag("")
                            ForEach(viewModel.catalog, id: \.id) { m in
                                Text(m.displayName).tag(m.id)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Worker model")
                            .font(.headline)
                        Picker("", selection: Binding(
                            get: { viewModel.state.workerModelId ?? "" },
                            set: { viewModel.setWorker($0.isEmpty ? nil : $0) }
                        )) {
                            Text("—").tag("")
                            ForEach(viewModel.catalog, id: \.id) { m in
                                Text(m.displayName).tag(m.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            Button("Continue") { viewModel.advance() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .onAppear {
            if !catalogLoaded {
                Task {
                    await viewModel.loadCatalog()
                    viewModel.assignDefaultRoles()
                    catalogLoaded = true
                }
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & offline")
                .font(.title2)
            Toggle("Use local models only", isOn: Binding(
                get: { viewModel.state.offlineMode },
                set: { viewModel.setOfflineMode($0) }
            ))
            Text("When enabled, only local models are used. Network is used only for downloads and updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Continue") { viewModel.advance() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

// MARK: - Download & install

private struct DownloadInstallStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download & install")
                .font(.title2)
            Text("Models will be installed via Ollama. If Ollama isn’t running, start it first.")
                .foregroundStyle(.secondary)

            ForEach(viewModel.modelsToInstallForDisplay(), id: \.id) { model in
                let p = viewModel.installProgress[model.id]
                HStack {
                    Text(model.displayName)
                    Spacer()
                    Text(p.map { statusLabel($0.status) } ?? "Pending")
                        .foregroundStyle(.secondary)
                    if let prog = p, let total = prog.totalBytes, total > 0 {
                        Text("\(prog.bytesDownloaded / 1_000_000) / \(total / 1_000_000) MB")
                            .font(.caption)
                    }
                }
                if let err = p?.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !started {
                Button("Start install") {
                    started = true
                    Task { await viewModel.startDownloads() }
                }
                .buttonStyle(.borderedProminent)
            } else if viewModel.modelsToInstallForDisplay().allSatisfy({ viewModel.installProgress[$0.id]?.status == .completed }) {
                Button("Continue") { viewModel.advance() }
                    .buttonStyle(.borderedProminent)
            } else if viewModel.modelsToInstallForDisplay().contains(where: { viewModel.installProgress[$0.id]?.status == .failed }) {
                Button("Retry failed installs") {
                    Task { await viewModel.retryFailedDownloads() }
                }
                .buttonStyle(.bordered)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func statusLabel(_ s: DownloadJobStatus) -> String {
        switch s {
        case .pending: return "Pending"
        case .downloading: return "Downloading…"
        case .paused: return "Paused"
        case .verifying: return "Verifying…"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

extension OnboardingViewModel {
    func modelsToInstallForDisplay() -> [ModelManifest] {
        var ids = Set<String>()
        if let p = plannerModelId { ids.insert(p) }
        if let w = workerModelId { ids.insert(w) }
        return catalog.filter { ids.contains($0.id) }
    }
}

// Fix: OnboardingViewModel has state.plannerModelId / state.workerModelId
extension OnboardingViewModel {
    var plannerModelId: String? { state.plannerModelId }
    var workerModelId: String? { state.workerModelId }
}

// MARK: - Health check

private struct HealthCheckStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var run = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Health check")
                .font(.title2)
            Text("Run a quick test to ensure the runtime and models respond.")
                .foregroundStyle(.secondary)

            if run && !viewModel.healthCheckResults.isEmpty {
                ForEach(viewModel.healthCheckResults, id: \.checkName) { r in
                    HStack {
                        Circle()
                            .fill(color(for: r.status))
                            .frame(width: 10, height: 10)
                        Text(r.checkName)
                        Spacer()
                        Text(r.details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let rem = r.remediation {
                        Text(rem)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !run {
                Button("Run quick test") {
                    run = true
                    Task { await viewModel.runHealthCheck() }
                }
                .buttonStyle(.borderedProminent)
            } else if viewModel.healthCheckResults.isEmpty {
                ProgressView()
            } else {
                Button("Continue") { viewModel.advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.healthCheckResults.contains(where: { $0.status == .fail }))
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func color(for s: HealthCheckStatus) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}

// MARK: - Completion

private struct CompletionStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("You’re all set")
                .font(.title)
            Text("Setup is complete. Installed models: \(viewModel.state.plannerModelId ?? "—") (planner), \(viewModel.state.workerModelId ?? "—") (worker). Offline mode: \(viewModel.state.offlineMode ? "On" : "Off").")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Open TinkerTown") {
                viewModel.advance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

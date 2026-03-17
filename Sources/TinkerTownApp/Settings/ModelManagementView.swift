import SwiftUI
import TinkerTownCore

struct ModelManagementView: View {
    let paths: AppContainerPaths
    @State private var installed: [String: InstalledModel] = [:]
    @State private var errorMessage: String?
    @State private var settings: ConfigFacade.AppSettings = .default
    @State private var busyModelIDs: Set<String> = []

    private var installManager: ModelInstallManager {
        ModelInstallManager(paths: paths)
    }

    private var configFacade: ConfigFacade {
        ConfigFacade(paths: paths)
    }

    /// All available model IDs: installed models plus whatever's in the workspace config.
    private var availableModelIDs: [String] {
        let ids = installed.keys.sorted()
        return ids.isEmpty ? ["qwen2.5-coder:32b", "qwen2.5-coder:7b"] : ids
    }

    var body: some View {
        Form {
            Section {
                modelRolePicker(
                    label: "Mayor (Planner)",
                    detail: "Plans tasks from the project plan and delegates to Tinkers.",
                    binding: Binding(
                        get: { settings.plannerModelId ?? "" },
                        set: { settings.plannerModelId = $0.isEmpty ? nil : $0; saveSettings() }
                    )
                )
                modelRolePicker(
                    label: "Tinker (Worker)",
                    detail: "Implements individual tasks by writing code patches.",
                    binding: Binding(
                        get: { settings.workerModelId ?? "" },
                        set: { settings.workerModelId = $0.isEmpty ? nil : $0; saveSettings() }
                    )
                )
                Text("Leave blank to use the model configured in each workspace's .tinkertown/config.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Model roles")
            }

            Section("Installed models") {
                ForEach(Array(installed.values).sorted(by: { $0.id < $1.id }), id: \.id) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.id)
                                .font(.headline)
                            Text("v\(model.version) · \(formatBytes(model.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let last = model.lastUsedAt {
                                Text("Last used: \(last.formatted())")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(model.status.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Reinstall") {
                            Task { await reinstallModel(model.id) }
                        }
                        .disabled(busyModelIDs.contains(model.id))
                        Button("Update") {
                            Task { await updateModel(model.id) }
                        }
                        .disabled(busyModelIDs.contains(model.id))
                        Button("Remove", role: .destructive) {
                            removeModel(model.id)
                        }
                        .disabled(busyModelIDs.contains(model.id))
                    }
                    .padding(.vertical, 4)
                }
                if installed.isEmpty {
                    Text("No models installed. Complete onboarding to install models.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Auto-update") {
                Toggle("Automatically check for updates", isOn: $settings.updatePolicy.autoUpdateEnabled)
                Toggle("Wi‑Fi only", isOn: $settings.updatePolicy.wifiOnly)
                    .disabled(!settings.updatePolicy.autoUpdateEnabled)
                Toggle("When charging only", isOn: $settings.updatePolicy.chargingOnly)
                    .disabled(!settings.updatePolicy.autoUpdateEnabled)
            }

            if let err = errorMessage {
                Section {
                    Text(err)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
        }
        .onChange(of: settings.updatePolicy.autoUpdateEnabled) { _ in saveSettings() }
        .onChange(of: settings.updatePolicy.wifiOnly) { _ in saveSettings() }
        .onChange(of: settings.updatePolicy.chargingOnly) { _ in saveSettings() }
    }

    private func reload() {
        installed = installManager.loadInstalledModels()
        settings = (try? configFacade.loadSettings()) ?? .default
    }

    private func removeModel(_ modelId: String) {
        do {
            try installManager.removeModel(modelId: modelId)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reinstallModel(_ modelId: String) async {
        guard let manifest = ModelCatalogService.bundledManifest().first(where: { $0.id == modelId }) else {
            errorMessage = "No manifest available for \(modelId)."
            return
        }
        busyModelIDs.insert(modelId)
        defer { busyModelIDs.remove(modelId) }
        do {
            try await installManager.reinstall(modelId: modelId, manifest: manifest) { _ in }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateModel(_ modelId: String) async {
        guard let manifest = ModelCatalogService.bundledManifest().first(where: { $0.id == modelId }) else {
            errorMessage = "No update manifest available for \(modelId)."
            return
        }
        busyModelIDs.insert(modelId)
        defer { busyModelIDs.remove(modelId) }
        do {
            try await installManager.update(modelId: modelId, to: manifest) { _ in }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func modelRolePicker(label: String, detail: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("", selection: binding) {
                    Text("Use workspace config").tag("")
                    Divider()
                    ForEach(availableModelIDs, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                if !binding.wrappedValue.isEmpty {
                    Button("Clear") { binding.wrappedValue = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func saveSettings() {
        do {
            try configFacade.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        let gb = Double(n) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(n) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
}

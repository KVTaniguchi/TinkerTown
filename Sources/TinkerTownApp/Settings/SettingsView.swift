import SwiftUI
import TinkerTownCore

struct SettingsView: View {
    let paths: AppContainerPaths?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ConfigFacade.AppSettings = .default
    @State private var errorMessage: String?

    private var configFacade: ConfigFacade? {
        guard let paths else { return nil }
        return ConfigFacade(paths: paths)
    }

    var body: some View {
        if let paths {
            TabView {
                ModelManagementView(paths: paths)
                    .tabItem { Label("Models", systemImage: "cpu") }
                privacyTab(paths: paths)
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
            }
            .frame(minWidth: 440, minHeight: 360)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadSettings() }
        } else {
            Text("App container not available.")
                .padding()
        }
    }

    private func privacyTab(paths: AppContainerPaths) -> some View {
        Form {
            Section("Offline mode") {
                Toggle("Use local models only", isOn: $settings.offlineMode)
                Text("When on, only local models are used. Network is used only for downloads and updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Model roles") {
                Text("Planner: \(settings.plannerModelId ?? "—")")
                    .font(.caption)
                Text("Worker: \(settings.workerModelId ?? "—")")
                    .font(.caption)
            }
            if let err = errorMessage {
                Section {
                    Text(err)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.offlineMode) { _ in saveSettings(paths: paths) }
    }

    private func loadSettings() {
        guard let facade = configFacade else { return }
        settings = (try? facade.loadSettings()) ?? .default
    }

    private func saveSettings(paths: AppContainerPaths) {
        guard let facade = configFacade else { return }
        do {
            try facade.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

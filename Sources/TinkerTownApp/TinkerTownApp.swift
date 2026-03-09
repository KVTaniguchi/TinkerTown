import AppKit
import Foundation
import SwiftUI
import TinkerTownCore

private struct PreflightCheck: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
}

@MainActor
private final class AppViewModel: ObservableObject {
    @Published var repoURL: URL
    @Published var requestText: String = ""
    @Published var runs: [String] = []
    @Published var selectedRunID: String?
    @Published var runRecord: RunRecord?
    @Published var tasks: [TaskRecord] = []
    @Published var selectedTaskID: String?
    @Published var logsText: String = ""
    @Published var preflightChecks: [PreflightCheck] = []
    @Published var escalationSeverity: String = "HIGH"
    @Published var escalationMessage: String = ""
    @Published var statusMessage: String = "Ready"
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false

    init() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.repoURL = cwd
        reloadAll()
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"
        if panel.runModal() == .OK, let picked = panel.url {
            repoURL = picked
            selectedRunID = nil
            selectedTaskID = nil
            reloadAll()
        }
    }

    func reloadAll() {
        performTask(success: "Refreshed") { [repoURL] in
            let context = try Self.makeContext(root: repoURL)
            let checks = try Self.preflightChecks(root: repoURL, config: context.config)
            let runIDs = try context.store.listRuns().sorted(by: >)
            let selected = runIDs.first
            let selectedRun = try selected.map { try context.store.loadRun($0) }
            let selectedTasks = try selected.map { try context.store.listTasks(runID: $0) } ?? []
            let logs = try selected.map { try Self.readRunLogs(paths: context.paths, runID: $0) } ?? ""
            self.preflightChecks = checks
            self.runs = runIDs
            self.selectedRunID = selected
            self.runRecord = selectedRun
            self.tasks = selectedTasks
            self.selectedTaskID = selectedTasks.first?.taskID
            self.logsText = logs
        }
    }

    func selectRun(_ runID: String?) {
        selectedRunID = runID
        selectedTaskID = nil
        guard let runID else {
            runRecord = nil
            tasks = []
            logsText = ""
            return
        }

        performTask(success: "Loaded \(runID)") { [repoURL, selectedTaskID] in
            let context = try Self.makeContext(root: repoURL)
            let run = try context.store.loadRun(runID)
            let taskList = try context.store.listTasks(runID: runID)
            let selected = selectedTaskID ?? taskList.first?.taskID
            let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: selected)
            self.runRecord = run
            self.tasks = taskList
            self.selectedTaskID = selected
            self.logsText = logs
        }
    }

    func selectTask(_ taskID: String?) {
        selectedTaskID = taskID
        guard let runID = selectedRunID else {
            logsText = ""
            return
        }
        performTask(success: "Loaded logs") { [repoURL] in
            let context = try Self.makeContext(root: repoURL)
            let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: taskID)
            self.logsText = logs
        }
    }

    func runRequest() {
        let trimmed = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a request first."
            return
        }

        performTask(success: "Run completed") { [repoURL, trimmed] in
            let context = try Self.makeContext(root: repoURL)
            try Self.ensureGitPreflight(cwd: repoURL)
            let adapters = Self.makeAdapters(config: context.config, guardrails: context.guardrails)
            let orchestrator = Orchestrator(
                root: repoURL,
                paths: context.paths,
                config: context.config,
                store: context.store,
                events: context.events,
                worktrees: WorktreeManager(),
                inspector: context.inspector,
                scheduler: Scheduler(),
                mergeGate: MergeGate(),
                mayor: adapters.mayor,
                tinker: adapters.tinker
            )
            let runID = try orchestrator.run(request: trimmed)
            let runIDs = try context.store.listRuns().sorted(by: >)
            let run = try context.store.loadRun(runID)
            let taskList = try context.store.listTasks(runID: runID)
            let logs = try Self.readRunLogs(paths: context.paths, runID: runID)
            self.requestText = ""
            self.runs = runIDs
            self.selectedRunID = runID
            self.runRecord = run
            self.tasks = taskList
            self.selectedTaskID = taskList.first?.taskID
            self.logsText = logs
            self.preflightChecks = (try? Self.preflightChecks(root: repoURL, config: context.config)) ?? []
        }
    }

    func retrySelectedTask() {
        guard let runID = selectedRunID, let taskID = selectedTaskID else {
            errorMessage = "Select a run and task first."
            return
        }
        performTask(success: "Task reset for retry") { [repoURL] in
            let context = try Self.makeContext(root: repoURL)
            var task = try context.store.loadTask(runID: runID, taskID: taskID)
            guard task.state == .failed else {
                throw NSError(domain: "TinkerTownApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Task is not FAILED."])
            }
            task.retryCount = 0
            task.state = .taskCreated
            try context.store.saveTask(task)
            let taskList = try context.store.listTasks(runID: runID)
            let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: taskID)
            self.tasks = taskList
            self.logsText = logs
        }
    }

    func cleanupSelectedRun() {
        guard let runID = selectedRunID else {
            errorMessage = "Select a run first."
            return
        }
        performTask(success: "Cleanup complete") { [repoURL] in
            let context = try Self.makeContext(root: repoURL)
            let taskList = try context.store.listTasks(runID: runID)
            let manager = WorktreeManager()
            for task in taskList {
                manager.teardown(task: task, root: repoURL)
            }
            manager.cleanupOrphaned(root: repoURL)
            let refreshedTasks = try context.store.listTasks(runID: runID)
            self.tasks = refreshedTasks
        }
    }

    func escalate() {
        let message = escalationMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errorMessage = "Enter an escalation message."
            return
        }

        performTask(success: "Escalation logged") { [repoURL, escalationSeverity, selectedRunID, message] in
            let context = try Self.makeContext(root: repoURL)
            try context.events.appendEscalation(severity: escalationSeverity, message: message, runID: selectedRunID)
            self.escalationMessage = ""
        }
    }

    private func performTask(success: String, work: () throws -> Void) {
        isBusy = true
        errorMessage = nil
        statusMessage = "Working..."
        do {
            try work()
            isBusy = false
            statusMessage = success
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
            statusMessage = "Failed"
        }
    }

    private struct Context {
        let paths: AppPaths
        let config: AppConfig
        let store: RunStore
        let events: EventLogger
        let guardrails: GuardrailService
        let inspector: Inspector
    }

    private static func makeContext(root: URL) throws -> Context {
        let paths = AppPaths(root: root)
        let configStore = ConfigStore(paths: paths)
        let config = try configStore.bootstrap()
        let store = RunStore(paths: paths)
        let events = EventLogger(paths: paths)
        let guardrails = GuardrailService(config: config.guardrails)
        let inspector = Inspector(eventLogger: events)
        return Context(paths: paths, config: config, store: store, events: events, guardrails: guardrails, inspector: inspector)
    }

    private static func makeAdapters(config: AppConfig, guardrails: GuardrailService) -> (mayor: MayorAdapting, tinker: TinkerAdapting) {
        if config.shouldUseOllama {
            let client = OllamaClient()
            let mayor = OllamaMayorAdapter(client: client, model: config.models.mayor, numCtx: config.ollama.mayorNumCtx)
            let tinker = OllamaTinkerAdapter(client: client, model: config.models.tinker, numCtx: config.ollama.tinkerNumCtx, guardrails: guardrails)
            return (mayor, tinker)
        }
        return (DefaultMayorAdapter(), DefaultTinkerAdapter(guardrails: guardrails))
    }

    private static func ensureGitPreflight(cwd: URL) throws {
        let shell = ShellRunner()
        let inside = try shell.run("git rev-parse --is-inside-work-tree", cwd: cwd)
        guard inside.exitCode == 0, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw NSError(domain: "TinkerTownApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected directory is not a git repository."])
        }

        let branch = try shell.run("git rev-parse --verify main", cwd: cwd)
        guard branch.exitCode == 0 else {
            throw NSError(domain: "TinkerTownApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base branch 'main' not found."])
        }
    }

    private static func preflightChecks(root: URL, config: AppConfig) throws -> [PreflightCheck] {
        let shell = ShellRunner()
        var checks: [PreflightCheck] = []

        let gitResult = try shell.run("command -v git", cwd: root)
        checks.append(PreflightCheck(name: "git", ok: gitResult.exitCode == 0, detail: gitResult.exitCode == 0 ? "Installed" : "Missing"))

        let swiftResult = try shell.run("command -v swift", cwd: root)
        checks.append(PreflightCheck(name: "swift", ok: swiftResult.exitCode == 0, detail: swiftResult.exitCode == 0 ? "Installed" : "Missing"))

        let repoResult = try shell.run("git rev-parse --is-inside-work-tree", cwd: root)
        let repoOK = repoResult.exitCode == 0 && repoResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        checks.append(PreflightCheck(name: "git repo", ok: repoOK, detail: repoOK ? "OK" : "Not a repository"))

        let mainResult = try shell.run("git rev-parse --verify main", cwd: root)
        checks.append(PreflightCheck(name: "main branch", ok: mainResult.exitCode == 0, detail: mainResult.exitCode == 0 ? "OK" : "Missing"))

        if config.shouldUseOllama {
            let ollamaResult = try shell.run("command -v ollama", cwd: root)
            checks.append(PreflightCheck(name: "ollama", ok: ollamaResult.exitCode == 0, detail: ollamaResult.exitCode == 0 ? "Installed" : "Missing"))
            if ollamaResult.exitCode == 0 {
                let listResult = try shell.run("ollama list", cwd: root)
                checks.append(PreflightCheck(name: "ollama service", ok: listResult.exitCode == 0, detail: listResult.exitCode == 0 ? "Reachable" : "Unavailable"))
            }
        }

        return checks
    }

    private static func readRunLogs(paths: AppPaths, runID: String) throws -> String {
        let data = try Data(contentsOf: paths.eventsFile(runID))
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func readLogs(paths: AppPaths, runID: String, taskID: String?) throws -> String {
        if let taskID {
            let taskDir = paths.tasksDir(runID).appendingPathComponent(taskID)
            let files = try LocalFileSystem().listFiles(taskDir)
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let parts = try files.map { file -> String in
                let data = try Data(contentsOf: file)
                return "=== \(file.lastPathComponent) ===\n\(String(data: data, encoding: .utf8) ?? "")"
            }
            return parts.joined(separator: "\n\n")
        }
        return try readRunLogs(paths: paths, runID: runID)
    }
}

private struct StatusBadge: View {
    let ok: Bool

    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }
}

private struct ContentView: View {
    @StateObject private var model = AppViewModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Repository")
                    .font(.headline)
                Text(model.repoURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(3)
                HStack {
                    Button("Choose…") { model.chooseRepository() }
                    Button("Refresh") { model.reloadAll() }
                }

                Divider()

                Text("Preflight")
                    .font(.headline)
                ForEach(model.preflightChecks) { check in
                    HStack(spacing: 8) {
                        StatusBadge(ok: check.ok)
                        Text(check.name)
                        Spacer()
                        Text(check.detail)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                Divider()

                Text("Runs")
                    .font(.headline)
                List(model.runs, id: \.self, selection: $model.selectedRunID) { runID in
                    Text(runID)
                        .font(.system(.body, design: .monospaced))
                        .tag(runID)
                }
            }
            .padding()
            .onChange(of: model.selectedRunID) { newValue in
                model.selectRun(newValue)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Request", text: $model.requestText)
                    Button("Run") { model.runRequest() }
                        .disabled(model.isBusy)
                }

                if model.isBusy {
                    ProgressView()
                }

                Text("Status: \(model.statusMessage)")
                    .font(.caption)
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let run = model.runRecord {
                    GroupBox("Run \(run.runID)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("State: \(run.state.rawValue)")
                            Text("Request: \(run.request)")
                            Text("Tasks total: \(run.metrics.tasksTotal)  merged: \(run.metrics.tasksMerged)  failed: \(run.metrics.tasksFailed)  retries: \(run.metrics.totalRetries)")
                        }
                        .font(.caption)
                    }

                    HStack {
                        Text("Task logs:")
                        Picker("Task", selection: $model.selectedTaskID) {
                            Text("Run events").tag(String?.none)
                            ForEach(model.tasks, id: \.taskID) { task in
                                Text(task.taskID).tag(Optional(task.taskID))
                            }
                        }
                        .frame(maxWidth: 220)
                        .onChange(of: model.selectedTaskID) { newValue in
                            model.selectTask(newValue)
                        }

                        Button("Retry Task") { model.retrySelectedTask() }
                            .disabled(model.selectedTaskID == nil || model.isBusy)
                        Button("Cleanup Run") { model.cleanupSelectedRun() }
                            .disabled(model.isBusy)
                    }

                    List(model.tasks, id: \.taskID) { task in
                        HStack {
                            Text(task.taskID)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 90, alignment: .leading)
                            Text(task.state.rawValue)
                                .frame(width: 170, alignment: .leading)
                            Text(task.title)
                            Spacer()
                            Text("retry \(task.retryCount)/\(task.maxRetries)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .frame(minHeight: 150)
                }

                GroupBox("Logs") {
                    TextEditor(text: $model.logsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                }

                GroupBox("Escalate") {
                    HStack {
                        Picker("Severity", selection: $model.escalationSeverity) {
                            Text("HIGH").tag("HIGH")
                            Text("CRITICAL").tag("CRITICAL")
                        }
                        TextField("Message", text: $model.escalationMessage)
                        Button("Log") { model.escalate() }
                            .disabled(model.isBusy)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 1200, minHeight: 760)
    }
}

@main
struct TinkerTownAppMain: App {
    var body: some Scene {
        WindowGroup("TinkerTown") {
            ContentView()
        }
    }
}

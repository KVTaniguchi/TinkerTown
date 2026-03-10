import AppKit
import Foundation
import SwiftUI
import TinkerTownCore
import UniformTypeIdentifiers

private struct PreflightCheck: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
}

private struct PlanChecklistRow: Identifiable {
    let id = UUID()
    let title: String
    let completed: Bool
}

/// One unchecked plan item with the exact request text to run for that step.
private struct SuggestedStep: Identifiable {
    let id: String
    let title: String
    let requestText: String
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
    @Published var failureExplanation: String?
    @Published var buildSystemMode: String = "auto" // auto, none, spm, xcodebuild
    @Published var availableSchemes: [String] = []
    @Published var selectedScheme: String?
    @Published var approvedTaskIDs: Set<String> = []
    @Published var currentConfig: AppConfig?
    @Published var planChecklist: [PlanChecklistRow] = []
    /// Unchecked plan items with the exact request to run for each; used for "Run this step" buttons.
    var suggestedNextSteps: [SuggestedStep] {
        planChecklist
            .filter { !$0.completed }
            .prefix(5)
            .enumerated()
            .map { SuggestedStep(id: "step-\($0.offset)", title: $0.element.title, requestText: "Focus on the next items from the project plan checklist in plan/PROJECT_PLAN.md: \($0.element.title).") }
    }
    @Published var shouldShowPDRPrompt: Bool = false
    @Published var hasChosenRepository: Bool = false
    /// When the failure explanation mentions a button, we highlight it so the user knows what to press.
    @Published var highlightedButtonIDs: Set<String> = []

    private let appContainerPaths: AppContainerPaths?
    /// G3: Timer for live UI updates while orchestration runs in background.
    private var pollTimer: Timer?
    /// G4: Monitor that re-evaluates failed runs and can trigger resume.
    private var monitorLoop: MonitorLoop?
    /// In-flight orchestration task so the user can cancel and regain control.
    private var orchestrationTask: Task<Void, Never>?

    init(appContainerPaths: AppContainerPaths? = nil) {
        self.appContainerPaths = appContainerPaths
        let cwd: URL
        if Bundle.main.bundlePath.hasSuffix(".app") {
            cwd = FileManager.default.homeDirectoryForCurrentUser
        } else {
            cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.repoURL = cwd
        loadBuildSettings()
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
            hasChosenRepository = true
            selectedRunID = nil
            selectedTaskID = nil
            inspectWorkspaceAndReload()
            startMonitor()
        }
    }

    func reloadAll() {
        performTask(success: "Refreshed") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            let checks = try Self.preflightChecks(root: repoURL, config: context.config)
            let runIDs = try context.store.listRuns().sorted(by: >)
            let selected = runIDs.first
            let selectedRun = try selected.map { try context.store.loadRun($0) }
            let selectedTasks = try selected.map { try context.store.listTasks(runID: $0) } ?? []
            let logs = try selected.map { try Self.readRunLogs(paths: context.paths, runID: $0) } ?? ""
            self.preflightChecks = checks
            self.currentConfig = context.config
            self.refreshPlanChecklist(paths: context.paths)
            self.runs = runIDs
            self.selectedRunID = selected
            self.runRecord = selectedRun
            self.tasks = selectedTasks
            self.selectedTaskID = selectedTasks.first?.taskID
            self.logsText = logs
        }
    }

    private func inspectWorkspaceAndReload() {
        performTask(success: "Refreshed") { [repoURL] in
            self.inspectWorkspace(root: repoURL)
            self.reloadAll()
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
            let context = try self.makeContext(root: repoURL)
            let run = try context.store.loadRun(runID)
            let taskList = try context.store.listTasks(runID: runID)
            let selected = selectedTaskID ?? taskList.first?.taskID
            let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: selected)
            self.currentConfig = context.config
            self.runRecord = run
            self.tasks = taskList
            self.approvedTaskIDs = Set(taskList.map(\.taskID))
            self.selectedTaskID = selected
            self.logsText = logs
        }
    }

    func selectTask(_ taskID: String?) {
        selectedTaskID = taskID
        guard let runID = selectedRunID else {
            logsText = ""
            failureExplanation = nil
            return
        }
        performTask(success: "Loaded logs") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: taskID)
            self.logsText = logs
            self.updateFailureExplanationIfNeeded(runID: runID, taskID: taskID, logs: logs)
        }
    }

    func editOrCreatePDR() {
        performTask(success: "Opened Product Design Requirement") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            let pdrService = PDRService(paths: context.paths)
            let fs = LocalFileSystem()
            let pdrURL = context.paths.pdrFile

            if !fs.fileExists(pdrURL) {
                let title = repoURL.lastPathComponent.isEmpty ? "My project" : repoURL.lastPathComponent
                try pdrService.writeDefaultMinimal(title: title)
            }

            NSWorkspace.shared.open(pdrURL)
        }
    }

    func openOrCreatePlan() {
        performTask(success: "Opened Project Plan") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            let planning = PlanningService(paths: context.paths)
            let title = repoURL.lastPathComponent.isEmpty ? "My project" : repoURL.lastPathComponent
            let planURL = try planning.ensureDefaultPlanExists(title: title)
            self.planChecklist = planning.loadChecklistItems().map { PlanChecklistRow(title: $0.title, completed: $0.completed) }
            NSWorkspace.shared.open(planURL)
        }
    }

    /// Imports pasted or uploaded project plan content: writes to plan/PROJECT_PLAN.md and
    /// creates/updates the PDR from the plan so the mirror can use it without editing JSON.
    func importProjectPlan(content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Paste or choose a file with your project plan."
            return
        }
        performTask(success: "Project plan imported") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            let planning = PlanningService(paths: context.paths)
            let result = try planning.importPlanContent(trimmed)
            let pdrService = PDRService(paths: context.paths)
            try pdrService.writeFromPlan(
                title: result.derivedTitle,
                summary: result.derivedSummary,
                acceptanceCriteria: nil
            )
            DispatchQueue.main.sync {
                self.shouldShowPDRPrompt = false
            }
            self.refreshPlanChecklist(paths: context.paths)
        }
    }

    /// Opens a file picker and returns the contents of the selected file, or nil if cancelled.
    func pickFileAndReturnPlanContent() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        panel.title = "Choose Project Plan"
        panel.message = "Select a Markdown or text file (e.g. PROJECT_PLAN.md)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Starts the Ollama server in a new Terminal window. Call when ollama service is unavailable.
    func startOllamaInTerminal() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"Terminal\" to do script \"ollama serve\""]
        do {
            try proc.run()
            statusMessage = "Started Ollama in Terminal; use Refresh when it’s up."
        } catch {
            statusMessage = "Could not start Terminal: \(error.localizedDescription)"
        }
    }

    /// Plans from the checklist and then executes in one background flow so the user is not
    /// prompted to "Confirm and Start" unless they explicitly open a run already in PENDING_APPROVAL.
    func runMayorFromPlanChecklist() {
        runOrchestrationInBackground { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            try Self.ensureGitPreflight(cwd: repoURL)

            let planning = PlanningService(paths: context.paths)
            let title = repoURL.lastPathComponent.isEmpty ? "My project" : repoURL.lastPathComponent
            _ = try planning.ensureDefaultPlanExists(title: title)
            let checklist = planning.loadChecklistItems()
            DispatchQueue.main.sync {
                self.planChecklist = checklist.map { PlanChecklistRow(title: $0.title, completed: $0.completed) }
            }

            let summary: String
            if checklist.isEmpty {
                summary = "Use the project plan document (plan/PROJECT_PLAN.md) to derive an initial task plan and start work."
            } else {
                let pending = checklist.filter { !$0.completed }.map(\.title)
                if pending.isEmpty {
                    summary = "The checklist in plan/PROJECT_PLAN.md is fully completed. Review for any follow-ups or refinements that improve quality or robustness."
                } else {
                    let joined = pending.joined(separator: "; ")
                    summary = "Focus on the next items from the project plan checklist in plan/PROJECT_PLAN.md: \(joined)."
                }
            }

            let pdrService = PDRService(paths: context.paths)
            let (pdr, resolvedURL) = try pdrService.resolve(customPath: nil)
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
                mergeManager: DefaultMergeManager(root: repoURL, store: context.store),
                mayor: adapters.mayor,
                tinker: adapters.tinker
            )
            let runID = try orchestrator.generatePlan(request: summary, pdr: pdr, pdrResolvedURL: resolvedURL, skipApproval: true)
            let runIDs = try context.store.listRuns().sorted(by: >)
            let run = try context.store.loadRun(runID)
            let taskList = try context.store.listTasks(runID: runID)
            let logs = try Self.readRunLogs(paths: context.paths, runID: runID)
            DispatchQueue.main.sync {
                self.currentConfig = context.config
                self.runs = runIDs
                self.selectedRunID = runID
                self.runRecord = run
                self.tasks = taskList
                self.approvedTaskIDs = Set(taskList.map(\.taskID))
                self.selectedTaskID = taskList.first?.taskID
                self.logsText = logs
                self.preflightChecks = (try? Self.preflightChecks(root: repoURL, config: context.config)) ?? []
                self.updateFailureExplanationIfNeeded(runID: runID, taskID: self.selectedTaskID, logs: logs)
            }
            try orchestrator.execute(runID: runID, approvedTaskIDs: nil)
        }
    }

    func runRequest() {
        let trimmed = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a request first."
            return
        }
        runWithRequest(trimmed)
        requestText = ""
    }

    /// Run the orchestrator with a specific request string (e.g. from a "Run this step" button).
    /// Plans and then executes in one background flow so the user is not prompted to "Confirm and Start"
    /// unless they explicitly open a run that is already in PENDING_APPROVAL.
    func runWithRequest(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runOrchestrationInBackground { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            try Self.ensureGitPreflight(cwd: repoURL)
            let pdrService = PDRService(paths: context.paths)
            let (pdr, resolvedURL) = try pdrService.resolve(customPath: nil)
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
                mergeManager: DefaultMergeManager(root: repoURL, store: context.store),
                mayor: adapters.mayor,
                tinker: adapters.tinker
            )
            let runID = try orchestrator.generatePlan(request: trimmed, pdr: pdr, pdrResolvedURL: resolvedURL, skipApproval: true)
            let runIDs = try context.store.listRuns().sorted(by: >)
            let run = try context.store.loadRun(runID)
            let taskList = try context.store.listTasks(runID: runID)
            let logs = try Self.readRunLogs(paths: context.paths, runID: runID)
            DispatchQueue.main.sync {
                self.currentConfig = context.config
                self.runs = runIDs
                self.selectedRunID = runID
                self.runRecord = run
                self.tasks = taskList
                self.approvedTaskIDs = Set(taskList.map(\.taskID))
                self.selectedTaskID = taskList.first?.taskID
                self.logsText = logs
                self.preflightChecks = (try? Self.preflightChecks(root: repoURL, config: context.config)) ?? []
                self.updateFailureExplanationIfNeeded(runID: runID, taskID: self.selectedTaskID, logs: logs)
            }
            try orchestrator.execute(runID: runID, approvedTaskIDs: nil)
        }
    }

    func continueWorking() {
        guard let runID = selectedRunID else {
            errorMessage = "No run selected to continue."
            return
        }
        runOrchestrationInBackground { [repoURL] in
            let context = try self.makeContext(root: repoURL)
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
                mergeManager: DefaultMergeManager(root: repoURL, store: context.store),
                mayor: adapters.mayor,
                tinker: adapters.tinker
            )
            try orchestrator.resume(runID: runID)
        }
    }

    func confirmAndStartExecution() {
        guard let runID = selectedRunID else {
            errorMessage = "No run selected to start."
            return
        }
        let approved = approvedTaskIDs
        runOrchestrationInBackground { [repoURL] in
            let context = try self.makeContext(root: repoURL)
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
                mergeManager: DefaultMergeManager(root: repoURL, store: context.store),
                mayor: adapters.mayor,
                tinker: adapters.tinker
            )
            let approvedList = approved.isEmpty ? nil : Array(approved)
            try orchestrator.execute(runID: runID, approvedTaskIDs: approvedList)
        }
    }

    func retrySelectedTask() {
        guard let runID = selectedRunID, let taskID = selectedTaskID else {
            errorMessage = "Select a run and task first."
            return
        }
        performTask(success: "Task reset for retry") { [repoURL] in
            let context = try self.makeContext(root: repoURL)
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
            let context = try self.makeContext(root: repoURL)
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
            let context = try self.makeContext(root: repoURL)
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

    /// G3: Run orchestration work off the main thread so UI stays responsive; poll run/tasks/logs while running.
    private func runOrchestrationInBackground(work: @escaping () throws -> Void) {
        orchestrationTask?.cancel()
        isBusy = true
        errorMessage = nil
        statusMessage = "Running…"
        startPolling()
        let task = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work() }
            }.value
            guard !Task.isCancelled else {
                stopPolling()
                isBusy = false
                orchestrationTask = nil
                return
            }
            stopPolling()
            switch result {
            case .success:
                try? refreshSelectedRun()
                if let runID = selectedRunID {
                    updateFailureExplanationIfNeeded(runID: runID, taskID: selectedTaskID, logs: logsText)
                }
                statusMessage = "Run completed"
            case .failure(let error):
                errorMessage = error.localizedDescription
                statusMessage = "Failed"
                try? refreshSelectedRun()
            }
            isBusy = false
            orchestrationTask = nil
        }
        orchestrationTask = task
    }

    /// Stop the current run so the UI is responsive again. Background work may still complete; state will refresh.
    func stopRun() {
        orchestrationTask?.cancel()
        orchestrationTask = nil
        stopPolling()
        isBusy = false
        statusMessage = "Stopped"
        errorMessage = nil
        try? refreshSelectedRun()
        if let runID = selectedRunID {
            updateFailureExplanationIfNeeded(runID: runID, taskID: selectedTaskID, logs: logsText)
        }
    }

    /// Reload run/tasks/logs for the selected run from disk (on main actor).
    private func refreshSelectedRun() throws {
        guard let runID = selectedRunID else { return }
        let context = try makeContext(root: repoURL)
        let run = try context.store.loadRun(runID)
        let taskList = try context.store.listTasks(runID: runID)
        let logs = try Self.readLogs(paths: context.paths, runID: runID, taskID: selectedTaskID)
        runRecord = run
        currentConfig = context.config
        tasks = taskList
        logsText = logs
        preflightChecks = (try? Self.preflightChecks(root: repoURL, config: context.config)) ?? preflightChecks
        if run.state == .completed {
            var titlesToMark = taskList.filter { [TaskState.merged, .cleaned].contains($0.state) }.map(\.title)
            if let focusTitles = Self.focusTitlesFromRunRequest(run.request) {
                titlesToMark.append(contentsOf: focusTitles)
            }
            if !titlesToMark.isEmpty {
                let planning = PlanningService(paths: context.paths)
                try? planning.markChecklistItemsComplete(titles: titlesToMark)
                refreshPlanChecklist(paths: context.paths)
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSelectedRunIfNeeded()
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshSelectedRunIfNeeded() {
        guard
            isBusy,
            let run = runRecord,
            run.state == .executing || run.state == .merging
        else {
            return
        }
        try? refreshSelectedRun()
    }

    /// G4: Start the monitor loop; when a run is FAILED it will trigger continueWorking (if not busy).
    func startMonitor() {
        stopMonitor()
        guard let context = try? makeContext(root: repoURL) else { return }
        monitorLoop = MonitorLoop(store: context.store, interval: 30) { [weak self] runID in
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.selectedRunID = runID
                self.continueWorking()
            }
        }
        monitorLoop?.start()
    }

    func stopMonitor() {
        monitorLoop?.stop()
        monitorLoop = nil
    }

    private struct Context {
        let paths: AppPaths
        let config: AppConfig
        let store: RunStore
        let events: EventLogger
        let guardrails: GuardrailService
        let inspector: Inspector
    }

    private func makeContext(root: URL) throws -> Context {
        let paths = AppPaths(root: root)
        let configStore = ConfigStore(paths: paths)
        var config = try configStore.bootstrap()
        if let appPaths = appContainerPaths {
            let facade = ConfigFacade(paths: appPaths)
            if let settings = try? facade.loadSettings() {
                if settings.useOllama {
                    config.useOllama = true
                    if let planner = settings.plannerModelId { config.models.mayor = planner }
                    if let worker = settings.workerModelId { config.models.tinker = worker }
                }

                // Apply user-selected build system overrides when present.
                if let mode = settings.buildSystemMode {
                    switch mode {
                    case "none":
                        config.verification.mode = "none"
                        config.verification.command = "true"
                    case "spm":
                        config.verification.mode = "spm"
                        config.verification.command = "swift build"
                    case "xcodebuild":
                        config.verification.mode = "xcodebuild"
                        if let scheme = settings.xcodeScheme, !scheme.isEmpty {
                            config.verification.command = "xcodebuild build -scheme \(scheme) -configuration Debug"
                        }
                    default:
                        break
                    }
                }
                // Keep UI state in sync.
                if let mode = settings.buildSystemMode {
                    buildSystemMode = mode
                }
                Task { @MainActor in
                    selectedScheme = settings.xcodeScheme
                }
            }
        }

        // Auto-tune verification mode based on workspace contents when no explicit override.
        let fm = FileManager.default
        let packagePath = root.appendingPathComponent("Package.swift").path
        let hasPackage = fm.fileExists(atPath: packagePath)
        let hasXcodeproj: Bool = {
            guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return false }
            return items.contains(where: { $0.hasSuffix(".xcodeproj") })
        }()

        if (buildSystemMode == "auto" || buildSystemMode.isEmpty) {
            if !hasPackage && !hasXcodeproj {
                // Generic repo: disable build verification so the agent can still plan/edit.
                config.verification.mode = "none"
                config.verification.command = "true"
            } else if hasPackage && !hasXcodeproj {
                // Swift package only.
                config.verification.mode = "spm"
                config.verification.command = "swift build"
            } else {
                // Xcode project present: keep existing config (typically xcodebuild).
            }
        }

        let store = RunStore(paths: paths)
        let events = EventLogger(paths: paths)
        let guardrails = GuardrailService(config: config.guardrails)
        let inspector = Inspector(eventLogger: events)
        return Context(paths: paths, config: config, store: store, events: events, guardrails: guardrails, inspector: inspector)
    }

    /// Parses failure explanation text for mentioned button names and returns IDs to highlight.
    private static func detectMentionedButtons(in text: String) -> Set<String> {
        let lower = text.localizedLowercase
        var ids: Set<String> = []
        if lower.contains("edit product design requirement") || lower.contains("edit the pdr") || lower.contains("update the pdr") || lower.contains("open the pdr") || lower.contains("edit pdr") {
            ids.insert("editPDR")
        }
        if lower.contains("view plan") || lower.contains("open the plan") {
            ids.insert("viewPlan")
        }
        if lower.contains("continue working") {
            ids.insert("continueWorking")
        }
        if lower.contains("retry task") || lower.contains("retry the task") {
            ids.insert("retryTask")
        }
        if lower.contains("cleanup run") || lower.contains("cleanup") {
            ids.insert("cleanupRun")
        }
        if lower.contains("confirm and start") || lower.contains("approval") || lower.contains("approve") {
            ids.insert("confirmAndStart")
        }
        if lower.contains("run mayor on plan") || lower.contains("run mayor") {
            ids.insert("runMayorOnPlan")
        }
        if lower.contains("click run") || lower.contains("tap run") || lower.contains("hit run") {
            ids.insert("run")
        }
        return ids
    }

    /// Extracts checklist item title(s) from a run request when it was "Run this step" / "Focus on the next items...".
    /// Returns nil if the request doesn't match that format. Used to tick off the correct plan line when the run completes.
    private static func focusTitlesFromRunRequest(_ request: String) -> [String]? {
        let prefix = "Focus on the next items from the project plan checklist in plan/PROJECT_PLAN.md: "
        guard request.hasPrefix(prefix) else { return nil }
        var rest = String(request.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix("..") { rest = String(rest.dropLast(2)) }
        else if rest.hasSuffix(".") { rest = String(rest.dropLast()) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let titles = rest.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles
    }

    private func updateFailureExplanationIfNeeded(runID: String, taskID: String?, logs: String) {
        failureExplanation = nil
        highlightedButtonIDs = []

        if let context = try? makeContext(root: repoURL),
           let run = try? context.store.loadRun(runID) {
            // Successful run: do not show any failure/PDR/plan banner so we don't confuse the user.
            if run.state == .completed && run.metrics.tasksFailed == 0 {
                return
            }
        }

        // Detect the common case where a run has FAILED but all tasks are already
        // in terminal states. In this situation there is no more automatic work for the
        // agent to perform, so surface a clear explanation instead of encouraging the
        // user to "Continue Working" repeatedly.
        if let context = try? makeContext(root: repoURL) {
            if let run = try? context.store.loadRun(runID) {
                if run.state == .failed, let tasks = try? context.store.listTasks(runID: runID) {
                    let terminal: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
                    let hasPendingOrRetryable = tasks.contains { task in
                        if !terminal.contains(task.state) {
                            return true
                        }
                        if task.state == .verifyFailedRetryable {
                            return task.retryCount < task.maxRetries
                        }
                        return false
                    }
                    if !hasPendingOrRetryable {
                        let message = """
                        This run failed because at least one task could not be merged or was rejected, but all tasks are now in finished states. There is no further automatic work for TinkerTown to perform on this run. Review the git history and files it changed (for example, tinkertown-task-notes.md and plan/PROJECT_PLAN.md), adjust your project plan or other inputs as needed, and then start a new run with an updated request.
                        """
                        failureExplanation = message
                        highlightedButtonIDs = Self.detectMentionedButtons(in: message)
                        return
                    }
                }
            }
        }

        let trimmedLogs = logs.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLogs.isEmpty {
            failureExplanation = "Logs for this task are empty. TinkerTown will use a verification command that matches this workspace on the next run. You can retry the task or run again."
            return
        }

        // Common, high-signal failures we can explain directly without calling into a model.
        if trimmedLogs.contains("does not contain an Xcode project, workspace or package") {
            let message = """
            The build step is running xcodebuild in a directory that does not contain an Xcode project, workspace, or Swift package. Point the workspace at a repo with a valid Xcode project (and the expected scheme), or change the verification command so it runs a tool that makes sense for this repo.
            """
            failureExplanation = message
            highlightedButtonIDs = Self.detectMentionedButtons(in: message)
            return
        }

        if trimmedLogs.localizedCaseInsensitiveContains("invalid configuration in the project plan")
            || trimmedLogs.localizedCaseInsensitiveContains("undefined variable in the plan/PROJECT_PLAN.md") {
            let message = """
            The agents failed while trying to read plan/PROJECT_PLAN.md because the plan text referenced a variable or configuration value they could not resolve. Open the project plan, simplify any templating or placeholders, and make the checklist explicit so the Mayor has concrete work items to derive tasks from.
            """
            failureExplanation = message
            highlightedButtonIDs = Self.detectMentionedButtons(in: message).union(["viewPlan", "runMayorOnPlan"])
            return
        }

        if trimmedLogs.localizedCaseInsensitiveContains("invalid workspace")
            || (trimmedLogs.localizedCaseInsensitiveContains("workspace") && trimmedLogs.localizedCaseInsensitiveContains("configuration"))
            || trimmedLogs.localizedCaseInsensitiveContains("necessary files are present") {
            let message = """
            The run hit a workspace or configuration issue. TinkerTown can try to fix this by ensuring the project plan and PDR exist and are valid. Click "Fix workspace" below, then retry the task or run again.
            """
            failureExplanation = message
            highlightedButtonIDs = ["fixWorkspace", "retryTask", "runMayorOnPlan"]
            return
        }

        guard let appPaths = appContainerPaths else { return }

        let installManager = ModelInstallManager(paths: appPaths)
        let installed = installManager.loadInstalledModels()
        let runtime = ModelRuntimeAdapter(installedModels: installed)
        let configFacade = ConfigFacade(paths: appPaths)
        let settings = (try? configFacade.loadSettings()) ?? .default

        guard settings.useOllama,
              let modelId = settings.plannerModelId ?? settings.workerModelId else {
            return
        }

        let runPart = "Run ID: \(runID)"
        let taskPart = "Task ID: \(taskID ?? "run_events")"
        let system = """
        You are helping a developer understand why an automated planning-and-orchestration task failed.
        This application does NOT directly edit source code. The user can change their workspace (for example, by adding files manually), update the Product Design Requirement (PDR), or edit the project plan in plan/PROJECT_PLAN.md, then run the agent again.
        Read the logs and respond with a short, clear explanation (2–4 sentences) of what went wrong and what adjustments the user can make to their plan, configuration, or workspace inputs before starting a new run.
        Do not tell the user to "edit the code" or similar; instead, refer to updating the plan, PDR, or repository contents outside of TinkerTown.
        Do not repeat the full logs; focus on the root cause and next steps.
        """
        let prompt = """
        \(runPart)
        \(taskPart)

        Logs:
        \(trimmedLogs)
        """

        Task.detached { [runtime] in
            let reply = runtime.generate(modelId: modelId, prompt: prompt, system: system, numCtx: 4096)
            guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await MainActor.run {
                self.failureExplanation = reply
                self.highlightedButtonIDs = Self.detectMentionedButtons(in: reply)
            }
        }
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

    private func loadBuildSettings() {
        guard let appPaths = appContainerPaths else { return }
        let facade = ConfigFacade(paths: appPaths)
        guard let settings = try? facade.loadSettings() else { return }
        buildSystemMode = settings.buildSystemMode ?? "auto"
        selectedScheme = settings.xcodeScheme
    }

    private func saveBuildSettings() {
        guard let appPaths = appContainerPaths else { return }
        let facade = ConfigFacade(paths: appPaths)
        var settings = (try? facade.loadSettings()) ?? .default
        settings.buildSystemMode = buildSystemMode == "auto" ? nil : buildSystemMode
        settings.xcodeScheme = selectedScheme
        try? facade.saveSettings(settings)
    }

    /// Call when the agent hits a workspace/configuration failure; ensures plan and PDR exist so the next run can proceed.
    func fixWorkspace() {
        let root = repoURL
        let paths = AppPaths(root: root)
        do {
            let planning = PlanningService(paths: paths)
            let title = root.lastPathComponent.isEmpty ? "My project" : root.lastPathComponent
            try planning.ensureDefaultPlanExists(title: title)
            planChecklist = planning.loadChecklistItems().map { PlanChecklistRow(title: $0.title, completed: $0.completed) }
            failureExplanation = nil
        } catch {
            // Non-fatal.
        }
    }

    private func inspectWorkspace(root: URL) {
        let paths = AppPaths(root: root)

        // Ensure a default project plan exists so the Mayor has a persistent
        // planning surface and checklist for this workspace. If creation fails,
        // do not block workspace inspection.
        do {
            let planning = PlanningService(paths: paths)
            let title = root.lastPathComponent.isEmpty ? "My project" : root.lastPathComponent
            try planning.ensureDefaultPlanExists(title: title)
            self.planChecklist = planning.loadChecklistItems().map { PlanChecklistRow(title: $0.title, completed: $0.completed) }
        } catch {
            // Non-fatal.
        }

        // Detect missing PDR and trigger a one-time prompt so the user can
        // attach or create a Product Design Requirement for this workspace.
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.pdrFile.path) {
            shouldShowPDRPrompt = true
        }

        // Discover Xcode schemes if a project exists.
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              let projectName = items.first(where: { $0.hasSuffix(".xcodeproj") }) else {
            availableSchemes = []
            return
        }

        let shell = ShellRunner()
        let result = try? shell.run("xcodebuild -list -project '\(projectName)'", cwd: root)
        guard let output = result?.stdout, result?.exitCode == 0 else {
            availableSchemes = []
            return
        }

        var schemes: [String] = []
        var inSchemesSection = false
        for line in output.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Schemes:" {
                inSchemesSection = true
                continue
            }
            if inSchemesSection {
                if trimmed.isEmpty { break }
                schemes.append(trimmed)
            }
        }
        availableSchemes = schemes
        if selectedScheme == nil, let first = schemes.first {
            selectedScheme = first
        }
        saveBuildSettings()
    }

    private static func ensureGitPreflight(cwd: URL) throws {
        // Ensure the selected workspace is a usable git repository. If it is not,
        // attempt to initialize one in-place so the user can start immediately.
        do {
            let initializer = GitRepositoryInitializer()
            _ = try initializer.ensureRepository(at: cwd)
        } catch {
            throw NSError(
                domain: "TinkerTownApp",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize git repository in selected workspace: \(error.localizedDescription)"]
            )
        }

        // Double-check that the expected base branch exists.
        let shell = ShellRunner()
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

    private func refreshPlanChecklist(paths: AppPaths) {
        let planning = PlanningService(paths: paths)
        self.planChecklist = planning.loadChecklistItems().map { PlanChecklistRow(title: $0.title, completed: $0.completed) }
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
            .frame(width: 8, height: 8)
    }
}

// MARK: - Agent-manager style layout (Cursor/Codex-like)

private struct ContentView: View {
    let appContainerPaths: AppContainerPaths?
    @StateObject private var model: AppViewModel
    @State private var showSettings = false
    @State private var showEscalate = false
    @State private var showPDRPrompt = false
    @State private var showImportPlanSheet = false
    @State private var importPlanPastedText = ""
    @State private var isAgentActivityAnimating = false

    private var isContinueWorkingEnabled: Bool {
        guard let run = model.runRecord else { return false }
        // When a run is waiting for explicit user approval, do not allow "Continue Working"
        // to start execution implicitly; the user should use "Confirm and Start" instead.
        if run.state == .pendingApproval { return false }
        let terminal: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
        return model.tasks.contains { task in
            if terminal.contains(task.state) { return false }
            if task.state == .verifyFailedRetryable {
                return task.retryCount < task.maxRetries
            }
            return true
        }
    }

    /// Highlight "Continue Working" when there is an in-flight or resumable run so it is
    /// obvious to the user how to pick up where the agent left off.
    private var shouldEmphasizeContinueWorking: Bool {
        guard isContinueWorkingEnabled, let run = model.runRecord else { return false }
        switch run.state {
        case .executing, .failed, .merging:
            return true
        default:
            return false
        }
    }

    /// Buttons to highlight because the failure explanation (or PDR/plan instructions) mentions them.
    private var effectiveHighlightedButtonIDs: Set<String> {
        var set = model.highlightedButtonIDs
        if let exp = model.failureExplanation, isPDRRelatedFailure(exp) {
            set.insert("editPDR")
        }
        if let exp = model.failureExplanation, isPlanRelatedFailure(exp) {
            set.insert("viewPlan")
        }
        return set
    }

    init(appContainerPaths: AppContainerPaths? = nil) {
        self.appContainerPaths = appContainerPaths
        _model = StateObject(wrappedValue: AppViewModel(appContainerPaths: appContainerPaths))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
        }
        .frame(minWidth: 1000, minHeight: 640)
        .sheet(isPresented: $showSettings) {
            SettingsView(paths: appContainerPaths)
        }
        .sheet(isPresented: $showEscalate) {
            escalateSheet
        }
        .sheet(isPresented: Binding(
            get: { model.shouldShowPDRPrompt || showPDRPrompt },
            set: { newValue in
                showPDRPrompt = newValue
                if !newValue {
                    model.shouldShowPDRPrompt = false
                }
            }
        )) {
            pdrPromptSheet
        }
        .sheet(isPresented: $showImportPlanSheet) {
            importPlanSheet
        }
        .onAppear { model.startMonitor() }
        .onDisappear { model.stopMonitor() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Repo
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.repoURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Button(model.hasChosenRepository ? "Change…" : "Choose Workspace…") { model.chooseRepository() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Button("Refresh") { model.reloadAll() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Build system picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Build System")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Build system", selection: $model.buildSystemMode) {
                    Text("Automatic").tag("auto")
                    Text("Plan only (no build)").tag("none")
                    Text("Swift Package (swift build)").tag("spm")
                    Text("Xcode (xcodebuild)").tag("xcodebuild")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.buildSystemMode == "xcodebuild" {
                    if model.availableSchemes.isEmpty {
                        Text("No schemes detected. Make sure an Xcode project exists.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Picker("Scheme", selection: Binding<String>(
                            get: { model.selectedScheme ?? model.availableSchemes.first ?? "" },
                            set: { model.selectedScheme = $0 }
                        )) {
                            ForEach(model.availableSchemes, id: \.self) { scheme in
                                Text(scheme).tag(scheme)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let config = model.currentConfig {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Mayor (planner): \(config.models.mayor)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Tinkers (workers): \(config.models.tinker)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(config.shouldUseOllama ? "Engine: Ollama" : "Engine: Local defaults")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // Preflight (compact)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Environment")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(model.preflightChecks) { check in
                            StatusBadge(ok: check.ok)
                        }
                    }
                }
                if !model.preflightChecks.allSatisfy(\.ok) {
                    ForEach(model.preflightChecks.filter { !$0.ok }) { check in
                        Text("\(check.name): \(check.detail)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if model.preflightChecks.contains(where: { $0.name == "ollama service" && !$0.ok }) {
                        Button("Start Ollama") { model.startOllamaInTerminal() }
                            .font(.system(size: 11))
                            .buttonStyle(.borderedProminent)
                    }
                }
                if effectiveHighlightedButtonIDs.contains("editPDR") {
                    Button("Edit Product Design Requirement…") { model.editOrCreatePDR() }
                        .font(.system(size: 11))
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Edit Product Design Requirement…") { model.editOrCreatePDR() }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                }
                if effectiveHighlightedButtonIDs.contains("viewPlan") {
                    Button("View Plan") { model.openOrCreatePlan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                } else {
                    Button("View Plan") { model.openOrCreatePlan() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
                Button("Import Project Plan…") {
                    importPlanPastedText = ""
                    showImportPlanSheet = true
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                if !model.planChecklist.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checklist")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(model.planChecklist.prefix(5)) { item in
                            HStack(spacing: 4) {
                                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(item.completed ? .green : .secondary)
                                    .font(.system(size: 9))
                                Text(item.title)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if !item.completed {
                                    Spacer(minLength: 2)
                                    Button("Run this step") {
                                        model.runWithRequest("Focus on the next items from the project plan checklist in plan/PROJECT_PLAN.md: \(item.title).")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.mini)
                                    .font(.system(size: 9))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Runs (conversation history style)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Runs")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let latest = model.runs.first {
                        Text("Latest: \(latest)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                List(model.runs, id: \.self, selection: $model.selectedRunID) { runID in
                    HStack(spacing: 6) {
                        if runID == model.runs.first {
                            Text("●")
                                .font(.system(size: 8))
                                .foregroundStyle(.blue)
                                .help("Most recent run")
                        } else {
                            Text("  ")
                                .font(.system(size: 8))
                        }
                        Text(runID)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .tag(runID)
                }
                .listStyle(.sidebar)
            }

            Spacer(minLength: 0)

            Divider()
            Button("Settings…") { showSettings = true }
                .buttonStyle(.plain)
                .padding(12)
        }
        .frame(minWidth: 220, idealWidth: 260)
        .onChange(of: model.selectedRunID) { newValue in
            model.selectRun(newValue)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top: status bar
            HStack {
                if model.isBusy {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Running…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if model.selectedRunID != nil {
                    HStack(spacing: 8) {
                        if model.isBusy {
                            Button("Stop") { model.stopRun() }
                                .controlSize(.small)
                                .keyboardShortcut(".", modifiers: .command)
                        }
                        if shouldEmphasizeContinueWorking || effectiveHighlightedButtonIDs.contains("continueWorking") {
                            Button("Continue Working") { model.continueWorking() }
                                .disabled(!isContinueWorkingEnabled || model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Continue Working") { model.continueWorking() }
                                .disabled(!isContinueWorkingEnabled || model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                        }
                        if effectiveHighlightedButtonIDs.contains("retryTask") {
                            Button("Retry Task") { model.retrySelectedTask() }
                                .disabled(model.selectedTaskID == nil || model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Retry Task") { model.retrySelectedTask() }
                                .disabled(model.selectedTaskID == nil || model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                        }
                        if effectiveHighlightedButtonIDs.contains("cleanupRun") {
                            Button("Cleanup Run") { model.cleanupSelectedRun() }
                                .disabled(model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Cleanup Run") { model.cleanupSelectedRun() }
                                .disabled(model.isBusy)
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Center: run context + task list + logs (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let run = model.runRecord {
                        runHeader(run, tasks: model.tasks)
                        agentActivitySection(run: run, tasks: model.tasks)
                        taskPickerAndList
                        logsSection
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Bottom: composer-style input (agent manager style)
            composerBar
        }
    }

    private func runHeader(_ run: RunRecord, tasks: [TaskRecord]) -> some View {
        let progress = GoalProgressService().progress(run: run, tasks: tasks)
        return VStack(alignment: .leading, spacing: 6) {
            Text(run.request)
                .font(.system(size: 13))
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text(run.state.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Tasks: \(run.metrics.tasksTotal) · Merged: \(run.metrics.tasksMerged) · Failed: \(run.metrics.tasksFailed)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if run.state == .pendingApproval {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                    Text("Awaiting your approval. Review the planned tasks below, uncheck any you don’t want to run, then click “Confirm and Start” at the bottom to begin execution.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            // Goal/spec progress (G1)
            HStack(spacing: 8) {
                Text("Progress")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", progress.progressPercent * 100))
                    .font(.system(size: 11, weight: .medium))
                Text("· \(progress.goalsCompleted)/\(progress.goalsTotal) goals")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            // Goal checklist derived from GoalProgressItem (G1)
            if !progress.items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(progress.items, id: \.goalId) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(item.completed ? .green : .secondary)
                                .font(.system(size: 11))
                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(item.completedCount)/\(max(1, item.taskCount)) tasks")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Simple "what now" guidance so users understand the next action after a run.
            if run.state == .completed || run.state == .failed {
                Divider()
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What you should do next")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if run.state == .completed {
                        Text("Review the plan and checklist in plan/PROJECT_PLAN.md, then either click “Run Mayor on Plan” to continue implementation or type a new request describing your next goal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else if run.state == .failed {
                        Text("Inspect the failing task’s logs below, update your project plan or workspace inputs if needed, then use “Retry Task” or “Continue Working” when there is additional work for TinkerTown to perform.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Surface the exact next step from the plan with a one-tap "Run this step" button.
            if let first = model.suggestedNextSteps.first {
                Divider()
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next step")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(first.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Button("Run this step") {
                        model.runWithRequest(first.requestText)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// G2: Show which agent role is doing what (from task currentActorRole/currentActivity).
    @ViewBuilder
    private func agentActivitySection(run: RunRecord, tasks: [TaskRecord]) -> some View {
        let inProgress = tasks.filter { t in
            switch t.state {
            case .worktreeReady, .prompted, .patchApplied, .verifying, .verifyFailedRetryable, .mergeReady: return true
            default: return false
            }
        }
        let lines: [(String, String)] = inProgress.compactMap { t in
            let role = t.currentActorRole ?? "worker"
            let activity = t.currentActivity ?? t.state.rawValue
            return ("\(role.capitalized): \(t.taskID)", activity)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if lines.isEmpty {
                let role = run.state == .planning ? "Planner" : "Orchestrator"
                Text("\(role): idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .rotationEffect(.degrees(isAgentActivityAnimating ? 360 : 0))
                        .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAgentActivityAnimating)
                        .foregroundStyle(Color.accentColor)
                    Text("Agents are actively working…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .onAppear { isAgentActivityAnimating = true }
                .onDisappear { isAgentActivityAnimating = false }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 8) {
                        Text(pair.0)
                            .font(.system(size: 11, weight: .medium))
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(pair.1)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var taskPickerAndList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Task", selection: $model.selectedTaskID) {
                    Text("Run events").tag(String?.none)
                    ForEach(model.tasks, id: \.taskID) { task in
                        Text(task.taskID).tag(Optional(task.taskID))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: model.selectedTaskID) { newValue in
                    model.selectTask(newValue)
                }
            }
            if !model.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.tasks, id: \.taskID) { task in
                        HStack(spacing: 12) {
                            if model.runRecord?.state == .pendingApproval {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { model.approvedTaskIDs.contains(task.taskID) },
                                        set: { isOn in
                                            if isOn { model.approvedTaskIDs.insert(task.taskID) }
                                            else { model.approvedTaskIDs.remove(task.taskID) }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                            StatusBadge(ok: task.state != .failed)
                            Text(task.taskID)
                                .font(.system(size: 11, design: .monospaced))
                            Text(task.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(task.state.rawValue) · retry \(task.retryCount)/\(task.maxRetries)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(model.selectedTaskID == task.taskID ? Color.accentColor.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    /// True when the failure explanation mentions PDR/plan/requirements so we can show clear "what to provide" steps.
    private func isPDRRelatedFailure(_ explanation: String) -> Bool {
        let lower = explanation.localizedLowercase
        return lower.contains("pdr") || lower.contains("product design requirement")
            || (lower.contains("incomplete") && lower.contains("requirement")) || lower.contains("plan") && lower.contains("prd")
    }

    /// True when the failure explanation or logs clearly point at problems in plan/PROJECT_PLAN.md.
    private func isPlanRelatedFailure(_ explanation: String) -> Bool {
        let lower = explanation.localizedLowercase
        return lower.contains("project plan") || lower.contains("plan/project_plan.md")
            || (lower.contains("undefined variable") && lower.contains("plan"))
    }

    private func isWorkspaceRelatedFailure(_ explanation: String) -> Bool {
        let lower = explanation.localizedLowercase
        return lower.contains("workspace") && (lower.contains("configuration") || lower.contains("config") || lower.contains("necessary files"))
            || lower.contains("fix workspace")
    }

    private var pdrInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to provide")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text("The Product Design Requirement (PDR) tells the Mayor what to build. It lives in your workspace at .tinkertown/pdr.json.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click “Edit Product Design Requirement…” in the left sidebar to open the PDR file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("2. Fill in at least: Title (project name), Summary (what the product does in a few sentences), Scope (what’s in and out of scope), and Acceptance criteria (testable conditions the product must meet).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("3. Save the file, then run your request again or click “Run Mayor on Plan”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Edit Product Design Requirement…") { model.editOrCreatePDR() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let explanation = model.failureExplanation {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if isPDRRelatedFailure(explanation) {
                    pdrInstructionsView
                } else if isPlanRelatedFailure(explanation) {
                    planInstructionsView
                } else if isWorkspaceRelatedFailure(explanation) {
                    workspaceInstructionsView
                }
            }
            Text("Logs")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: .constant(model.logsText))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200, maxHeight: 400)
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Guided helper for fixing plan/PROJECT_PLAN.md when the agents complain about its configuration.
    private var planInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make the project plan usable")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text("The project plan in plan/PROJECT_PLAN.md is where you and the Mayor agree on concrete steps. When it contains unresolved variables or opaque placeholders, the agents cannot safely turn it into tasks.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click “View Plan” in the sidebar to open plan/PROJECT_PLAN.md.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("2. In the “Overview” section, write 2–4 sentences in plain English describing what you’re building and why.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("3. Under “Active Checklist (Mayor-owned)”, replace any template variables with a short list of real, concrete tasks, each on its own line using the form `- [ ] Do something specific`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("4. Remove or edit any leftover placeholders like `${variable}` or `{{todo}}` so the file reads like normal Markdown.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("5. Save the file, then use “Run Mayor on Plan” to let the agents derive a fresh task plan from your updated checklist.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Open Project Plan…") { model.openOrCreatePlan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// When the agent reports invalid workspace/configuration, offer a one-tap fix so the agent can proceed on retry.
    private var workspaceInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix workspace")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text("TinkerTown will ensure the project plan and PDR exist. Then retry the task or run again; verification will match this workspace (e.g. Node vs Swift) automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Fix workspace") {
                model.fixWorkspace()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No run selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Click “Choose Workspace…” in the sidebar to select a git repo, then enter a task below and tap Run to start the agent.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Describe what you want the agent to do…", text: $model.requestText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("Run") { model.runRequest() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBusy)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            HStack {
                Button("Escalate…") { showEscalate = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.runRecord?.state == .pendingApproval {
                    if effectiveHighlightedButtonIDs.contains("confirmAndStart") {
                        Button("Confirm and Start") { model.confirmAndStartExecution() }
                            .disabled(model.isBusy)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Confirm and Start") { model.confirmAndStartExecution() }
                            .disabled(model.isBusy)
                            .buttonStyle(.bordered)
                    }
                }
                if effectiveHighlightedButtonIDs.contains("runMayorOnPlan") {
                    Button("Run Mayor on Plan") { model.runMayorFromPlanChecklist() }
                        .disabled(model.isBusy)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Run Mayor on Plan") { model.runMayorFromPlanChecklist() }
                        .disabled(model.isBusy)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var escalateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Escalate")
                .font(.headline)
            HStack {
                Picker("Severity", selection: $model.escalationSeverity) {
                    Text("HIGH").tag("HIGH")
                    Text("CRITICAL").tag("CRITICAL")
                }
                .frame(width: 140)
            }
            TextField("Message", text: $model.escalationMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { showEscalate = false }
                Button("Log") {
                    model.escalate()
                    showEscalate = false
                }
                .disabled(model.isBusy)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private var pdrPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attach Product Requirements")
                .font(.headline)
            Text("This workspace does not yet have a Product Design Requirement file at .tinkertown/pdr.json. TinkerTown needs one before the Mayor can reliably plan work.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Paste or upload a project plan (TinkerTown will configure the PDR for you), or create a minimal PDR to edit.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") {
                    model.shouldShowPDRPrompt = false
                    showPDRPrompt = false
                }
                Button("Import Project Plan…") {
                    model.shouldShowPDRPrompt = false
                    showPDRPrompt = false
                    importPlanPastedText = ""
                    showImportPlanSheet = true
                }
                .buttonStyle(.borderedProminent)
                Button("Create and Open PDR") {
                    model.shouldShowPDRPrompt = false
                    showPDRPrompt = false
                    model.editOrCreatePDR()
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var importPlanSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Project Plan")
                .font(.headline)
            Text("Paste your project plan below or choose a file. TinkerTown will save it to plan/PROJECT_PLAN.md and configure the PDR so the Mayor and mirror can use it—no need to edit .tinkertown/pdr.json yourself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $importPlanPastedText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 200, maxHeight: 360)
            HStack {
                Button("Choose File…") {
                    if let content = model.pickFileAndReturnPlanContent() {
                        importPlanPastedText = content
                    }
                }
                Spacer()
                Button("Cancel") {
                    showImportPlanSheet = false
                    importPlanPastedText = ""
                }
                Button("Import") {
                    model.importProjectPlan(content: importPlanPastedText)
                    showImportPlanSheet = false
                    importPlanPastedText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(importPlanPastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
    }
}

@main
struct TinkerTownAppMain: App {
    private static let appContainerPaths: AppContainerPaths = {
        AppContainerPaths(root: AppContainerPaths.defaultRoot())
    }()

    var body: some Scene {
        WindowGroup("TinkerTown") {
            RootView(appPaths: Self.appContainerPaths)
        }
    }
}

// MARK: - Onboarding gate

private struct RootView: View {
    let appPaths: AppContainerPaths
    @State private var showMain = false

    var body: some View {
        Group {
            if showMain {
                ContentView(appContainerPaths: appPaths)
            } else {
                OnboardingView(paths: appPaths) {
                    NotificationCenter.default.post(name: .onboardingDidComplete, object: nil)
                }
            }
        }
        .onAppear {
            let store = OnboardingStore(paths: appPaths)
            showMain = OnboardingStateMachine.isComplete(store.load())
        }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingDidComplete)) { _ in
            showMain = true
        }
    }
}

extension Notification.Name {
    static let onboardingDidComplete = Notification.Name("onboardingDidComplete")
}

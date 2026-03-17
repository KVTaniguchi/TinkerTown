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

private struct ActivityFeedEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let icon: String
    let actor: String
    let message: String
    enum Level { case info, success, failure, progress }
    let level: Level
    var iconColor: Color {
        switch level {
        case .info:     return .secondary
        case .success:  return .green
        case .failure:  return .red
        case .progress: return Color.accentColor
        }
    }
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
    @Published var activityFeed: [ActivityFeedEntry] = []
    @Published var mayorChannel: [ActivityFeedEntry] = []

    // MARK: Autopilot
    @Published var autopilotEnabled: Bool = UserDefaults.standard.bool(forKey: "autopilot.enabled") {
        didSet {
            UserDefaults.standard.set(autopilotEnabled, forKey: "autopilot.enabled")
            if autopilotEnabled { startAutopilotTimer() } else { stopAutopilotTimer() }
        }
    }
    @Published var autopilotIntervalHours: Double = {
        let v = UserDefaults.standard.double(forKey: "autopilot.intervalHours")
        return v > 0 ? v : 4.0
    }() {
        didSet {
            UserDefaults.standard.set(autopilotIntervalHours, forKey: "autopilot.intervalHours")
            if autopilotEnabled { startAutopilotTimer() }
        }
    }
    @Published var nextAutopilotFireDate: Date?
    private var autopilotTimer: Timer?

    private let appContainerPaths: AppContainerPaths?
    private var seenTaskStates: [String: TaskState] = [:]
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
            if autopilotEnabled { startAutopilotTimer() }
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

    // MARK: Autopilot timer

    func startAutopilotTimer() {
        stopAutopilotTimer()
        guard hasChosenRepository else { return }
        let interval = autopilotIntervalHours * 3600
        nextAutopilotFireDate = Date().addingTimeInterval(interval)
        autopilotTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isBusy else { return }
                self.nextAutopilotFireDate = Date().addingTimeInterval(self.autopilotIntervalHours * 3600)
                self.appendActivity("⏰", actor: "autopilot", message: "Autopilot: starting scheduled run", level: .info)
                self.runMayorFromPlanChecklist()
            }
        }
    }

    func stopAutopilotTimer() {
        autopilotTimer?.invalidate()
        autopilotTimer = nil
        nextAutopilotFireDate = nil
    }

    /// Opens plan/PROJECT_PLAN.md in the default editor (e.g. TextEdit, VS Code, etc.).
    /// Creates a default plan template first if the file doesn't exist.
    func openPlanFile() {
        guard hasChosenRepository else { return }
        let planURL = repoURL
            .appendingPathComponent("plan", isDirectory: true)
            .appendingPathComponent("PROJECT_PLAN.md")
        if !FileManager.default.fileExists(atPath: planURL.path) {
            try? FileManager.default.createDirectory(
                at: planURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let title = repoURL.lastPathComponent
            let template = """
            # Project Plan – \(title)

            ## Overview
            Briefly restate the project scope and goals here.

            ## Active Checklist (Mayor-owned)
            - [ ] First concrete task derived from the product requirements

            ## Backlog (Mayor-owned)
            - [ ] Future task or idea to consider

            ## Decisions Log (Mayor-owned)
            - \(ISO8601DateFormatter().string(from: Date()).prefix(10)): Document major decisions here.

            ## Risks / Unknowns (Mayor-owned)
            - Describe known risks or open questions.
            """
            try? template.write(to: planURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(planURL)
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

    /// Starts a run driven by the project plan. The Mayor reads PROJECT_PLAN.md directly
    /// and derives tasks from it, so no checklist pre-processing is needed here.
    func runMayorFromPlanChecklist() {
        runWithRequest("Follow the project plan.")
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
        appendActivity("▶", actor: "app", message: "Starting: \(String(trimmed.prefix(80)))", level: .info)
        appendMayor("🤔", message: "Planning: \"\(String(trimmed.prefix(100)))\"", level: .progress)
        runOrchestrationInBackground { [repoURL] in
            let context = try self.makeContext(root: repoURL)
            try Self.ensureGitPreflight(cwd: repoURL)
            let pdrService = PDRService(paths: context.paths)
            let (pdr, resolvedURL) = try pdrService.resolve(customPath: nil)
            let wsLogger = WorkspaceLogger(root: repoURL)
            let adapters = Self.makeAdapters(config: context.config, guardrails: context.guardrails, logger: wsLogger)
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
                tinker: adapters.tinker,
                logger: wsLogger
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
                if taskList.isEmpty {
                    self.appendMayor("⚠", message: "No tasks were planned. The model may have returned an unparseable response — check .tinkertown/tinkertown.log.", level: .failure)
                } else {
                    self.appendMayor("📋", message: "Dispatching \(taskList.count) task\(taskList.count == 1 ? "" : "s") to Tinkers:")
                    for task in taskList {
                        self.appendMayor("→", message: "\(task.title) [\(task.targetFiles.joined(separator: ", "))]")
                    }
                }
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
            let wsLogger = WorkspaceLogger(root: repoURL)
            let adapters = Self.makeAdapters(config: context.config, guardrails: context.guardrails, logger: wsLogger)
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
                tinker: adapters.tinker,
                logger: wsLogger
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
            let wsLogger = WorkspaceLogger(root: repoURL)
            let adapters = Self.makeAdapters(config: context.config, guardrails: context.guardrails, logger: wsLogger)
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
                tinker: adapters.tinker,
                logger: wsLogger
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
                appendActivity("●", actor: "app", message: "Run completed", level: .success)
                let merged = tasks.filter { $0.state == .merged || $0.state == .cleaned }.count
                let failed = tasks.filter { $0.state == .failed || $0.state == .rejected }.count
                if failed == 0 {
                    appendMayor("✅", message: "All done. \(merged) task\(merged == 1 ? "" : "s") merged successfully.", level: .success)
                } else {
                    appendMayor("⚠", message: "\(merged) merged, \(failed) failed. Review the log for details.", level: .failure)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                statusMessage = "Failed"
                appendActivity("!", actor: "app", message: error.localizedDescription, level: .failure)
                appendMayor("✗", message: "Run stopped with error: \(error.localizedDescription)", level: .failure)
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
        appendActivity("■", actor: "app", message: "Run stopped by user", level: .info)
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
        updateActivityFeedFromTasks(taskList)
        logsText = logs
        preflightChecks = (try? Self.preflightChecks(root: repoURL, config: context.config)) ?? preflightChecks
        if run.state == .completed {
            // Only mark checklist items complete when at least one task actually produced file changes.
            // This avoids marking e.g. "API contracts" done when tasks merged with 0 files changed.
            let completedTasks = taskList.filter { [TaskState.merged, .cleaned].contains($0.state) }
            let hasActualChanges: (TaskRecord) -> Bool = { task in
                let d = task.result.diffStats
                return d.files > 0 || d.insertions + d.deletions > 0
            }
            let tasksWithChanges = completedTasks.filter(hasActualChanges)
            var titlesToMark = tasksWithChanges.map(\.title)
            if !tasksWithChanges.isEmpty, let focusTitles = Self.focusTitlesFromRunRequest(run.request) {
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

    private static func makeAdapters(config: AppConfig, guardrails: GuardrailService, logger: WorkspaceLogger?) -> (mayor: MayorAdapting, tinker: TinkerAdapting) {
        if config.shouldUseOllama {
            let client = OllamaClient()
            let mayor = OllamaMayorAdapter(client: client, model: config.models.mayor, numCtx: config.ollama.mayorNumCtx, logger: logger)
            let tinker = OllamaTinkerAdapter(client: client, model: config.models.tinker, numCtx: config.ollama.tinkerNumCtx, guardrails: guardrails, logger: logger)
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

        // Ensure a default branch exists (main, master, or origin/HEAD).
        let defaultBranch = try GitDefaultBranch().detect(at: cwd)
        guard !defaultBranch.isEmpty else {
            throw NSError(domain: "TinkerTownApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "No default branch found. Ensure the repository has a branch (e.g. main or master)."])
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

        let defaultBranchDetector = GitDefaultBranch(shell: shell)
        let defaultBranchOK: Bool
        let defaultBranchDetail: String
        if let detected = try? defaultBranchDetector.detect(at: root) {
            defaultBranchOK = true
            defaultBranchDetail = "\(detected)"
        } else {
            defaultBranchOK = false
            defaultBranchDetail = "Missing"
        }
        checks.append(PreflightCheck(name: "default branch", ok: defaultBranchOK, detail: defaultBranchDetail))

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

    // MARK: - Activity feed

    func clearForNewRun() {
        selectedRunID = nil
        runRecord = nil
        tasks = []
        logsText = ""
        failureExplanation = nil
        errorMessage = nil
        statusMessage = "Ready"
        activityFeed = []
        mayorChannel = []
        seenTaskStates = [:]
        requestText = ""
    }

    func appendActivity(_ icon: String, actor: String, message: String, level: ActivityFeedEntry.Level) {
        let entry = ActivityFeedEntry(timestamp: .now, icon: icon, actor: actor, message: message, level: level)
        activityFeed.append(entry)
        if activityFeed.count > 500 {
            activityFeed = Array(activityFeed.suffix(500))
        }
        AppLogger.shared.log(level == .failure ? "ERROR" : "INFO", actor: actor.uppercased(), message)
    }

    func appendMayor(_ icon: String, message: String, level: ActivityFeedEntry.Level = .info) {
        let entry = ActivityFeedEntry(timestamp: .now, icon: icon, actor: "mayor", message: message, level: level)
        mayorChannel.append(entry)
        if mayorChannel.count > 200 {
            mayorChannel = Array(mayorChannel.suffix(200))
        }
    }

    func updateActivityFeedFromTasks(_ newTasks: [TaskRecord]) {
        for task in newTasks {
            let prev = seenTaskStates[task.taskID]
            guard prev != task.state else { continue }
            seenTaskStates[task.taskID] = task.state
            switch task.state {
            case .worktreeReady:
                appendActivity("⚙", actor: "tinker", message: "Setting up: \(task.title)", level: .progress)
            case .prompted:
                appendActivity("✎", actor: task.currentActorRole ?? "tinker", message: "Generating: \(task.title)", level: .progress)
                appendMayor("→", message: "Tinker working on: \(task.title)", level: .progress)
            case .patchApplied:
                appendActivity("◆", actor: "tinker", message: "Patch applied: \(task.title)", level: .info)
            case .verifying:
                appendActivity("◎", actor: "inspector", message: "Verifying: \(task.title)", level: .progress)
                appendMayor("◎", message: "Verifying build for: \(task.title)", level: .progress)
            case .merged, .cleaned:
                appendActivity("✓", actor: "merge", message: "Merged: \(task.title)", level: .success)
                appendMayor("✓", message: "\(task.title) — merged ✓", level: .success)
            case .rejected:
                appendActivity("✗", actor: "merge", message: "Rejected: \(task.title)", level: .failure)
                appendMayor("✗", message: "\(task.title) — rejected", level: .failure)
            case .failed:
                appendActivity("✗", actor: "tinker", message: "Failed: \(task.title) (retry \(task.retryCount)/\(task.maxRetries))", level: .failure)
                if task.retryCount < task.maxRetries {
                    appendMayor("↺", message: "\(task.title) failed — retrying (\(task.retryCount + 1)/\(task.maxRetries))", level: .failure)
                } else {
                    appendMayor("✗", message: "\(task.title) — exhausted all retries", level: .failure)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Worker pill

private struct WorkerPill: View {
    let name: String
    let isActive: Bool
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulsing ? 1.8 : 1.0)
                        .opacity(pulsing ? 0.0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
                }
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Text(name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isActive ? Color.green.opacity(0.1) : Color.secondary.opacity(0.07)))
        .onAppear { pulsing = isActive }
        .onChange(of: isActive) { newValue in pulsing = newValue }
    }
}

// MARK: - Main UI

private struct ContentView: View {
    let appContainerPaths: AppContainerPaths?
    @StateObject private var model: AppViewModel
    @State private var showSettings = false
    @State private var showPDRPrompt = false
    @State private var showImportPlanSheet = false
    @State private var importPlanPastedText = ""

    init(appContainerPaths: AppContainerPaths? = nil) {
        self.appContainerPaths = appContainerPaths
        _model = StateObject(wrappedValue: AppViewModel(appContainerPaths: appContainerPaths))
    }

    var body: some View {
        VStack(spacing: 0) {
            workerRail
            Divider()
            HStack(alignment: .top, spacing: 20) {
                primaryButtonPanel
                activityFeedPanel
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composerSection
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) { SettingsView(paths: appContainerPaths) }
        .sheet(isPresented: $showImportPlanSheet) { importPlanSheet }
        .sheet(isPresented: Binding(
            get: { model.shouldShowPDRPrompt || showPDRPrompt },
            set: { newValue in
                showPDRPrompt = newValue
                if !newValue { model.shouldShowPDRPrompt = false }
            }
        )) { pdrPromptSheet }
        .onAppear { model.startMonitor() }
        .onDisappear { model.stopMonitor() }
    }

    // MARK: Worker Rail

    private var workerSlots: [(name: String, isActive: Bool, activity: String?)] {
        let maxParallel = model.currentConfig?.orchestrator.maxParallelTasks ?? 2
        let activeTasks = model.tasks.filter {
            switch $0.state {
            case .worktreeReady, .prompted, .patchApplied, .verifying, .verifyFailedRetryable, .mergeReady:
                return true
            default: return false
            }
        }
        let mayorActive = model.isBusy && activeTasks.isEmpty
        var slots: [(name: String, isActive: Bool, activity: String?)] = [
            ("Mayor", mayorActive, mayorActive ? "planning…" : nil)
        ]
        for i in 0..<maxParallel {
            if i < activeTasks.count {
                let task = activeTasks[i]
                slots.append(("Tinker \(i + 1)", true, task.currentActivity ?? task.state.rawValue))
            } else {
                slots.append(("Tinker \(i + 1)", false, nil))
            }
        }
        return slots
    }

    private var workerRail: some View {
        HStack(spacing: 10) {
            ForEach(Array(workerSlots.enumerated()), id: \.offset) { _, slot in
                WorkerPill(name: slot.name, isActive: slot.isActive)
                    .help(slot.activity ?? (slot.isActive ? "Active" : "Idle"))
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Primary Button

    private enum PrimaryAction {
        case chooseWorkspace, startOllama, startRun, stop, approveAndStart, resume, newRun
    }

    private var primaryAction: PrimaryAction {
        if !model.hasChosenRepository { return .chooseWorkspace }
        if model.isBusy { return .stop }
        // When not busy, prefer "Start Ollama" if service is down so user can fix it before running or resuming.
        let ollamaDown = model.preflightChecks.contains { $0.name == "ollama service" && !$0.ok }
        if ollamaDown { return .startOllama }
        if let run = model.runRecord {
            switch run.state {
            case .pendingApproval: return .approveAndStart
            case .executing, .merging, .planning: return .stop
            case .failed:
                let terminal: Set<TaskState> = [.merged, .rejected, .failed, .cleaned]
                return model.tasks.contains { !terminal.contains($0.state) } ? .resume : .newRun
            case .completed: return .newRun
            default: break
            }
        }
        return .startRun
    }

    private var primaryButtonTitle: String {
        switch primaryAction {
        case .chooseWorkspace: return "Choose\nWorkspace"
        case .startOllama:     return "Start\nOllama"
        case .startRun:        return "Start\nRun"
        case .stop:            return "Stop"
        case .approveAndStart: return "Approve\n& Start"
        case .resume:          return "Resume"
        case .newRun:          return "New\nRun"
        }
    }

    private var primaryButtonTint: Color {
        switch primaryAction {
        case .stop:   return .red
        case .resume: return .orange
        case .newRun: return Color(nsColor: .systemGray)
        default:      return .accentColor
        }
    }

    private func executePrimary() {
        switch primaryAction {
        case .chooseWorkspace: model.chooseRepository()
        case .startOllama:     model.startOllamaInTerminal()
        case .startRun:        model.runRequest()
        case .stop:            model.stopRun()
        case .approveAndStart: model.confirmAndStartExecution()
        case .resume:          model.continueWorking()
        case .newRun:          model.clearForNewRun()
        }
    }

    private var autopilotRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: $model.autopilotEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.75, anchor: .leading)
                    .frame(width: 38)
                Text("Autopilot")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.autopilotEnabled {
                    Picker("", selection: $model.autopilotIntervalHours) {
                        Text("1h").tag(1.0)
                        Text("2h").tag(2.0)
                        Text("4h").tag(4.0)
                        Text("8h").tag(8.0)
                        Text("24h").tag(24.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                    .frame(width: 52)
                }
            }
            if model.autopilotEnabled, let next = model.nextAutopilotFireDate {
                Text("Next run \(next, style: .relative) from now")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.autopilotEnabled
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.autopilotEnabled
                    ? Color.accentColor.opacity(0.3)
                    : Color(nsColor: .separatorColor),
                    lineWidth: 1)
        )
        .frame(width: 180)
    }

    private var primaryButtonPanel: some View {
        VStack(spacing: 14) {
            Button(action: executePrimary) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(primaryButtonTint)
                    VStack(spacing: 10) {
                        if model.isBusy {
                            ProgressView()
                                .scaleEffect(0.85)
                                .tint(.white)
                        }
                        Text(primaryButtonTitle)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 180, height: 110)

            if model.hasChosenRepository {
                Button(action: model.openPlanFile) {
                    Label("View Plan", systemImage: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(width: 180)
            }

            if model.hasChosenRepository {
                autopilotRow

                VStack(spacing: 3) {
                    Text(model.repoURL.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Button("Change workspace…") { model.chooseRepository() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 180)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 180)
    }

    // MARK: Activity Feed

    private var activityFeedPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.activityFeed.isEmpty {
                        Text(emptyFeedMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    } else {
                        ForEach(model.activityFeed) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.icon)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(entry.iconColor)
                                    .frame(width: 16)
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.actor.uppercased())
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 60, alignment: .leading)
                                    Text(entry.message)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("feedBottom")
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
            .onChange(of: model.activityFeed.count) { _ in
                withAnimation { proxy.scrollTo("feedBottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFeedMessage: String {
        guard model.hasChosenRepository else { return "Choose a workspace to get started." }
        return "No activity yet. Type a request below and tap Start Run."
    }

    // MARK: Composer

    private var composerSection: some View {
        HStack(spacing: 0) {
            // Left: user input
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.requestText)
                        .font(.system(size: 13))
                        .frame(minHeight: 36, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .disabled(model.isBusy)
                    if model.requestText.isEmpty {
                        Text("Describe a task, ask a question, or give the mayor instructions…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                Button("Send") { model.runRequest() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)

            Divider()

            // Right: Mayor channel
            mayorChannelPanel
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxHeight: 160)
    }

    private var mayorChannelPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MAYOR")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.mayorChannel.isEmpty {
                    Button("Clear") { model.mayorChannel = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.mayorChannel.isEmpty {
                            Text(model.hasChosenRepository ? "Waiting for the Mayor…" : "Choose a workspace to get started.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(model.mayorChannel) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(entry.iconColor)
                                        .frame(width: 14)
                                    Text(entry.message)
                                        .font(.system(size: 11))
                                        .foregroundStyle(entry.level == .failure ? Color.red : entry.level == .success ? Color.green : Color.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 12)
                                .id(entry.id)
                            }
                            Color.clear.frame(height: 1).id("mayorBottom")
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.mayorChannel.count) { _ in
                    withAnimation { proxy.scrollTo("mayorBottom", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Sheets

    private var pdrPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attach Product Requirements")
                .font(.headline)
            Text("This workspace does not yet have a Product Design Requirement file. TinkerTown needs one before the Mayor can reliably plan work.")
                .font(.system(size: 12))
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
            Text("Paste your project plan below or choose a file. TinkerTown will save it to plan/PROJECT_PLAN.md and configure the PDR.")
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

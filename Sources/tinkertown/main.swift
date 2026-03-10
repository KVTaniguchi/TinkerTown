import Foundation
import TinkerTownCore

@main
struct TinkerTownCLI {
    static func main() {
        do {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let paths = AppPaths(root: cwd)
            let configStore = ConfigStore(paths: paths)
            let config = try configStore.bootstrap()

            let store = RunStore(paths: paths)
            let events = EventLogger(paths: paths)
            let guardrails = GuardrailService(config: config.guardrails)
            let inspector = Inspector(eventLogger: events)

            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else {
                printUsage()
                exit(1)
            }

            switch command {
            case "run":
                guard args.count >= 2 else {
                    print("Missing request. Usage: tinkertown run [--pdr <path>] \"<request>\"")
                    exit(1)
                }
                try ensureGitPreflight(cwd: cwd)
                var runArgs = args.dropFirst()
                var pdrPath: URL?
                if runArgs.first == "--pdr", runArgs.count >= 3 {
                    pdrPath = URL(fileURLWithPath: String(runArgs.dropFirst().first!))
                    runArgs = runArgs.dropFirst(2)
                }
                let request = runArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.isEmpty else {
                    fputs("error: Request cannot be empty.\n", stderr)
                    exit(1)
                }
                let pdrService = PDRService(paths: paths)
                let (pdr, resolvedURL) = try pdrService.resolve(customPath: pdrPath)
                let mayor: MayorAdapting
                let tinker: TinkerAdapting
                if config.shouldUseOllama {
                    let client = OllamaClient()
                    mayor = OllamaMayorAdapter(client: client, model: config.models.mayor, numCtx: config.ollama.mayorNumCtx)
                    tinker = OllamaTinkerAdapter(client: client, model: config.models.tinker, numCtx: config.ollama.tinkerNumCtx, guardrails: guardrails)
                } else {
                    mayor = DefaultMayorAdapter()
                    tinker = DefaultTinkerAdapter(guardrails: guardrails)
                }
                let orchestrator = Orchestrator(
                    root: cwd,
                    paths: paths,
                    config: config,
                    store: store,
                    events: events,
                    worktrees: WorktreeManager(),
                    inspector: inspector,
                    scheduler: Scheduler(),
                    mergeManager: DefaultMergeManager(root: cwd, store: store),
                    mayor: mayor,
                    tinker: tinker
                )
                let runID = try orchestrator.run(request: request, pdr: pdr, pdrResolvedURL: resolvedURL)
                print(runID)
                // Best-effort index refresh after successful merge cycles.
                try? refreshIndexIfCompleted(runID: runID, cwd: cwd, paths: paths, store: store)

            case "status":
                guard args.count >= 2 else {
                    print("Usage: tinkertown status <run_id>")
                    exit(1)
                }
                let run = try store.loadRun(args[1])
                let tasks = try store.listTasks(runID: run.runID)
                print("run_id: \(run.runID)")
                print("state: \(run.state.rawValue)")
                print("tasks_total: \(run.metrics.tasksTotal)")
                print("tasks_merged: \(run.metrics.tasksMerged)")
                print("tasks_failed: \(run.metrics.tasksFailed)")
                for t in tasks {
                    print("- \(t.taskID): \(t.state.rawValue) retries=\(t.retryCount)")
                }

            case "summary":
                guard args.count >= 2 else {
                    print("Usage: tinkertown summary <run_id>")
                    exit(1)
                }
                let runID = args[1]
                let agent = StatusAgent(store: store)
                let report = try agent.report(runID: runID)
                let summary = report.summary
                print("run_id: \(summary.runID)")
                print("state: \(summary.state.rawValue)")
                print("tasks_total: \(summary.tasksTotal)")
                print("tasks_merged: \(summary.tasksMerged)")
                print("tasks_failed: \(summary.tasksFailed)")
                print(String(format: "run_duration_seconds: %.1f", summary.runDurationSeconds))
                print(String(format: "task_cycle_time_seconds: %.2f", summary.taskCycleTimeSeconds))
                print(String(format: "retry_rate: %.2f", summary.retryRate))
                print(String(format: "merge_success_rate: %.2f", summary.mergeSuccessRate))
                print(String(format: "conflict_rate: %.2f", summary.conflictRate))
                print(String(format: "median_build_time_seconds: %.1f", summary.medianBuildTimeSeconds))
                let gp = report.goalProgress
                print(String(format: "goal_progress: %.0f%% (%d/%d goals)", gp.progressPercent * 100, gp.goalsCompleted, gp.goalsTotal))
                print("")
                print("Tasks:")
                for task in report.tasks {
                    let mark: String
                    switch task.state {
                    case .merged: mark = "[✓]"
                    case .failed, .rejected: mark = "[✗]"
                    case .verifyFailedRetryable: mark = "[!]"
                    default: mark = "[…]"
                    }
                    print("\(mark) \(task.taskID): \(task.state.rawValue) retries=\(task.retryCount)/\(task.maxRetries) — \(task.title)")
                }

            case "logs":
                guard args.count >= 2 else {
                    print("Usage: tinkertown logs <run_id> [--task <task_id>]")
                    exit(1)
                }
                let runID = args[1]
                if args.count == 4, args[2] == "--task" {
                    let taskID = args[3]
                    let taskDir = paths.tasksDir(runID).appendingPathComponent(taskID)
                    let logs = try LocalFileSystem().listFiles(taskDir).filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for log in logs {
                        print("=== \(log.lastPathComponent) ===")
                        let data = try Data(contentsOf: log)
                        print(String(data: data, encoding: .utf8) ?? "")
                    }
                } else {
                    let data = try Data(contentsOf: paths.eventsFile(runID))
                    print(String(data: data, encoding: .utf8) ?? "")
                }

            case "retry":
                guard args.count >= 3 else {
                    print("Usage: tinkertown retry <run_id> <task_id>")
                    exit(1)
                }
                var task = try store.loadTask(runID: args[1], taskID: args[2])
                if task.state == .failed {
                    task.retryCount = 0
                    task.state = .taskCreated
                    try store.saveTask(task)
                    print("Task reset for retry: \(task.taskID)")
                } else {
                    print("Task is not FAILED; current state: \(task.state.rawValue)")
                }

            case "cleanup":
                guard args.count >= 2 else {
                    print("Usage: tinkertown cleanup <run_id>")
                    exit(1)
                }
                let runID = args[1]
                let tasks = try store.listTasks(runID: runID)
                let worktreeManager = WorktreeManager()
                for task in tasks {
                    worktreeManager.teardown(task: task, root: cwd)
                }
                worktreeManager.cleanupOrphaned(root: cwd)
                print("cleanup complete for \(runID)")

            case "index":
                // Manual index regeneration for the current repository. Does not depend
                // on a particular run state.
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(at: cwd, includingPropertiesForKeys: nil) else {
                    print("Failed to enumerate source files for indexing.")
                    exit(1)
                }
                var swiftFiles: [URL] = []
                for case let url as URL in enumerator {
                    if url.pathExtension == "swift" {
                        swiftFiles.append(url)
                    }
                }
                let indexer = IndexerService(paths: paths)
                let map = try indexer.buildIndex(sourceFiles: swiftFiles)
                try indexer.writeIndex(map: map)
                print("TinkerMap.json updated.")

            case "pdr":
                if args.count >= 2, args[1] == "validate" {
                    let validatePath: URL
                    if args.count >= 4, args[2] == "--path" {
                        validatePath = URL(fileURLWithPath: args[3])
                    } else {
                        validatePath = paths.pdrFile
                    }
                    let pdrService = PDRService(paths: paths)
                    if let errors = pdrService.validate(at: validatePath) {
                        fputs("Invalid PDR:\n", stderr)
                        for e in errors { fputs("  \(e)\n", stderr) }
                        exit(1)
                    }
                    print("PDR valid: \(validatePath.path)")
                } else if args.count >= 2, args[1] == "init" {
                    var title = "My project"
                    var i = 2
                    while i < args.count {
                        if args[i] == "--title", i + 1 < args.count {
                            title = args[i + 1]
                            i += 2
                            continue
                        }
                        i += 1
                    }
                    let pdrService = PDRService(paths: paths)
                    try pdrService.writeDefaultMinimal(title: title)
                    print("Created \(paths.pdrFile.path)")
                } else {
                    print("Usage: tinkertown pdr validate [--path <path>]")
                    print("       tinkertown pdr init [--title \"<title>\"]")
                    exit(1)
                }

            case "escalate":
                var severity = "HIGH"
                var runID: String?
                var messageStart = 1
                var i = 1
                while i < args.count {
                    if args[i] == "--severity", i + 1 < args.count {
                        severity = args[i + 1]
                        i += 2
                        continue
                    }
                    if args[i] == "--run", i + 1 < args.count {
                        runID = args[i + 1]
                        i += 2
                        continue
                    }
                    messageStart = i
                    break
                }
                let message = args.dropFirst(messageStart).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    print("Usage: tinkertown escalate [--severity HIGH|CRITICAL] [--run <run_id>] \"<message>\"")
                    exit(1)
                }
                try events.appendEscalation(severity: severity, message: message, runID: runID)
                print("escalation logged (\(severity))")

            case "monitor":
                var intervalSeconds: TimeInterval = 30
                var i = 1
                while i < args.count {
                    if args[i] == "--interval", i + 1 < args.count, let sec = Double(args[i + 1]) {
                        intervalSeconds = sec
                        i += 2
                        continue
                    }
                    break
                }
                let mayor: MayorAdapting
                let tinker: TinkerAdapting
                if config.shouldUseOllama {
                    let client = OllamaClient()
                    mayor = OllamaMayorAdapter(client: client, model: config.models.mayor, numCtx: config.ollama.mayorNumCtx)
                    tinker = OllamaTinkerAdapter(client: client, model: config.models.tinker, numCtx: config.ollama.tinkerNumCtx, guardrails: guardrails)
                } else {
                    mayor = DefaultMayorAdapter()
                    tinker = DefaultTinkerAdapter(guardrails: guardrails)
                }
                let orchestrator = Orchestrator(
                    root: cwd,
                    paths: paths,
                    config: config,
                    store: store,
                    events: events,
                    worktrees: WorktreeManager(),
                    inspector: inspector,
                    scheduler: Scheduler(),
                    mergeManager: DefaultMergeManager(root: cwd, store: store),
                    mayor: mayor,
                    tinker: tinker
                )
                print("Monitor running (interval \(Int(intervalSeconds))s). Ctrl+C to stop.")
                while true {
                    do {
                        let runIDs = try runsNeedingResume(store: store)
                        if let runID = runIDs.first {
                            print("Resuming \(runID)...")
                            try orchestrator.resume(runID: runID)
                            try? refreshIndexIfCompleted(runID: runID, cwd: cwd, paths: paths, store: store)
                        }
                    } catch {
                        fputs("monitor: \(error.localizedDescription)\n", stderr)
                    }
                    sleep(UInt32(intervalSeconds))
                }

            default:
                printUsage()
                exit(1)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func refreshIndexIfCompleted(runID: String, cwd: URL, paths: AppPaths, store: RunStore) throws {
        let run = try store.loadRun(runID)
        guard run.state == .completed else { return }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cwd, includingPropertiesForKeys: nil) else { return }
        var swiftFiles: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }

        let indexer = IndexerService(paths: paths)
        let map = try indexer.buildIndex(sourceFiles: swiftFiles)
        try indexer.writeIndex(map: map)
    }

    private static func printUsage() {
        print("""
        tinkertown commands:
          tinkertown run [--pdr <path>] \"<request>\"   (requires .tinkertown/pdr.json or --pdr)
          tinkertown pdr validate [--path <path>]
          tinkertown pdr init [--title \"<title>\"]
          tinkertown status <run_id>
          tinkertown summary <run_id>
          tinkertown logs <run_id> [--task <task_id>]
          tinkertown retry <run_id> <task_id>
          tinkertown cleanup <run_id>
          tinkertown monitor [--interval <seconds>]
          tinkertown escalate [--severity HIGH|CRITICAL] [--run <run_id>] \"<message>\"
        """)
    }

    private static func ensureGitPreflight(cwd: URL) throws {
        // Ensure the current directory is a usable git repository. If it is not,
        // attempt to initialize one so the CLI can run immediately.
        do {
            let initializer = GitRepositoryInitializer()
            _ = try initializer.ensureRepository(at: cwd)
        } catch {
            throw NSError(
                domain: "tinkertown",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize git repository in current directory: \(error.localizedDescription)"]
            )
        }

        // Double-check that the expected base branch exists.
        let shell = ShellRunner()
        let branch = try shell.run("git rev-parse --verify main", cwd: cwd)
        guard branch.exitCode == 0 else {
            throw NSError(domain: "tinkertown", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base branch 'main' not found. Create or rename your primary branch to 'main'."])
        }
    }
}

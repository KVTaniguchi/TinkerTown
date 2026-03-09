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
                    print("Missing request. Usage: tinkertown run \"<request>\"")
                    exit(1)
                }
                try ensureGitPreflight(cwd: cwd)
                let request = args.dropFirst().joined(separator: " ")
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
                    mergeGate: MergeGate(),
                    mayor: mayor,
                    tinker: tinker
                )
                let runID = try orchestrator.run(request: request)
                print(runID)

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

            default:
                printUsage()
                exit(1)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print("""
        tinkertown commands:
          tinkertown run \"<request>\"
          tinkertown status <run_id>
          tinkertown logs <run_id> [--task <task_id>]
          tinkertown retry <run_id> <task_id>
          tinkertown cleanup <run_id>
          tinkertown escalate [--severity HIGH|CRITICAL] [--run <run_id>] \"<message>\"
        """)
    }

    private static func ensureGitPreflight(cwd: URL) throws {
        let shell = ShellRunner()
        let inside = try shell.run("git rev-parse --is-inside-work-tree", cwd: cwd)
        guard inside.exitCode == 0, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw NSError(domain: "tinkertown", code: 1, userInfo: [NSLocalizedDescriptionKey: "Current directory is not a git repository."])
        }

        let branch = try shell.run("git rev-parse --verify main", cwd: cwd)
        guard branch.exitCode == 0 else {
            throw NSError(domain: "tinkertown", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base branch 'main' not found. Create or rename your primary branch to 'main'."])
        }
    }
}

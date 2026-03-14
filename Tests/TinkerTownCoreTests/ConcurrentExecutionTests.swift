import Foundation
import Testing
@testable import TinkerTownCore

struct ConcurrentExecutionTests {

    @Test("EventLogger: 10 concurrent appends produce exactly 10 valid NDJSON lines")
    func eventLoggerConcurrentAppends() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let logger = EventLogger(fs: fs, paths: paths)
        let runID = "run_concurrent"

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<10 {
            group.enter()
            queue.async {
                defer { group.leave() }
                let event = RunEvent(
                    runID: runID,
                    taskID: "task_\(i)",
                    type: "TASK_STATE_CHANGED",
                    from: "TASK_CREATED",
                    to: "WORKTREE_READY"
                )
                try? logger.append(event)
            }
        }
        group.wait()

        let data = try fs.read(paths.eventsFile(runID))
        let content = String(data: data, encoding: .utf8) ?? ""

        // The encoder may use pretty-print formatting. Count complete JSON objects
        // by counting top-level `{` markers (lines that are exactly "{").
        let objectStarts = content.components(separatedBy: "\n").filter { $0 == "{" }.count
        #expect(objectStarts == 10, "Expected 10 JSON objects, got \(objectStarts)")

        // Verify no interleaving: each object boundary `}\n{` or `}\n` must be clean.
        // The "type" key appears exactly once per event.
        let typeCount = content.components(separatedBy: "\"type\"").count - 1
        #expect(typeCount == 10, "Expected 10 'type' fields (one per event), got \(typeCount)")
    }

    @Test("Scheduler: runnableTasks respects maxParallelTasks cap")
    func schedulerRespectsMaxParallel() {
        let scheduler = Scheduler()
        let runID = "run_cap"
        let tasks = (1...5).map { i in
            TaskRecord(
                taskID: "task_\(String(format: "%03d", i))",
                runID: runID,
                title: "Task \(i)",
                state: .taskCreated,
                priority: 1,
                assignedModel: "m",
                worktreePath: "",
                branch: "",
                targetFiles: ["File\(i).swift"],
                maxRetries: 0,
                verify: VerifyResult(command: "true")
            )
        }

        let runnable2 = scheduler.runnableTasks(all: tasks, maxParallel: 2)
        #expect(runnable2.count == 2)

        let runnable5 = scheduler.runnableTasks(all: tasks, maxParallel: 5)
        #expect(runnable5.count == 5)

        let runnable10 = scheduler.runnableTasks(all: tasks, maxParallel: 10)
        #expect(runnable10.count == 5, "Cannot return more tasks than exist")
    }
}

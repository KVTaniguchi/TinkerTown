import Foundation
import Testing
@testable import TinkerTownCore

struct RunStoreAgentTests {
    @Test func bootstrapsDefaultAgentsAndPersistsActivity() throws {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let store = RunStore(fs: fs, paths: paths)

        try store.ensureDefaultAgents(maxParallelTasks: 3)
        let agents = try store.listAgents()

        #expect(agents.contains(where: { $0.agentID == "mayor_001" }))
        #expect(agents.contains(where: { $0.agentID == "orchestrator_001" }))
        #expect(agents.contains(where: { $0.agentID == "monitor_001" }))
        #expect(agents.contains(where: { $0.agentID == "operator_001" }))
        #expect(agents.filter { $0.role == .tinker }.count == 3)

        try store.updateAgentActivity(
            agentID: "tinker_001",
            name: "Tinker 1",
            role: .tinker,
            state: .busy,
            runID: "run_1",
            taskID: "task_001",
            activity: "verifying"
        )

        let updated = try store.loadAgent("tinker_001")
        #expect(updated.state == .busy)
        #expect(updated.currentRunID == "run_1")
        #expect(updated.currentTaskID == "task_001")
        #expect(updated.currentActivity == "verifying")
    }
}

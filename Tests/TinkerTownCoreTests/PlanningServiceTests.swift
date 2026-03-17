import Foundation
import Testing
@testable import TinkerTownCore

struct PlanningServiceTests {

    @Test("parsePlanMetadata extracts title and overview from project plan markdown")
    func parsePlanMetadataExtractsTitleAndOverview() {
        let plan = """
        Project Plan – todoagainagain
        Overview
        The goal is to build todoagain, a full-stack task management application.
        """
        // Title comes from first # heading; this sample has no # so we get default
        let (t1, s1) = PlanningService.parsePlanMetadata(plan)
        #expect(t1 == "My project")
        #expect(s1.contains("plan/PROJECT_PLAN.md"))

        let planWithHeading = """
        # Project Plan – todoagainagain

        ## Overview
        The goal is to build todoagain, a full-stack task management application.
        """
        let (t2, s2) = PlanningService.parsePlanMetadata(planWithHeading)
        #expect(t2 == "todoagainagain")
        #expect(s2.contains("build todoagain"))
        #expect(s2.contains("task management"))
    }

    @Test("importPlanContent writes file and returns derived title and summary")
    func importPlanContentWritesAndReturnsMetadata() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let planning = PlanningService(fs: fs, paths: paths)

        let content = """
        # Project Plan – myapp

        ## Overview
        Build a small CLI tool.

        ## Active Checklist (Mayor-owned)
        - [ ] First task
        """
        let result = try planning.importPlanContent(content)

        #expect(result.planFileURL.lastPathComponent == "PROJECT_PLAN.md")
        #expect(result.derivedTitle == "myapp")
        #expect(result.derivedSummary.contains("CLI tool"))

        let data = try fs.read(result.planFileURL)
        let read = String(data: Data(data), encoding: .utf8) ?? ""
        #expect(read.contains("Project Plan – myapp"))
        #expect(read.contains("- [ ] First task"))
    }

    @Test("plan detection: loadChecklistItems when plan file does not exist returns empty")
    func loadChecklistItemsWhenNoPlanReturnsEmpty() {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let planning = PlanningService(fs: fs, paths: paths)

        let items = planning.loadChecklistItems()
        #expect(items.isEmpty)
    }

    @Test("plan detection: loadChecklistItems when plan file exists returns checklist items")
    func loadChecklistItemsWhenPlanExistsReturnsItems() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let planning = PlanningService(fs: fs, paths: paths)

        let content = """
        # Project Plan – myapp

        ## Overview
        Build a small CLI.

        ## Active Checklist (Mayor-owned)
        - [ ] First task
        - [ ] Second task
        - [x] Done task
        """
        _ = try planning.importPlanContent(content)

        let items = planning.loadChecklistItems()
        #expect(items.count == 3)
        #expect(items[0].title == "First task")
        #expect(!items[0].completed)
        #expect(items[1].title == "Second task")
        #expect(!items[1].completed)
        #expect(items[2].title == "Done task")
        #expect(items[2].completed)
    }

    @Test("plan detection: ensureDefaultPlanExists then loadChecklistItems returns at least one item")
    func ensureDefaultPlanThenLoadChecklistReturnsItems() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let planning = PlanningService(fs: fs, paths: paths)

        _ = try planning.ensureDefaultPlanExists(title: "Test Project")
        let items = planning.loadChecklistItems()
        #expect(!items.isEmpty)
        #expect(items.contains(where: { $0.title.contains("First") || $0.title.contains("task") }))
    }

    @Test("plan detection: planFileExists is false when no file, true after import")
    func planFileExistsReflectsFilePresence() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let planning = PlanningService(fs: fs, paths: paths)

        #expect(!planning.planFileExists)
        _ = try planning.importPlanContent("# Project Plan – x\n\n## Overview\nOK.")
        #expect(planning.planFileExists)
    }
}

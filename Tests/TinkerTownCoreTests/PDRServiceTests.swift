import Foundation
import Testing
@testable import TinkerTownCore

struct PDRServiceTests {

    @Test("PDR load and validate: valid file returns PDR")
    func loadValidPDR() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let codec = JSONCodec()
        try fs.createDirectory(paths.tinkerRoot)
        let pdr = PDRRecord(pdrId: "pdr_001", title: "Checkout banner", summary: "Add banner", acceptanceCriteria: ["Visible", "Dismissible"])
        let data = try codec.encoder.encode(pdr)
        try fs.write(data, to: paths.pdrFile)

        let service = PDRService(fs: fs, codec: codec, paths: paths)
        let loaded = try service.loadDefault()
        #expect(loaded.pdrId == "pdr_001")
        #expect(loaded.title == "Checkout banner")
        #expect(loaded.acceptanceCriteria == ["Visible", "Dismissible"])
    }

    @Test("PDR resolve: missing file throws with required message")
    func resolveMissingThrows() {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let service = PDRService(fs: fs, paths: paths)

        do {
            _ = try service.resolve(customPath: nil)
            #expect(Bool(false), "expected PDRError to be thrown")
        } catch let e as PDRError {
            #expect(e.errorDescription?.contains("Product Design Requirement required") == true)
        } catch {
            #expect(Bool(false), "expected PDRError, got \(error)")
        }
    }

    @Test("PDR validate: invalid JSON returns errors")
    func validateInvalidJSON() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        try fs.createDirectory(paths.tinkerRoot)
        try fs.write(Data("not json".utf8), to: paths.pdrFile)

        let service = PDRService(fs: fs, paths: paths)
        let errors = service.validate(at: paths.pdrFile)
        #expect(errors != nil)
        #expect(!(errors ?? []).isEmpty)
    }

    @Test("PDR init: writeDefaultMinimal creates valid PDR file")
    func initCreatesMinimalPDR() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)
        let service = PDRService(fs: fs, codec: JSONCodec(), paths: paths)

        try service.writeDefaultMinimal(title: "Scaffold project")
        #expect(fs.fileExists(paths.pdrFile))

        let loaded = try service.load(from: paths.pdrFile)
        #expect(!loaded.pdrId.isEmpty)
        #expect(loaded.title == "Scaffold project")
        #expect(loaded.summary.contains("Describe the product"))
    }

    @Test("RunRecord stores pdrId when created with PDR")
    func runRecordStoresPdrId() throws {
        let run = RunRecord(
            runID: "run_1",
            state: .runCreated,
            request: "add feature",
            config: OrchestratorConfig(maxParallelTasks: 2, maxRetriesPerTask: 3),
            pdrId: "pdr_001",
            pdrPath: "/repo/.tinkertown/pdr.json"
        )
        #expect(run.pdrId == "pdr_001")
        #expect(run.pdrPath == "/repo/.tinkertown/pdr.json")
        try run.validate()
    }
}

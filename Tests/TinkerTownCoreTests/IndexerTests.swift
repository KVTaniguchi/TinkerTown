import Foundation
import Testing
@testable import TinkerTownCore

struct IndexerTests {
    @Test func generatesTinkerMapForSimpleSource() throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/repo")
        let paths = AppPaths(root: root)

        let sourceFile = root.appendingPathComponent("MyType.swift")
        try fs.write(
            """
            struct Foo {
            }

            func bar() {}
            """.data(using: .utf8)!,
            to: sourceFile
        )

        let shell = StubShell(results: [
            "git rev-parse HEAD": ShellResult(exitCode: 0, stdout: "abc123\n", stderr: "")
        ])
        let fixedDate = Date(timeIntervalSince1970: 0)
        let indexer = IndexerService(fs: fs, paths: paths, shell: shell, dateProvider: { fixedDate })

        let map = try indexer.buildIndex(sourceFiles: [sourceFile])
        try indexer.writeIndex(map: map)

        let indexURL = paths.tinkerRoot.appendingPathComponent("TinkerMap.json")
        #expect(fs.fileExists(indexURL))

        let data = try fs.read(indexURL)
        let decoded = try JSONDecoder().decode(TinkerMap.self, from: data)

        #expect(decoded.version == "1")
        #expect(decoded.sourceRevision == "abc123")
        #expect(decoded.modules.count == 1)
        #expect(decoded.modules[0].files.count == 1)
        let symbols = decoded.modules[0].files[0].symbols
        #expect(symbols.contains(where: { $0.name == "Foo" && $0.kind == "struct" }))
        #expect(symbols.contains(where: { $0.name == "bar" && $0.kind == "func" }))
    }
}


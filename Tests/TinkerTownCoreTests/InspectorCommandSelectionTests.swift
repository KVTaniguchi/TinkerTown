import Foundation
import Testing
@testable import TinkerTownCore

struct InspectorCommandSelectionTests {
    @Test func respectsExplicitModes() {
        let fs = InMemoryFileSystem()
        let paths = AppPaths(root: URL(fileURLWithPath: "/repo"))
        let logger = EventLogger(fs: fs, paths: paths)
        let inspector = Inspector(shell: StubShell(results: [:]), eventLogger: logger)
        let root = URL(fileURLWithPath: "/repo")

        let noneConfig = VerificationConfig(mode: "none", command: "xcodebuild build -scheme App -configuration Debug")
        #expect(inspector.selectCommand(config: noneConfig, root: root) == "true")

        let spmConfig = VerificationConfig(mode: "spm", command: "xcodebuild build -scheme App -configuration Debug")
        #expect(inspector.selectCommand(config: spmConfig, root: root) == "swift build")

        let xcodeConfig = VerificationConfig(mode: "xcodebuild", command: "xcodebuild build -scheme App -configuration Debug")
        #expect(inspector.selectCommand(config: xcodeConfig, root: root) == "xcodebuild build -scheme App -configuration Debug")
    }
}


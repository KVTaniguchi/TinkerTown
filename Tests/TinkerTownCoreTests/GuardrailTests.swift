import Foundation
import Testing
@testable import TinkerTownCore

struct GuardrailTests {
    @Test func blocksConfiguredCommands() {
        let service = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: ["git reset --hard"]))
        #expect(throws: GuardrailError.self) {
            try service.validateCommand("git reset --hard")
        }
    }

    @Test func blocksOutOfRootPaths() {
        let service = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: []))
        let root = URL(fileURLWithPath: "/repo/.tinkertown/task_001")
        let bad = URL(fileURLWithPath: "/repo/README.md")

        #expect(throws: GuardrailError.self) {
            try service.validatePath(bad, inside: root)
        }
    }

    @Test func allowsInRootPaths() throws {
        let service = GuardrailService(config: GuardrailConfig(enforcePathSandbox: true, blockedCommands: []))
        let root = URL(fileURLWithPath: "/repo/.tinkertown/task_001")
        let ok = root.appendingPathComponent("src/File.swift")
        try service.validatePath(ok, inside: root)
    }
}

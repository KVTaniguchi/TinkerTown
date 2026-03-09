import Foundation
@testable import TinkerTownCore

final class InMemoryFileSystem: FileSysteming {
    var data: [String: Data] = [:]
    var directories: Set<String> = []

    func createDirectory(_ path: URL) throws {
        directories.insert(path.path)
    }

    func fileExists(_ path: URL) -> Bool {
        data[path.path] != nil || directories.contains(path.path)
    }

    func write(_ data: Data, to path: URL) throws {
        directories.insert(path.deletingLastPathComponent().path)
        self.data[path.path] = data
    }

    func append(_ string: String, to path: URL) throws {
        let existing = data[path.path] ?? Data()
        self.data[path.path] = existing + Data(string.utf8)
    }

    func read(_ path: URL) throws -> Data {
        guard let value = data[path.path] else {
            throw NSError(domain: "InMemoryFileSystem", code: 404)
        }
        return value
    }

    func listFiles(_ path: URL) throws -> [URL] {
        let prefix = path.path + "/"
        var out: [URL] = []
        for key in data.keys where key.hasPrefix(prefix) {
            let relative = String(key.dropFirst(prefix.count))
            if !relative.contains("/") {
                out.append(URL(fileURLWithPath: key))
            }
        }
        for dir in directories where dir.hasPrefix(prefix) {
            let relative = String(dir.dropFirst(prefix.count))
            if !relative.isEmpty && !relative.contains("/") {
                out.append(URL(fileURLWithPath: dir, isDirectory: true))
            }
        }
        return Array(Set(out))
    }

    func remove(_ path: URL) throws {
        data.removeValue(forKey: path.path)
        directories.remove(path.path)
    }
}

struct StubShell: ShellRunning {
    var results: [String: ShellResult]
    var defaultResult: ShellResult = ShellResult(exitCode: 0, stdout: "", stderr: "")

    func run(_ command: String, cwd: URL?) throws -> ShellResult {
        results[command] ?? defaultResult
    }
}

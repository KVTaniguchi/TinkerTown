import Foundation

public struct TinkerSymbol: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var signature: String
}

public struct TinkerFile: Codable, Equatable, Sendable {
    public var path: String
    public var symbols: [TinkerSymbol]
}

public struct TinkerModule: Codable, Equatable, Sendable {
    public var name: String
    public var files: [TinkerFile]
}

public struct TinkerMap: Codable, Equatable, Sendable {
    public var version: String
    public var generatedAt: String
    public var sourceRevision: String
    public var modules: [TinkerModule]
}

public struct IndexerService {
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let paths: AppPaths
    private let shell: ShellRunning
    private let dateProvider: () -> Date

    public init(
        fs: FileSysteming = LocalFileSystem(),
        codec: JSONCodec = JSONCodec(),
        paths: AppPaths,
        shell: ShellRunning = ShellRunner(),
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.fs = fs
        self.codec = codec
        self.paths = paths
        self.shell = shell
        self.dateProvider = dateProvider
    }

    public func buildIndex(sourceFiles: [URL]) throws -> TinkerMap {
        let iso8601 = ISO8601DateFormatter()
        let generatedAt = iso8601.string(from: dateProvider())
        let revisionResult = try? shell.run("git rev-parse HEAD", cwd: paths.root)
        let sourceRevision = revisionResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? revisionResult!.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "unknown"

        var files: [TinkerFile] = []
        for url in sourceFiles where url.pathExtension == "swift" {
            guard let data = try? fs.read(url),
                  let contents = String(data: data, encoding: .utf8) else { continue }
            let symbols = extractSymbols(from: contents)
            let relativePath = url.path.replacingOccurrences(of: paths.root.path + "/", with: "")
            files.append(TinkerFile(path: relativePath, symbols: symbols))
        }

        let module = TinkerModule(name: "App", files: files.sorted { $0.path < $1.path })
        return TinkerMap(
            version: "1",
            generatedAt: generatedAt,
            sourceRevision: sourceRevision,
            modules: [module]
        )
    }

    public func writeIndex(map: TinkerMap) throws {
        try fs.createDirectory(paths.tinkerRoot)
        let data = try codec.encoder.encode(map)
        let url = paths.tinkerRoot.appendingPathComponent("TinkerMap.json")
        try fs.write(data, to: url)
    }

    private func extractSymbols(from contents: String) -> [TinkerSymbol] {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var symbols: [TinkerSymbol] = []
        let typePattern = try? NSRegularExpression(pattern: #"^\s*(struct|class|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let funcPattern = try? NSRegularExpression(pattern: #"^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)"#)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let typePattern {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = typePattern.firstMatch(in: trimmed, range: range), match.numberOfRanges >= 3 {
                    let kindRange = match.range(at: 1)
                    let nameRange = match.range(at: 2)
                    if let kindSwift = Range(kindRange, in: trimmed),
                       let nameSwift = Range(nameRange, in: trimmed) {
                        let kind = String(trimmed[kindSwift])
                        let name = String(trimmed[nameSwift])
                        symbols.append(TinkerSymbol(name: name, kind: kind, signature: trimmed))
                        continue
                    }
                }
            }

            if let funcPattern {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = funcPattern.firstMatch(in: trimmed, range: range), match.numberOfRanges >= 2 {
                    let nameRange = match.range(at: 1)
                    if let nameSwift = Range(nameRange, in: trimmed) {
                        let name = String(trimmed[nameSwift])
                        symbols.append(TinkerSymbol(name: name, kind: "func", signature: trimmed))
                    }
                }
            }
        }
        return symbols
    }
}


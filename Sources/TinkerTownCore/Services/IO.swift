import Foundation

public protocol FileSysteming {
    func createDirectory(_ path: URL) throws
    func fileExists(_ path: URL) -> Bool
    func write(_ data: Data, to path: URL) throws
    func append(_ string: String, to path: URL) throws
    func read(_ path: URL) throws -> Data
    func listFiles(_ path: URL) throws -> [URL]
    func remove(_ path: URL) throws
}

public struct LocalFileSystem: FileSysteming {
    private let fm = FileManager.default

    public init() {}

    public func createDirectory(_ path: URL) throws {
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
    }

    public func fileExists(_ path: URL) -> Bool {
        fm.fileExists(atPath: path.path)
    }

    public func write(_ data: Data, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try createDirectory(dir)
        try data.write(to: path, options: .atomic)
    }

    public func append(_ string: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try createDirectory(dir)
        if !fileExists(path) {
            try write(Data(), to: path)
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        if let data = string.data(using: .utf8) {
            handle.write(data)
        }
    }

    public func read(_ path: URL) throws -> Data {
        try Data(contentsOf: path)
    }

    public func listFiles(_ path: URL) throws -> [URL] {
        guard fileExists(path) else { return [] }
        return try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
    }

    public func remove(_ path: URL) throws {
        if fileExists(path) {
            try fm.removeItem(at: path)
        }
    }
}

public struct JSONCodec {
    public let encoder: JSONEncoder
    public let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
}

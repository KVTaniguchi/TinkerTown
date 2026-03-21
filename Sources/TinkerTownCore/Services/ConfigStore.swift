import Foundation

public struct ConfigStore {
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let paths: AppPaths

    public init(fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec(), paths: AppPaths) {
        self.fs = fs
        self.codec = codec
        self.paths = paths
    }

    @discardableResult
    public func bootstrap() throws -> AppConfig {
        try fs.createDirectory(paths.tinkerRoot)
        try fs.createDirectory(paths.runsRoot)
        try fs.createDirectory(paths.agentsRoot)

        if !fs.fileExists(paths.configFile) {
            let data = try codec.encoder.encode(AppConfig.default)
            try fs.write(data, to: paths.configFile)
        }
        return try load()
    }

    public func load() throws -> AppConfig {
        let data = try fs.read(paths.configFile)
        return try codec.decoder.decode(AppConfig.self, from: data)
    }
}

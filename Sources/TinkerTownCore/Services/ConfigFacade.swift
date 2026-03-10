import Foundation

/// UI-facing settings layer: model selection, offline mode, update policy.
/// Persists to app container; internal config file format is implementation detail.
public struct ConfigFacade {
    public let paths: AppContainerPaths
    private let fs: FileSysteming
    private let codec: JSONCodec

    public init(paths: AppContainerPaths, fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec()) {
        self.paths = paths
        self.fs = fs
        self.codec = codec
    }

    public struct AppSettings: Codable, Equatable, Sendable {
        public var useOllama: Bool
        public var plannerModelId: String?
        public var workerModelId: String?
        public var offlineMode: Bool
        public var updatePolicy: UpdatePolicy
        /// Optional build system / verification preferences for the macOS app.
        /// When nil, the app will auto-detect based on the workspace contents.
        public var buildSystemMode: String? // "none", "spm", "xcodebuild", or "auto"/nil
        public var xcodeScheme: String?

        enum CodingKeys: String, CodingKey {
            case useOllama = "use_ollama"
            case plannerModelId = "planner_model_id"
            case workerModelId = "worker_model_id"
            case offlineMode = "offline_mode"
            case updatePolicy = "update_policy"
            case buildSystemMode = "build_system_mode"
            case xcodeScheme = "xcode_scheme"
        }

        public static var `default`: AppSettings {
            AppSettings(
                useOllama: true,
                plannerModelId: nil,
                workerModelId: nil,
                offlineMode: false,
                updatePolicy: .default,
                buildSystemMode: nil,
                xcodeScheme: nil
            )
        }

        public init(
            useOllama: Bool,
            plannerModelId: String?,
            workerModelId: String?,
            offlineMode: Bool,
            updatePolicy: UpdatePolicy,
            buildSystemMode: String? = nil,
            xcodeScheme: String? = nil
        ) {
            self.useOllama = useOllama
            self.plannerModelId = plannerModelId
            self.workerModelId = workerModelId
            self.offlineMode = offlineMode
            self.updatePolicy = updatePolicy
            self.buildSystemMode = buildSystemMode
            self.xcodeScheme = xcodeScheme
        }
    }

    public func loadSettings() throws -> AppSettings {
        guard fs.fileExists(paths.appConfigFile) else { return .default }
        let data = try fs.read(paths.appConfigFile)
        return try codec.decoder.decode(AppSettings.self, from: data)
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try fs.createDirectory(paths.root)
        let data = try codec.encoder.encode(settings)
        try fs.write(data, to: paths.appConfigFile)
    }

    public func loadUpdatePolicy() throws -> UpdatePolicy {
        guard fs.fileExists(paths.updatePolicyFile) else { return .default }
        let data = try fs.read(paths.updatePolicyFile)
        return try codec.decoder.decode(UpdatePolicy.self, from: data)
    }

    public func saveUpdatePolicy(_ policy: UpdatePolicy) throws {
        try fs.createDirectory(paths.root)
        let data = try codec.encoder.encode(policy)
        try fs.write(data, to: paths.updatePolicyFile)
    }
}

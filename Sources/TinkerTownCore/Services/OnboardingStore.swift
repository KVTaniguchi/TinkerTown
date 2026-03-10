import Foundation

/// Persists and loads onboarding state for resume-on-restart.
public struct OnboardingStore {
    private let paths: AppContainerPaths
    private let fs: FileSysteming
    private let codec: JSONCodec

    public init(paths: AppContainerPaths, fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec()) {
        self.paths = paths
        self.fs = fs
        self.codec = codec
    }

    public func load() -> OnboardingState {
        guard fs.fileExists(paths.onboardingStateFile) else { return .initial }
        do {
            let data = try fs.read(paths.onboardingStateFile)
            return try codec.decoder.decode(OnboardingState.self, from: data)
        } catch {
            return .initial
        }
    }

    public func save(_ state: OnboardingState) throws {
        try fs.createDirectory(paths.root)
        let data = try codec.encoder.encode(state)
        try fs.write(data, to: paths.onboardingStateFile)
    }

    /// Mark onboarding complete so app shows main content on next launch.
    public func markComplete() throws {
        var state = load()
        state.currentStep = .completion
        state.completedAt = Date()
        state.updatedAt = Date()
        try save(state)
    }

    /// Reset for testing or re-onboarding.
    public func reset() throws {
        try save(.initial)
    }
}

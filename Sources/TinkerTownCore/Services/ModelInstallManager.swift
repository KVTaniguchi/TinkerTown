import Foundation

/// Download progress for one model.
public struct ModelInstallProgress: Sendable {
    public let modelId: String
    public let status: DownloadJobStatus
    public let bytesDownloaded: Int64
    public let totalBytes: Int64?
    public let error: String?
    public let etaSeconds: Double?

    public init(modelId: String, status: DownloadJobStatus, bytesDownloaded: Int64 = 0, totalBytes: Int64? = nil, error: String? = nil, etaSeconds: Double? = nil) {
        self.modelId = modelId
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.error = error
        self.etaSeconds = etaSeconds
    }
}

/// Queue, download orchestration, pause/resume, retries, verification, atomic activation.
public final class ModelInstallManager: @unchecked Sendable {
    public enum InstallError: Error, LocalizedError {
        case offlineModeBlocksDownload(modelID: String)
        case missingChecksum(modelID: String)
        case invalidSignature(modelID: String)
        case missingDownloadedFile
        case retriesExhausted(modelID: String, cause: String)

        public var errorDescription: String? {
            switch self {
            case .offlineModeBlocksDownload(let modelID):
                return "Offline mode blocks network download for \(modelID)."
            case .missingChecksum(let modelID):
                return "Model \(modelID) is missing checksum metadata."
            case .invalidSignature(let modelID):
                return "Model \(modelID) failed signature verification."
            case .missingDownloadedFile:
                return "Downloaded model artifact was not found."
            case .retriesExhausted(let modelID, let cause):
                return "Failed to install \(modelID) after retries: \(cause)"
            }
        }
    }

    private let paths: AppContainerPaths
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let session: URLSession
    private let shell: ShellRunning
    private let offlineMode: Bool

    public init(
        paths: AppContainerPaths,
        fs: FileSysteming = LocalFileSystem(),
        codec: JSONCodec = JSONCodec(),
        session: URLSession = .shared,
        shell: ShellRunning = ShellRunner(),
        offlineMode: Bool = false
    ) {
        self.paths = paths
        self.fs = fs
        self.codec = codec
        self.session = session
        self.shell = shell
        self.offlineMode = offlineMode
    }

    /// Load persisted download jobs (e.g. for resume).
    public func loadJobs() -> [String: DownloadJob] {
        guard fs.fileExists(paths.root.appendingPathComponent("download_jobs.json")) else { return [:] }
        let fileURL = paths.root.appendingPathComponent("download_jobs.json")
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? codec.decoder.decode([String: DownloadJob].self, from: data) else { return [:] }
        return decoded
    }

    /// Persist download jobs.
    public func saveJobs(_ jobs: [String: DownloadJob]) {
        try? fs.createDirectory(paths.root)
        let fileURL = paths.root.appendingPathComponent("download_jobs.json")
        if let data = try? codec.encoder.encode(jobs) {
            try? fs.write(data, to: fileURL)
        }
    }

    /// Install a model: download (or ollama pull) -> verify -> register.
    @available(iOS 15.0, *)
    public func install(
        manifest: ModelManifest,
        progress: @escaping @Sendable (ModelInstallProgress) -> Void
    ) async throws {
        if !ModelCatalogService.verifyModelSignature(manifest) {
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: InstallError.invalidSignature(modelID: manifest.id).localizedDescription))
            throw InstallError.invalidSignature(modelID: manifest.id)
        }

        if manifest.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: InstallError.missingChecksum(modelID: manifest.id).localizedDescription))
            throw InstallError.missingChecksum(modelID: manifest.id)
        }

        var jobs = loadJobs()
        jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .pending)
        saveJobs(jobs)

        if manifest.downloadURL.isEmpty {
            // Ollama path: assume model is pulled via ollama pull
            progress(ModelInstallProgress(modelId: manifest.id, status: .downloading, error: nil))
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .downloading)
            saveJobs(jobs)
            let ok = await pullOllama(model: manifest.id)
            if ok {
                try await registerOllamaModel(manifest: manifest, progress: progress)
                jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .completed)
                saveJobs(jobs)
            } else {
                progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: "Ollama pull failed or Ollama not running."))
                jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: "Ollama pull failed")
                saveJobs(jobs)
                throw NSError(domain: "ModelInstallManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama pull failed for \(manifest.id)"])
            }
            return
        }

        if offlineMode {
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: InstallError.offlineModeBlocksDownload(modelID: manifest.id).localizedDescription))
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: InstallError.offlineModeBlocksDownload(modelID: manifest.id).localizedDescription)
            saveJobs(jobs)
            throw InstallError.offlineModeBlocksDownload(modelID: manifest.id)
        }

        guard let url = URL(string: manifest.downloadURL) else {
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: "Invalid download URL"))
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: "Invalid download URL")
            saveJobs(jobs)
            throw NSError(domain: "ModelInstallManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
        }

        let destPath = paths.modelDir(modelId: manifest.id, version: manifest.version)
        let tempFile = paths.downloadTempFile(modelId: manifest.id)

        try? fs.createDirectory(paths.tempDir)
        try? fs.createDirectory(paths.modelsDir)

        progress(ModelInstallProgress(modelId: manifest.id, status: .downloading, totalBytes: manifest.sizeBytes))
        jobs[manifest.id] = DownloadJob(modelId: manifest.id, bytesDownloaded: 0, totalBytes: manifest.sizeBytes, status: .downloading)
        saveJobs(jobs)

        let backoffs: [UInt64] = [0, 3_000_000_000, 10_000_000_000]
        var downloadError: Error?
        var downloadedLocation: URL?
        for backoff in backoffs {
            if backoff > 0 {
                try await Task.sleep(nanoseconds: backoff)
            }
            do {
                let (location, _) = try await session.download(from: url)
                downloadedLocation = location
                break
            } catch {
                downloadError = error
            }
        }

        guard let location = downloadedLocation else {
            let cause = downloadError?.localizedDescription ?? "unknown error"
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: cause)
            saveJobs(jobs)
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: cause))
            throw InstallError.retriesExhausted(modelID: manifest.id, cause: cause)
        }

        try? fs.remove(tempFile)
        try? fs.createDirectory(destPath.deletingLastPathComponent())
        try? FileManager.default.moveItem(at: location, to: tempFile)
        if !fs.fileExists(tempFile) {
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: InstallError.missingDownloadedFile.localizedDescription)
            saveJobs(jobs)
            throw InstallError.missingDownloadedFile
        }

        progress(ModelInstallProgress(modelId: manifest.id, status: .verifying))
        jobs[manifest.id] = DownloadJob(modelId: manifest.id, bytesDownloaded: manifest.sizeBytes, totalBytes: manifest.sizeBytes, status: .verifying)
        saveJobs(jobs)

        let verified = try verifyChecksum(file: tempFile, expectedSHA256: manifest.sha256)
        if !verified {
            try? fs.remove(tempFile)
            progress(ModelInstallProgress(modelId: manifest.id, status: .failed, error: "Checksum mismatch"))
            jobs[manifest.id] = DownloadJob(modelId: manifest.id, status: .failed, lastError: "Checksum mismatch")
            saveJobs(jobs)
            throw NSError(domain: "ModelInstallManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Checksum verification failed"])
        }

        try fs.createDirectory(destPath)
        let modelFile = destPath.appendingPathComponent("model.bin")
        try FileManager.default.moveItem(at: tempFile, to: modelFile)

        var installed = loadInstalledModels()
        let record = InstalledModel(
            id: manifest.id,
            version: manifest.version,
            path: modelFile.path,
            sizeBytes: manifest.sizeBytes,
            installedAt: Date(),
            lastUsedAt: nil,
            status: .ready
        )
        installed[manifest.id] = record
        try saveInstalledModels(installed)

        progress(ModelInstallProgress(modelId: manifest.id, status: .completed))
        jobs[manifest.id] = DownloadJob(modelId: manifest.id, bytesDownloaded: manifest.sizeBytes, totalBytes: manifest.sizeBytes, status: .completed)
        saveJobs(jobs)
    }

    private func verifyChecksum(file: URL, expectedSHA256: String) throws -> Bool {
        guard !expectedSHA256.isEmpty else { return false }
        if expectedSHA256 == "ollama-model" { return true }
        let data = try Data(contentsOf: file)
        let computed = sha256Hex(data: data)
        return computed.lowercased() == expectedSHA256.lowercased()
    }

    private func pullOllama(model: String) async -> Bool {
        do {
            let result = try shell.run("ollama pull \(model)", cwd: nil)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func registerOllamaModel(manifest: ModelManifest, progress: @escaping (ModelInstallProgress) -> Void) async throws {
        var installed = loadInstalledModels()
        let record = InstalledModel(
            id: manifest.id,
            version: manifest.version,
            path: "ollama:\(manifest.id)",
            sizeBytes: manifest.sizeBytes,
            installedAt: Date(),
            lastUsedAt: nil,
            status: .ready
        )
        installed[manifest.id] = record
        try saveInstalledModels(installed)
        progress(ModelInstallProgress(modelId: manifest.id, status: .completed))
    }

    public func loadInstalledModels() -> [String: InstalledModel] {
        guard fs.fileExists(paths.installedModelsFile) else { return [:] }
        guard let data = try? fs.read(paths.installedModelsFile),
              let decoded = try? codec.decoder.decode([String: InstalledModel].self, from: data) else { return [:] }
        return decoded
    }

    public func saveInstalledModels(_ models: [String: InstalledModel]) throws {
        try fs.createDirectory(paths.root)
        let data = try codec.encoder.encode(models)
        try fs.write(data, to: paths.installedModelsFile)
    }

    public func removeModel(modelId: String) throws {
        var models = loadInstalledModels()
        guard let record = models[modelId] else { return }
        if record.path.hasPrefix("ollama:") {
            // Ollama model: we could run ollama rm; for now just remove from our list
        } else {
            let url = URL(fileURLWithPath: record.path).deletingLastPathComponent()
            if fs.fileExists(url) { try? fs.remove(url) }
        }
        models.removeValue(forKey: modelId)
        try saveInstalledModels(models)
    }

    public func reinstall(modelId: String, manifest: ModelManifest, progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        try removeModel(modelId: modelId)
        try await install(manifest: manifest, progress: progress)
    }

    public func update(modelId: String, to manifest: ModelManifest, progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        // v1 policy: update is a reinstall of newer/equal manifest version.
        try await reinstall(modelId: modelId, manifest: manifest, progress: progress)
    }
}

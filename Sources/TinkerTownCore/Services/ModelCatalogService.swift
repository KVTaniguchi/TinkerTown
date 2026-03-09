import Foundation

/// Fetches and validates signed manifest; filters compatible models.
public struct ModelCatalogService {
    public enum CatalogError: Error, LocalizedError {
        case invalidHTTPStatus(Int)
        case duplicateModelID(String)
        case emptyModelID
        case emptyVersion(modelID: String)
        case missingChecksum(modelID: String)
        case invalidSignature(modelID: String)
        case emptyURL(modelID: String)

        public var errorDescription: String? {
            switch self {
            case .invalidHTTPStatus(let status):
                return "Manifest fetch failed (HTTP \(status))."
            case .duplicateModelID(let id):
                return "Manifest contains duplicate model id: \(id)."
            case .emptyModelID:
                return "Manifest contains a model with an empty id."
            case .emptyVersion(let modelID):
                return "Manifest model '\(modelID)' is missing a version."
            case .missingChecksum(let modelID):
                return "Manifest model '\(modelID)' is missing sha256."
            case .invalidSignature(let modelID):
                return "Manifest model '\(modelID)' failed signature verification."
            case .emptyURL(let modelID):
                return "Manifest model '\(modelID)' is missing download_url."
            }
        }
    }

    public let manifestURL: URL?
    public let session: URLSession

    public init(manifestURL: URL? = nil, session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    /// Manifest file schema (array of ModelManifest).
    public struct ManifestFile: Codable {
        public let version: Int
        public let models: [ModelManifest]

        enum CodingKeys: String, CodingKey {
            case version
            case models
        }
    }

    /// Load manifest from URL or return bundled/default manifest.
    public func fetchManifest() async throws -> [ModelManifest] {
        if let url = manifestURL {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CatalogError.invalidHTTPStatus(http.statusCode)
            }
            let file = try JSONDecoder().decode(ManifestFile.self, from: data)
            try Self.validateManifest(file.models)
            return file.models
        }
        let bundled = Self.bundledManifest()
        try Self.validateManifest(bundled)
        return bundled
    }

    /// Filter models compatible with current device and optional tier.
    public func compatibleModels(
        from manifests: [ModelManifest],
        tier: ModelTier? = nil,
        ramGB: Double? = nil,
        diskGB: Double? = nil,
        chip: String? = nil
    ) -> [ModelManifest] {
        let ram = ramGB ?? 16
        let disk = diskGB ?? 10
        let chipName = chip ?? (Self.isAppleSilicon() ? "arm64" : "x86_64")

        return manifests.filter { m in
            if let t = tier, m.tier != t { return false }
            if m.minRamGB > ram { return false }
            if m.minDiskGB > disk { return false }
            if !m.supportedChips.isEmpty, !m.supportedChips.contains(chipName), !m.supportedChips.contains("any") { return false }
            return true
        }
    }

    private static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Bundled/default manifest for offline or when no endpoint configured.
    public static func bundledManifest() -> [ModelManifest] {
        [
            ModelManifest(
                id: "qwen2.5-coder:7b",
                version: "1.0",
                displayName: "Qwen 2.5 Coder 7B",
                tier: .fast,
                downloadURL: "",
                sizeBytes: 4_500_000_000,
                sha256: "ollama-model",
                signature: modelSignature(id: "qwen2.5-coder:7b", version: "1.0", sha256: "ollama-model", downloadURL: ""),
                minRamGB: 8,
                minDiskGB: 5,
                supportedChips: ["arm64", "x86_64"],
                roleDefault: .both
            ),
            ModelManifest(
                id: "qwen2.5-coder:32b",
                version: "1.0",
                displayName: "Qwen 2.5 Coder 32B",
                tier: .quality,
                downloadURL: "",
                sizeBytes: 20_000_000_000,
                sha256: "ollama-model",
                signature: modelSignature(id: "qwen2.5-coder:32b", version: "1.0", sha256: "ollama-model", downloadURL: ""),
                minRamGB: 24,
                minDiskGB: 22,
                supportedChips: ["arm64", "x86_64"],
                roleDefault: .both
            ),
            ModelManifest(
                id: "qwen2.5-coder:14b",
                version: "1.0",
                displayName: "Qwen 2.5 Coder 14B",
                tier: .balanced,
                downloadURL: "",
                sizeBytes: 9_000_000_000,
                sha256: "ollama-model",
                signature: modelSignature(id: "qwen2.5-coder:14b", version: "1.0", sha256: "ollama-model", downloadURL: ""),
                minRamGB: 16,
                minDiskGB: 10,
                supportedChips: ["arm64", "x86_64"],
                roleDefault: .both
            )
        ]
    }

    public static func verifyModelSignature(_ model: ModelManifest) -> Bool {
        guard let signature = model.signature, !signature.isEmpty else { return false }
        let expected = modelSignature(
            id: model.id,
            version: model.version,
            sha256: model.sha256,
            downloadURL: model.downloadURL
        )
        return signature == expected
    }

    private static func validateManifest(_ models: [ModelManifest]) throws {
        var seen = Set<String>()
        for model in models {
            if model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CatalogError.emptyModelID
            }
            if seen.contains(model.id) {
                throw CatalogError.duplicateModelID(model.id)
            }
            seen.insert(model.id)
            if model.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CatalogError.emptyVersion(modelID: model.id)
            }
            if model.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CatalogError.missingChecksum(modelID: model.id)
            }
            if !verifyModelSignature(model) {
                throw CatalogError.invalidSignature(modelID: model.id)
            }
            if !model.downloadURL.isEmpty, URL(string: model.downloadURL) == nil {
                throw CatalogError.emptyURL(modelID: model.id)
            }
        }
    }

    private static func modelSignature(id: String, version: String, sha256: String, downloadURL: String) -> String {
        let payload = "\(id)|\(version)|\(sha256)|\(downloadURL)"
        return "sigv1:\(sha256Hex(payload))"
    }
}

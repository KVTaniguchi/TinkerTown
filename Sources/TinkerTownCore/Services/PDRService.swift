import Foundation

/// Standard error message when PDR is missing or invalid. Surfaces in CLI and app.
public let pdrRequiredMessage = "Product Design Requirement required. Add `.tinkertown/pdr.json` or pass --pdr <path>."

public enum PDRError: Error, LocalizedError, Sendable {
    case fileNotFound(path: String)
    case invalidJSON(path: String, underlying: String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "PDR file not found: \(path). \(pdrRequiredMessage)"
        case let .invalidJSON(path, underlying):
            return "Invalid PDR at \(path): \(underlying). \(pdrRequiredMessage)"
        case let .validationFailed(msg):
            return "Invalid PDR: \(msg). \(pdrRequiredMessage)"
        }
    }
}

/// Resolves and validates the Product Design Requirement. Use before creating a run.
public struct PDRService {
    private let fs: FileSysteming
    private let codec: JSONCodec
    private let paths: AppPaths

    public init(fs: FileSysteming = LocalFileSystem(), codec: JSONCodec = JSONCodec(), paths: AppPaths) {
        self.fs = fs
        self.codec = codec
        self.paths = paths
    }

    /// Load and validate PDR from the default path (`.tinkertown/pdr.json`).
    public func loadDefault() throws -> PDRRecord {
        try load(from: paths.pdrFile)
    }

    /// Load and validate PDR from the given file URL (e.g. from `--pdr <path>`).
    public func load(from url: URL) throws -> PDRRecord {
        guard fs.fileExists(url) else {
            throw PDRError.fileNotFound(path: url.path)
        }
        let data: Data
        do {
            data = try fs.read(url)
        } catch {
            throw PDRError.invalidJSON(path: url.path, underlying: error.localizedDescription)
        }
        let record: PDRRecord
        do {
            record = try codec.decoder.decode(PDRRecord.self, from: data)
        } catch {
            throw PDRError.invalidJSON(path: url.path, underlying: error.localizedDescription)
        }
        do {
            try record.validate()
        } catch {
            throw PDRError.validationFailed(error.localizedDescription)
        }
        return record
    }

    /// Resolve PDR: from custom path if given and valid, otherwise from default path.
    /// - Parameter customPath: Optional path (file URL or path string) from e.g. `--pdr <path>`.
    /// - Returns: Valid PDR and the resolved URL used (for storing pdr_path on RunRecord).
    public func resolve(customPath: URL?) throws -> (pdr: PDRRecord, resolvedURL: URL) {
        if let custom = customPath {
            let pdr = try load(from: custom)
            return (pdr, custom)
        }
        let pdr = try loadDefault()
        return (pdr, paths.pdrFile)
    }

    /// Validate PDR at path and return errors (for `tinkertown pdr validate`). Returns nil if valid.
    public func validate(at url: URL) -> [String]? {
        do {
            _ = try load(from: url)
            return nil
        } catch let e as PDRError {
            return [e.localizedDescription]
        } catch {
            return [error.localizedDescription]
        }
    }

    /// Write a minimal valid PDR to the default path (for `tinkertown pdr init`).
    public func writeDefaultMinimal(title: String = "My project", pdrId: String? = nil) throws {
        try writeFromPlan(title: title, summary: nil, acceptanceCriteria: nil, pdrId: pdrId)
    }

    /// Write a PDR derived from an imported project plan so the user does not have to edit JSON.
    /// Uses the given title and summary; acceptance criteria default to following the plan checklist.
    public func writeFromPlan(
        title: String,
        summary: String?,
        acceptanceCriteria: [String]?,
        pdrId: String? = nil
    ) throws {
        try fs.createDirectory(paths.tinkerRoot)
        let id = pdrId ?? "pdr_\(UUID().uuidString.prefix(8))"
        let summaryText = summary ?? "Describe the product and goals here."
        let criteria = acceptanceCriteria ?? ["Follow the checklist and backlog in plan/PROJECT_PLAN.md."]
        let record = PDRRecord(
            pdrId: id,
            title: title,
            summary: summaryText,
            scope: "In scope: see plan/PROJECT_PLAN.md. Out of scope: TBD.",
            acceptanceCriteria: criteria
        )
        let data = try codec.encoder.encode(record)
        try fs.write(data, to: paths.pdrFile)
    }
}

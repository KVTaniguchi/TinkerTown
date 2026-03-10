import Foundation

// MARK: - Model manifest (from signed registry)

public struct ModelManifest: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var displayName: String
    public var tier: ModelTier
    public var downloadURL: String
    public var sizeBytes: Int64
    public var sha256: String
    public var signature: String?
    public var minRamGB: Double
    public var minDiskGB: Double
    public var supportedChips: [String]
    public var roleDefault: ModelRoleDefault

    enum CodingKeys: String, CodingKey {
        case id, version, signature
        case displayName = "display_name"
        case tier
        case downloadURL = "download_url"
        case sizeBytes = "size_bytes"
        case sha256
        case minRamGB = "min_ram_gb"
        case minDiskGB = "min_disk_gb"
        case supportedChips = "supported_chips"
        case roleDefault = "role_default"
    }

    public init(
        id: String,
        version: String,
        displayName: String,
        tier: ModelTier,
        downloadURL: String,
        sizeBytes: Int64,
        sha256: String,
        signature: String? = nil,
        minRamGB: Double,
        minDiskGB: Double,
        supportedChips: [String],
        roleDefault: ModelRoleDefault
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.tier = tier
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.signature = signature
        self.minRamGB = minRamGB
        self.minDiskGB = minDiskGB
        self.supportedChips = supportedChips
        self.roleDefault = roleDefault
    }
}

public enum ModelTier: String, Codable, CaseIterable, Sendable {
    case fast
    case balanced
    case quality
}

public enum ModelRoleDefault: String, Codable, CaseIterable, Sendable {
    case planner
    case worker
    case both
}

// MARK: - Installed model (local state)

public enum InstalledModelStatus: String, Codable, Sendable {
    case downloading
    case verifying
    case ready
    case failed
    case removing
}

public struct InstalledModel: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var path: String
    public var sizeBytes: Int64
    public var installedAt: Date
    public var lastUsedAt: Date?
    public var status: InstalledModelStatus

    enum CodingKeys: String, CodingKey {
        case id, version, path, status
        case sizeBytes = "size_bytes"
        case installedAt = "installed_at"
        case lastUsedAt = "last_used_at"
    }

    public init(
        id: String,
        version: String,
        path: String,
        sizeBytes: Int64,
        installedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        status: InstalledModelStatus = .ready
    ) {
        self.id = id
        self.version = version
        self.path = path
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.lastUsedAt = lastUsedAt
        self.status = status
    }
}

// MARK: - Download job (in-memory / persisted for resume)

public struct DownloadJob: Codable, Equatable, Sendable {
    public var modelId: String
    public var resumeData: Data?
    public var bytesDownloaded: Int64
    public var totalBytes: Int64?
    public var status: DownloadJobStatus
    public var lastError: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case resumeData = "resume_data"
        case bytesDownloaded = "bytes_downloaded"
        case totalBytes = "total_bytes"
        case status
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }

    public init(
        modelId: String,
        resumeData: Data? = nil,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64? = nil,
        status: DownloadJobStatus = .pending,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.modelId = modelId
        self.resumeData = resumeData
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.status = status
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public enum DownloadJobStatus: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case verifying
    case completed
    case failed
    case cancelled
}

// MARK: - Onboarding state (persisted for resume)

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case welcome
    case deviceCheck
    case chooseTier
    case roleAssignment
    case privacy
    case downloadInstall
    case healthCheck
    case completion
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public var currentStep: OnboardingStep
    public var selectedTier: ModelTier?
    public var plannerModelId: String?
    public var workerModelId: String?
    public var offlineMode: Bool
    public var downloadJobs: [String: DownloadJob]
    public var lastError: String?
    public var completedAt: Date?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case currentStep = "current_step"
        case selectedTier = "selected_tier"
        case plannerModelId = "planner_model_id"
        case workerModelId = "worker_model_id"
        case offlineMode = "offline_mode"
        case downloadJobs = "download_jobs"
        case lastError = "last_error"
        case completedAt = "completed_at"
        case updatedAt = "updated_at"
    }

    public static var initial: OnboardingState {
        OnboardingState(
            currentStep: .welcome,
            selectedTier: nil,
            plannerModelId: nil,
            workerModelId: nil,
            offlineMode: false,
            downloadJobs: [:],
            lastError: nil,
            completedAt: nil,
            updatedAt: Date()
        )
    }

    public init(
        currentStep: OnboardingStep,
        selectedTier: ModelTier?,
        plannerModelId: String?,
        workerModelId: String?,
        offlineMode: Bool,
        downloadJobs: [String: DownloadJob],
        lastError: String?,
        completedAt: Date?,
        updatedAt: Date
    ) {
        self.currentStep = currentStep
        self.selectedTier = selectedTier
        self.plannerModelId = plannerModelId
        self.workerModelId = workerModelId
        self.offlineMode = offlineMode
        self.downloadJobs = downloadJobs
        self.lastError = lastError
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Health check result

public enum HealthCheckStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
}

public struct HealthCheckResult: Codable, Equatable, Sendable {
    public var checkName: String
    public var status: HealthCheckStatus
    public var details: String
    public var errorCode: String?
    public var remediation: String?

    enum CodingKeys: String, CodingKey {
        case checkName = "check_name"
        case status
        case details
        case errorCode = "error_code"
        case remediation
    }

    public init(
        checkName: String,
        status: HealthCheckStatus,
        details: String,
        errorCode: String? = nil,
        remediation: String? = nil
    ) {
        self.checkName = checkName
        self.status = status
        self.details = details
        self.errorCode = errorCode
        self.remediation = remediation
    }
}

// MARK: - Update policy

public struct UpdatePolicy: Codable, Equatable, Sendable {
    public var autoUpdateEnabled: Bool
    public var wifiOnly: Bool
    public var chargingOnly: Bool

    enum CodingKeys: String, CodingKey {
        case autoUpdateEnabled = "auto_update_enabled"
        case wifiOnly = "wifi_only"
        case chargingOnly = "charging_only"
    }

    public static var `default`: UpdatePolicy {
        UpdatePolicy(autoUpdateEnabled: false, wifiOnly: true, chargingOnly: false)
    }

    public init(autoUpdateEnabled: Bool, wifiOnly: Bool, chargingOnly: Bool) {
        self.autoUpdateEnabled = autoUpdateEnabled
        self.wifiOnly = wifiOnly
        self.chargingOnly = chargingOnly
    }
}

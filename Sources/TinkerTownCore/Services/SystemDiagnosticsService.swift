import Foundation

/// Single capability check (chip, RAM, disk, power).
public struct DeviceCapability: Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let recommendation: String?

    public init(name: String, ok: Bool, detail: String, recommendation: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.recommendation = recommendation
    }
}

/// Result of full device check for onboarding.
public struct SystemDiagnosticsResult: Sendable {
    public let capabilities: [DeviceCapability]
    public let recommendedTier: ModelTier
    /// Tiers that can run on this device.
    public let runnableTiers: Set<ModelTier>

    public init(capabilities: [DeviceCapability], recommendedTier: ModelTier, runnableTiers: Set<ModelTier>) {
        self.capabilities = capabilities
        self.recommendedTier = recommendedTier
        self.runnableTiers = runnableTiers
    }

    public func canRunTier(_ tier: ModelTier) -> Bool {
        runnableTiers.contains(tier)
    }
}

/// Collects hardware/runtime constraints and scores compatibility for onboarding.
public struct SystemDiagnosticsService {
    public init() {}

    /// Run all checks and return pass/warn status plus tier recommendation.
    public func run() -> SystemDiagnosticsResult {
        var capabilities: [DeviceCapability] = []

        #if os(macOS)
        let chip = detectChip()
        capabilities.append(chip)

        let ram = checkRAM()
        capabilities.append(ram)

        let disk = checkFreeDisk()
        capabilities.append(disk)

        let power = checkPower()
        capabilities.append(power)
        #else
        capabilities.append(DeviceCapability(name: "Platform", ok: false, detail: "macOS required", recommendation: nil))
        #endif

        let (recommended, runnable) = recommendTier(capabilities: capabilities)
        return SystemDiagnosticsResult(
            capabilities: capabilities,
            recommendedTier: recommended,
            runnableTiers: runnable
        )
    }

    #if os(macOS)
    private func memoryGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    private func freeDiskGB() -> Double? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        do {
            let values = try support.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            let available = values.volumeAvailableCapacity ?? 0
            return Double(available) / (1024 * 1024 * 1024)
        } catch {
            return nil
        }
    }

    private func chipName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func detectChip() -> DeviceCapability {
        let chip = chipName()
        let ok = chip == "arm64"
        let detail = chip == "arm64" ? "Apple Silicon" : "Intel"
        let recommendation = ok ? nil : "Apple Silicon is recommended for the best model tiers."
        return DeviceCapability(name: "Chip", ok: ok, detail: detail, recommendation: recommendation)
    }

    private func checkRAM() -> DeviceCapability {
        let gbDouble = memoryGB()
        var ok = true
        var recommendation: String? = nil
        if gbDouble < 8 {
            ok = false
            recommendation = "At least 8 GB RAM recommended for local models."
        } else if gbDouble < 16 {
            recommendation = "For Best quality tier, 16 GB+ RAM is recommended."
        }
        return DeviceCapability(
            name: "Memory",
            ok: ok,
            detail: String(format: "%.1f GB", gbDouble),
            recommendation: recommendation
        )
    }

    private func checkFreeDisk() -> DeviceCapability {
        guard let gb = freeDiskGB() else {
            return DeviceCapability(name: "Free disk", ok: false, detail: "Cannot determine", recommendation: "Check storage in System Settings.")
        }
        let ok = gb >= 5
        var recommendation: String? = nil
        if !ok {
            recommendation = "Free at least 5 GB in Application Support. Balanced needs ~10 GB and Best quality needs ~22 GB."
        }
        return DeviceCapability(
            name: "Free disk",
            ok: ok,
            detail: String(format: "%.1f GB available", gb),
            recommendation: recommendation
        )
    }

    private func checkPower() -> DeviceCapability {
        #if canImport(IOKit) && !targetEnvironment(simulator)
        // On real Mac we could use IOPSCopyPowerSourcesInfo; in SPM we don't have IOKit by default.
        #endif
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let ok = !lowPowerMode
        let detail = lowPowerMode ? "Low power mode enabled" : "Normal power mode"
        let recommendation = lowPowerMode ? "For large downloads, disable Low Power Mode and plug in power." : nil
        return DeviceCapability(name: "Power", ok: ok, detail: detail, recommendation: recommendation)
    }
    #endif

    private func recommendTier(capabilities: [DeviceCapability]) -> (ModelTier, Set<ModelTier>) {
        let memoryGB = extractGB(from: capabilities.first(where: { $0.name == "Memory" })?.detail)
        let diskGB = extractGB(from: capabilities.first(where: { $0.name == "Free disk" })?.detail)
        let chipOk = capabilities.first(where: { $0.name == "Chip" })?.ok ?? false

        let fast = (memoryGB ?? 0) >= 8 && (diskGB ?? 0) >= 5
        let balanced = (memoryGB ?? 0) >= 16 && (diskGB ?? 0) >= 10
        let quality = (memoryGB ?? 0) >= 24 && (diskGB ?? 0) >= 22 && chipOk

        var runnable = Set<ModelTier>()
        if fast { runnable.insert(.fast) }
        if balanced { runnable.insert(.balanced) }
        if quality { runnable.insert(.quality) }
        if runnable.isEmpty { runnable.insert(.fast) }

        let recommended: ModelTier
        if quality { recommended = .quality }
        else if balanced { recommended = .balanced }
        else { recommended = .fast }
        return (recommended, runnable)
    }

    private func extractGB(from detail: String?) -> Double? {
        guard let detail else { return nil }
        let first = detail.split(separator: " ").first
        return first.flatMap { Double($0) }
    }
}

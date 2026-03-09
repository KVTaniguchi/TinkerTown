import Foundation

/// Unified inference interface for planner/worker role usage.
/// Routes to Ollama (or future bundled runtime) based on installed model path.
public struct ModelRuntimeAdapter {
    private let client: OllamaClient
    private let installedModels: [String: InstalledModel]
    private let localOnly: Bool

    public init(client: OllamaClient = OllamaClient(), installedModels: [String: InstalledModel], localOnly: Bool = true) {
        self.client = client
        self.installedModels = installedModels
        self.localOnly = localOnly
    }

    /// Generate completion using the given model id (planner or worker).
    public func generate(modelId: String, prompt: String, system: String? = nil, numCtx: Int? = 8192) -> String? {
        if localOnly && !isLocalHost(client.baseURL.host) {
            return nil
        }
        let ollamaModel = resolveOllamaModel(modelId: modelId)
        return client.generate(model: ollamaModel, prompt: prompt, numCtx: numCtx, system: system)
    }

    /// Resolve our model id to Ollama model name (may be same; path "ollama:name" -> name).
    private func resolveOllamaModel(modelId: String) -> String {
        guard let record = installedModels[modelId] else { return modelId }
        if record.path.hasPrefix("ollama:") {
            return String(record.path.dropFirst("ollama:".count))
        }
        return modelId
    }

    /// Check if runtime (Ollama) is reachable.
    public func isAvailable() -> Bool {
        if localOnly && !isLocalHost(client.baseURL.host) {
            return false
        }
        guard let url = URL(string: "\(client.baseURL.absoluteString)/api/tags") else { return false }
        let result = AtomicBool(false)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, response, _ in
            result.value = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return result.value
    }

    private func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}

private final class AtomicBool: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

import Foundation

/// Simple box so the data task closure can assign the result without capturing a mutable var.
private final class SyncBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Synchronous client for local Ollama API (http://localhost:11434).
public struct OllamaClient {
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, timeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Generate completion for the given prompt. Returns full response text or nil on failure.
    public func generate(model: String, prompt: String, numCtx: Int? = nil, system: String? = nil) -> String? {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        if let numCtx { body["num_ctx"] = numCtx }
        if let system { body["system"] = system }

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "api/generate", relativeTo: baseURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout

        let result = SyncBox<String?>(nil)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return }
            result.value = response
        }.resume()
        _ = sem.wait(timeout: .now() + timeout)

        return result.value
    }
}

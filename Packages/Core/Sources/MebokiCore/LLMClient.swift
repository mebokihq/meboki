import Foundation

/// Something that proofreads one chunk: the local `llama-server` (`LLMClient`) or a cloud model with the
/// user's own key (`ResponsesClient`). `ProofreadEngine` runs the same post-filters on both.
public protocol Corrector: Sendable {
    /// The model's raw corrected text for `text`. `system` is the session's fixed prompt (`Prompt.system(for:)`).
    func correct(_ text: String, system: String) async throws -> LLMClient.Reply
}

/// Minimal OpenAI-compatible chat client for the bundled llama-server.
public struct LLMClient: Corrector {
    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval

    public init(baseURL: URL, model: String = "local", timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        /// Every request would fail the same way (bad key, no credit, unknown model, rate limit): the check
        /// stops with this message instead of skipping each paragraph as unreliable.
        public var fatal: Bool

        public init(message: String, fatal: Bool = false) {
            self.message = message
            self.fatal = fatal
        }

        public var errorDescription: String? { message }
    }

    public struct Reply: Sendable {
        public var text: String
        /// The model hit its output cap (or stopped early): the text is cut off and must never be applied.
        public var truncated: Bool

        public init(text: String, truncated: Bool) {
            self.text = text
            self.truncated = truncated
        }
    }

    /// Output cap: one token per input UTF-16 unit plus slack. Dense scripts (CJK, Cyrillic, code)
    /// can need about that many; normal English needs ~1/4. Truncated replies are rejected anyway.
    public static func maxTokens(for text: String) -> Int { text.utf16.count + 64 }

    /// Returns the model's raw corrected text for `text`. `system` must be the session's fixed prompt
    /// (`Prompt.system(for:)`), the same string for every request, so the server's prompt cache holds.
    public func correct(_ text: String, system: String = Prompt.system) async throws -> Reply {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": Prompt.user(text)],
            ],
            "temperature": 0,
            "seed": 1,
            "max_tokens": Self.maxTokens(for: text),
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw Failure(message: "Model server returned HTTP \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let choice = choices.first,
            let message = choice["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw Failure(message: "Unexpected response from model server") }
        let finish = choice["finish_reason"] as? String
        return Reply(text: content, truncated: finish == "length")
    }

    /// True when the server reports it's ready.
    public func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

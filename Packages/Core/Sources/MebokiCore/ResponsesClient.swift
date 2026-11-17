import Foundation

/// BYOK cloud client (PLAN.md §4): the OpenAI Responses API (`POST {base}/responses`) with streaming, which
/// OpenAI recommends over Chat Completions and OpenRouter serves with the same wire format. Neither provider
/// ships a Swift SDK and Core stays dependency-free, so this speaks the documented HTTP + SSE format directly.
///
/// Same contract as `LLMClient`: the session's fixed system prompt goes in `instructions` (byte-identical per
/// request, so provider prompt caches can hold), the paragraph in `input`, and the raw reply goes through the
/// same post-filters. Privacy: `store: false` on every request; on OpenRouter, `provider.zdr` and
/// `data_collection: "deny"` keep requests on zero-data-retention endpoints.
public struct ResponsesClient: Corrector {
    public var model: CloudModel
    public var apiKey: String
    /// Idle timeout between streamed bytes.
    public var timeout: TimeInterval
    public var session: URLSession

    public init(model: CloudModel, apiKey: String, timeout: TimeInterval = 30, session: URLSession = .shared) {
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    public var provider: CloudProvider { model.provider }

    /// Stop reading once the reply is this long (UTF-16): a proofread paragraph is about as long as the
    /// input, so anything far longer is a reasoning leak or an answer, and the similarity guard would reject it.
    public static func outputLimit(for text: String) -> Int { text.utf16.count * 2 + 200 }

    /// The JSON body for one paragraph.
    public func body(for text: String, system: String) -> [String: Any] {
        var b: [String: Any] = [
            "model": model.id,
            "instructions": system,
            "input": Prompt.user(text),
            "max_output_tokens": LLMClient.maxTokens(for: text),
            "stream": true,
            "store": false,
        ]
        if model.supportsTemperature { b["temperature"] = 0 }
        if let effort = model.reasoningEffort { b["reasoning"] = ["effort": effort] }
        if provider == .openRouter {
            b["provider"] = ["zdr": true, "data_collection": "deny"]
        }
        return b
    }

    public func request(for text: String, system: String) throws -> URLRequest {
        var req = URLRequest(url: provider.baseURL.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(for: text, system: system))
        return req
    }

    public func correct(_ text: String, system: String) async throws -> LLMClient.Reply {
        let (bytes, resp) = try await session.bytes(for: request(for: text, system: system))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count >= 4096 { break }
            }
            throw Self.failure(status: status, body: data, provider: provider)
        }
        var stream = ResponsesStream(outputLimit: Self.outputLimit(for: text))
        for try await line in bytes.lines {
            try stream.feed(line)
            if stream.isFinished { break }  // also cancels the rest of the download
        }
        return stream.reply
    }

    /// A non-200 reply as a message for the user. Any 4xx is `fatal`: a bad key, no credit, an unknown model
    /// or a rate limit fails every paragraph alike.
    static func failure(status: Int, body: Data, provider: CloudProvider) -> LLMClient.Failure {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        let head: String
        switch status {
        case 401: head = "\(provider.name) rejected the API key"
        case 402: head = "\(provider.name): not enough credits"
        case 403: head = "\(provider.name) refused the request"
        case 404: head = "\(provider.name) can't serve this model"
        case 429: head = "\(provider.name) rate limit or quota reached"
        default: head = "\(provider.name) returned HTTP \(status)"
        }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? head : "\(head): \(trimmed.prefix(200))"
        return LLMClient.Failure(message: message, fatal: (400..<500).contains(status))
    }
}

/// Reads a Responses API event stream line by line (`data: {json}`). Collects the output text deltas and
/// notes how the response ended; anything but `response.completed` counts as cut off, so a dropped connection
/// or an incomplete response is never applied.
public struct ResponsesStream: Sendable {
    public private(set) var text = ""
    public private(set) var isFinished = false
    private var completed = false
    let outputLimit: Int

    public init(outputLimit: Int = .max) {
        self.outputLimit = outputLimit
    }

    /// `truncated` unless the stream ended with `response.completed` (status `completed`).
    public var reply: LLMClient.Reply { LLMClient.Reply(text: text, truncated: !completed) }

    public mutating func feed(_ line: String) throws {
        guard !isFinished, line.hasPrefix("data:") else { return }  // `event:` lines and `:` keep-alive comments
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isFinished = true
            return
        }
        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
            if text.utf16.count > outputLimit { isFinished = true }  // stays not completed: rejected
        case "response.output_text.done":
            if text.isEmpty, let t = event["text"] as? String { text = t }
        case "response.completed":
            let response = event["response"] as? [String: Any]
            if text.isEmpty, let response { text = Self.outputText(of: response) }
            completed = (response?["status"] as? String ?? "completed") == "completed"
            isFinished = true
        case "response.incomplete":
            isFinished = true
        case "response.failed":
            let response = event["response"] as? [String: Any]
            let message = (response?["error"] as? [String: Any])?["message"] as? String
            throw LLMClient.Failure(message: "The model failed: \(message ?? "no reason given")")
        case "error":
            let message = event["message"] as? String
                ?? (event["error"] as? [String: Any])?["message"] as? String
            throw LLMClient.Failure(message: "The model failed: \(message ?? "no reason given")")
        case nil:
            // OpenRouter reports mid-stream errors as `{"error": {...}}` without a type.
            if let error = event["error"] as? [String: Any] {
                throw LLMClient.Failure(message: "The model failed: \(error["message"] as? String ?? "no reason given")")
            }
        default:
            break
        }
    }

    /// The `output_text` parts of a response object's `message` items.
    static func outputText(of response: [String: Any]) -> String {
        let items = response["output"] as? [[String: Any]] ?? []
        return items.filter { ($0["type"] as? String) == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}

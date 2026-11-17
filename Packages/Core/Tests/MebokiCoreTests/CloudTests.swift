import Foundation
import Testing
@testable import MebokiCore

@Suite struct CloudCatalogTests {
    @Test func defaultsAndCustomModels() {
        #expect(CloudCatalog.recommended(for: .openRouter).id == "anthropic/claude-haiku-5.5")
        #expect(CloudCatalog.recommended(for: .openAI).id == "gpt-6-luna")
        #expect(CloudCatalog.model(id: nil, provider: .openAI).id == "gpt-6-luna")
        #expect(CloudCatalog.model(id: "  ", provider: .openRouter).id == "anthropic/claude-haiku-5.5")
        let custom = CloudCatalog.model(id: "mistralai/some-model", provider: .openRouter)
        #expect(custom.isCustom && custom.reasoningEffort == nil && !custom.supportsTemperature)
        #expect(!CloudCatalog.model(id: "openai/gpt-6-luna", provider: .openRouter).isCustom)
    }

    @Test func keyShapes() {
        #expect(CloudProvider.openRouter.keyProblem("sk-or-v1-abc") == nil)
        #expect(CloudProvider.openRouter.keyProblem("sk-proj-abc") != nil)
        #expect(CloudProvider.openAI.keyProblem("sk-proj-abc") == nil)
        #expect(CloudProvider.openAI.keyProblem("sk-or-v1-abc") != nil)
        #expect(CloudProvider.openAI.keyProblem("") != nil)
        #expect(CloudProvider.openAI.keyProblem("sk-a b") != nil)
    }
}

@Suite struct ResponsesRequestTests {
    @Test func openRouterBodyKeepsDataOffAndThinkingOff() throws {
        let client = ResponsesClient(model: CloudCatalog.recommended(for: .openRouter), apiKey: "sk-or-test")
        let body = client.body(for: "He go home.", system: Prompt.system)
        #expect(body["model"] as? String == "anthropic/claude-haiku-5.5")
        #expect(body["instructions"] as? String == Prompt.system)
        #expect(body["input"] as? String == "<text>He go home.</text>")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] as? Int == LLMClient.maxTokens(for: "He go home."))
        #expect(body["temperature"] == nil)
        #expect((body["reasoning"] as? [String: String]) == ["effort": "none"])
        let provider = try #require(body["provider"] as? [String: Any])
        #expect(provider["zdr"] as? Bool == true)
        #expect(provider["data_collection"] as? String == "deny")

        let req = try client.request(for: "He go home.", system: Prompt.system)
        #expect(req.url?.absoluteString == "https://openrouter.ai/api/v1/responses")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
    }

    @Test func openAIBodyHasNoOpenRouterFields() throws {
        let client = ResponsesClient(model: .custom("gpt-9", provider: .openAI), apiKey: "sk-test")
        let body = client.body(for: "x", system: Prompt.systemUK)
        #expect(body["instructions"] as? String == Prompt.systemUK)
        #expect(body["provider"] == nil)
        #expect(body["reasoning"] == nil)
        #expect(try client.request(for: "x", system: "").url?.absoluteString == "https://api.openai.com/v1/responses")
    }

    @Test func temperatureOnlyWhereSupported() {
        let flash = CloudCatalog.model(id: "google/gemini-3.1-flash-lite", provider: .openRouter)
        #expect(ResponsesClient(model: flash, apiKey: "k").body(for: "x", system: "")["temperature"] as? Int == 0)
    }

    @Test func httpErrorsAreFatalFor4xx() {
        let body = Data(#"{"error":{"code":401,"message":"User not found."}}"#.utf8)
        let e = ResponsesClient.failure(status: 401, body: body, provider: .openRouter)
        #expect(e.fatal)
        #expect(e.message == "OpenRouter rejected the API key: User not found.")
        #expect(!ResponsesClient.failure(status: 502, body: Data(), provider: .openAI).fatal)
    }
}

@Suite struct ResponsesStreamTests {
    private func run(_ lines: [String], limit: Int = .max) throws -> ResponsesStream {
        var s = ResponsesStream(outputLimit: limit)
        for l in lines {
            try s.feed(l)
            if s.isFinished { break }
        }
        return s
    }

    @Test func collectsDeltasUntilCompleted() throws {
        let s = try run([
            ": OPENROUTER PROCESSING",
            "event: response.created",
            #"data: {"type":"response.created","response":{"status":"in_progress"}}"#,
            #"data: {"type":"response.output_text.delta","delta":"He goes"}"#,
            #"data: {"type":"response.output_text.delta","delta":" home."}"#,
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
            #"data: {"type":"response.output_text.delta","delta":" ignored"}"#,
        ])
        #expect(s.reply.text == "He goes home.")
        #expect(!s.reply.truncated)
    }

    @Test func textFromTheCompletedResponseWhenNoDeltas() throws {
        let s = try run([#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"Fine."}]}]}}"#])
        #expect(s.reply.text == "Fine." && !s.reply.truncated)
    }

    @Test func incompleteOrDroppedStreamsAreTruncated() throws {
        let cut = try run([
            #"data: {"type":"response.output_text.delta","delta":"He goes"}"#,
            #"data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#,
        ])
        #expect(cut.reply.truncated)
        let dropped = try run([#"data: {"type":"response.output_text.delta","delta":"He goes"}"#])
        #expect(dropped.reply.truncated)
        let done = try run([#"data: {"type":"response.output_text.delta","delta":"He"}"#, "data: [DONE]"])
        #expect(done.isFinished && done.reply.truncated)
    }

    @Test func stopsAtTheOutputLimit() throws {
        let s = try run([
            #"data: {"type":"response.output_text.delta","delta":"Wait, the instruction says"}"#,
            #"data: {"type":"response.completed","response":{"status":"completed"}}"#,
        ], limit: 10)
        #expect(s.isFinished && s.reply.truncated)
    }

    @Test func errorEventsThrow() {
        #expect(throws: LLMClient.Failure.self) {
            try run([#"data: {"type":"error","code":"server_error","message":"boom"}"#])
        }
        #expect(throws: LLMClient.Failure.self) {
            try run([#"data: {"type":"response.failed","response":{"status":"failed","error":{"message":"boom"}}}"#])
        }
        #expect(throws: LLMClient.Failure.self) {
            try run([#"data: {"error":{"code":502,"message":"Provider disconnected"}}"#])
        }
    }
}

/// `ProofreadEngine` on `ResponsesClient` over a fake SSE server.
@Suite(.serialized) struct ResponsesEngineTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSEMock.self]
        return URLSession(configuration: config)
    }

    @Test func checksThroughTheStream() async throws {
        SSEMock.set(status: 200, replies: ["He go to school.": "He goes to school."])
        let client = ResponsesClient(model: CloudCatalog.recommended(for: .openRouter), apiKey: "sk-or-x", session: session())
        let text = "He go to school.\nAll good here."
        let result = try await ProofreadEngine(client: client).check(text)
        #expect(Diff.apply(result.edits, to: text) == "He goes to school.\nAll good here.")
        #expect(result.rejectedChunks == 0)
        #expect(SSEMock.seenInstructions() == [Prompt.system, Prompt.system])
    }

    @Test func badKeyStopsTheCheck() async throws {
        SSEMock.set(status: 401, replies: [:])
        let client = ResponsesClient(model: CloudCatalog.recommended(for: .openAI), apiKey: "sk-bad", session: session())
        await #expect(throws: LLMClient.Failure.self) {
            _ = try await ProofreadEngine(client: client).check("One.\nTwo.")
        }
    }
}

/// Answers `POST …/responses` with a streamed reply (input → output; unknown input echoes), or an error status.
final class SSEMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var replies: [String: String] = [:]
    nonisolated(unsafe) private static var instructions: [String] = []
    private static let lock = NSLock()

    static func set(status s: Int, replies r: [String: String]) {
        lock.lock(); status = s; replies = r; instructions = []; lock.unlock()
    }

    static func seenInstructions() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return instructions
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let input = (json?["input"] as? String ?? "")
            .replacingOccurrences(of: "<text>", with: "").replacingOccurrences(of: "</text>", with: "")
        Self.lock.lock()
        Self.instructions.append(json?["instructions"] as? String ?? "")
        let status = Self.status
        let reply = Self.replies[input] ?? input
        Self.lock.unlock()

        let data: Data
        if status == 200 {
            func event(_ e: [String: Any]) -> String {
                "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: e), as: UTF8.self) + "\n\n"
            }
            let mid = reply.index(reply.startIndex, offsetBy: reply.count / 2)
            data = Data((": keep-alive\n\n"
                + event(["type": "response.output_text.delta", "delta": String(reply[..<mid])])
                + event(["type": "response.output_text.delta", "delta": String(reply[mid...])])
                + event(["type": "response.completed", "response": ["status": "completed"]])).utf8)
        } else {
            data = Data(#"{"error":{"message":"Incorrect API key provided."}}"#.utf8)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

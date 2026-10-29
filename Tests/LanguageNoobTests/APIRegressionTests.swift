import Foundation
import StudyCore
@testable import StudyAssistant

extension LanguageNoobTests {
    static func apiRegressionTests() async throws {
        let request = AssistantRequest(word: Word(id: "api", language: .english, text: "word"), messages: [.init(role: .user, content: "解释")])
        let keys = FixtureKeyStore()
        var messages = AssistantConfiguration(); messages.provider = .messagesAPI; messages.model = "fixture-model"
        var responses = messages; responses.provider = .responsesAPI
        for configuration in [messages, responses] {
            try keys.save("fixture-value", for: configuration)
            let built = try APIRequest.make(request, configuration: configuration, key: "fixture-value")
            let body = try JSONSerialization.jsonObject(with: built.httpBody!) as! [String: Any]
            try check(body["stream"] as? Bool == true && body["tools"] == nil, "API requests stream without tools")
            try check(body["thinking"] == nil && body["output_config"] == nil && body["reasoning"] == nil, "default effort leaves the service configuration unchanged")
            try check(!String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self).contains("fixture-value"), "ordinary settings exclude the key")
            if configuration.provider == .messagesAPI {
                try check(built.url?.path == "/v1/messages" && built.value(forHTTPHeaderField: "x-api-key") == "fixture-value" && body["max_tokens"] as? Int == 4096, "Messages request contract")
            } else {
                try check(built.url?.path == "/v1/responses" && built.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-value" && body["store"] as? Bool == false, "Responses request contract")
            }
        }
        for configuration in [messages, responses] {
            let levels = ["low", "medium", "high", "xhigh", "max"]
            try check(configuration.allowedEfforts == [""] + levels, "API effort choices follow the selected protocol")
            for level in levels {
                var configured = configuration; configured.effort = level
                let restored = try JSONDecoder().decode(AssistantConfiguration.self, from: JSONEncoder().encode(configured))
                try check(restored == configured, "selected API effort survives settings persistence")
                let built = try APIRequest.make(request, configuration: restored, key: "fixture-value")
                let body = try JSONSerialization.jsonObject(with: built.httpBody!) as! [String: Any]
                if configured.provider == .messagesAPI {
                    try check((body["output_config"] as? [String: String])?["effort"] == level && (body["thinking"] as? [String: String])?["type"] == "adaptive", "Messages effort enables adaptive thinking")
                    try check(body["max_tokens"] as? Int == 16384 && body["reasoning"] == nil, "Messages leaves bounded room for thinking and its answer")
                } else {
                    try check((body["reasoning"] as? [String: String])?["effort"] == level && body["output_config"] == nil && body["thinking"] == nil, "Responses retains its own effort contract")
                }
            }
        }
        for invalid in ["none", "minimal", "adaptive", "unsupported"] {
            var configured = messages; configured.effort = invalid
            do { _ = try APIRequest.make(request, configuration: configured, key: "fixture-value"); throw TestFailure("invalid Messages effort accepted") } catch AssistantError.configuration { }
        }
        var custom = responses; custom.baseURL = "https://API.EXAMPLE.COM:443/v1/"
        var equivalent = custom; equivalent.baseURL = "https://api.example.com/v1/responses"
        try check(try custom.keyAccount() == equivalent.keyAccount(), "canonical API destination")
        try check(try !keys.contains(custom), "keys never cross endpoints")
        try keys.save("fixture-custom", for: custom); try keys.remove(equivalent)
        try check(try !keys.contains(custom) && keys.contains(responses), "removal is destination scoped")
        for address in ["http://remote.example/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=value", "https://example.com/#fragment", "relative", "file:///tmp/service"] {
            custom.baseURL = address
            do { _ = try custom.endpoint(); throw TestFailure("invalid API endpoint accepted") } catch AssistantError.endpoint { }
        }
        custom.baseURL = "http://127.0.0.1:8080/v1"; _ = try custom.endpoint()
        let retired = try JSONDecoder().decode(AssistantConfiguration.self, from: Data("{\"provider\":\"grok\",\"model\":\"retired\"}".utf8))
        try check(retired == AssistantConfiguration(), "retired provider recovers locally")
        let previous = try JSONDecoder().decode(AssistantConfiguration.self, from: Data("{\"provider\":\"claude\",\"model\":\"chosen\",\"effort\":\"high\",\"executablePath\":\"\"}".utf8))
        try check(previous.model == "chosen" && previous.baseURL.isEmpty, "existing CLI configuration remains readable")

        let messageEvents: [[String: Any]] = [
            ["type": "message_start"],
            ["type": "content_block_start", "content_block": ["type": "thinking", "thinking": "fixture thinking"]],
            ["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "fixture thinking"]],
            ["type": "content_block_delta", "delta": ["type": "signature_delta", "signature": "fixture signature"]],
            ["type": "content_block_stop"],
            ["type": "content_block_start", "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "你好"]],
            ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "，世界"]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"]], ["type": "message_stop"]]
        let responseEvents: [[String: Any]] = [["type": "response.output_text.delta", "delta": "你好"], ["type": "response.output_text.delta", "delta": "，世界"], ["type": "response.completed", "response": ["status": "completed"]]]
        func wire(_ events: [[String: Any]], ending: String = "\n") throws -> Data {
            var result = Data()
            for event in events { result.append(Data(("event: " + (event["type"] as! String) + ending + "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + ending + ending).utf8)) }
            return result
        }
        for (provider, events) in [(AssistantProvider.messagesAPI, messageEvents), (.responsesAPI, responseEvents)] {
            for ending in ["\n", "\r\n", "\r"] {
                var decoder = ServerSentEvents(), parser = APIResponseParser(provider: provider), deltas = [String]()
                for byte in try wire(events, ending: ending) {
                    for event in try decoder.append(Data([byte])) { if let value = try parser.receive(event) { deltas.append(value) } }
                }
                _ = try decoder.append(Data(), final: true)
                try check(deltas == ["你好", "，世界"] && parser.completed, "SSE byte fragmentation preserves deltas and completion")
            }
        }
        var incomplete = ServerSentEvents()
        var marker = ServerSentEvents()
        try check(try marker.append(Data("data: [DONE]\n\n".utf8)).first?["type"] as? String == "stream.done", "gateway marker is framed without implying completion")
        _ = try incomplete.append(Data("data: {\"type\":\"message_stop\"}\n".utf8))
        do { _ = try incomplete.append(Data(), final: true); throw TestFailure("partial SSE event accepted") } catch AssistantError.invalidResponse { }
        var oversized = ServerSentEvents()
        do { _ = try oversized.append(Data(repeating: 97, count: 1_000_001)); throw TestFailure("unbounded SSE line") } catch AssistantError.outputLimit { }
        var limited = APIResponseParser(provider: .messagesAPI)
        _ = try limited.receive(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "partial"]])
        _ = try limited.receive(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]])
        do { _ = try limited.receive(["type": "message_stop"]); throw TestFailure("truncated message accepted") } catch AssistantError.invalidResponse { }
        for event in [["type": "response.failed"], ["type": "error"]] {
            var parser = APIResponseParser(provider: .responsesAPI)
            do { _ = try parser.receive(event); throw TestFailure("API failure accepted") } catch AssistantError.failed { }
        }
        let client = AssistantClient(keys: keys, networkConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureURLProtocol.self]; return configuration
        })
        for (configuration, events) in [(messages, messageEvents), (responses, responseEvents)] {
            FixtureURLProtocol.configure(parts: try events.map { try wire([$0]) })
            var chunks = [String]()
            for try await chunk in client.reply(request, configuration: configuration) { chunks.append(chunk) }
            try check(chunks == ["你好", "，世界"], "HTTP stream renders actual chunks")
        }
        FixtureURLProtocol.configure(parts: try responseEvents.map { try wire([$0]) }, pause: true)
        var iterator = client.reply(request, configuration: responses).makeAsyncIterator()
        try check(try await iterator.next() == "你好", "first text arrives before the server completes")
        FixtureURLProtocol.resume()
        try check(try await iterator.next() == "，世界", "remaining streamed text arrives separately")
        try check(try await iterator.next() == nil, "successful HTTP completion")
        for (status, expected) in [(401, AssistantError.authentication), (403, .authentication), (429, .rateLimited), (500, .apiStatus(500))] {
            FixtureURLProtocol.configure(parts: [], status: status)
            do { for try await _ in client.reply(request, configuration: responses) {} ; throw TestFailure("HTTP failure accepted") } catch let error as AssistantError { try check(error == expected, "sanitized HTTP failure") }
        }
        FixtureURLProtocol.configure(parts: try [wire([responseEvents[0]])])
        do { for try await _ in client.reply(request, configuration: responses) {}; throw TestFailure("early EOF accepted") } catch AssistantError.invalidResponse { }
        FixtureURLProtocol.configure(parts: [], error: URLError(.timedOut))
        do { for try await _ in client.reply(request, configuration: responses) {}; throw TestFailure("timeout accepted") } catch AssistantError.timeout { }
        FixtureURLProtocol.configure(parts: try responseEvents.map { try wire([$0]) }, pause: true)
        let first = AsyncStream<Void>.makeStream()
        let task = Task {
            for try await _ in client.reply(request, configuration: responses) { first.continuation.yield(()) }
        }
        var seen = first.stream.makeAsyncIterator(); _ = await seen.next(); task.cancel()
        do { try await task.value } catch is CancellationError { }
        first.continuation.finish(); FixtureURLProtocol.resume()
        print("PASS: API destinations, key isolation, request contracts, SSE framing, HTTP streaming and cancellation")
    }
}

private final class FixtureKeyStore: AssistantKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String: String]()
    func key(for configuration: AssistantConfiguration) throws -> String? { let account = try configuration.keyAccount(); return lock.withLock { values[account] } }
    func contains(_ configuration: AssistantConfiguration) throws -> Bool { try key(for: configuration) != nil }
    func save(_ key: String, for configuration: AssistantConfiguration) throws { let account = try configuration.keyAccount(); lock.withLock { values[account] = key } }
    func remove(_ configuration: AssistantConfiguration) throws { let account = try configuration.keyAccount(); _ = lock.withLock { values.removeValue(forKey: account) } }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var parts = [Data](), status = 200, pause = false
    private static var error: Error?
    private static var release: (() -> Void)?
    private let queue = DispatchQueue(label: "fixture-api")
    private var stopped = false
    static func configure(parts: [Data], status: Int = 200, pause: Bool = false, error: Error? = nil) {
        lock.withLock { self.parts = parts; self.status = status; self.pause = pause; self.error = error; release = nil }
    }
    static func resume() { let action = lock.withLock { let value = release; release = nil; return value }; action?() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (parts, status, pause, error) = Self.lock.withLock { (Self.parts, Self.status, Self.pause, Self.error) }
        queue.async {
            guard !self.stopped else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            let rest = {
                self.queue.async {
                    guard !self.stopped else { return }
                    for part in pause ? Array(parts.dropFirst()) : parts { self.client?.urlProtocol(self, didLoad: part) }
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
            if pause {
                Self.lock.withLock { Self.release = rest }
                if let part = parts.first { self.client?.urlProtocol(self, didLoad: part) }
            } else { rest() }
        }
    }
    override func stopLoading() { queue.async { self.stopped = true } }
}

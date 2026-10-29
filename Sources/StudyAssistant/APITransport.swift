import Foundation

struct APIRequest {
    static func make(_ request: AssistantRequest, configuration: AssistantConfiguration, key: String) throws -> URLRequest {
        try configuration.validate(); try AssistantKeyStore.validate(key)
        var result = URLRequest(url: try configuration.endpoint(), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let prompt = try request.prompt()
        var body: [String: Any] = ["model": configuration.model, "stream": true]
        if configuration.provider == .messagesAPI {
            result.setValue(key, forHTTPHeaderField: "x-api-key")
            result.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = 4096
            body["messages"] = [["role": "user", "content": prompt]]
            if !configuration.effort.isEmpty {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": configuration.effort]
                // Thinking shares the output limit with the answer.
                body["max_tokens"] = 16384
            }
        } else {
            result.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body["input"] = [["role": "user", "content": prompt]]
            body["store"] = false
            if !configuration.effort.isEmpty { body["reasoning"] = ["effort": configuration.effort] }
        }
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        return result
    }
}

/// Delegate-driven chunks preserve UTF-8 across network boundaries and cancel immediately.
final class APITransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = OperationQueue()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var received = 0
    private var finished = false
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration; super.init()
        queue.maxConcurrentOperationCount = 1
    }
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in self.queue.addOperation { self.finish(CancellationError()) } }
            queue.addOperation {
                guard !self.finished else { return }
                self.configuration.urlCache = nil; self.configuration.httpCookieStorage = nil
                self.configuration.urlCredentialStorage = nil; self.configuration.httpShouldSetCookies = false
                self.configuration.timeoutIntervalForRequest = 120; self.configuration.timeoutIntervalForResource = 120
                let session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: self.queue)
                self.session = session
                let task = session.dataTask(with: request); self.task = task; task.resume()
            }
        }
    }
    func cancel() { queue.addOperation { self.finish(CancellationError()) } }
    private func finish(_ error: Error?) {
        guard !finished else { return }; finished = true
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil; task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(AssistantError.invalidResponse); return }
        guard (200...299).contains(response.statusCode) else {
            completionHandler(.cancel)
            let error: AssistantError = [401,403].contains(response.statusCode) ? .authentication : response.statusCode == 429 ? .rateLimited : .apiStatus(response.statusCode)
            finish(error); return
        }
        guard response.mimeType?.lowercased() == "text/event-stream" else { completionHandler(.cancel); finish(AssistantError.invalidResponse); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        received += data.count
        guard received <= 2_000_000 else { finish(AssistantError.outputLimit); return }
        continuation?.yield(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            if error.code == .cancelled { finish(CancellationError()) }
            else { finish(error.code == .timedOut ? AssistantError.timeout : AssistantError.failed) }
        } else { finish(error == nil ? nil : AssistantError.failed) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(AssistantError.endpoint)
    }
}

/// SSE framing accepts LF, CRLF and CR, including split separators and Unicode.
struct ServerSentEvents {
    private var line = Data(), fields = [String](), skipLF = false
    private var eventBytes = 0
    mutating func append(_ data: Data, final: Bool = false) throws -> [[String: Any]] {
        var events = [[String: Any]]()
        for byte in data {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                if let event = try finishLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                guard line.count + eventBytes <= 1_000_000 else { throw AssistantError.outputLimit }
            }
        }
        // An unterminated event cannot establish successful completion.
        if final && (!line.isEmpty || !fields.isEmpty) { throw AssistantError.invalidResponse }
        return events
    }
    private mutating func finishLine() throws -> [String: Any]? {
        guard let text = String(data: line, encoding: .utf8) else { throw AssistantError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { fields.removeAll(keepingCapacity: true); eventBytes = 0 }
            guard !fields.isEmpty else { return nil }
            let value = fields.joined(separator: "\n")
            // Some compatible gateways append this marker; it never replaces a terminal event.
            if value == "[DONE]" { return ["type": "stream.done"] }
            guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw AssistantError.invalidResponse }
            return object
        }
        if text == "data" || text.hasPrefix("data:") {
            var value = text == "data" ? "" : String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            fields.append(value); eventBytes += value.utf8.count + 1
            guard eventBytes <= 1_000_000 else { throw AssistantError.outputLimit }
        }
        return nil
    }
}

struct APIResponseParser {
    let provider: AssistantProvider
    private(set) var completed = false
    private(set) var accumulated = ""
    private var stopReason: String?
    mutating func receive(_ event: [String: Any]) throws -> String? {
        guard !completed else { throw AssistantError.invalidResponse }
        let type = event["type"] as? String ?? ""
        var delta: String?
        if type == "error" || type == "response.failed" { throw AssistantError.failed }
        if provider == .messagesAPI {
            if type == "content_block_start", let block = event["content_block"] as? [String: Any] {
                if block["type"] as? String == "tool_use" { throw AssistantError.invalidResponse }
                if block["type"] as? String == "text" { delta = block["text"] as? String }
            }
            if type == "content_block_delta", let change = event["delta"] as? [String: Any], change["type"] as? String == "text_delta" { delta = change["text"] as? String }
            if type == "message_delta", let change = event["delta"] as? [String: Any] { stopReason = change["stop_reason"] as? String ?? stopReason }
            if type == "message_stop" {
                guard stopReason == "end_turn" || stopReason == "stop_sequence" else { throw AssistantError.invalidResponse }
                completed = true
            }
        } else {
            if type == "response.output_text.delta" { delta = event["delta"] as? String }
            if type == "response.incomplete" { throw AssistantError.invalidResponse }
            if type == "response.completed" {
                guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed", response["error"] == nil || response["error"] is NSNull else { throw AssistantError.invalidResponse }
                completed = true
            }
        }
        if let delta { accumulated += delta; guard accumulated.utf8.count <= 100_000 else { throw AssistantError.outputLimit } }
        if completed && accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AssistantError.invalidResponse }
        return delta?.isEmpty == false ? delta : nil
    }
}

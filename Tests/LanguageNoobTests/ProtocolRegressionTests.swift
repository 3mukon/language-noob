import Foundation
@testable import StudyAssistant

extension LanguageNoobTests {
    static func protocolRegressionTests() throws {
        var lines = JSONLines()
        let wire = Data("{\"type\":\"result\",\"result\":\"你好\"}\n".utf8)
        var decoded = [[String: Any]]()
        for byte in wire { decoded += try lines.append(Data([byte])) }
        try check(decoded.count == 1 && decoded[0]["result"] as? String == "你好", "JSON lines preserve split UTF-8")
        var invalid = JSONLines()
        do { _ = try invalid.append(Data("not-json\n".utf8)); throw TestFailure("malformed protocol accepted") }
        catch AssistantError.invalidResponse { }
        var final = JSONLines()
        _ = try final.append(Data("{\"type\":\"turn.completed\"}".utf8))
        try check(try final.append(Data(), final: true).count == 1, "unterminated final protocol line")

        var partial = ResponseParser()
        try check(try partial.receive(["type": "stream_event", "event": ["delta": ["type": "text_delta", "text": "reply"]]]) == "reply", "partial CLI text")
        try check(!partial.completed, "a message does not imply successful turn completion")
        _ = try partial.receive(["type": "result", "result": "reply"])
        try check(partial.completed && partial.accumulated == "reply", "explicit completion without duplication")
        var failure = ResponseParser()
        do { _ = try failure.receive(["type": "result", "is_error": true]); throw TestFailure("failed adapter result accepted") }
        catch AssistantError.failed { }
        var bounded = ResponseParser()
        do {
            _ = try bounded.receive(["type": "result", "result": String(repeating: "x", count: 100_001)])
            throw TestFailure("oversized adapter response accepted")
        } catch AssistantError.outputLimit { }
        let config = AssistantConfiguration()
        let legacy = try JSONDecoder().decode(AssistantConfiguration.self, from: Data("{}".utf8))
        try check(config.enrichmentConcurrency == 1 && legacy.enrichmentConcurrency == 1, "new and existing settings default to serial enrichment")
        for value in [0, 9] {
            var invalid = config; invalid.enrichmentConcurrency = value
            do { try invalid.validate(); throw TestFailure("unbounded enrichment concurrency accepted") }
            catch AssistantError.configuration { }
        }
        let args = try AdapterCommand.arguments(for: .codex, configuration: config)
        try check(args.prefix(3) == ["app-server", "--listen", "stdio://"] && args.contains("history.persistence=\"none\""), "isolated streaming adapter uses stdio")
        var automatic = AssistantConfiguration(); automatic.model = "configured-model"; automatic.effort = "xhigh"
        try automatic.validate()
        let selectedClaude = try AdapterCommand.arguments(for: .claude, configuration: automatic)
        try check(Array(selectedClaude.suffix(4)) == ["--model", "configured-model", "--effort", "xhigh"], "automatic service selection retains explicit model and effort")
        print("PASS: fragmented protocol, completion, error and output bounds")
    }
}

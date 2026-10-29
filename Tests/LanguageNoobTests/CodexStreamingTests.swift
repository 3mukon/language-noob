import Foundation
import StudyCore
@testable import StudyAssistant

extension LanguageNoobTests {
    static func codexStreamingTests() async throws {
        var configuration = AssistantConfiguration(); configuration.provider = .codex
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func prepared(_ settings: AssistantConfiguration? = nil) throws -> CodexSession {
            var session = CodexSession(configuration: settings ?? configuration, directory: directory, prompt: "quoted vocabulary")
            _ = try session.receive(["id": 0, "result": [:]])
            _ = try session.receive(["id": -1, "result": ["config": [:]]])
            let start = try session.receive(["id": 1, "result": ["data": [["name": "local"], ["name": "plugin-server", "pluginId": "fixture-plugin"]]]])
            let params = start.messages.last!["params"] as! [String: Any]
            try check(params["model"] as? String == settings?.model, "Codex receives an explicit model only when configured")
            try check(params["ephemeral"] as? Bool == true && params["sandbox"] as? String == "read-only", "Codex starts a temporary read-only thread")
            let overrides = params["config"] as! [String: Any]
            try check((overrides["mcp_servers"] as! [String: [String: Bool]])["local"]?["enabled"] == false && (overrides["plugins"] as! [String: [String: Bool]])["fixture-plugin"]?["enabled"] == false, "existing servers and plugins are disabled for this thread")
            let inventory = try session.receive(["id": 2, "result": ["thread": ["id": "thread", "ephemeral": true], "approvalPolicy": "never", "sandbox": ["type": "readOnly"]]])
            try check(inventory.messages.first?["method"] as? String == "mcpServerStatus/list", "capability check precedes the prompt")
            return session
        }
        var automatic = AssistantConfiguration(); automatic.model = "configured-model"; automatic.effort = "max"
        var inheritedSession = CodexSession(configuration: AssistantConfiguration(), directory: directory, prompt: "quoted vocabulary")
        _ = try inheritedSession.receive(["id": 0, "result": [:]])
        _ = try inheritedSession.receive(["method": "configWarning", "params": [:]])
        _ = try inheritedSession.receive(["id": -1, "result": ["config": ["model": "local-model", "model_reasoning_effort": "high"]]])
        try check(inheritedSession.configuration.model == "local-model" && inheritedSession.configuration.effort == "high", "Codex request inherits live local preferences")
        var explicitSession = CodexSession(configuration: automatic, directory: directory, prompt: "quoted vocabulary")
        _ = try explicitSession.receive(["id": 0, "result": [:]])
        _ = try explicitSession.receive(["id": -1, "result": ["config": ["model": "local-model", "model_reasoning_effort": "high"]]])
        try check(explicitSession.configuration == automatic, "Codex local values cannot replace application overrides")
        var unavailablePreferences = CodexSession(configuration: automatic, directory: directory, prompt: "quoted vocabulary")
        _ = try unavailablePreferences.receive(["id": 0, "result": [:]])
        let fallback = try unavailablePreferences.receive(["id": -1, "error": ["code": -32601]])
        try check(unavailablePreferences.configuration == automatic && fallback.messages.first?["method"] as? String == "mcpServerStatus/list", "unavailable preferences retain overrides and continue capability checks")
        var selectedCodex = try prepared(automatic)
        let selectedTurn = try selectedCodex.receive(["id": 3, "result": ["data": [], "nextCursor": NSNull()]])
        try check((selectedTurn.messages.first?["params"] as? [String: Any])?["effort"] as? String == "max", "automatic service selection preserves Codex effort")
        var session = try prepared()
        _ = try session.receive(["id": 3, "result": ["data": [["runtimeStatus": "disabled", "tools": [:]]], "nextCursor": NSNull()]])
        let text = try session.receive(["method": "item/agentMessage/delta", "params": ["threadId": "thread", "turnId": "turn", "itemId": "reply", "delta": "你好"]])
        try check(text.delta == "你好" && !session.completed, "Codex delta precedes completion and turn acknowledgment")
        _ = try session.receive(["id": 4, "result": ["turn": ["id": "turn"]]])
        let completeItem = try session.receive(["method": "item/completed", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "reply", "type": "agentMessage", "text": "你好"]]])
        try check(completeItem.delta == nil, "final Codex item does not repeat streamed text")
        _ = try session.receive(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]]])
        try check(session.completed && session.accumulated == "你好", "successful Codex terminal event")
        var tools = try prepared()
        do { _ = try tools.receive(["id": 3, "result": ["data": [["name": "unexpected"]]]]); throw TestFailure("external tools accepted") } catch AssistantError.unsupported { }
        var persistent = CodexSession(configuration: configuration, directory: directory, prompt: "quoted vocabulary")
        _ = try persistent.receive(["id": 0, "result": [:]])
        _ = try persistent.receive(["id": -1, "result": ["config": [:]]])
        _ = try persistent.receive(["id": 1, "result": ["data": []]])
        do { _ = try persistent.receive(["id": 2, "result": ["thread": ["id": "thread", "ephemeral": false], "approvalPolicy": "never", "sandbox": ["type": "readOnly"]]]); throw TestFailure("persistent thread accepted") } catch AssistantError.unsupported { }
        do { _ = try tools.receive(["method": "item/commandExecution/requestApproval", "id": 42]); throw TestFailure("server tool request accepted") } catch AssistantError.unsupported { }
        let executable = directory.appendingPathComponent("codex-fixture")
        let script = #"""
        #!/usr/bin/env python3
        import sys, json, time
        if '--help' in sys.argv:
            print('--listen stdio://'); sys.exit(0)
        assert sys.argv[1:4] == ['app-server', '--listen', 'stdio://']
        assert 'features.shell_tool=false' in sys.argv
        assert 'features.apps=false' in sys.argv
        def send(value):
            data=json.dumps(value,ensure_ascii=False).encode()+bytes([10])
            for part in [data[:7],data[7:]]:
                sys.stdout.buffer.write(part); sys.stdout.buffer.flush()
        for line in sys.stdin:
            event=json.loads(line)
            method=event['method']
            if method=='initialize':
                send({'id':0,'result':{'userAgent':'fixture'}})
            elif method=='config/read':
                send({'id':event['id'],'result':{'config':{'model':'local-model','model_reasoning_effort':'high'}}})
            elif method=='thread/start':
                params=event['params']
                assert params['ephemeral'] and params['sandbox']=='read-only'
                assert not params['dynamicTools'] and not params['environments']
                send({'id':2,'result':{'thread':{'id':'thread','ephemeral':True},'approvalPolicy':'never','sandbox':{'type':'readOnly'}}})
            elif method=='mcpServerStatus/list':
                send({'id':event['id'],'result':{'data':[],'nextCursor':None}})
            elif method=='turn/start':
                prompt=event['params']['input'][0]['text']
                assert 'Vocabulary JSON:' in prompt
                send({'method':'item/agentMessage/delta','params':{'threadId':'thread','turnId':'turn','itemId':'reply','delta':'你好'}})
                send({'id':4,'result':{'turn':{'id':'turn','status':'inProgress'}}})
                if 'cancel-fixture' in prompt: time.sleep(10)
                send({'method':'item/agentMessage/delta','params':{'threadId':'thread','turnId':'turn','itemId':'reply','delta':'，世界'}})
                send({'method':'item/completed','params':{'threadId':'thread','turnId':'turn','item':{'type':'agentMessage','id':'reply','text':'你好，世界'}}})
                send({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'completed'}}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let preferences = try await LocalAssistantPreferencesReader.codex(executable: executable)
        try check(preferences.model == "local-model" && preferences.effort == "high", "Codex reads effective configuration without starting a model turn")
        configuration.executablePath = executable.path
        let request = AssistantRequest(word: Word(id: "one", language: .english, text: "one"), messages: [.init(role: .user, content: "解释")])
        var chunks = [String]()
        for try await delta in AssistantClient().reply(request, configuration: configuration) { chunks.append(delta) }
        try check(chunks == ["你好", "，世界"], "duplex Codex transport streams real increments without replay")
        let signal = AsyncStream<Void>.makeStream()
        let cancellation = AssistantRequest(word: request.word, messages: [.init(role: .user, content: "cancel-fixture")])
        let savedConfiguration = configuration
        let task = Task { for try await _ in AssistantClient().reply(cancellation, configuration: savedConfiguration) { signal.continuation.yield(()) } }
        var progress = signal.stream.makeAsyncIterator(); _ = await progress.next()
        task.cancel(); do { try await task.value } catch is CancellationError { }
        signal.continuation.finish()
        let closedInput = directory.appendingPathComponent("closed-input-fixture")
        try """
        #!/bin/sh
        if [ "$3" = '--help' ] || [ "$2" = '--help' ]; then printf '%s\\n' '--listen stdio://'; exit 0; fi
        exec 0<&-
        printf '%s\\n' '{"id":0,"result":{}}'
        sleep 0.1
        """.write(to: closedInput, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closedInput.path)
        configuration.executablePath = closedInput.path
        do {
            for try await _ in AssistantClient().reply(request, configuration: configuration) {}
            throw TestFailure("closed provider input accepted")
        } catch is AssistantError { }
        print("PASS: Codex handshake, transient isolation, actual deltas, deduplication and cancellation")
    }
}

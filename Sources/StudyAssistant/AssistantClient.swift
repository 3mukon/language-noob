import Foundation
import StudyCore

public protocol AssistantServing: Sendable {
    func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error>
}

public struct AssistantClient: AssistantServing {
    private static let requests = DispatchGroup()
    /// Terminal shutdown waits for cancelled request tasks and their owned child processes.
    public static func waitForIdle() async {
        await withCheckedContinuation { continuation in
            requests.notify(queue: .global()) { continuation.resume() }
        }
        await ProcessTransport.waitForExit()
    }
    private let keys: any AssistantKeyStoring
    private let networkConfiguration: @Sendable () -> URLSessionConfiguration
    public init(keys: any AssistantKeyStoring = AssistantKeyStore()) {
        self.keys = keys; networkConfiguration = { .ephemeral }
    }
    init(keys: any AssistantKeyStoring, networkConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.keys = keys; self.networkConfiguration = networkConfiguration
    }
    public func resolve(_ configuration: AssistantConfiguration) async throws -> ResolvedAssistant {
        try configuration.validate()
        let providers: [AssistantProvider] = configuration.provider == .automatic ? [.codex, .claude] : [configuration.provider]
        var found = false
        for provider in providers {
            try Task.checkCancellation()
            guard let executable = ExecutableDiscovery.find(provider, customPath: configuration.executablePath) else { continue }
            found = true
            var help = Data()
            do {
                for try await chunk in ProcessTransport(limit: 200_000).stream(executable: executable, arguments: provider == .codex ? ["app-server", "--help"] : ["--help"], prompt: nil, timeout: 8) { help.append(chunk) }
            } catch { if Task.isCancelled { throw CancellationError() }; if configuration.provider != .automatic { throw error }; continue }
            if AdapterCommand.supports(String(decoding: help, as: UTF8.self), provider: provider) { return ResolvedAssistant(provider: provider, executable: executable, incremental: true) }
        }
        throw found ? AssistantError.unsupported : AssistantError.unavailable
    }

    public func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Self.requests.enter()
            let task = Task {
                defer { Self.requests.leave() }
                do {
                    try configuration.validate(); try Task.checkCancellation()
                    if configuration.provider.isAPI {
                        guard let key = try keys.key(for: configuration) else { throw AssistantError.missingKey }
                        let request = try APIRequest.make(request, configuration: configuration, key: key)
                        let transport = APITransport(configuration: networkConfiguration())
                        defer { transport.cancel() }
                        var events = ServerSentEvents(), parser = APIResponseParser(provider: configuration.provider)
                        stream: for try await bytes in transport.stream(request) {
                            try Task.checkCancellation()
                            for event in try events.append(bytes) {
                                if let delta = try parser.receive(event) { continuation.yield(delta) }
                                if parser.completed { break stream }
                            }
                        }
                        guard parser.completed else { throw AssistantError.invalidResponse }
                        try Task.checkCancellation(); continuation.finish(); return
                    }
                    let resolved = try await resolve(configuration)
                    try Task.checkCancellation()
                    let prompt = try request.prompt()
                    let preferences = resolved.provider == .claude ? LocalAssistantPreferencesReader.claude(model: configuration.model) : LocalAssistantPreferences()
                    let effective = preferences.applying(to: configuration)
                    let arguments = try AdapterCommand.arguments(for: resolved.provider, configuration: configuration, inheriting: preferences)
                    if resolved.provider == .codex {
                        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-ai-" + UUID().uuidString)
                        var session = CodexSession(configuration: configuration, directory: directory, prompt: prompt)
                        let transport = ProcessTransport(); defer { transport.stop() }
                        var lines = JSONLines()
                        let initial = String(decoding: try CodexSession.encode(CodexSession.initialize), as: UTF8.self)
                        stream: for try await bytes in transport.stream(executable: resolved.executable, arguments: arguments, prompt: initial, timeout: 120, keepInputOpen: true, workingDirectory: directory) {
                            try Task.checkCancellation()
                            for event in try lines.append(bytes) {
                                let update = try session.receive(event)
                                for message in update.messages { transport.send(try CodexSession.encode(message)) }
                                if let delta = update.delta { continuation.yield(delta) }
                                if session.completed { break stream }
                            }
                        }
                        guard session.completed else { throw AssistantError.invalidResponse }
                        try Task.checkCancellation(); continuation.finish(); return
                    }
                    var lines = JSONLines(), parser = ResponseParser()
                    var environment = [String: String]()
                    if !effective.effort.isEmpty { environment["CLAUDE_CODE_EFFORT_LEVEL"] = effective.effort }
                    for try await bytes in ProcessTransport().stream(executable: resolved.executable, arguments: arguments, prompt: prompt, timeout: 120, environmentOverrides: environment) {
                        try Task.checkCancellation()
                        for object in try lines.append(bytes) { if let text = try parser.receive(object) { continuation.yield(text) } }
                    }
                    for object in try lines.append(Data(), final: true) { if let text = try parser.receive(object) { continuation.yield(text) } }
                    guard parser.completed, !parser.accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalidResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public static func enrichedWord(from response: String, original: Word) throws -> Word {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), let newline = json.firstIndex(of: "\n"), json.hasSuffix("```") {
            json = String(json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)])
        }
        struct Fields: Decodable { let pronunciation: String; let chinese_def: String; let part_of_speech: String; let examples: [Example] }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: Data(json.utf8)), !fields.chinese_def.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalidResponse }
        var word = original; word.pronunciation = fields.pronunciation; word.definition = fields.chinese_def
        word.partOfSpeech = fields.part_of_speech; word.examples = fields.examples
        try VocabularyImport.validate(word)
        return word
    }
}


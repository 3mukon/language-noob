import Foundation

public struct LocalAssistantPreferences: Equatable, Sendable {
    public var provider: AssistantProvider?
    public var model: String
    public var effort: String
    public var executablePath: String
    var sourceFiles = [String]()

    public init(provider: AssistantProvider? = nil, model: String = "", effort: String = "", executablePath: String = "") {
        self.provider = provider
        self.model = Self.clean(model, limit: 120)
        self.executablePath = executablePath
        let level = Self.clean(effort, limit: 32)
        self.effort = level.unicodeScalars.allSatisfy { (97...122).contains($0.value) } ? level : ""
    }

    public func applying(to configuration: AssistantConfiguration) -> AssistantConfiguration {
        var result = configuration
        if result.model.isEmpty { result.model = model }
        if result.effort.isEmpty { result.effort = effort }
        return result
    }

    private static func clean(_ value: String, limit: Int) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= limit, !value.hasPrefix("-"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return value
    }

    static func codex(_ result: [String: Any]) -> LocalAssistantPreferences {
        let config = result["config"] as? [String: Any] ?? [:]
        let models = config["models"] as? [String: Any] ?? [:]
        let defaults = models["new_thread"] as? [String: Any] ?? [:]
        var preferences = LocalAssistantPreferences(provider: .codex,
            model: defaults["model"] as? String ?? config["model"] as? String ?? "",
            effort: defaults["model_reasoning_effort"] as? String ?? config["model_reasoning_effort"] as? String ?? "")
        let origins = result["origins"] as? [String: [String: Any]] ?? [:]
        preferences.sourceFiles = Array(Set(origins.values.compactMap {
            ($0["name"] as? [String: Any])?["file"] as? String
        }.filter { $0.hasPrefix("/") })).sorted()
        return preferences
    }
}

/// Reads only presentation preferences. No model turn or configuration write.
public struct LocalAssistantPreferencesReader: Sendable {
    public init() {}

    public func read(for configuration: AssistantConfiguration) async -> LocalAssistantPreferences {
        await LocalPreferencesCache.shared.read(for: configuration)
    }

    static func readUncached(for configuration: AssistantConfiguration) async -> LocalAssistantPreferences {
        guard !configuration.provider.isAPI else { return LocalAssistantPreferences() }
        if configuration.provider == .claude {
            var preferences = Self.claude(model: configuration.model)
            preferences.executablePath = ExecutableDiscovery.find(.claude, customPath: configuration.executablePath)?.path ?? ""
            return preferences
        }
        var probe = configuration; probe.model = ""; probe.effort = ""
        // A successful stdio handshake and config/read already prove that the
        // executable can supply these settings. Actual model requests keep their
        // full capability and isolation checks.
        if let executable = ExecutableDiscovery.find(.codex, customPath: configuration.executablePath),
           let preferences = try? await codex(executable: executable), !Task.isCancelled { return preferences }
        guard !Task.isCancelled else { return LocalAssistantPreferences() }
        guard let resolved = try? await AssistantClient().resolve(probe), !Task.isCancelled else { return LocalAssistantPreferences() }
        var preferences: LocalAssistantPreferences
        if resolved.provider == .claude { preferences = Self.claude(model: configuration.model) }
        else { preferences = LocalAssistantPreferences(provider: .codex) }
        preferences.executablePath = resolved.executable.path
        return preferences
    }

    static func codex(executable: URL) async throws -> LocalAssistantPreferences {
        let transport = ProcessTransport(); defer { transport.stop() }
        let configuration = AssistantConfiguration()
        let arguments = try AdapterCommand.arguments(for: .codex, configuration: configuration)
        let initial = String(decoding: try CodexSession.encode(CodexSession.initialize), as: UTF8.self)
        var lines = JSONLines(), initialized = false
        for try await bytes in transport.stream(executable: executable, arguments: arguments, prompt: initial, timeout: 8, keepInputOpen: true) {
            try Task.checkCancellation()
            for event in try lines.append(bytes) {
                guard event["error"] == nil else { throw AssistantError.failed }
                if event["method"] != nil {
                    guard event["id"] == nil else { throw AssistantError.unsupported }
                    continue
                }
                if event["id"] as? Int == 0 && !initialized {
                    initialized = true
                    transport.send(try CodexSession.encode(["method": "initialized", "params": [String: Any]()]))
                    transport.send(try CodexSession.encode(["id": -1, "method": "config/read", "params": ["includeLayers": false]]))
                } else if event["id"] as? Int == -1 && initialized, let result = event["result"] as? [String: Any] {
                    var preferences = LocalAssistantPreferences.codex(result)
                    preferences.executablePath = executable.path
                    return preferences
                } else { throw AssistantError.invalidResponse }
            }
        }
        throw AssistantError.invalidResponse
    }

    static func claude(model: String = "", home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> LocalAssistantPreferences {
        let custom = environment["CLAUDE_CONFIG_DIR"] ?? ""
        let directory = custom.hasPrefix("/") ? URL(fileURLWithPath: custom) : home.appendingPathComponent(".claude")
        let file = directory.appendingPathComponent("settings.json")
        var data = Data()
        if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            if let bytes = try? handle.read(upToCount: 1_000_001), bytes.count <= 1_000_000 { data = bytes }
        }
        return claude(data: data, model: model, environment: environment)
    }

    static func claude(data: Data, model override: String = "", environment: [String: String] = [:]) -> LocalAssistantPreferences {
        let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let env = settings["env"] as? [String: Any] ?? [:]
        let model = environment["ANTHROPIC_MODEL"] ?? env["ANTHROPIC_MODEL"] as? String
            ?? settings["model"] as? String ?? environment["ANTHROPIC_DEFAULT_MODEL"]
            ?? env["ANTHROPIC_DEFAULT_MODEL"] as? String ?? ""
        let models = settings["modelSettings"] as? [String: [String: Any]] ?? [:]
        let selected = override.isEmpty ? model : override
        let effort = environment["CLAUDE_CODE_EFFORT_LEVEL"] ?? env["CLAUDE_CODE_EFFORT_LEVEL"] as? String
            ?? models[selected]?["effortLevel"] as? String ?? settings["effortLevel"] as? String ?? ""
        return LocalAssistantPreferences(provider: .claude, model: model == "default" ? "" : model, effort: effort)
    }
}

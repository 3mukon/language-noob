import Foundation
@testable import StudyAssistant

extension LanguageNoobTests {
    static func localPreferencesTests() throws {
        try desktopExecutableTests()
        let local = LocalAssistantPreferences(provider: .codex, model: "local-model", effort: "high")
        var settings = AssistantConfiguration()
        let inherited = local.applying(to: settings)
        try check(inherited.model == "local-model" && inherited.effort == "high" && settings.model.isEmpty && settings.effort.isEmpty, "inherited values do not become saved overrides")
        settings.model = "chosen-model"
        try check(local.applying(to: settings).model == "chosen-model" && local.applying(to: settings).effort == "high", "model override is independent of inherited effort")
        settings.effort = "max"
        try check(local.applying(to: settings) == settings, "explicit model and effort take precedence")
        try check(LocalAssistantPreferences().applying(to: AssistantConfiguration()) == AssistantConfiguration(), "unreadable local values retain service defaults")
        let discovered = LocalAssistantPreferences(provider: .codex, model: "local-model", effort: "high", executablePath: "/fixture/codex")
        try check(discovered.applying(to: AssistantConfiguration()).executablePath.isEmpty, "discovered executable is display metadata, never a saved override")
        let parsed = LocalAssistantPreferences.codex(["config": ["model": "local-model", "model_reasoning_effort": "high", "unrelated": ["ignored": true]]])
        try check(parsed == local, "Codex config read extracts only model and effort")
        let otherLevel = LocalAssistantPreferences(provider: .codex, effort: "ultra")
        try check(otherLevel.effort == "ultra", "a configured service level is never mislabeled as default")
        let managed = LocalAssistantPreferences.codex(["config": ["model": "base", "model_reasoning_effort": "low", "models": ["new_thread": ["model": "managed-model", "model_reasoning_effort": "xhigh"]]]])
        try check(managed.model == "managed-model" && managed.effort == "xhigh", "Codex new-thread defaults are reflected")
        let data = Data(#"{"model":"local-model","effortLevel":"high","env":{"ANTHROPIC_MODEL":"env-model"},"modelSettings":{"chosen-model":{"effortLevel":"xhigh"}}}"#.utf8)
        let fromFile = LocalAssistantPreferencesReader.claude(data: data)
        try check(fromFile.model == "env-model" && fromFile.effort == "high", "Claude settings provide model and effort")
        let perModel = LocalAssistantPreferencesReader.claude(data: data, model: "chosen-model")
        try check(perModel.effort == "xhigh", "explicit model selects its saved effort when effort is not overridden")
        let fromEnvironment = LocalAssistantPreferencesReader.claude(data: data, environment: ["ANTHROPIC_MODEL": "process-model", "CLAUDE_CODE_EFFORT_LEVEL": "low"])
        try check(fromEnvironment.model == "process-model" && fromEnvironment.effort == "low", "Claude process preferences outrank file preferences")
        let invalid = LocalAssistantPreferencesReader.claude(data: Data("invalid".utf8))
        try check(invalid.model.isEmpty && invalid.effort.isEmpty, "malformed local configuration falls back")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-preferences-" + UUID().uuidString)
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try data.write(to: custom.appendingPathComponent("settings.json"))
        let loaded = LocalAssistantPreferencesReader.claude(home: root, environment: ["CLAUDE_CONFIG_DIR": custom.path])
        try check(loaded == fromFile, "Claude reads the configured directory without changing it")
        try check(try Data(contentsOf: custom.appendingPathComponent("settings.json")) == data, "preference lookup is read-only")
        let absent = LocalAssistantPreferencesReader.claude(home: root, environment: [:])
        try check(absent.model.isEmpty && absent.effort.isEmpty, "missing settings keep defaults")
        print("PASS: explicit, local and default preference priority, isolated reads and malformed fallback")
    }

    private static func desktopExecutableTests() throws {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-discovery-" + UUID().uuidString)
        defer { try? manager.removeItem(at: home) }
        func bundle(_ version: String, _ build: String, executable: Bool = true) throws -> URL {
            let file = home.appendingPathComponent("Library/Application Support/Claude/claude-code/\(version)/\(build)/claude.app/Contents/MacOS/claude")
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: file.path)
            return file
        }
        try check(ExecutableDiscovery.desktopClaude(home: home) == nil, "a missing desktop installation stays unavailable")
        let older = try bundle("2.1.9", "old")
        let newest = try bundle("2.1.10", "complete")
        _ = try bundle("2.1.11", "partial", executable: false)
        _ = try bundle("pending", "download")
        try check(ExecutableDiscovery.desktopClaude(home: home) == newest, "numeric version ordering skips incomplete and unversioned desktop downloads")
        let rebuilt = try bundle("2.1.10", "replaced")
        let build = rebuilt.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: build.path)
        try check(ExecutableDiscovery.desktopClaude(home: home) == rebuilt, "a newer complete installation wins within the same version")
        try manager.removeItem(at: rebuilt)
        try manager.createDirectory(at: rebuilt, withIntermediateDirectories: false)
        try check(ExecutableDiscovery.desktopClaude(home: home) == newest, "executable directories are not mistaken for a CLI")
        try manager.removeItem(at: newest)
        try check(ExecutableDiscovery.desktopClaude(home: home) == older, "removed and incomplete updates fall back to a complete older bundle")
        try check(ExecutableDiscovery.find(.claude, customPath: older.path) == older, "an explicit executable wins over installed discovery")
        try check(ExecutableDiscovery.find(.claude, customPath: home.appendingPathComponent("missing").path) == nil, "an invalid explicit path never silently falls back")
        print("PASS: versioned desktop CLI discovery and explicit-path precedence")
    }

    static func localPreferenceLoadingTests() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-preference-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("preferences"), layer = root.appendingPathComponent("layer")
        try Data("first".utf8).write(to: source)
        try Data("layer".utf8).write(to: layer)
        let counter = PreferenceReadCounter()
        let cache = LocalPreferencesCache(sources: { _ in [source.path] }, load: { _ in
            let number = await counter.next()
            try? await Task.sleep(for: .milliseconds(30))
            var value = LocalAssistantPreferences(provider: .codex, model: "model-\(number)", effort: "high", executablePath: "/fixture/codex")
            value.sourceFiles = [layer.path]
            return value
        })
        let configuration = AssistantConfiguration()
        async let first = cache.read(for: configuration)
        async let second = cache.read(for: configuration)
        let pair = await (first, second)
        var count = await counter.count
        try check(pair.0 == pair.1 && count == 1, "concurrent settings reads share one provider process")
        let reused = await cache.read(for: configuration)
        count = await counter.count
        try check(reused == pair.0 && count == 1, "unchanged configuration reuses its complete snapshot")
        try Data("changed preferences".utf8).write(to: source, options: .atomic)
        let changed = await cache.read(for: configuration)
        try check(changed.model == "model-2", "configuration replacement invalidates cached settings")
        try Data("new layer".utf8).write(to: layer, options: .atomic)
        let changedLayer = await cache.read(for: configuration)
        try check(changedLayer.model == "model-3", "provider-reported source layers also invalidate the cache")
        try FileManager.default.removeItem(at: source)
        let removed = await cache.read(for: configuration)
        try check(removed.model == "model-4", "deleting configuration cannot leave stale displayed values")
        let expired = LocalPreferencesCache(maxAge: .zero, sources: { _ in [] }, load: { _ in
            let number = await counter.next()
            return LocalAssistantPreferences(provider: .codex, model: "model-\(number)")
        })
        _ = await expired.read(for: configuration)
        _ = await expired.read(for: configuration)
        count = await counter.count
        try check(count == 6, "age bounds unknown managed-configuration changes")
        let fast = LocalAssistantPreferencesLoad(load: { pair.0 }, completion: { _ in })
        try check(fast.wait() == pair.0, "fast reads expose a complete first-paint snapshot")
        let gate = PreferenceReadGate(), delivered = PreferenceDelivery()
        let slow = LocalAssistantPreferencesLoad(load: { await gate.read() }, completion: { delivered.receive($0) })
        let start = ContinuousClock.now
        try check(slow.wait(upTo: 0.015) == nil && start.duration(to: .now) < .milliseconds(150), "slow reads release the native form within its waiting budget")
        await gate.finish(pair.0)
        try check(delivered.wait() == pair.0 && slow.wait(upTo: 0) == pair.0, "a slow read delivers all fields in one later update")
        let cancelledGate = PreferenceReadGate(), cancelledDelivery = PreferenceDelivery()
        let cancelled = LocalAssistantPreferencesLoad(load: { await cancelledGate.read() }, completion: { cancelledDelivery.receive($0) })
        cancelled.cancel()
        await cancelledGate.finish(pair.0)
        try check(cancelledDelivery.wait(timeout: 0.03) == nil, "closed settings cannot receive late read callbacks")
        print("PASS: shared preference reads, file/layer invalidation, bounded first paint and cancelled delivery")
    }
}

private actor PreferenceReadCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
private actor PreferenceReadGate {
    private var result: LocalAssistantPreferences?
    private var continuation: CheckedContinuation<LocalAssistantPreferences, Never>?
    func read() async -> LocalAssistantPreferences {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: LocalAssistantPreferences) {
        result = value; continuation?.resume(returning: value); continuation = nil
    }
}
private final class PreferenceDelivery: @unchecked Sendable {
    private let lock = NSLock(), ready = DispatchSemaphore(value: 0)
    private var value: LocalAssistantPreferences?
    func receive(_ value: LocalAssistantPreferences) {
        lock.lock(); self.value = value; lock.unlock(); ready.signal()
    }
    func wait(timeout: TimeInterval = 1) -> LocalAssistantPreferences? {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }; return value
    }
}

import Foundation

/// Presentation-only cache. Actual requests still read the provider's current configuration.
actor LocalPreferencesCache {
    static let shared = LocalPreferencesCache()
    private struct Key: Hashable {
        var provider: AssistantProvider
        var model: String
        var executablePath: String
    }
    private struct FileStamp: Equatable {
        var path: String
        var modified: Date?
        var size: UInt64?
        var inode: UInt64?
        init(_ path: String) {
            self.path = path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            modified = attributes?[.modificationDate] as? Date
            size = (attributes?[.size] as? NSNumber)?.uint64Value
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
    private struct Entry {
        var value: LocalAssistantPreferences
        var files: [FileStamp]
        var expires: ContinuousClock.Instant
    }
    private struct Pending {
        var id: UUID
        var files: [FileStamp]
        var task: Task<LocalAssistantPreferences, Never>
    }
    private var entries = [Key: Entry]()
    private var pending = [Key: Pending]()
    private let maxAge: Duration
    private let sources: @Sendable (AssistantConfiguration) -> [String]
    private let load: @Sendable (AssistantConfiguration) async -> LocalAssistantPreferences

    init(maxAge: Duration = .seconds(30),
         sources: @escaping @Sendable (AssistantConfiguration) -> [String] = { LocalPreferencesCache.sourceFiles($0) },
         load: @escaping @Sendable (AssistantConfiguration) async -> LocalAssistantPreferences = { await LocalAssistantPreferencesReader.readUncached(for: $0) }) {
        self.maxAge = maxAge; self.sources = sources; self.load = load
    }

    func read(for configuration: AssistantConfiguration) async -> LocalAssistantPreferences {
        guard !configuration.provider.isAPI else { return LocalAssistantPreferences() }
        let key = Key(provider: configuration.provider, model: configuration.provider == .codex ? "" : configuration.model,
                      executablePath: configuration.executablePath)
        let files = sources(configuration).map(FileStamp.init)
        if let entry = entries[key], ContinuousClock.now < entry.expires,
           files.allSatisfy({ entry.files.contains($0) }),
           entry.files == entry.files.map({ FileStamp($0.path) }) { return entry.value }
        let work: Pending
        if let existing = pending[key], existing.files == files { work = existing }
        else {
            let load = self.load
            work = Pending(id: UUID(), files: files, task: Task { await load(configuration) })
            pending[key] = work
        }
        let value = await work.task.value
        guard pending[key]?.id == work.id else { return value }
        pending.removeValue(forKey: key)
        // A file edited during the read must be fetched again on the next open.
        if files == sources(configuration).map(FileStamp.init) {
            if entries.count >= 16, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
                entries.removeValue(forKey: oldest)
            }
            let paths = Set(files.map(\.path) + value.sourceFiles)
            entries[key] = Entry(value: value, files: paths.sorted().map(FileStamp.init),
                                 expires: .now.advanced(by: value.provider == nil ? .seconds(1) : maxAge))
        }
        return value
    }

    private static func sourceFiles(_ configuration: AssistantConfiguration) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        let codex = environment["CODEX_HOME"] ?? home + "/.codex"
        let claude = environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        var paths = [codex + "/config.toml", codex + "/requirements.toml",
                     "/etc/codex/config.toml", "/etc/codex/managed_config.toml", "/etc/codex/requirements.toml",
                     claude + "/settings.json"]
        let providers: [AssistantProvider] = configuration.provider == .automatic ? [.codex, .claude] : [configuration.provider]
        for provider in providers {
            if let executable = ExecutableDiscovery.find(provider, customPath: configuration.executablePath) {
                paths += [executable.path, executable.resolvingSymlinksInPath().path]
            }
        }
        if !configuration.executablePath.isEmpty { paths.append(configuration.executablePath) }
        return Array(Set(paths)).sorted()
    }
}

/// Gives a native form one bounded opportunity to render complete values before its first paint.
public final class LocalAssistantPreferencesLoad: @unchecked Sendable {
    private let lock = NSLock(), completed = DispatchSemaphore(value: 0)
    private var result: LocalAssistantPreferences?
    private var task: Task<Void, Never>?

    public convenience init(configuration: AssistantConfiguration,
                            completion: @escaping @Sendable (LocalAssistantPreferences) -> Void) {
        self.init(load: { await LocalAssistantPreferencesReader().read(for: configuration) }, completion: completion)
    }
    init(load: @escaping @Sendable () async -> LocalAssistantPreferences,
         completion: @escaping @Sendable (LocalAssistantPreferences) -> Void) {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let value = await load()
            guard !Task.isCancelled, let self else { return }
            self.store(value)
            self.completed.signal()
            completion(value)
        }
    }
    deinit { task?.cancel() }
    public func cancel() { task?.cancel() }
    public func wait(upTo interval: TimeInterval = 0.150) -> LocalAssistantPreferences? {
        if let value = snapshot() { return value }
        _ = completed.wait(timeout: .now() + max(0, min(interval, 0.150)))
        return snapshot()
    }
    private func snapshot() -> LocalAssistantPreferences? {
        lock.lock(); defer { lock.unlock() }; return result
    }
    private func store(_ value: LocalAssistantPreferences) {
        lock.lock(); defer { lock.unlock() }; result = value
    }
}

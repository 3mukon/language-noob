import Foundation
import Darwin
import StudyCore
import StudyAssistant

public struct StudySettings: Codable, Equatable {
    public var language: StudyLanguage = .english
    public var mode: StudyMode = .study
    public var newLimit: Int?
    public var assistant = AssistantConfiguration()
    public init() {}

    public static func load(from url: URL) -> (settings: StudySettings, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (StudySettings(), nil) }
        do {
            var settings = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            if let limit = settings.newLimit { settings.newLimit = min(100, max(0, limit)) }
            do { try settings.assistant.validate() }
            catch {
                settings.assistant = AssistantConfiguration()
                return (settings, "AI 设置暂不可用，已使用默认值。离线学习可以继续，也可以重新打开 AI 设置。")
            }
            return (settings, nil)
        } catch { return (StudySettings(), "无法读取设置，已使用默认值。原有词库和学习进度不受影响。") }
    }

    /// Merge only fields edited since the caller's snapshot, under a process-shared lock.
    @discardableResult public func save(to url: URL, replacing baseline: StudySettings? = nil) throws -> StudySettings {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let encode: (StudySettings) throws -> [String: Any] = { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as! [String: Any] }
        let value = try encode(self), old = try baseline.map(encode)
        let existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        var output = try encode(StudySettings()).merging(existing) { _, saved in saved }
        for key in ["language", "mode", "newLimit"] {
            if old == nil || !Self.equal(value[key], old?[key]) { output[key] = value[key] }
        }
        var assistant = output["assistant"] as? [String: Any] ?? [:]
        let proposed = value["assistant"] as! [String: Any], previous = old?["assistant"] as? [String: Any]
        for key in ["provider", "model", "effort", "executablePath", "baseURL", "enrichmentConcurrency"] {
            if old == nil || !Self.equal(proposed[key], previous?[key]) { assistant[key] = proposed[key] }
        }
        output["assistant"] = assistant
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        let merged = try JSONDecoder().decode(Self.self, from: data)
        try merged.assistant.validate()
        try data.write(to: url, options: .atomic)
        return merged
    }
    private static func equal(_ a: Any?, _ b: Any?) -> Bool { (a as? NSObject) == (b as? NSObject) }
}

public enum StudyEnvironment {
    public static func dataDirectory(override: String? = nil) throws -> URL {
        if let override { return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Language Noob", isDirectory: true)
    }
}

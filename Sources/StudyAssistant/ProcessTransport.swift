import Foundation
import Darwin

/// Bounded byte transport. Prompts travel through stdin, never argv or a file.
final class ProcessTransport: @unchecked Sendable {
    private static let lifetimes = DispatchGroup()
    private let queue = DispatchQueue(label: "app.languagenoob.assistant-process")
    private let inputQueue = DispatchQueue(label: "app.languagenoob.assistant-input")
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var timer: DispatchSourceTimer?
    private var finished = false, terminated = false, outputClosed = false
    private var bytes = 0
    private var directory: URL?
    private var lifetimeActive = false
    private let limit: Int

    init(limit: Int = 2_000_000) { self.limit = limit }
    func stream(executable: URL, arguments: [String], prompt: String?, timeout: TimeInterval, keepInputOpen: Bool = false, workingDirectory: URL? = nil, environmentOverrides: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Self.lifetimes.enter()
            self.lifetimeActive = true
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in self.queue.async { self.finish(CancellationError()) } }
            queue.async {
                guard !self.finished else { return }
                do {
                    // Keep provider scratch data outside the project and make it private.
                    // A fixed system temporary root also works when the app is launched from
                    // a restricted desktop container whose default Foundation temp URL is not writable.
                    let directory = workingDirectory ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("language-noob-ai-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    self.directory = directory
                    self.process.executableURL = executable; self.process.arguments = arguments; self.process.currentDirectoryURL = directory
                    self.process.standardInput = self.input; self.process.standardOutput = self.output; self.process.standardError = self.errors
                    guard fcntl(self.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw AssistantError.failed }
                    var environment = ProcessInfo.processInfo.environment
                    // Do not inherit host application IPC or project routing into the provider.
                    for key in environment.keys where key.hasPrefix("CODEX_") && key != "CODEX_HOME" { environment.removeValue(forKey: key) }
                    environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
                    environment["NO_COLOR"] = "1"
                    environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin:" + FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:" + FileManager.default.homeDirectoryForCurrentUser.path + "/.local/node/bin"
                    for (key, value) in environmentOverrides { environment[key] = value }
                    self.process.environment = environment
                    self.output.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        self.queue.async {
                            guard !self.finished else { return }
                            if data.isEmpty { self.outputClosed = true; self.output.fileHandleForReading.readabilityHandler = nil; self.completeIfReady(); return }
                            self.bytes += data.count
                            guard self.bytes <= self.limit else { self.finish(AssistantError.outputLimit); return }
                            self.continuation?.yield(data)
                        }
                    }
                    self.errors.fileHandleForReading.readabilityHandler = { handle in
                        // Drain without retaining or exposing provider diagnostics or credentials.
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil }
                    }
                    self.process.terminationHandler = { _ in self.queue.async {
                        self.terminated = true
                        self.process.terminationHandler = nil
                        if self.finished { self.cleanScratch() } else { self.completeIfReady() }
                    } }
                    try self.process.run()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler { self.finish(AssistantError.timeout) }; self.timer = timer; timer.resume()
                    // Avoid blocking the state queue on a provider that never reads stdin.
                    self.inputQueue.async {
                        if let prompt { try? self.input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8)) }
                        if !keepInputOpen { try? self.input.fileHandleForWriting.close() }
                    }
                } catch { self.finish(AssistantError.unavailable) }
            }
        }
    }
    func send(_ data: Data) {
        queue.async {
            guard !self.finished else { return }
            self.inputQueue.async {
                do { try self.input.fileHandleForWriting.write(contentsOf: data) }
                catch { self.queue.async { self.finish(AssistantError.failed) } }
            }
        }
    }
    func stop() { queue.async { self.finish(nil) } }
    static func waitForExit() async {
        await withCheckedContinuation { continuation in
            lifetimes.notify(queue: .global()) { continuation.resume() }
        }
    }
    private func completeIfReady() {
        guard terminated && outputClosed else { return }
        finish(process.terminationStatus == 0 ? nil : AssistantError.failed)
    }
    private func finish(_ error: Error?) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let process = process
            queue.asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        try? input.fileHandleForWriting.close()
        if !process.isRunning { process.terminationHandler = nil; cleanScratch() }
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
    }
    private func cleanScratch() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        if lifetimeActive { lifetimeActive = false; Self.lifetimes.leave() }
    }
}

struct JSONLines {
    var pending = Data()
    mutating func append(_ data: Data, final: Bool = false) throws -> [[String: Any]] {
        pending.append(data)
        guard pending.count <= 1_000_000 else { throw AssistantError.outputLimit }
        var lines = [Data]()
        while let newline = pending.firstIndex(of: 10) { lines.append(pending[..<newline]); pending.removeSubrange(...newline) }
        if final && !pending.isEmpty { lines.append(pending); pending.removeAll() }
        return try lines.compactMap { line in
            if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AssistantError.invalidResponse }
            return object
        }
    }
}

struct ResponseParser {
    var completed = false
    var accumulated = ""
    mutating func receive(_ event: [String: Any]) throws -> String? {
        let type = event["type"] as? String ?? ""
        var delta: String?
        if type == "stream_event", let body = event["event"] as? [String: Any], let change = body["delta"] as? [String: Any], change["type"] as? String == "text_delta" { delta = change["text"] as? String }
        if type == "result" {
            guard event["is_error"] as? Bool != true, (event["subtype"] as? String ?? "success") == "success" else { throw AssistantError.failed }
            if accumulated.isEmpty { delta = event["result"] as? String }
            completed = true
        }
        if let delta { accumulated += delta; guard accumulated.utf8.count <= 100_000 else { throw AssistantError.outputLimit } }
        return delta
    }
}

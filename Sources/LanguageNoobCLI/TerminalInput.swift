import Foundation
import Darwin

enum TerminalEvent { case line(String), end, interrupt, invalid }

/// Input and signals share one serial queue; no blocking read runs on the session actor.
final class TerminalInput: @unchecked Sendable {
    let events: AsyncStream<TerminalEvent>
    private let continuation: AsyncStream<TerminalEvent>.Continuation
    private let queue = DispatchQueue(label: "language-noob.terminal-input")
    private var input: DispatchSourceRead?
    private var signals = [DispatchSourceSignal]()
    private var buffer = Data()
    private var ended = false

    init() {
        (events, continuation) = AsyncStream.makeStream()
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        input = source
        source.setEventHandler { [weak self] in self?.read() }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: number, queue: queue)
            signalSource.setEventHandler { [weak self] in self?.finish(.interrupt) }
            signalSource.resume(); signals.append(signalSource)
        }
        source.resume()
    }
    private func read() {
        guard !ended else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0 { if errno != EINTR && errno != EAGAIN { finish(.invalid) }; return }
        if count == 0 {
            if !buffer.isEmpty { emitLine(buffer); buffer.removeAll() }
            finish(.end); return
        }
        buffer.append(contentsOf: bytes.prefix(count))
        while let end = buffer.firstIndex(of: 10) {
            emitLine(buffer.prefix(upTo: end))
            buffer.removeSubrange(...end)
        }
        if buffer.count > 8192 { finish(.invalid) }
    }
    private func emitLine(_ data: Data) {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8) else { finish(.invalid); return }
        continuation.yield(.line(text.trimmingCharacters(in: .newlines)))
    }
    private func finish(_ event: TerminalEvent) {
        guard !ended else { return }; ended = true
        continuation.yield(event); continuation.finish(); input?.cancel()
    }
    func stop() { queue.async { [self] in finish(.end); signals.forEach { $0.cancel() }; signals.removeAll() } }
}

enum TerminalText {
    /// Model text is plain text; terminal control sequences never execute.
    static func safe(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
    }
    static func write(_ value: String) { FileHandle.standardOutput.write(Data(safe(value).utf8)) }
    static func error(_ value: String) { FileHandle.standardError.write(Data(safe(value).utf8)) }
}

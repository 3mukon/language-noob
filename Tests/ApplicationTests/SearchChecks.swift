import Foundation
import StudyCore
import StudyStorage

private final class SearchFixture: VocabularySearching, @unchecked Sendable {
    struct Call {
        let query: String
        let language: StudyLanguage
        let onMainThread: Bool
        let continuation: CheckedContinuation<[Word], Error>
    }
    let calls: AsyncStream<Call>
    private let incoming: AsyncStream<Call>.Continuation
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    init() { (calls, incoming) = AsyncStream.makeStream() }
    func search(_ query: String, language: StudyLanguage, limit: Int) async throws -> [Word] {
        // Deliberately allow late completion after cancellation to exercise the
        // controller's ownership checks independently of SQLite cancellation.
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); count += 1; lock.unlock()
            incoming.yield(Call(query: query, language: language, onMainThread: Thread.isMainThread, continuation: continuation))
        }
    }
}

extension ApplicationChecks {
    static func searchLifecycleChecks() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-search-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.sqlite"))
        let word = Word(id: "one", language: .english, text: "one", definition: "一")
        try store.seed([word])
        try store.cacheEnrichment(word)
        let searcher = SearchFixture()
        var calls = searcher.calls.makeAsyncIterator()
        var events = [[String: Any]](), errors = [Error]()
        let (changes, updates) = AsyncStream<Void>.makeStream()
        var changesIterator = changes.makeAsyncIterator()
        let controller = StudyController(store: store, settings: AppSettings(), searcher: searcher,
                                         emit: { events.append($0); updates.yield(()) }, reportError: { errors.append($0) })
        try controller.beginRound()
        func command(_ op: String, query: String = "", request: UUID = UUID()) throws {
            let value: [String: Any] = ["op": op, "roundID": controller.round.id.uuidString,
                                      "query": query, "requestID": request.uuidString, "wordID": word.id]
            try controller.handle(JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        func waitFor(_ request: UUID) async {
            while !events.contains(where: { $0["requestID"] as? String == request.uuidString.lowercased() }) { _ = await changesIterator.next() }
        }
        func settle() async {
            for _ in 0..<4 { await Task.yield() }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        let oldID = UUID(), newID = UUID()
        try command("search", query: "old", request: oldID)
        let old = await calls.next()!
        try check(!old.onMainThread, "the search service runs away from the native UI thread")
        try command("search", query: "one", request: newID)
        let newer = await calls.next()!
        old.continuation.resume(returning: [word])
        newer.continuation.resume(returning: [word])
        await waitFor(newID)
        try check(!events.contains { $0["requestID"] as? String == oldID.uuidString.lowercased() }, "superseded search cannot publish stale results")
        let callCount = searcher.callCount
        try command("browse", query: "one", request: newID)
        try check(controller.round.isBrowsing && searcher.callCount == callCount, "opening a displayed result reuses its ordered snapshot without another query")
        try controller.beginRound()

        let closedID = UUID()
        try command("search", query: "closed", request: closedID)
        let closed = await calls.next()!
        try command("closeLibrary")
        closed.continuation.resume(throwing: StorageError.database("late fixture error"))
        await settle()
        try check(errors.isEmpty && !events.contains { $0["requestID"] as? String == closedID.uuidString.lowercased() }, "closing library discards late search errors")

        let replacedID = UUID()
        try command("browse", query: "one", request: replacedID)
        let replaced = await calls.next()!
        controller.finishRound()
        replaced.continuation.resume(returning: [word])
        await settle()
        try check(controller.round.ended && !controller.round.isBrowsing, "late browsing cannot reopen an ended round")

        try controller.beginRound()
        let languageID = UUID()
        try command("search", query: "one", request: languageID)
        let wrongLanguage = await calls.next()!
        controller.settings.language = .japanese
        try controller.beginRound(announce: true, preserveLibrary: true)
        wrongLanguage.continuation.resume(returning: [word])
        await settle()
        try check(!events.contains { $0["requestID"] as? String == languageID.uuidString.lowercased() }, "changing language invalidates pending search results")
        let replacement = events.last { $0["type"] as? String == "round" }
        try check(controller.isLibraryVisible && replacement?["preserveLibrary"] as? Bool == true && replacement?["announcement"] == nil, "language changes preserve the open library without a temporary round announcement")
        let translatedQuery = UUID()
        try command("search", query: "one", request: translatedQuery)
        let translated = await calls.next()!
        try check(translated.language == .japanese && translated.query == "one", "the retained library query uses only the new language")
        translated.continuation.resume(returning: [])
        await waitFor(translatedQuery)
        try command("closeLibrary")
        try check(!controller.isLibraryVisible, "closing the retained library restores the study context")

        controller.settings.language = .english
        try controller.beginRound()
        let refreshedID = UUID()
        try command("search", query: "one", request: refreshedID)
        let beforeImport = await calls.next()!
        controller.vocabularyDidChange()
        let afterImport = await calls.next()!
        var changed = word; changed.definition = "更新后的释义"
        beforeImport.continuation.resume(returning: [word])
        afterImport.continuation.resume(returning: [changed])
        await waitFor(refreshedID)
        let refreshed = events.last?["words"] as? [[String: String]]
        try check(refreshed?.first?["definition"] == changed.definition, "vocabulary changes refresh the active query and invalidate its previous snapshot")
        controller.cancelWork(); updates.finish()
        print("PASS: asynchronous search ownership, result reuse and lifecycle cancellation")
    }
}

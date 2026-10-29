import Foundation
import SQLite3
import StudyCore
import StudyStorage
import StudyAssistant
import StudyRuntime

private final class PreparationFixture: AssistantServing, @unchecked Sendable {
    struct Call {
        let request: AssistantRequest
        let configuration: AssistantConfiguration
        let continuation: AsyncThrowingStream<String, Error>.Continuation
    }
    let calls: AsyncStream<Call>
    private let incoming: AsyncStream<Call>.Continuation
    private let lock = NSLock()
    private var count = 0
    private var active = 0, peak = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }
    var peakCount: Int { lock.lock(); defer { lock.unlock() }; return peak }
    init() { (calls, incoming) = AsyncStream.makeStream() }
    func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error> {
        lock.lock(); count += 1; active += 1; peak = max(peak, active); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock(); active -= 1; lock.unlock()
            }
            incoming.yield(Call(request: request, configuration: configuration, continuation: continuation))
        }
    }
}

extension LanguageNoobTests {
    @MainActor static func roundEnrichmentQueueTests() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-round-preparation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw TestFailure(message)
        }
        func complete(_ call: PreparationFixture.Call, _ definition: String = "已补全") {
            call.continuation.yield("{\"pronunciation\":\"reading\",\"chinese_def\":\"\(definition)\",\"part_of_speech\":\"名词\",\"examples\":[]}")
            call.continuation.finish()
        }
        let words = (0..<6).map { Word(id: "w\($0)", language: .japanese, text: "語\($0)") }
        let serialDatabase = directory.appendingPathComponent("serial.sqlite")
        let store = try StudyStore(url: serialDatabase)
        try store.seed(words)
        var settings = StudySettings(); settings.language = .japanese; settings.newLimit = 3
        let assistant = PreparationFixture(), session = StudySession(store: store, settings: settings, assistant: assistant)
        var calls = assistant.calls.makeAsyncIterator()
        try session.begin(shuffle: { $0 })
        let firstID = session.round.cards[0].id
        try check(session.preparationState(for: words[1].key) == .queued && session.preparationState(for: words[2].key) == .queued, "unvisited round words enter the queue immediately")
        try await waitUntil("first serial request missing", { assistant.callCount == 1 })
        let first = await calls.next()!
        session.navigate(to: session.round.cards.first { $0.word.key == words[1].key && $0.kind == .recall }!.id)
        session.prepareCurrentWord()
        let duplicate = session.enrich { _ in }, forcedDuplicate = session.enrich(force: true) { _ in }
        try check(!duplicate && !forcedDuplicate, "manual actions cannot duplicate a queued entry")
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(assistant.callCount == 1 && assistant.activeCount == 1, "navigation neither cancels nor duplicates the first serial request")
        complete(first)
        try await waitUntil("second serial request missing", { assistant.callCount == 2 })
        let second = await calls.next()!
        try check(first.request.word.key == words[0].key && second.request.word.key == words[1].key, "serial preparation follows the study order rather than navigation order")
        let anotherStore = try StudyStore(url: serialDatabase)
        var shared = words[2]; shared.definition = "另一个会话已补全"
        try anotherStore.cacheEnrichment(shared)
        complete(second)
        try await waitUntil("serial queue did not drain", { !session.isEnriching })
        try check(assistant.callCount == 2 && assistant.peakCount == 1, "only unique uncached round entries reach the model")
        try check(session.preparationState(for: words[2].key) == .ready && session.round.cards.filter { $0.word.key == words[2].key }.allSatisfy { $0.word.definition == shared.definition }, "dequeue rechecks persistent data written by another client")
        try check(session.round.current?.direction == .wordToMeaning && session.round.current?.revealed == false, "prefetch does not change a prompt already displayed or reveal its answer")
        session.navigate(to: firstID)
        var completion: Result<WordCompletion, Error>?
        session.enrich { completion = $0 }
        try check(try completion?.get().reused == true && assistant.callCount == 2, "ordinary manual completion immediately reuses storage")
        completion = nil
        session.enrich(force: true) { completion = $0 }
        try await waitUntil("confirmed regeneration missing", { assistant.callCount == 3 })
        let failed = await calls.next()!
        failed.continuation.yield("partial invalid result"); failed.continuation.finish()
        try await waitUntil("failed regeneration missing", { completion != nil })
        try check(try store.cachedEnrichment(words[0].key)?.definition == "已补全", "failed regeneration preserves the existing persisted result")
        completion = nil
        session.enrich(force: true) { completion = $0 }
        try await waitUntil("regeneration retry missing", { assistant.callCount == 4 })
        complete(await calls.next()!, "重新生成")
        try await waitUntil("regeneration did not persist", { completion != nil })
        try check(try completion?.get().reused == false && store.cachedEnrichment(words[0].key)?.definition == "重新生成", "confirmed regeneration replaces data only after successful persistence")
        try session.begin(shuffle: { $0 })
        let reopened = StudySession(store: anotherStore, settings: settings, assistant: assistant)
        try reopened.begin(shuffle: { $0 })
        try check(!session.isEnriching && !reopened.isEnriching && assistant.callCount == 4, "later rounds and clients reuse all prefetched results")
        await reopened.shutdown(); await session.shutdown()

        let parallelStore = try StudyStore(url: directory.appendingPathComponent("parallel.sqlite"))
        try parallelStore.seed(words)
        settings.newLimit = 6; settings.assistant.enrichmentConcurrency = 2
        let parallel = PreparationFixture(), pool = StudySession(store: parallelStore, settings: settings, assistant: parallel)
        var parallelCalls = parallel.calls.makeAsyncIterator()
        try pool.begin(shuffle: { $0 })
        try await waitUntil("bounded parallel requests missing", { parallel.callCount == 2 })
        let a = await parallelCalls.next()!, b = await parallelCalls.next()!
        try check(Set([a.request.word.key, b.request.word.key]).count == 2 && parallel.peakCount == 2, "configured concurrency fills unique entries up to its limit")
        pool.settings.assistant.enrichmentConcurrency = 1
        complete(a)
        try await waitUntil("first parallel completion missing", { pool.preparationState(for: a.request.word.key) == .ready })
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(parallel.callCount == 2 && parallel.activeCount == 1, "lowering concurrency leaves active work intact and waits for capacity")
        pool.settings.assistant.enrichmentConcurrency = 3
        try await waitUntil("increased concurrency did not fill", { parallel.callCount == 4 })
        let c = await parallelCalls.next()!, d = await parallelCalls.next()!
        try check(parallel.activeCount == 3 && parallel.peakCount == 3, "raising concurrency fills slots without restarting existing work")
        pool.finish()
        await pool.shutdown()
        for call in [b, c, d] { complete(call, "过期结果") }
        try check(parallel.activeCount == 0 && parallel.callCount == 4, "ending cancels active requests and discards queued words")
        try check(try parallelStore.words(language: .japanese).filter { !$0.definition.isEmpty }.count == 1, "cancelled partial and queued entries never enter storage")

        try pool.begin(shuffle: { $0 })
        try await waitUntil("replacement queue missing", { parallel.callCount == 7 })
        let resumed = [await parallelCalls.next()!, await parallelCalls.next()!, await parallelCalls.next()!]
        try check(resumed.allSatisfy { $0.request.word.key != a.request.word.key }, "replacement skips completed work")
        resumed[0].continuation.finish(throwing: AssistantError.unavailable)
        complete(resumed[1]); complete(resumed[2])
        try await waitUntil("unavailable queue did not stop", { !pool.isEnriching })
        pool.navigate(offset: 1); pool.prepareCurrentWord()
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(parallel.callCount == 7 && parallel.peakCount == 3, "an unavailable service stops pending background attempts without a navigation retry loop")
        await pool.shutdown()
        print("PASS: round prefetch, persisted manual reuse, confirmed regeneration, serial order, bounded concurrency, live limits and queue cancellation")
    }

    @MainActor static func automaticEnrichmentTests() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-preparation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("study.sqlite")
        let store = try StudyStore(url: database)
        let japanese = Word(id: "one", language: .japanese, text: "空", pronunciation: "そら")
        let second = Word(id: "two", language: .japanese, text: "海", pronunciation: "うみ")
        let english = Word(id: "one", language: .english, text: "sky", definition: "天空")
        try store.seed([japanese, second, english])
        var settings = StudySettings(); settings.language = .japanese; settings.newLimit = 1
        let assistant = PreparationFixture()
        var calls = assistant.calls.makeAsyncIterator()
        let session = StudySession(store: store, settings: settings, assistant: assistant)
        func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw TestFailure(message)
        }
        func response(_ definition: String) -> String {
            "{\"pronunciation\":\"そら\",\"chinese_def\":\"\(definition)\",\"part_of_speech\":\"名词\",\"examples\":[{\"sentence\":\"空が青い。\",\"translation\":\"天空很蓝。\"}]}"
        }

        try session.begin(shuffle: { $0 })
        try check(session.preparationState(for: japanese.key) == .loading, "an uncached current word immediately has a visible preparation state")
        session.prepareCurrentWord(); session.prepareCurrentWord()
        try await waitUntil("automatic request did not begin", { assistant.callCount == 1 })
        let first = await calls.next()!
        try check(first.request.enrichment && first.request.word.key == japanese.key && first.request.messages.isEmpty, "automatic enrichment is scoped to one word without conversation context")
        first.continuation.yield("{\"pronunciation\":")
        try check(try store.cachedEnrichment(japanese.key) == nil && session.round.current?.word.definition == "", "partial output cannot replace vocabulary or enter the cache")
        first.continuation.yield(String(response("天空").dropFirst("{\"pronunciation\":".count)))
        first.continuation.finish()
        try await waitUntil("automatic enrichment did not complete", { !session.isEnriching })
        try check(try store.cachedEnrichment(japanese.key)?.definition == "天空", "successful automatic enrichment is persisted")
        try check(session.round.cards.allSatisfy { $0.word.definition == "天空" }, "reading and recall share the saved enrichment")
        session.navigate(offset: 1)
        try check(session.round.current?.direction == .meaningToWord && session.round.current?.revealed == false, "an unseen recall uses the completed Chinese prompt without revealing the answer")
        session.navigate(offset: -1); try session.begin(shuffle: { $0 })
        try check(!session.isEnriching && assistant.callCount == 1, "navigation and later rounds reuse persisted enrichment")
        let reopened = try StudyStore(url: database)
        let other = StudySession(store: reopened, settings: settings, assistant: assistant)
        try other.begin(shuffle: { $0 })
        try check(other.round.current?.word.definition == "天空" && !other.isEnriching, "another frontend reuses the same persisted cache")
        await other.shutdown()

        session.settings.language = .english
        try session.begin(shuffle: { $0 })
        try await waitUntil("English request missing", { assistant.callCount == 2 })
        let unavailable = await calls.next()!
        try check(unavailable.request.word.key == english.key, "identical IDs in different languages do not share enrichment")
        unavailable.continuation.finish(throwing: AssistantError.unavailable)
        try await waitUntil("failure did not settle", { !session.isEnriching })
        session.navigate(offset: 1); session.navigate(offset: -1); session.prepareCurrentWord()
        try check(!session.isEnriching && assistant.callCount == 2 && session.round.current?.word.definition == english.definition, "failure keeps source data and does not retry on every visit")
        var manualResult: Result<WordCompletion, Error>?
        try check(session.enrich { manualResult = $0 }, "explicit regeneration can retry a failed automatic request")
        try await waitUntil("manual retry missing", { assistant.callCount == 3 })
        let malformed = await calls.next()!
        malformed.continuation.yield("not a vocabulary response"); malformed.continuation.finish()
        try await waitUntil("invalid response did not settle", { manualResult != nil })
        try check(try store.cachedEnrichment(english.key) == nil && session.round.current?.word.definition == english.definition, "invalid completion preserves the source and cache")
        manualResult = nil
        session.enrich { manualResult = $0 }
        try await waitUntil("second manual retry missing", { assistant.callCount == 4 })
        let manual = await calls.next()!
        manual.continuation.yield(response("天空；天际")); manual.continuation.finish()
        try await waitUntil("manual persistence did not settle", { manualResult != nil })
        try check(try store.cachedEnrichment(english.key)?.definition == "天空；天际", "manual regeneration remains available and persists")

        session.preparationPaused = true
        session.settings.language = .japanese
        try session.begin(shuffle: { Array($0.reversed()) })
        try check(!session.isEnriching && assistant.callCount == 4, "a library-only language change starts no hidden model request")
        session.preparationPaused = false
        try await waitUntil("resumed preparation missing", { assistant.callCount == 5 })
        let cancelled = await calls.next()!
        session.preparationPaused = true
        cancelled.continuation.yield(response("过期结果")); cancelled.continuation.finish()
        await Task.yield()
        try check(try store.cachedEnrichment(second.key) == nil, "opening the library cancels automatic work before it can save")
        session.preparationPaused = false
        try await waitUntil("returning to study did not resume", { assistant.callCount == 6 })
        let hidden = await calls.next()!
        session.navigate(offset: 1)
        try check(session.round.current?.direction == .wordToMeaning && assistant.callCount == 6, "same-word navigation shares the pending request")
        hidden.continuation.yield(response("大海")); hidden.continuation.finish()
        try await waitUntil("hidden completion missing", { !session.isEnriching })
        try check(session.round.current?.direction == .wordToMeaning && session.round.current?.revealed == false, "a displayed prompt keeps its direction and reveal state when enrichment arrives")

        // A rejected cache write must not update the live word, either.
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw TestFailure("open cache rollback fixture") }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TRIGGER reject_enrichment BEFORE INSERT ON enrichment BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil)
        manualResult = nil
        session.enrich(force: true) { manualResult = $0 }
        try await waitUntil("cache write fixture missing", { assistant.callCount == 7 })
        let rejected = await calls.next()!
        rejected.continuation.yield(response("不可保存")); rejected.continuation.finish()
        try await waitUntil("cache failure did not settle", { manualResult != nil })
        try check(try store.cachedEnrichment(second.key)?.definition == "大海" && session.round.current?.word.definition == "大海", "failed persistence leaves the previous cached and displayed word intact")
        sqlite3_exec(db, "DROP TRIGGER reject_enrichment", nil, nil, nil)

        var obsoleteDelivered = false
        session.enrich(force: true) { _ in obsoleteDelivered = true }
        try await waitUntil("old round request missing", { assistant.callCount == 8 })
        let obsolete = await calls.next()!
        session.finish()
        try session.begin(shuffle: { $0 })
        obsolete.continuation.yield(response("旧轮次")); obsolete.continuation.finish()
        await session.shutdown()
        try check(try !obsoleteDelivered && store.cachedEnrichment(second.key)?.definition == "大海", "ended-round completions cannot alter the next round or persistent data")
        print("PASS: automatic enrichment, per-language cache, partial/invalid output, offline fallback, deduplication, prompt stability and cancellation")
    }
}

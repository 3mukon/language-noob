import Foundation
import StudyCore
import StudyStorage
import StudyAssistant
#if canImport(LanguageNoob)
@testable import LanguageNoob
#endif

private final class EnrichmentFixture: AssistantServing, @unchecked Sendable {
    let calls: AsyncStream<AsyncThrowingStream<String, Error>.Continuation>
    private let incoming: AsyncStream<AsyncThrowingStream<String, Error>.Continuation>.Continuation
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    init() { (calls, incoming) = AsyncStream.makeStream() }
    func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error> {
        lock.lock(); count += 1; lock.unlock()
        return AsyncThrowingStream { incoming.yield($0) }
    }
}

extension ApplicationChecks {
    static func enrichmentChecks() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-enrichment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.sqlite"))
        let word = Word(id: "one", language: .english, text: "one", definition: "original")
        try store.seed([word])
        let assistant = EnrichmentFixture()
        var calls = assistant.calls.makeAsyncIterator()
        var feedback = [[String: Any]]()
        var patches = [[String: Any]]()
        let controller = StudyController(store: store, settings: AppSettings(), assistant: assistant, emit: {
            if $0["type"] as? String == "feedback" || $0["announcement"] != nil { feedback.append($0) }
            if $0["type"] as? String == "patch" { patches.append($0) }
        }, reportError: { _ in })
        func settled() async throws {
            for _ in 0..<100 {
                if !controller.isEnriching { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ApplicationFailure(message: "enrichment did not settle")
        }
        try controller.beginRound()
        let old = await calls.next()!
        func command(_ op: String, card: UUID, question: String? = nil) throws {
            var payload: [String: Any] = ["op": op, "roundID": controller.round.id.uuidString, "cardID": card.uuidString]
            if let question { payload["question"] = question; payload["requestID"] = UUID().uuidString }
            try controller.handle(JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: payload)))
        }
        let readingID = controller.round.cards.first!.id, recallID = controller.round.cards.last!.id
        try command("navigate", card: recallID)
        try command("question", card: recallID, question: "premature question")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try check(assistant.callCount == 1, "unrevealed questions cannot add a request to the automatic preparation")
        try command("navigate", card: readingID)
        controller.enrich()
        try check(controller.isEnriching && assistant.callCount == 1, "repeated enrichment retains the existing owned pending request")
        try controller.beginRound(); controller.enrich()
        let current = await calls.next()!
        let json = "{\"pronunciation\":\"one\",\"chinese_def\":\"fresh\",\"part_of_speech\":\"number\",\"examples\":[]}"
        old.yield(json.replacingOccurrences(of: "fresh", with: "stale")); old.finish()
        // Pass through the main executor so a cancelled old task can finish its cleanup.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        controller.enrich()
        try check(assistant.callCount == 2, "old enrichment cleanup cannot clear the active request")
        current.yield(json); current.finish()
        try await settled()
        await Task.yield()
        try check(patches.last?["roundID"] as? String == controller.round.id.uuidString.lowercased(), "enrichment belongs to the replacement round")
        try check(try store.word(word.key)?.definition == "fresh", "cancelled enrichment never overwrites current data")
        let cards = patches.last?["cards"] as? [[String: Any]]
        try check(cards?.allSatisfy { ($0["word"] as? [String: String])?["definition"] == "fresh" && $0["enrichmentStatus"] == nil } == true, "automatic completion updates the paper and clears loading without a transient announcement")
        try controller.beginRound()
        try check(!controller.isEnriching && assistant.callCount == 2, "a new native round reuses the cache")
        controller.enrich()
        controller.enrich()
        try check(!controller.isEnriching && assistant.callCount == 2, "repeated ordinary manual actions reuse saved data without a request")
        try check(feedback.last?["announcement"] as? String == "词条已补全，已使用本地保存的结果。", "cached manual actions acknowledge reuse")
        try check(controller.hasCurrentEnrichment && controller.canEnrich && controller.enrichmentMenuTitle == "重新生成释义和例句…", "cached entries expose the confirmed regeneration action")
        controller.enrich(force: true)
        let manual = await calls.next()!
        try check(assistant.callCount == 3 && !controller.canEnrich && controller.enrichmentMenuTitle == "正在补全释义和例句…", "only confirmed regeneration starts a new request and disables duplicates")
        controller.enrich(force: true)
        try check(assistant.callCount == 3, "repeated confirmed requests cannot duplicate pending work")
        manual.yield(json); manual.finish()
        try await settled()
        try check(feedback.last?["announcement"] as? String == "词条已补全，已保存到本地。", "confirmed regeneration retains visible completion feedback")
        controller.cancelWork()
        print("PASS: native automatic enrichment, cache reuse, hidden questions, cancellation and generation ownership")
    }
}

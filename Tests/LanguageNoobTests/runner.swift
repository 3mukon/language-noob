import Foundation
import StudyCore
import StudyStorage
import StudyAssistant

struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }

@main
struct LanguageNoobTests {
    static func main() async {
        do {
            try coreTests(); try storageTests(); try await assistantTests()
            try roundRegressionTests(); try storageRegressionTests(); try motionTests(); try protocolRegressionTests()
            try bundledVocabularyTests()
            try await runtimeTests()
            try await automaticEnrichmentTests()
            try await roundEnrichmentQueueTests()
            try await searchTests()
            try await conversationRegressionTests()
            try await apiRegressionTests()
            try localPreferencesTests()
            try await localPreferenceLoadingTests()
            try await codexStreamingTests()
            print("PASS: LanguageNoobTests")
        } catch { f("unexpected error: \(error)") }
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message) } }
    static func f(_ message: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    static func coreTests() throws {
        let word = Word(id: "one", language: .english, text: "one", definition: "一"), now = Date(timeIntervalSince1970: 1_700_000_000)
        var p = StudyCore.Progress(key: word.key, now: now)
        p = Scheduler.review(p, grade: .good, now: now); try check(p.interval == 1 && p.ease == 2.5, "first SM-2 review")
        p = Scheduler.review(p, grade: .good, now: now); try check(p.interval == 6, "second SM-2 review")
        p = Scheduler.review(p, grade: .easy, now: now); try check(p.interval == 16 && p.correct == 3, "easy SM-2 review")
        p = Scheduler.review(p, grade: .again, now: now); try check(p.interval == 1 && p.repetitions == 0 && p.reviews == 4, "lapse reset")
        for _ in 0..<20 { p = Scheduler.review(p, grade: .hard, now: now) }; try check(p.ease == 1.3, "ease floor")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let next = Scheduler.review(StudyCore.Progress(key: word.key, now: date), grade: .good, now: date, calendar: calendar)
        try check(calendar.component(.hour, from: next.due) == 12, "calendar day scheduling")
        let words = (0..<80).map { Word(id: String(format: "%03d", $0), language: .english, text: "word\($0)") }
        for (count, expected) in [(10,10),(11,5),(20,5),(21,0),(40,0)] {
            let records = Dictionary(uniqueKeysWithValues: words.prefix(count).map { ($0.key, StudyCore.Progress(key: $0.key, now: now)) })
            let load = Workload.select(words: words, progress: records, mode: .study, now: now)
            try check(load.reviews.count == min(30, count) && load.newWords.count == expected, "adaptive workload \(count)")
            try check(Workload.select(words: words, progress: records, mode: .study, now: now, newLimit: 7).newWords.count == 7, "explicit new limit")
        }
        var round = StudyRound(cards: [StudyCard(word: word, kind: .recall)]); let id = round.cards[0].id
        try check(!round.canGrade(id), "hidden recall cannot grade"); round.reveal(id); try check(round.canGrade(id), "revealed recall grades")
        round.didGrade(id, grade: .again); round.didGrade(id, grade: .again); try check(round.cards.count == 2 && round.cards[0].id != round.cards[1].id, "one retry card")
        round.end(); try check(round.cards.isEmpty, "round cleanup")
        let valid = Data("{\"version\":\"1.0\",\"language\":\"en\",\"words\":[{\"id\":\"a\",\"text\":\"word\"}]}".utf8)
        let imported = try VocabularyImport(data: valid); try check(imported.words[0].language == .english, "import default language")
        let duplicate = Data("{\"version\":\"1.0\",\"language\":\"en\",\"words\":[{\"id\":\"a\",\"text\":\"word\"},{\"id\":\"a\",\"text\":\"word\"}]}".utf8)
        do { _ = try VocabularyImport(data: duplicate); throw TestFailure("duplicate import accepted") } catch is VocabularyError { }
    }
    static func storageTests() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite"), word = Word(id: "shared", language: .english, text: "solace", definition: "慰藉"), event = UUID()
        do { let store = try StudyStore(url: url); try store.seed([word]); try store.markSeen(word.key); _ = try store.grade(word.key, event: event, grade: .good); _ = try store.grade(word.key, event: event, grade: .again) }
        let reopened = try StudyStore(url: url); let progress = try reopened.progress(language: .english); let stats = try reopened.statistics(language: .english); try check(progress[word.key]?.reviews == 1, "idempotent grade"); try check(stats.totalReviews == 1, "history transaction")
        let json = Data("{\"version\":\"1.0\",\"language\":\"en\",\"words\":[{\"id\":\"shared\",\"text\":\"solace\",\"chinese_def\":\"慰藉\"},{\"id\":\"two\",\"text\":\"solaceful\"}]}".utf8); try reopened.importVocabulary(VocabularyImport(data: json)); let search = try reopened.search("solace", language: .english); try check(search.count == 2, "import search")
        var enriched = word; enriched.pronunciation = "/ˈsɒlɪs/"; enriched.definition = "安慰；慰藉"; try reopened.cacheEnrichment(enriched); let enrichedSearch = try reopened.search("安慰", language: .english); try check(enrichedSearch.count == 1, "enrichment search")
    }
    @MainActor static func assistantTests() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("assistant-fixture")
        let script = """
        #!/bin/sh
        if [ "$1" = '--help' ]; then printf '%s\\n' '--no-session-persistence --include-partial-messages --tools --strict-mcp-config --setting-sources'; exit 0; fi
        cat >/dev/null
        printf '%s\\n' '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"你好"}}}'
        printf '%s\\n' '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"，世界"}}}'
        printf '%s\\n' '{"type":"result","subtype":"success","result":"你好，世界","is_error":false}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = AssistantConfiguration(); config.provider = .claude; config.executablePath = executable.path
        let request = AssistantRequest(word: Word(id: "one", language: .english, text: "one"), messages: [.init(role: .user, content: "解释")])
        var chunks = [String](); for try await chunk in AssistantClient().reply(request, configuration: config) { chunks.append(chunk) }; try check(chunks == ["你好", "，世界"], "real incremental protocol")
        var second = config; second.executablePath = "/bin/sh"
        do { for try await _ in AssistantClient().reply(request, configuration: second) {} ; throw TestFailure("failed provider accepted") } catch is AssistantError { }
        let response = "```json\n{\"pronunciation\":\"そら\",\"chinese_def\":\"天空\",\"part_of_speech\":\"名词\",\"examples\":[]}\n```", original = Word(id: "one", language: .japanese, text: "空")
        let enriched = try AssistantClient.enrichedWord(from: response, original: original); try check(enriched.key == original.key && enriched.definition == "天空", "enrichment identity")
        let recording = RecordingClient(), book = ConversationBook(client: recording), card = UUID(), word = original
        book.submit(card: card, word: word, question: "first", configuration: AssistantConfiguration()) { _ in }
        book.submit(card: card, word: word, question: "second", configuration: AssistantConfiguration()) { _ in }
        for _ in 0..<60 { if book.messages(for: card).count == 4 { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        try check(book.messages(for: card).map(\.content) == ["first", "answer:first", "second", "answer:second"], "ordered temporary context")
        book.endRound(); try check(book.messages(for: card).isEmpty, "conversation cleanup")
    }

}

private final class RecordingClient: AssistantServing, @unchecked Sendable {
    func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await Task.sleep(nanoseconds: 20_000_000); try Task.checkCancellation(); continuation.yield("answer:" + (request.messages.last?.content ?? "")); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

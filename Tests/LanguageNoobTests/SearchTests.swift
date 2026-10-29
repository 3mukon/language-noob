import Foundation
import SQLite3
import StudyCore
@testable import StudyStorage

extension LanguageNoobTests {
    static func searchTests() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite")
        let store = try StudyStore(url: url)
        let exact = Word(id: "exact", language: .english, text: "sol", definition: "安慰；平静")
        let prefix = Word(id: "prefix", language: .english, text: "solar")
        let inside = Word(id: "inside", language: .english, text: "absolutes")
        let meaning = Word(id: "meaning", language: .english, text: "definition", definition: "sol")
        let literal = Word(id: "metadata-only-id", language: .english, text: "literal%_[]*?\"quote")
        let japanese = Word(id: "exact", language: .japanese, text: "𠮷野家", pronunciation: "はるかな", definition: "平静；sol")
        try store.seed([inside, meaning, literal, japanese, prefix, exact])
        let event = UUID()
        try store.grade(exact.key, event: event, grade: .good)
        try check(try store.search(" SOL ", language: .english).map(\.id) == ["exact", "prefix", "inside", "meaning"], "exact, prefix and other substrings retain their ranking")
        try check(try store.search("sol", language: .english, limit: 2).map(\.id) == ["exact", "prefix"], "a bounded result retains higher-ranked words")
        for term in ["%", "_", "[", "*?", "[]*", "\"quote"] {
            try check(try store.search(term, language: .english).map(\.id) == [literal.id], "punctuation remains a literal substring: \(term)")
        }
        for term in ["安", "平静"] {
            try check(try store.search(term, language: .english).map(\.id) == [exact.id], "short Chinese searches remain language-isolated")
        }
        for term in ["はる", "はるか", "𠮷野家"] {
            try check(try store.search(term, language: .japanese).map(\.id) == [japanese.id], "Japanese reading and supplementary Unicode characters remain searchable")
        }
        try check(try store.search("", language: .english).map(\.id) == ["exact", "inside", "meaning", literal.id, "prefix"], "empty-query difficulty and ID order remains stable")

        var enriched = exact
        enriched.definition = "晴朗"; enriched.partOfSpeech = "形容词"
        enriched.examples = [Example(sentence: "sunshine and clear skies", translation: "天空晴朗")]
        try store.cacheEnrichment(enriched)
        for term in ["晴朗", "形容", "sunshine"] {
            try check(try store.search(term, language: .english).map(\.id) == [exact.id], "enrichment values become searchable in the same write")
        }
        for term in ["pronunciation", "chinese_def", "metadata-only-id"] {
            try check(try store.search(term, language: .english).isEmpty, "JSON keys and internal IDs are not vocabulary content")
        }
        enriched.examples = [Example(sentence: "moonlight", translation: "月光")]
        try store.cacheEnrichment(enriched)
        try check(try store.search("sunshine", language: .english).isEmpty, "replacing enrichment removes obsolete index tokens")
        try check(try store.search("moonlight", language: .english).count == 1, "replacing enrichment indexes new tokens")

        let replacement = Data("{\"version\":\"1.0\",\"language\":\"en\",\"words\":[{\"id\":\"exact\",\"text\":\"replacement\",\"chinese_def\":\"更新\"},{\"id\":\"blocked\",\"text\":\"new\"}]}".utf8)
        try searchFixtureSQL(url, "CREATE TRIGGER reject_search_import BEFORE INSERT ON words WHEN NEW.id='blocked' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        do { try store.importVocabulary(VocabularyImport(data: replacement)); throw TestFailure("import failure was ignored") }
        catch StorageError.database { }
        try check(try store.search("moonlight", language: .english).count == 1, "failed import rolls back projection and FTS writes")
        try check(try store.search("replacement", language: .english).isEmpty, "rolled-back imports leave no search ghosts")
        try searchFixtureSQL(url, "DROP TRIGGER reject_search_import")
        try store.importVocabulary(VocabularyImport(data: replacement))
        try check(try store.search("moonlight", language: .english).isEmpty, "successful import removes stale enrichment tokens")
        try check(try store.search("replacement", language: .english).map(\.id) == [exact.id], "successful import updates search results")
        try check(try store.statistics(language: .english).totalReviews == 1, "index updates preserve learning history")

        let worker = store.makeSearchWorker()
        let found = try await worker.search("replacement", language: .english)
        try check(found.map(\.id) == [exact.id], "background connection reuses the persistent search index")
        try store.seed([Word(id: "later", language: .english, text: "later addition")])
        let added = try await worker.search("later", language: .english)
        try check(added.map(\.id) == ["later"], "an existing background connection sees committed vocabulary changes")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.search("later", language: .english)
        }
        do { _ = try await cancelled.value; throw TestFailure("cancelled search returned results") }
        catch is CancellationError { }
        let afterCancellation = try await worker.search("later", language: .english)
        try check(afterCancellation.count == 1, "cancellation leaves the connection reusable")

        let oracle = try StudyStore(url: directory.appendingPathComponent("oracle.sqlite"))
        let alphabet = Array("abcxyz%_[]*?0123456789")
        let corpus = (0..<160).map { index in
            Word(id: String(format: "%03d", index), language: .english,
                 text: String((0..<7).map { alphabet[(index * 7 + $0 * 3) % alphabet.count] }),
                 pronunciation: index % 7 == 0 ? "q" : "a b",
                 definition: index % 2 == 0 ? "平静安宁" : "安慰与恢复")
        }
        try oracle.seed(corpus)
        let terms = ["a", "q", "z", "ab", "ba", "xy", "[%", "?0", "_", "静", "平静", "安慰", "not-found"]
        for term in terms {
            func rank(_ word: Word) -> Int { word.text == term ? 0 : word.text.hasPrefix(term) ? 1 : 2 }
            let expected = corpus.filter { [$0.text, $0.pronunciation, $0.definition].contains { $0.contains(term) } }
                .sorted { left, right in
                    if rank(left) != rank(right) { return rank(left) < rank(right) }
                    if left.text != right.text { return left.text < right.text }
                    return left.id < right.id
                }.prefix(7).map(\.id)
            try check(try oracle.search(term, language: .english, limit: 7).map(\.id) == expected,
                      "short byte candidates are verified against literal fields and ordered correctly: \(term)")
        }

        let coldURL = directory.appendingPathComponent("cold.sqlite")
        let cold = try StudyStore(url: coldURL)
        try cold.seed((0..<2_000).map { Word(id: "\($0)", language: .english, text: "fixture\($0)", definition: "首次索引") })
        var interruptBuild = true, cancellationChecks = 0
        let interrupted = try StudyStore(url: coldURL, searchIsCancelled: {
            cancellationChecks += 1
            return interruptBuild && cancellationChecks >= 10
        })
        do { _ = try interrupted.search("fixture", language: .english); throw TestFailure("cancelled index build returned results") }
        catch is CancellationError { }
        try check(cancellationChecks >= 10, "cancellation occurs during SQLite execution, after the entry check")
        try check(try searchFixtureCount(coldURL, "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'library_%'") == 0,
                  "cancelled construction removes every partial index table and trigger")
        try check(try cold.words(language: .english).count == 2_000, "cancellation preserves the authoritative vocabulary")
        interruptBuild = false
        let rebuilt = try interrupted.search("fixture", language: .english)
        try check(rebuilt.count == 100, "an interrupted lazy build rolls back and can be retried")
        let reopened = try await cold.makeSearchWorker().search("fixture", language: .english)
        try check(reopened == rebuilt, "a background connection can reuse the rebuilt persistent index")
        print("PASS: literal indexed search, atomic refresh, background reads and cancellation")
    }

    private static func searchFixtureSQL(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw TestFailure("search fixture open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure("search fixture SQL") }
    }

    private static func searchFixtureCount(_ url: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw TestFailure("search fixture open") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw TestFailure("search fixture count") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

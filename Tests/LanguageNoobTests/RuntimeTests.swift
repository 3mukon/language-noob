import Foundation
import SQLite3
import StudyCore
import StudyStorage
import StudyAssistant
import StudyRuntime

extension LanguageNoobTests {
    @MainActor static func runtimeTests() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("study.sqlite")
        let store = try StudyStore(url: database)
        let words = (0..<4).map { Word(id: "w\($0)", language: .english, text: "word\($0)", definition: "释义\($0)") }
        try store.seed(words + [Word(id: "ja", language: .japanese, text: "空", pronunciation: "そら")])
        for word in try store.words(language: .english) + store.words(language: .japanese) { try store.cacheEnrichment(word) }
        var settings = StudySettings(); settings.newLimit = 2
        let session = StudySession(store: store, settings: settings)
        try session.begin(shuffle: { Array($0.reversed()) })
        let cards = session.round.cards
        try check(cards.map(\.word.id) == ["w3", "w2", "w2", "w3"], "shared runtime samples before quota and reshuffles recall")
        session.navigate(offset: -1)
        try check(session.round.currentID == cards.last!.id, "shared manual previous wraps first to last")
        session.navigate(offset: 1)
        try check(session.round.currentID == cards.first!.id, "shared manual next wraps last to first")
        try check(try store.progress(language: .english).isEmpty, "manual navigation never writes progress")
        let recall = cards[2]
        session.navigate(to: recall.id)
        try check(try !session.grade(recall.id, as: .good), "shared grade requires reveal")
        try check(!session.question(card: recall.id, requestID: UUID(), text: "hidden") { _ in }, "hidden cards cannot invoke AI")
        session.reveal(recall.id)
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw TestFailure("open rollback fixture") }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TRIGGER reject_grade BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil)
        do { _ = try session.grade(recall.id, as: .good); throw TestFailure("failed grade accepted") } catch is StorageError { }
        try check(!session.round.current!.graded && session.round.currentID == recall.id && session.round.pending.count == 2, "failed persistence cannot advance session")
        sqlite3_exec(db, "DROP TRIGGER reject_grade", nil, nil, nil)
        try check(try session.grade(recall.id, as: .again), "grade succeeds after storage recovers")
        try check(try !session.grade(recall.id, as: .good), "shared duplicate grade remains idempotent")
        let otherClient = try StudyStore(url: database)
        try check(try otherClient.statistics(language: .english).totalReviews == 1, "another frontend observes committed history")
        session.advanceAfterGrade()
        try check(session.round.currentID == cards[3].id && session.round.cards.last?.kind == .retry, "grade advancement preserves retry sequence")
        let position = session.round.currentID
        let browseID = session.browse([words[0], words[1]], selecting: words[0].key)!
        session.navigate(offset: -1)
        try check(session.round.current?.word.key == words[1].key, "shared library wraps only query results")
        session.returnToStudy()
        try check(session.round.currentID == position && !session.round.isBrowsing, "library return preserves study position")
        _ = session.browse([words[0]], selecting: words[0].key)
        _ = session.practice(browseID)
        try check(!session.round.isBrowsing && session.round.cards.filter { $0.word.key == words[0].key && $0.requiresGrade }.count == 1, "shared practice appends one assessment")
        let summary = session.finish()
        try check(summary.completed == 1 && summary.remaining == 3 && session.round.ended, "shared ending counts assessments, not reading")
        session.settings.language = .japanese
        try session.begin()
        try check(session.round.cards.allSatisfy { $0.word.language == .japanese }, "replacement session cannot mix language")
        try check(session.browse(words, selecting: words[0].key) == nil, "cross-language browse rejected")
        session.finish()

        let file = directory.appendingPathComponent("settings.json")
        let initial = StudySettings()
        var firstWrite = initial; firstWrite.newLimit = 7
        try firstWrite.save(to: file, replacing: initial)
        try check(StudySettings.load(from: file).settings.newLimit == 7, "partial first save includes required defaults")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        raw["futurePreference"] = "preserved"
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let baseline = StudySettings.load(from: file).settings
        var desktop = baseline; desktop.language = .japanese; desktop.assistant.enrichmentConcurrency = 3
        try desktop.save(to: file, replacing: baseline)
        var terminal = baseline; terminal.assistant.provider = .codex; terminal.assistant.effort = "high"; terminal.newLimit = nil
        let merged = try terminal.save(to: file, replacing: baseline)
        try check(merged.language == .japanese && merged.assistant.effort == "high" && merged.assistant.enrichmentConcurrency == 3 && merged.newLimit == nil, "settings merge preserves unrelated concurrent edits including enrichment concurrency and clears optionals")
        raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try check(raw["futurePreference"] as? String == "preserved", "settings preserve unknown unrelated fields")
        let before = try Data(contentsOf: file)
        var invalid = merged; invalid.assistant.effort = "unsupported"
        do { try invalid.save(to: file, replacing: merged); throw TestFailure("invalid settings saved") } catch is AssistantError { }
        try check(try Data(contentsOf: file) == before, "invalid merged preferences leave previous file intact")
        print("PASS: shared session transitions, language isolation, write rollback, cross-client persistence and settings merge")
    }
}

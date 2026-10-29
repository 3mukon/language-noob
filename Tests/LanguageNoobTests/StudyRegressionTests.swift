import Foundation
import SQLite3
import StudyCore
import StudyStorage

extension LanguageNoobTests {
    static func roundRegressionTests() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let words = (0..<4).map { Word(id: "\($0)", language: .english, text: "word\($0)", definition: "释义\($0)") }
        let progress = Dictionary(uniqueKeysWithValues: words.prefix(2).map { ($0.key, StudyCore.Progress(key: $0.key, now: now)) })
        let load = Workload.select(words: words, progress: progress, mode: .study, now: now, shuffle: { $0 })
        let cards = load.cards(shuffle: { $0.reversed() })
        try check(cards.map(\.kind) == [.review, .review, .introduction, .introduction, .recall, .recall], "review, introduction, shuffled recall phases")
        try check(cards[0].direction == .meaningToWord && cards[1].direction == .wordToMeaning, "batch alternates directions")
        try check(cards[4].word.key == words[3].key, "recall uses injectable shuffle")
        try check(Workload.select(words: words, progress: progress, mode: .study, now: now, newLimit: 0).newWords.isEmpty, "explicit zero quota")
        try check(Workload.select(words: words, progress: progress, mode: .review, now: now).newWords.isEmpty, "review mode excludes new words")
        try check(Workload.select(words: words, progress: progress, mode: .learn, now: now).reviews.isEmpty, "learn mode excludes due words")
        let randomized = Workload.select(words: words, progress: progress, mode: .study, now: now, newLimit: 1, shuffle: { $0.reversed() })
        try check(randomized.newWords.map(\.key) == [words[3].key], "new-word sampling shuffles the eligible pool before applying the quota")
        try check(randomized.reviews.map(\.key) == [words[1].key, words[0].key], "selected reviews are shuffled instead of using dictionary order")
        let many = (0..<40).map { Word(id: String(format:"%03d",$0), language:.english,text:"word\($0)") }
        let dueRecords = Dictionary(uniqueKeysWithValues: many.enumerated().map { index, word -> (WordKey,StudyCore.Progress) in
            var value = StudyCore.Progress(key:word.key,now:now); value.due=now.addingTimeInterval(Double(index-40));return (word.key,value)
        })
        let dueBatch = Workload.select(words:many, progress:dueRecords, mode:.review, now:now, shuffle:{ $0.reversed() })
        try check(dueBatch.reviews.map(\.key) == many.prefix(30).reversed().map(\.key), "random review order still selects the thirty earliest due entries")

        let blank = StudyCard(word: Word(id: "blank", language: .japanese, text: "空"), kind: .review)
        try check(!blank.revealed && blank.direction == .wordToMeaning, "missing definition uses a hidden word prompt")
        var round = StudyRound(cards: cards)
        round.navigate(to: cards.last!.id)
        try check(round.pending.map(\.kind) == [.review, .review, .recall, .recall] && round.reviewCount == 0, "reading is not an assessment and navigation does not grade")
        round.didGrade(cards[2].id, grade: .good)
        try check(!round.canGrade(cards[2].id) && round.reviewCount == 0, "reading papers cannot be graded")
        round.reveal(cards[0].id)
        round.didGrade(cards[0].id, grade: .again)
        try check(round.cards[2].kind == .retry && round.cards[3].kind == .introduction, "due retry stays before introduction")
        let retryID = round.cards[2].id
        round.reveal(retryID); round.didGrade(retryID, grade: .again)
        try check(round.cards.filter { $0.kind == .retry }.count == 1, "retry cannot recurse")
        round.didGrade(cards[0].id, grade: .good)
        try check(round.reviewCount == 2, "grade acknowledgement is idempotent")

        let existingIDs = Set(round.cards.map(\.id))
        let studyPosition = round.currentID
        let browseID = round.browse([words[3], words[1], words[2], words[3]], selecting: words[1].key)!
        try check(round.isBrowsing && round.visibleCards.map(\.word.key) == [words[3].key, words[1].key, words[2].key], "library uses the result order without duplicate or study cards")
        try check(round.currentID == round.visibleCards[1].id && !round.navigate(to: studyPosition!), "library opens the selected result and rejects hidden study navigation")
        try check(round.reviewCount == 2 && round.pending.count == 3, "browsing changes no assessments")
        round.navigate(to: round.visibleCards.last!.id)
        round.returnToStudy()
        try check(!round.isBrowsing && round.currentID == studyPosition && round.visibleCards.allSatisfy { $0.kind != .browse }, "returning restores the study position and excludes library cards")
        try check(round.browse([words[1]], selecting: words[1].key) == browseID && round.visibleCards.count == 1, "a filtered single result reuses its own card identity")
        let practiceBrowse = round.browse(words, selecting: words[3].key)!
        let destination = round.practice(practiceBrowse)
        try check(existingIDs.isSubset(of: Set(round.cards.map(\.id))), "library preserves round and conversation identities")
        try check(destination == cards[3].id && !round.isBrowsing, "practice returns to pending learning instead of duplicating it")
        let fresh = Word(id: "fresh", language: .english, text: "fresh", definition: "新鲜")
        let newBrowse = round.browse([fresh], selecting: fresh.key)!
        let newID = round.practice(newBrowse)
        try check(round.cards.suffix(2).map(\.kind) == [.introduction, .recall] && round.currentID == newID, "new library word appends a learning pair")
        let size = round.cards.count
        round.practice(newBrowse)
        try check(round.cards.count == size, "repeated practice does not duplicate pending work")
        let recallID = round.cards.last!.id
        round.reveal(recallID)
        round.didGrade(recallID, grade: .good)
        let nextIntroduction = round.practice(newBrowse)
        try check(nextIntroduction != newID && round.cards.count == size + 2, "completed practice creates a fresh reading and recall pair")
        try check(round.practice(newBrowse) == nextIntroduction && round.cards.count == size + 2, "new practice reuses its own introduction rather than an older paper")
        round.end()
        try check(round.current == nil && round.cards.isEmpty && round.browse([fresh], selecting: fresh.key) == nil, "ended round cannot be resurrected")
        var empty = StudyRound(cards: [])
        try check(empty.browse([], selecting: fresh.key) == nil && !empty.isBrowsing, "empty or stale searches cannot enter library browsing")
        empty.browse([fresh], selecting: fresh.key)
        empty.returnToStudy()
        try check(empty.currentID == nil && empty.visibleCards.isEmpty && !empty.ended, "returning from library to an empty workload is not a completed assessment")
        print("PASS: round state and workload regressions")
    }

    static func storageRegressionTests() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite")
        let a = Word(id: "same", language: .english, text: "same", definition: "相同")
        let b = Word(id: "same", language: .japanese, text: "同じ", definition: "一样")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let event = UUID()
        do {
            let store = try StudyStore(url: url)
            try store.seed([a, b])
            let first = try store.grade(a.key, event: event, grade: .good, now: now)
            let duplicate = try store.grade(a.key, event: event, grade: .again, now: now)
            try check(first == duplicate, "duplicate grade preserves the original result")
            do { try store.grade(b.key, event: event, grade: .good); throw TestFailure("cross-word event was accepted") }
            catch StorageError.conflictingEvent { }
            try check(try store.progress(language: .japanese).isEmpty, "event conflict writes no progress")

            try fixtureSQL(url, "CREATE TRIGGER reject_progress BEFORE INSERT ON progress BEGIN SELECT RAISE(ABORT,'fixture'); END")
            do { try store.grade(b.key, event: UUID(), grade: .good); throw TestFailure("forced write failure was ignored") }
            catch StorageError.database { }
            try fixtureSQL(url, "DROP TRIGGER reject_progress")
            try check(try store.statistics(language: .japanese).totalReviews == 0, "failed progress write rolls back history")

            var enriched = a; enriched.definition = "缓存释义"
            try store.cacheEnrichment(enriched)
            let replacement = Data("{\"version\":\"1.0\",\"language\":\"en\",\"words\":[{\"id\":\"same\",\"text\":\"same\",\"chinese_def\":\"更新释义\"},{\"id\":\"new\",\"text\":\"new\"}]}".utf8)
            try fixtureSQL(url, "CREATE TRIGGER reject_word BEFORE INSERT ON words WHEN NEW.id='new' BEGIN SELECT RAISE(ABORT,'fixture'); END")
            do { try store.importVocabulary(VocabularyImport(data: replacement)); throw TestFailure("forced import failure was ignored") }
            catch StorageError.database { }
            try check(try store.word(a.key)?.definition == "缓存释义", "failed import restores vocabulary and enrichment")
            try fixtureSQL(url, "DROP TRIGGER reject_word")
            try store.importVocabulary(VocabularyImport(data: replacement))
            try check(try store.word(a.key)?.definition == "更新释义", "successful import replaces stale enrichment")
            try check(try store.progress(language: .english)[a.key]?.reviews == 1, "import preserves progress")
        }
        let reopened = try StudyStore(url: url)
        try check(try reopened.statistics(language: .english).totalReviews == 1, "restart retains atomic history")
        try check(try reopened.word(b.key)?.text == "同じ", "language keys remain independent")
        try fixtureSQL(url, "PRAGMA user_version=2")
        do { _ = try StudyStore(url: url); throw TestFailure("future schema was accepted") }
        catch StorageError.unsupportedVersion { }
        try check(FileManager.default.fileExists(atPath: url.path), "future database is never deleted")
        print("PASS: storage identity, rollback and compatibility regressions")
    }

    private static func fixtureSQL(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw TestFailure("fixture database open") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw TestFailure("fixture SQL") }
    }
}

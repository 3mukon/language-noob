import Foundation
import SQLite3
import StudyCore
import StudyStorage

extension LanguageNoobTests {
    static func bundledVocabularyTests() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/StudyRuntime/Resources")
        func read(_ name: String) throws -> [Word] { try VocabularyImport(data: Data(contentsOf: resources.appendingPathComponent(name))).words }
        let english = try read("dictionary-en.json"), japanese = try read("dictionary-ja.json")
        let samples = try read("sample-en.json") + read("sample-ja.json")
        try check(english.count == 12_126 && japanese.count == 8_505, "bundled dictionaries retain their required source counts")
        try check(Set((english + japanese).map(\.key)).count == 20_631, "source readings and repeated records retain distinct stable identities")
        try check(japanese.allSatisfy { !$0.pronunciation.isEmpty && $0.definition.isEmpty }, "Japanese source readings are preserved without fabricated translations")
        let directory = URL(fileURLWithPath: "/private/tmp/language-noob-bundle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite"), version = "fixture"
        let store = try StudyStore(url: url)
        let started = Date()
        try store.installBundledVocabulary(english + japanese, version: version, legacySamples: samples)
        let elapsed = Date().timeIntervalSince(started)
        try check(try store.words(language: .english).count == 12_126 && store.words(language: .japanese).count == 8_505, "fresh installs have exactly both dictionaries, not additional samples")
        try store.installBundledVocabulary(english + japanese, version: version)
        let reopened = try StudyStore(url: url)
        try check(try reopened.hasBundledVocabulary(version), "the installation marker persists across launches")
        for language in StudyLanguage.allCases {
            let words = try reopened.words(language: language)
            let load = Workload.select(words: words, progress: [:], mode: .learn, now: Date())
            try check(load.cards().allSatisfy { $0.word.language == language }, "a learning round contains only its selected language")
            let search = try reopened.search("a", language: language)
            try check(search.allSatisfy { $0.language == language }, "search cannot leak another language")
        }
        let migration = try StudyStore(url: directory.appendingPathComponent("migration.sqlite"))
        try migration.seed(samples)
        let sample = samples.first { sample in english.contains { $0.text == sample.text } }!
        let destination = english.first { $0.text == sample.text }!
        let event = UUID()
        try migration.grade(sample.key, event: event, grade: .good)
        var enriched = sample; enriched.definition = "retained enrichment"
        try migration.cacheEnrichment(enriched)
        let originalProgress = try migration.progress(language: .english)[sample.key]!
        let unmatched = samples.first { sample in !((english + japanese).contains { $0.language == sample.language && $0.text == sample.text }) }!
        try migration.grade(unmatched.key, event: UUID(), grade: .easy)
        try migration.installBundledVocabulary(english + japanese, version: version, legacySamples: samples)
        let moved = try migration.progress(language: .english)[destination.key]!
        try check(moved.reviews == originalProgress.reviews && moved.due == originalProgress.due && moved.key == destination.key, "sample progress migrates to the corresponding dictionary identity")
        try check(try migration.word(destination.key)?.definition == "retained enrichment" && migration.word(sample.key) == nil, "sample enrichment follows its word without duplicate samples")
        try check(try migration.word(unmatched.key) != nil && migration.progress(language: unmatched.language)[unmatched.key]?.reviews == 1, "unmatched samples with saved work are retained")
        try migration.grade(destination.key, event: event, grade: .again)
        try check(try migration.statistics(language: .english).totalReviews == (unmatched.language == .english ? 2 : 1), "migrated history retains event identity and prevents regrading")
        var custom = english[10]; custom.definition = "custom import"
        let importData = try JSONSerialization.data(withJSONObject: ["version":"1.0", "language":"en", "words":[JSONSerialization.jsonObject(with: JSONEncoder().encode(custom))]])
        try migration.importVocabulary(VocabularyImport(data: importData))
        try migration.installBundledVocabulary(english + japanese, version: "next", legacySamples: samples)
        try check(try migration.word(custom.key)?.definition == "custom import", "a later bundle never overwrites user imports")

        // Force failure after the first insert to prove corpus and marker atomicity.
        let failureURL = directory.appendingPathComponent("failure.sqlite")
        let failure = try StudyStore(url: failureURL)
        _ = try failure.hasBundledVocabulary(version)
        var db: OpaquePointer?
        sqlite3_open(failureURL.path, &db)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TRIGGER reject_bundle BEFORE INSERT ON words WHEN NEW.id='reject' BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil)
        do {
            try failure.installBundledVocabulary([Word(id:"accept",language:.english,text:"first"), Word(id:"reject",language:.english,text:"second")], version: version)
            throw TestFailure("partial dictionary installation succeeded")
        } catch is StorageError { }
        try check(try failure.words(language: .english).isEmpty && !failure.hasBundledVocabulary(version), "failed installation rolls back entries and its marker")
        print("PASS: bundled counts, language isolation, idempotence, sample migration and rollback (initial insert \(Int(elapsed * 1000)) ms)")
    }
}

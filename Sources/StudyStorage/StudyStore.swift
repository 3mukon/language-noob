import Foundation
import SQLite3
import StudyCore

public struct StudyStatistics: Codable, Equatable {
    public var vocabulary: Int
    public var learned: Int
    public var mastered: Int
    public var due: Int
    public var totalReviews: Int
    public var todayReviews: Int
    public var accuracy: Double
    public var streak: Int
}

public enum StorageError: Error, LocalizedError {
    case database(String), unsupportedVersion, missingWord, conflictingEvent
    public var errorDescription: String? {
        switch self {
        case .database: return "无法读写学习数据，请检查存储空间和文件权限。"
        case .unsupportedVersion: return "数据来自较新的应用版本，请更新应用后再打开。"
        case .missingWord: return "词库中已找不到这张卡片。"
        case .conflictingEvent: return "这次复习记录与原词条不一致，请重新打开学习轮次。"
        }
    }
}

/// Use from one serial executor. No conversation data is accepted by this interface.
public final class StudyStore {
    private var database: OpaquePointer?
    private let url: URL
    private var searchIndexReady = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let searchIsCancelled: () -> Bool

    public convenience init(url: URL) throws {
        try self.init(url: url, searchIsCancelled: { Task<Never, Never>.isCancelled })
    }

    // The cancellation source is injectable so SQLite interruption can be
    // verified at an execution checkpoint instead of a scheduler-dependent delay.
    init(url: URL, searchIsCancelled: @escaping () -> Bool) throws {
        self.url = url
        self.searchIsCancelled = searchIsCancelled
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil; throw StorageError.database("open")
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            let version = try integers("PRAGMA user_version").first ?? 0
            guard version <= 1 else { throw StorageError.unsupportedVersion }
            try execute("PRAGMA journal_mode = WAL")
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE words (language TEXT NOT NULL, id TEXT NOT NULL, text TEXT NOT NULL, reading TEXT NOT NULL, definition TEXT NOT NULL, difficulty INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(language,id))")
                    try execute("CREATE TABLE progress (language TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(language,id), FOREIGN KEY(language,id) REFERENCES words(language,id))")
                    try execute("CREATE TABLE history (event TEXT PRIMARY KEY, language TEXT NOT NULL, id TEXT NOT NULL, grade INTEGER NOT NULL CHECK(grade IN (1,3,4,5)), at REAL NOT NULL, FOREIGN KEY(language,id) REFERENCES words(language,id))")
                    try execute("CREATE INDEX history_language_time ON history(language,at)")
                    try execute("CREATE TABLE enrichment (language TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(language,id), FOREIGN KEY(language,id) REFERENCES words(language,id))")
                    try execute("PRAGMA user_version = 1")
                }
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }

    public func importVocabulary(_ imported: VocabularyImport) throws {
        try writeWords(imported.words, replacing: true)
    }
    public func seed(_ words: [Word]) throws { try writeWords(words, replacing: false) }

    private func writeWords(_ words: [Word], replacing: Bool) throws {
        for word in words { try VocabularyImport.validate(word) }
        try transaction { for word in words { try writeWord(word, replacing: replacing) } }
    }

    private func writeWord(_ word: Word, replacing: Bool) throws {
        let conflict = replacing ? "DO UPDATE SET text=excluded.text, reading=excluded.reading, definition=excluded.definition, difficulty=excluded.difficulty, body=excluded.body" : "DO NOTHING"
        try execute("INSERT INTO words VALUES(?,?,?,?,?,?,?) ON CONFLICT(language,id) \(conflict)",
                    [.text(word.language.rawValue), .text(word.id), .text(word.text), .text(word.pronunciation), .text(word.definition), .integer(word.difficulty), .text(try json(word))])
        if replacing { try execute("DELETE FROM enrichment WHERE language=? AND id=?", keyValues(word.key)) }
    }

    public func hasBundledVocabulary(_ version: String) throws -> Bool {
        try execute("CREATE TABLE IF NOT EXISTS bundled_vocabulary (version TEXT PRIMARY KEY)")
        return try integers("SELECT COUNT(*) FROM bundled_vocabulary WHERE version=?", [.text(version)]).first == 1
    }

    /// Install once in one transaction. Existing user records always win.
    public func installBundledVocabulary(_ words: [Word], version: String, legacySamples: [Word] = []) throws {
        guard try !hasBundledVocabulary(version) else { return }
        for word in words { try VocabularyImport.validate(word) }
        let grouped = Dictionary(grouping: words, by: { $0.language.rawValue + "\0" + $0.text })
        try transaction {
            // Another process may have installed the same bundle while waiting.
            guard try integers("SELECT COUNT(*) FROM bundled_vocabulary WHERE version=?", [.text(version)]).first == 0 else { return }
            for word in words { try writeWord(word, replacing: false) }
            for sample in legacySamples {
                var original: Word?
                try query("SELECT body FROM words WHERE language=? AND id=?", keyValues(sample.key)) { original = try decode(Word.self, text($0, 0)) }
                // An imported or edited sample is user content, not disposable.
                guard original == sample else { continue }
                let target = grouped[sample.language.rawValue + "\0" + sample.text]?.first {
                    sample.language == .english || $0.pronunciation == sample.pronunciation
                }
                var progress: StudyCore.Progress?, enrichment: Word?
                try query("SELECT body FROM progress WHERE language=? AND id=?", keyValues(sample.key)) { progress = try decode(StudyCore.Progress.self, text($0, 0)) }
                try query("SELECT body FROM enrichment WHERE language=? AND id=?", keyValues(sample.key)) { enrichment = try decode(Word.self, text($0, 0)) }
                let histories = try integers("SELECT COUNT(*) FROM history WHERE language=? AND id=?", keyValues(sample.key)).first ?? 0
                if let target, target.key != sample.key {
                    let conflicts = try integers("SELECT (SELECT COUNT(*) FROM progress WHERE language=? AND id=?) + (SELECT COUNT(*) FROM enrichment WHERE language=? AND id=?)", keyValues(target.key) + keyValues(target.key)).first ?? 0
                    guard conflicts == 0, try word(target.key)?.text == sample.text else { continue }
                    if var value = progress {
                        value.key = target.key
                        try execute("INSERT INTO progress VALUES(?,?,?)", keyValues(target.key) + [.text(try json(value))])
                    }
                    if var value = enrichment {
                        value.id = target.id
                        try execute("INSERT INTO enrichment VALUES(?,?,?)", keyValues(target.key) + [.text(try json(value))])
                    }
                    try execute("UPDATE history SET id=? WHERE language=? AND id=?", [.text(target.id)] + keyValues(sample.key))
                } else if progress != nil || enrichment != nil || histories > 0 {
                    continue
                }
                try execute("DELETE FROM progress WHERE language=? AND id=?", keyValues(sample.key))
                try execute("DELETE FROM enrichment WHERE language=? AND id=?", keyValues(sample.key))
                try execute("DELETE FROM words WHERE language=? AND id=?", keyValues(sample.key))
            }
            try execute("INSERT INTO bundled_vocabulary VALUES(?)", [.text(version)])
        }
    }

    public func words(language: StudyLanguage) throws -> [Word] {
        try readWords("WHERE w.language=? ORDER BY w.difficulty,w.id", [.text(language.rawValue)])
    }
    public func word(_ key: WordKey) throws -> Word? { try readWords("WHERE w.language=? AND w.id=?", keyValues(key)).first }

    public func makeSearchWorker() -> StudySearch { StudySearch(url: url) }

    public func search(_ query: String, language: StudyLanguage, limit: Int = 100) throws -> [Word] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let limit = min(200, max(1, limit))
        // This connection belongs to its caller's serial executor. Cancellation
        // interrupts SQLite itself, including first-use index construction.
        sqlite3_progress_handler(database, 1_000, { context in
            let owner = Unmanaged<StudyStore>.fromOpaque(context!).takeUnretainedValue()
            return owner.searchIsCancelled() ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        do {
            try checkSearchCancellation()
            try prepareSearchIndex()
            try execute("BEGIN")
            do {
                let words = try indexedSearch(query, language: language, limit: limit)
                try execute("COMMIT")
                return words
            } catch {
                sqlite3_progress_handler(database, 0, nil, nil)
                try? execute("ROLLBACK")
                throw error
            }
        } catch {
            try checkSearchCancellation()
            throw error
        }
    }

    private func checkSearchCancellation() throws {
        if searchIsCancelled() { throw CancellationError() }
    }

    private func prepareSearchIndex() throws {
        guard !searchIndexReady else { return }
        let exists = try integers("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('library_search','library_search_short')").first == 2
        if !exists {
            try transaction {
                // Another connection may have completed the same lazy build.
                let needsProjection = try integers("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='library_search'").first == 0
                if needsProjection {
                    for sql in WordSearchIndex.schema { try execute(sql) }
                }
                if try integers("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='library_search_short'").first == 0 {
                    for sql in WordSearchIndex.shortSchema { try execute(sql) }
                    try execute("INSERT INTO library_search_short(rowid,word,reading,definition,supplement) SELECT rowid,\(WordSearchIndex.shortValues()) FROM library_search")
                }
                if needsProjection { try execute(WordSearchIndex.refresh()) }
            }
        }
        searchIndexReady = true
    }

    private func indexedSearch(_ term: String, language: StudyLanguage, limit: Int) throws -> [Word] {
        var ids = [String]()
        func select(_ tail: String, _ values: [Value]) throws {
            try query("SELECT s.id FROM library_search s \(tail) LIMIT ?", values + [.integer(limit - ids.count)]) {
                ids.append(self.text($0, 0))
            }
        }
        let lang = Value.text(language.rawValue)
        if term.isEmpty {
            try select("WHERE s.language=? ORDER BY s.difficulty,s.id", [lang])
        } else {
            try select("WHERE s.language=? AND s.word=? ORDER BY s.sort_text,s.id", [lang, .text(term)])
            if ids.count < limit {
                let prefix = term.replacingOccurrences(of: "[", with: "[[]")
                    .replacingOccurrences(of: "*", with: "[*]").replacingOccurrences(of: "?", with: "[?]") + "*"
                try select("WHERE s.language=? AND s.word GLOB ? AND s.word<>? ORDER BY s.sort_text,s.id", [lang, .text(prefix), .text(term)])
            }
            if ids.count < limit {
                let longQuery = term.unicodeScalars.count >= 3
                let table = longQuery ? "library_search_fts" : "library_search_short"
                let phrase = longQuery ? "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : WordSearchIndex.shortQuery(term)
                var values = [lang, .text(phrase)]
                values += Array(repeating: .text(term), count: 5)
                try select("""
                    JOIN \(table) f ON f.rowid=s.rowid WHERE s.language=? AND \(table) MATCH ? AND instr(s.word,?)<>1
                    AND (instr(s.word,?)>0 OR instr(s.reading,?)>0 OR instr(s.definition,?)>0 OR instr(s.supplement,?)>0)
                    ORDER BY s.sort_text,s.id
                    """, values)
            }
        }
        try checkSearchCancellation()
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let words = try readWords("WHERE w.language=? AND w.id IN (\(placeholders))", [lang] + ids.map(Value.text))
        let byID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private func readWords(_ tail: String, _ bindings: [Value]) throws -> [Word] {
        var result = [Word]()
        try query("SELECT w.body,e.body FROM words w LEFT JOIN enrichment e ON w.language=e.language AND w.id=e.id \(tail)", bindings) { statement in
            var word = try self.decode(Word.self, text(statement, 0))
            if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                let enriched = try self.decode(Word.self, text(statement, 1))
                word.pronunciation = enriched.pronunciation; word.definition = enriched.definition
                word.partOfSpeech = enriched.partOfSpeech; word.examples = enriched.examples
            }
            result.append(word)
        }
        return result
    }

    /// Distinguishes an enriched entry from a complete-looking source entry.
    public func cachedEnrichment(_ key: WordKey) throws -> Word? {
        let count = try integers("SELECT COUNT(*) FROM enrichment WHERE language=? AND id=?", keyValues(key)).first ?? 0
        return count == 0 ? nil : try word(key)
    }

    public func cacheEnrichment(_ enriched: Word) throws {
        try VocabularyImport.validate(enriched)
        guard let original = try word(enriched.key), original.text == enriched.text else { throw StorageError.missingWord }
        try execute("INSERT INTO enrichment VALUES(?,?,?) ON CONFLICT(language,id) DO UPDATE SET body=excluded.body", keyValues(enriched.key) + [.text(try json(enriched))])
    }

    public func progress(language: StudyLanguage) throws -> [WordKey: StudyCore.Progress] {
        var records = [WordKey: StudyCore.Progress]()
        try query("SELECT body FROM progress WHERE language=?", [.text(language.rawValue)]) { statement in
            let value = try self.decode(Progress.self, text(statement, 0)); records[value.key] = value
        }
        return records
    }
    public func markSeen(_ key: WordKey, now: Date = Date()) throws {
        try execute("INSERT INTO progress VALUES(?,?,?) ON CONFLICT(language,id) DO NOTHING", keyValues(key) + [.text(try json(Progress(key: key, now: now)))])
    }

    private func progress(for key: WordKey) throws -> StudyCore.Progress? {
        var result: StudyCore.Progress?
        try query("SELECT body FROM progress WHERE language=? AND id=?", keyValues(key)) { statement in
            result = try self.decode(Progress.self, self.text(statement, 0))
        }
        return result
    }

    /// The card UUID makes retries idempotent. History and scheduling commit together.
    @discardableResult public func grade(_ key: WordKey, event: UUID, grade: Grade, now: Date = Date(), calendar: Calendar = .current) throws -> StudyCore.Progress {
        try transaction {
            guard try word(key) != nil else { throw StorageError.missingWord }
            let old = try progress(for: key) ?? StudyCore.Progress(key: key, now: now)
            var recorded = false
            try query("SELECT language,id FROM history WHERE event=?", [.text(event.uuidString)]) { statement in
                guard self.text(statement, 0) == key.language.rawValue, self.text(statement, 1) == key.id else {
                    throw StorageError.conflictingEvent
                }
                recorded = true
            }
            if recorded { return old }
            let next = Scheduler.review(old, grade: grade, now: now, calendar: calendar)
            try execute("INSERT INTO history VALUES(?,?,?,?,?)", [.text(event.uuidString)] + keyValues(key) + [.integer(grade.rawValue), .real(now.timeIntervalSince1970)])
            try execute("INSERT INTO progress VALUES(?,?,?) ON CONFLICT(language,id) DO UPDATE SET body=excluded.body", keyValues(key) + [.text(try json(next))])
            return next
        }
    }

    public func statistics(language: StudyLanguage, now: Date = Date(), calendar: Calendar = .current) throws -> StudyStatistics {
        let records = Array(try progress(language: language).values)
        var dates = [Date](); var correct = 0
        try query("SELECT grade,at FROM history WHERE language=? ORDER BY at DESC", [.text(language.rawValue)]) { statement in
            if sqlite3_column_int(statement, 0) >= 3 { correct += 1 }
            dates.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
        }
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: now), streak = 0
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(day) { streak += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        return StudyStatistics(vocabulary: try integers("SELECT COUNT(*) FROM words WHERE language=?", [.text(language.rawValue)]).first ?? 0,
                               learned: records.count, mastered: records.filter { $0.interval >= 21 && $0.repetitions >= 3 }.count,
                               due: records.filter { $0.due <= now }.count, totalReviews: dates.count,
                               todayReviews: dates.filter { calendar.isDate($0, inSameDayAs: now) }.count,
                               accuracy: dates.isEmpty ? 0 : Double(correct) / Double(dates.count), streak: streak)
    }

    private enum Value { case text(String), integer(Int), real(Double) }
    private func keyValues(_ key: WordKey) -> [Value] { [.text(key.language.rawValue), .text(key.id)] }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try decoder.decode(type, from: Data(value.utf8)) }
    private func statement(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StorageError.database("prepare") }
        do {
            for (index, value) in bindings.enumerated() {
                let position = Int32(index + 1), status: Int32
                switch value {
                case .text(let text): status = sqlite3_bind_text(statement, position, text, -1, transient)
                case .integer(let number): status = sqlite3_bind_int64(statement, position, sqlite3_int64(number))
                case .real(let number): status = sqlite3_bind_double(statement, position, number)
                }
                guard status == SQLITE_OK else { throw StorageError.database("bind") }
            }
        } catch { sqlite3_finalize(statement); throw error }
        return statement
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
    private func execute(_ sql: String, _ bindings: [Value] = []) throws { try query(sql, bindings) { _ in } }
    private func query(_ sql: String, _ bindings: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        let statement = try statement(sql, bindings); defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw StorageError.database("step") }
            try row(statement)
        }
    }
    private func integers(_ sql: String, _ bindings: [Value] = []) throws -> [Int] {
        var values = [Int](); try query(sql, bindings) { values.append(Int(sqlite3_column_int64($0, 0))) }; return values
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

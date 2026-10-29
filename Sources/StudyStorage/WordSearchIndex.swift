import Foundation

/// Rebuildable search data. The authoritative vocabulary/progress schema stays
/// unchanged; triggers keep this projection and its FTS index in the same commit.
enum WordSearchIndex {
    // Hex encodes even one CJK character or two ASCII characters into enough
    // trigrams to find candidates. detail=none keeps only document membership;
    // the query must verify the original fields to reject byte-boundary matches.
    static func shortValues(_ prefix: String = "") -> String {
        ["word", "reading", "definition", "supplement"].map { "'G'||hex(\(prefix)\($0))||'G'" }.joined(separator: ",")
    }

    static var shortSchema: [String] {
        [
            """
            CREATE VIRTUAL TABLE library_search_short USING fts5(word,reading,definition,supplement,
              content='',tokenize='trigram case_sensitive 1',detail=none)
            """,
            """
            CREATE TRIGGER library_short_insert AFTER INSERT ON library_search BEGIN
              INSERT INTO library_search_short(rowid,word,reading,definition,supplement)
              VALUES(NEW.rowid,\(shortValues("NEW.")));
            END
            """,
            """
            CREATE TRIGGER library_short_delete AFTER DELETE ON library_search BEGIN
              INSERT INTO library_search_short(library_search_short,rowid,word,reading,definition,supplement)
              VALUES('delete',OLD.rowid,\(shortValues("OLD.")));
            END
            """,
            """
            CREATE TRIGGER library_short_update AFTER UPDATE ON library_search BEGIN
              INSERT INTO library_search_short(library_search_short,rowid,word,reading,definition,supplement)
              VALUES('delete',OLD.rowid,\(shortValues("OLD.")));
              INSERT INTO library_search_short(rowid,word,reading,definition,supplement)
              VALUES(NEW.rowid,\(shortValues("NEW.")));
            END
            """
        ]
    }

    static func shortQuery(_ term: String) -> String {
        let hex = Array(term.utf8.map { String(format: "%02X", $0) }.joined())
        if hex.count == 2 {
            // A single ASCII byte may be at either end of a field. G is a
            // non-hex boundary marker; enumerate its adjacent hex nibble too.
            let pair = String(hex)
            let terms = Set("0123456789ABCDEFG".flatMap { [String($0) + pair, pair + String($0)] })
            return terms.sorted().map { "\"" + $0 + "\"" }.joined(separator: " OR ")
        }
        return Set((0..<(hex.count - 2)).map { String(hex[$0..<($0 + 3)]) })
            .sorted().map { "\"" + $0 + "\"" }.joined(separator: " AND ")
    }

    static func refresh(_ predicate: String = "") -> String {
        """
        INSERT INTO library_search(language,id,word,reading,definition,supplement,sort_text,difficulty)
        SELECT w.language,w.id,lower(w.text),lower(w.reading),lower(w.definition),
          lower(COALESCE((SELECT group_concat(CAST(atom AS TEXT),char(10)) FROM json_tree(e.body)
            WHERE type='text' AND key IN ('pronunciation','chinese_def','part_of_speech','sentence','translation')),'')),
          w.text,w.difficulty
        FROM words w LEFT JOIN enrichment e ON w.language=e.language AND w.id=e.id
        WHERE 1 \(predicate)
        ON CONFLICT(language,id) DO UPDATE SET word=excluded.word,reading=excluded.reading,
          definition=excluded.definition,supplement=excluded.supplement,sort_text=excluded.sort_text,difficulty=excluded.difficulty
        """
    }

    static var schema: [String] {
        var statements = [
            """
            CREATE TABLE library_search(language TEXT NOT NULL,id TEXT NOT NULL,word TEXT NOT NULL,
              reading TEXT NOT NULL,definition TEXT NOT NULL,supplement TEXT NOT NULL,
              sort_text TEXT NOT NULL,difficulty INTEGER NOT NULL,PRIMARY KEY(language,id))
            """,
            "CREATE INDEX library_search_order ON library_search(language,sort_text,id)",
            "CREATE INDEX library_search_default ON library_search(language,difficulty,id)",
            "CREATE INDEX library_search_prefix ON library_search(language,word,sort_text,id)",
            """
            CREATE VIRTUAL TABLE library_search_fts USING fts5(word,reading,definition,supplement,
              content='library_search',content_rowid='rowid',tokenize='trigram')
            """,
            """
            CREATE TRIGGER library_search_insert AFTER INSERT ON library_search BEGIN
              INSERT INTO library_search_fts(rowid,word,reading,definition,supplement)
              VALUES(NEW.rowid,NEW.word,NEW.reading,NEW.definition,NEW.supplement);
            END
            """,
            """
            CREATE TRIGGER library_search_delete AFTER DELETE ON library_search BEGIN
              INSERT INTO library_search_fts(library_search_fts,rowid,word,reading,definition,supplement)
              VALUES('delete',OLD.rowid,OLD.word,OLD.reading,OLD.definition,OLD.supplement);
            END
            """,
            """
            CREATE TRIGGER library_search_update AFTER UPDATE ON library_search BEGIN
              INSERT INTO library_search_fts(library_search_fts,rowid,word,reading,definition,supplement)
              VALUES('delete',OLD.rowid,OLD.word,OLD.reading,OLD.definition,OLD.supplement);
              INSERT INTO library_search_fts(rowid,word,reading,definition,supplement)
              VALUES(NEW.rowid,NEW.word,NEW.reading,NEW.definition,NEW.supplement);
            END
            """
        ]
        for table in ["words", "enrichment"] {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let record = event == "DELETE" ? "OLD" : "NEW"
                var body = refresh("AND w.language=\(record).language AND w.id=\(record).id") + ";"
                if table == "words" && event == "DELETE" {
                    body = "DELETE FROM library_search WHERE language=OLD.language AND id=OLD.id;"
                } else if event == "UPDATE" {
                    body = "DELETE FROM library_search WHERE language=OLD.language AND id=OLD.id;" + body
                }
                statements.append("CREATE TRIGGER library_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN \(body) END")
            }
        }
        return statements
    }
}

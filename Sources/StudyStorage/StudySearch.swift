import Foundation
import StudyCore

public protocol VocabularySearching: Sendable {
    func search(_ query: String, language: StudyLanguage, limit: Int) async throws -> [Word]
}

/// A separate actor and SQLite connection keep index building, queries and
/// decoding off the UI executor without sharing StudyStore's mutable state.
public actor StudySearch: VocabularySearching {
    private let url: URL
    private var store: StudyStore?

    public init(url: URL) { self.url = url }

    public func search(_ query: String, language: StudyLanguage, limit: Int = 100) throws -> [Word] {
        try Task.checkCancellation()
        if store == nil { store = try StudyStore(url: url) }
        return try store!.search(query, language: language, limit: limit)
    }
}

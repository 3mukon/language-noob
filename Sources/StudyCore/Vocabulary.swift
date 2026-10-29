import Foundation

public enum StudyLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en", japanese = "ja"
}

public struct WordKey: Hashable, Codable, Sendable {
    public let language: StudyLanguage
    public let id: String
    public init(language: StudyLanguage, id: String) { self.language = language; self.id = id }
}

public struct Example: Codable, Equatable, Sendable {
    public var sentence: String
    public var translation: String
    public init(sentence: String, translation: String) { self.sentence = sentence; self.translation = translation }
}

public struct Word: Codable, Equatable, Sendable {
    public var id: String
    public var language: StudyLanguage
    public var text: String
    public var pronunciation: String
    public var definition: String
    public var difficulty: Int
    public var partOfSpeech: String
    public var examples: [Example]
    public var tags: [String]
    public var key: WordKey { WordKey(language: language, id: id) }

    public init(id: String, language: StudyLanguage, text: String, pronunciation: String = "", definition: String = "", difficulty: Int = 1, partOfSpeech: String = "", examples: [Example] = [], tags: [String] = []) {
        self.id = id; self.language = language; self.text = text; self.pronunciation = pronunciation
        self.definition = definition; self.difficulty = difficulty; self.partOfSpeech = partOfSpeech
        self.examples = examples; self.tags = tags
    }
    enum CodingKeys: String, CodingKey {
        case id, language, text, pronunciation, difficulty, examples, tags
        case definition = "chinese_def", partOfSpeech = "part_of_speech"
    }
}

public enum VocabularyError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct VocabularyImport {
    public static let maximumBytes = 20 * 1024 * 1024
    public let language: StudyLanguage
    public let words: [Word]

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw VocabularyError.invalid("词库文件不能超过 20 MB。") }
        struct Entry: Decodable {
            let id: String; let language: StudyLanguage?; let text: String
            let pronunciation: String?; let chinese_def: String?; let difficulty: Int?
            let part_of_speech: String?; let examples: [Example]?; let tags: [String]?
        }
        struct Document: Decodable { let version: String; let language: StudyLanguage; let words: [Entry] }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw VocabularyError.invalid("词库格式不正确，请检查 JSON 字段和语言（en 或 ja）。") }
        guard document.version == "1.0" else { throw VocabularyError.invalid("仅支持 version 为 1.0 的词库。") }
        guard !document.words.isEmpty, document.words.count <= 50_000 else { throw VocabularyError.invalid("词库应包含 1 到 50,000 个词条。") }
        var keys = Set<WordKey>()
        var result = [Word]()
        for entry in document.words {
            let word = Word(id: entry.id.trimmingCharacters(in: .whitespacesAndNewlines), language: entry.language ?? document.language,
                            text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines), pronunciation: entry.pronunciation ?? "",
                            definition: entry.chinese_def ?? "", difficulty: entry.difficulty ?? 1,
                            partOfSpeech: entry.part_of_speech ?? "", examples: entry.examples ?? [], tags: entry.tags ?? [])
            guard word.language == document.language else { throw VocabularyError.invalid("同一词库内的语言必须一致。") }
            try Self.validate(word)
            guard keys.insert(word.key).inserted else { throw VocabularyError.invalid("词库中存在重复的词条 ID：\(word.id)") }
            result.append(word)
        }
        language = document.language; words = result
    }

    public static func validate(_ word: Word) throws {
        let fields = [word.id, word.text, word.pronunciation, word.definition, word.partOfSpeech] + word.tags + word.examples.flatMap { [$0.sentence, $0.translation] }
        guard !word.id.isEmpty, word.id.count <= 200, !word.text.isEmpty, word.text.count <= 200,
              word.pronunciation.count <= 500, word.definition.count <= 4_000, word.partOfSpeech.count <= 100,
              (1...3).contains(word.difficulty), word.examples.count <= 10, word.tags.count <= 30,
              fields.allSatisfy({ $0.count <= 4_000 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) }) else {
            throw VocabularyError.invalid("词条字段为空、过长或包含无效内容：\(word.id.prefix(60))")
        }
    }
}

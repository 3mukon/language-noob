import Foundation

public enum CardKind: String, Codable, Sendable { case introduction, recall, review, retry, browse }
public enum RecallDirection: String, Codable, Sendable { case meaningToWord, wordToMeaning }

public struct StudyCard: Identifiable, Sendable {
    public let id: UUID
    public var word: Word
    public let kind: CardKind
    private let preferredDirection: RecallDirection
    private var displayedDirection: RecallDirection?
    public var direction: RecallDirection {
        displayedDirection ?? (word.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .wordToMeaning : preferredDirection)
    }
    public internal(set) var revealed: Bool
    public internal(set) var graded = false

    public init(word: Word, kind: CardKind, direction: RecallDirection = .meaningToWord) {
        id = UUID()
        self.word = word
        self.kind = kind
        preferredDirection = direction
        revealed = kind == .introduction || kind == .browse
    }

    fileprivate mutating func markDisplayed() { displayedDirection = direction }

    public var requiresGrade: Bool {
        switch kind {
        case .introduction, .browse: return false
        case .recall, .review, .retry: return true
        }
    }
}

/// Pure round state. Persist an operation successfully before acknowledging it here.
/// Navigation never implies that a card was learned or graded.
public struct StudyRound {
    public let id = UUID()
    public private(set) var cards: [StudyCard]
    public private(set) var currentID: UUID?
    public private(set) var ended = false
    private var retried = Set<WordKey>()
    private var browseIDs: [UUID]?
    private var studyCurrentID: UUID?

    public init(cards: [StudyCard]) {
        self.cards = cards
        currentID = cards.first?.id
        markCurrentDisplayed()
    }

    public var current: StudyCard? { cards.first { $0.id == currentID } }
    public var isBrowsing: Bool { browseIDs != nil }
    public var visibleCards: [StudyCard] {
        guard let browseIDs else { return cards.filter { $0.kind != .browse } }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        return browseIDs.compactMap { byID[$0] }
    }
    public var pending: [StudyCard] { cards.filter { $0.requiresGrade && !$0.graded } }
    public var reviewCount: Int { cards.filter(\.graded).count }

    @discardableResult public mutating func navigate(to id: UUID) -> Bool {
        guard !ended, visibleCards.contains(where: { $0.id == id }) else { return false }
        currentID = id
        markCurrentDisplayed()
        return true
    }

    public mutating func reveal(_ id: UUID) {
        guard !ended, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].revealed = true
    }

    public func canGrade(_ id: UUID) -> Bool {
        guard !ended, let card = cards.first(where: { $0.id == id }) else { return false }
        return card.requiresGrade && card.revealed && !card.graded
    }

    public mutating func didGrade(_ id: UUID, grade: Grade) {
        guard canGrade(id), let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].graded = true
        let card = cards[index]
        guard grade == .again, retried.insert(card.word.key).inserted else { return }
        let retry = StudyCard(word: card.word, kind: .retry, direction: card.direction)
        // Finish due reviews, including their retry pass, before introducing new words.
        let destination = card.kind == .review
            ? cards.firstIndex(where: { $0.kind == .introduction || $0.kind == .recall }) ?? cards.endIndex
            : cards.endIndex
        cards.insert(retry, at: destination)
    }

    /// Search order belongs to this view; it never changes the study sequence.
    @discardableResult public mutating func browse(_ words: [Word], selecting key: WordKey) -> UUID? {
        guard !ended, words.contains(where: { $0.key == key }) else { return nil }
        if !isBrowsing { studyCurrentID = currentID }
        let existing = Dictionary(uniqueKeysWithValues: cards.filter { $0.kind == .browse }.map { ($0.word.key, $0.id) })
        var seen = Set<WordKey>(), order = [UUID]()
        for word in words where seen.insert(word.key).inserted {
            let id: UUID
            if let retained = existing[word.key] {
                id = retained
                updateWord(word)
            } else {
                let card = StudyCard(word: word, kind: .browse)
                cards.append(card)
                id = card.id
            }
            order.append(id)
            if word.key == key { currentID = id }
        }
        browseIDs = order
        markCurrentDisplayed()
        return currentID
    }

    public mutating func returnToStudy() {
        guard !ended, isBrowsing else { return }
        browseIDs = nil
        currentID = visibleCards.first(where: { $0.id == studyCurrentID })?.id ?? visibleCards.first?.id
        studyCurrentID = nil
        markCurrentDisplayed()
    }

    /// Retains all existing cards and temporary conversation identities.
    @discardableResult public mutating func practice(_ id: UUID) -> UUID? {
        guard !ended, let card = cards.first(where: { $0.id == id && $0.kind == .browse }) else { return nil }
        if let index = cards.firstIndex(where: { $0.word.key == card.word.key && $0.requiresGrade && !$0.graded }) {
            let assessment = cards[index]
            // An unrevealed recall can still use its preceding reading paper.
            let introduction = assessment.kind == .recall && !assessment.revealed
                ? cards[..<index].last(where: { $0.kind == .introduction && $0.word.key == card.word.key }) : nil
            currentID = introduction?.id ?? assessment.id
        } else {
            let introduction = StudyCard(word: card.word, kind: .introduction)
            cards += [introduction, StudyCard(word: card.word, kind: .recall)]
            currentID = introduction.id
        }
        browseIDs = nil
        studyCurrentID = nil
        markCurrentDisplayed()
        return currentID
    }

    private mutating func markCurrentDisplayed() {
        if let index = cards.firstIndex(where: { $0.id == currentID }) { cards[index].markDisplayed() }
    }

    public mutating func updateWord(_ word: Word) {
        guard !ended else { return }
        for index in cards.indices where cards[index].word.key == word.key && cards[index].word.text == word.text {
            cards[index].word = word
        }
    }

    public mutating func end() {
        ended = true
        currentID = nil
        cards.removeAll()
        retried.removeAll()
        browseIDs = nil
        studyCurrentID = nil
    }
}

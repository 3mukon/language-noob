import Foundation
import StudyCore
import StudyStorage
import StudyAssistant

public struct RoundSummary: Equatable {
    public let completed: Int
    public let remaining: Int
}

public enum WordPreparation: Equatable {
    case idle, queued, loading, ready, failed(String)
}

public struct WordCompletion {
    public let word: Word
    public let reused: Bool
}

/// Shared effects. A frontend chooses when to paint; persistence always precedes acknowledgement.
@MainActor public final class StudySession {
    public let store: StudyStore
    public var settings: StudySettings {
        didSet {
            var transport = settings.assistant
            transport.enrichmentConcurrency = oldValue.assistant.enrichmentConcurrency
            if transport != oldValue.assistant {
                cancelEnrichment(); preparation.removeAll(); preparationStopped = false; prepareCurrentWord()
            } else if settings.assistant.enrichmentConcurrency != oldValue.assistant.enrichmentConcurrency {
                startNextEnrichment()
            }
        }
    }
    public private(set) var round = StudyRound(cards: [])
    private let conversations: ConversationBook
    private let assistant: any AssistantServing
    private struct PreparationRequest {
        let word: Word
        let force: Bool
        let receive: ((Result<WordCompletion, Error>) -> Void)?
    }
    private struct ActivePreparation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var activeEnrichments = [WordKey: ActivePreparation]()
    private var enrichmentQueue = [PreparationRequest]()
    private var preparationStopped = false
    private var preparation = [WordKey: WordPreparation]()
    public var preparationChanged: ((Set<WordKey>) -> Void)?
    private var pendingPreparationChanges = [UUID: Set<WordKey>]()
    /// A library panel has no active learning paper and must not launch model requests.
    public var preparationPaused = false {
        didSet {
            guard preparationPaused != oldValue else { return }
            if preparationPaused { cancelEnrichment() }
            else { prepareCurrentWord() }
        }
    }
    private var cleanup: Task<Void, Never>?
    public var isEnriching: Bool { !activeEnrichments.isEmpty }

    public init(store: StudyStore, settings: StudySettings, assistant: any AssistantServing = AssistantClient()) {
        self.store = store; self.settings = settings; self.assistant = assistant
        conversations = ConversationBook(client: assistant)
    }

    public func begin(now: Date = Date(), shuffle: ([Word]) -> [Word] = { $0.shuffled() }) throws {
        let words = try store.words(language: settings.language)
        let progress = try store.progress(language: settings.language)
        let workload = Workload.select(words: words, progress: progress, mode: settings.mode, now: now,
                                       newLimit: settings.newLimit, shuffle: shuffle)
        cancelWork()
        preparation.removeAll()
        preparationStopped = false
        round = StudyRound(cards: workload.cards(shuffle: shuffle))
        prepareCurrentWord()
    }

    @discardableResult public func navigate(to id: UUID) -> Bool {
        guard round.navigate(to: id) else { return false }
        prepareCurrentWord(); return true
    }
    @discardableResult public func navigate(offset: Int) -> Bool {
        let cards = round.visibleCards
        guard !cards.isEmpty, let index = cards.firstIndex(where: { $0.id == round.currentID }) else { return false }
        return navigate(to: cards[((index + offset % cards.count) % cards.count + cards.count) % cards.count].id)
    }
    @discardableResult public func reveal(_ id: UUID) -> Bool {
        guard !round.ended, round.currentID == id else { return false }
        round.reveal(id); return true
    }
    @discardableResult public func grade(_ id: UUID, as grade: Grade, now: Date = Date()) throws -> Bool {
        guard let card = round.current, card.id == id, round.canGrade(id) else { return false }
        try store.grade(card.word.key, event: id, grade: grade, now: now)
        round.didGrade(id, grade: grade)
        return true
    }
    /// Grading advances through the sequence; manual navigation remains circular.
    @discardableResult public func advanceAfterGrade() -> Bool {
        guard !round.isBrowsing, let card = round.current, card.graded,
              let index = round.visibleCards.firstIndex(where: { $0.id == card.id }) else { return false }
        let cards = round.visibleCards
        if index + 1 < cards.count { return navigate(to: cards[index + 1].id) }
        if let pending = round.pending.first { return navigate(to: pending.id) }
        return false
    }
    @discardableResult public func browse(_ words: [Word], selecting key: WordKey) -> UUID? {
        guard key.language == settings.language else { return nil }
        let words = words.filter { $0.language == settings.language }
        guard words.contains(where: { $0.key == key }) else { return nil }
        if round.ended { cancelWork(); round = StudyRound(cards: []) }
        let id = round.browse(words, selecting: key)
        prepareCurrentWord(); return id
    }
    @discardableResult public func practice(_ id: UUID) -> UUID? {
        let result = round.practice(id); prepareCurrentWord(); return result
    }
    public func returnToStudy() { round.returnToStudy(); prepareCurrentWord() }

    @discardableResult public func question(card id: UUID, requestID: UUID, text: String,
                                            receive: @escaping (ConversationBook.Event) -> Void) -> Bool {
        guard !round.ended, let card = round.current, card.id == id, card.revealed else { return false }
        let roundID = round.id
        conversations.submit(card: id, requestID: requestID, word: card.word, question: text, configuration: settings.assistant) { [weak self] event in
            guard let self, self.round.id == roundID, !self.round.ended else { return }
            receive(event)
        }
        return true
    }

    @discardableResult public func finish() -> RoundSummary {
        let result = RoundSummary(completed: round.reviewCount, remaining: round.pending.count)
        cancelWork(); round.end()
        return result
    }
    public func cancelEnrichment() {
        let keys = enrichmentQueue.map(\.word.key) + Array(activeEnrichments.keys)
        enrichmentQueue.removeAll()
        let tasks = activeEnrichments.values.map(\.task)
        activeEnrichments.removeAll()
        for task in tasks { task.cancel() }
        settle(tasks)
        for key in keys where preparation[key] == .loading || preparation[key] == .queued {
            preparation.removeValue(forKey: key); notifyPreparation(key)
        }
    }
    public func cancelWork() { settle(conversations.endRound()); cancelEnrichment() }
    public func cancelCurrentReply() {
        if let id = round.currentID { settle(conversations.cancel(card: id)) }
        let keys = enrichmentQueue.map(\.word.key) + Array(activeEnrichments.keys)
        cancelEnrichment()
        preparationStopped = true
        for key in keys { preparation[key] = .failed("已停止补全，可手动重试。"); notifyPreparation(key) }
    }
    public func shutdown() async { cancelWork(); await cleanup?.value }
    private func settle(_ tasks: [Task<Void, Never>]) {
        guard !tasks.isEmpty else { return }
        let previous = cleanup
        cleanup = Task { await previous?.value; for task in tasks { await task.value } }
    }

    public func preparationState(for key: WordKey) -> WordPreparation { preparation[key] ?? .idle }

    /// Queue the round once in study order; browsing adds only the explicitly opened word.
    public func prepareCurrentWord() {
        guard !preparationPaused, !preparationStopped, !round.ended, let card = round.current,
              card.word.language == settings.language else { return }
        let candidates = [card.word] + round.cards.filter { $0.kind != .browse }.map(\.word)
        var seen = Set<WordKey>()
        for word in candidates where word.language == settings.language && seen.insert(word.key).inserted {
            guard preparationState(for: word.key) == .idle else { continue }
            do {
                if try reuseEnrichment(for: word) != nil { continue }
                enrichmentQueue.append(PreparationRequest(word: word, force: false, receive: nil))
                preparation[word.key] = .queued
                notifyPreparation(word.key)
            } catch {
                preparation[word.key] = .failed("读取本地释义失败，暂用词库原文。")
                notifyPreparation(word.key)
            }
        }
        startNextEnrichment()
    }

    /// Manual completion has the same cache and duplicate-request boundary as automatic work.
    @discardableResult public func enrich(force: Bool = false, receive: @escaping (Result<WordCompletion, Error>) -> Void) -> Bool {
        guard !preparationPaused, let card = round.current, !round.ended else { return false }
        let state = preparationState(for: card.word.key)
        guard state != .loading && state != .queued else { return false }
        do {
            if !force, let cached = try reuseEnrichment(for: card.word) {
                receive(.success(WordCompletion(word: cached, reused: true))); return true
            }
        } catch { receive(.failure(error)); return true }
        enrichmentQueue.insert(PreparationRequest(word: card.word, force: force, receive: receive), at: 0)
        preparation[card.word.key] = .queued
        notifyPreparation(card.word.key)
        startNextEnrichment()
        return true
    }

    private func reuseEnrichment(for word: Word) throws -> Word? {
        guard let cached = try store.cachedEnrichment(word.key), cached.text == word.text else { return nil }
        let previous = preparationState(for: word.key)
        let changed = cached != word || (previous != .idle && previous != .ready)
        round.updateWord(cached); preparation[word.key] = .ready
        if changed { notifyPreparation(word.key) }
        return cached
    }

    private func startNextEnrichment() {
        guard !preparationPaused, !round.ended else { return }
        let roundID = round.id
        let limit = min(8, max(1, settings.assistant.enrichmentConcurrency))
        while round.id == roundID && !round.ended && !preparationPaused && activeEnrichments.count < limit && !enrichmentQueue.isEmpty {
            let request = enrichmentQueue.removeFirst()
            guard request.word.language == settings.language else { continue }
            do {
                // Another client may have completed this entry while it waited in our queue.
                if !request.force, let cached = try reuseEnrichment(for: request.word) {
                    request.receive?(.success(WordCompletion(word: cached, reused: true))); continue
                }
            } catch {
                preparation[request.word.key] = .failed("读取本地释义失败，暂用词库原文。")
                notifyPreparation(request.word.key); request.receive?(.failure(error)); continue
            }
            startEnrichment(request)
        }
    }

    private func startEnrichment(_ request: PreparationRequest) {
        let word = request.word
        let token = UUID(), roundID = round.id, configuration = settings.assistant
        let previousCleanup = cleanup
        preparation[word.key] = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // A replacement queue waits for the cancelled request to release its resources.
                await previousCleanup?.value
                if request.receive == nil { try await Task.sleep(nanoseconds: 120_000_000) }
                try Task.checkCancellation()
                var response = ""
                for try await text in assistant.reply(AssistantRequest(word: word, messages: [], enrichment: true), configuration: configuration) {
                    try Task.checkCancellation(); response += text
                    guard response.utf8.count <= 100_000 else { throw AssistantError.outputLimit }
                }
                try Task.checkCancellation()
                guard activeEnrichments[word.key]?.id == token, round.id == roundID, !round.ended else { return }
                let enriched = try AssistantClient.enrichedWord(from: response, original: word)
                try store.cacheEnrichment(enriched)
                round.updateWord(enriched)
                finishEnrichment(token, key: word.key, state: .ready)
                request.receive?(.success(WordCompletion(word: enriched, reused: false)))
                startNextEnrichment()
            } catch {
                if !Task.isCancelled, activeEnrichments[word.key]?.id == token, round.id == roundID {
                    let message = (error as? AssistantError)?.localizedDescription ?? "补全未完成，请稍后重试。"
                    finishEnrichment(token, key: word.key, state: .failed(message))
                    if Self.stopsPreparation(error) { stopPreparation(error, message: message) }
                    request.receive?(.failure(error))
                    startNextEnrichment()
                }
            }
        }
        activeEnrichments[word.key] = ActivePreparation(id: token, task: task)
        notifyPreparation(word.key)
    }

    private func finishEnrichment(_ token: UUID, key: WordKey, state: WordPreparation) {
        guard activeEnrichments[key]?.id == token else { return }
        activeEnrichments.removeValue(forKey: key)
        preparation[key] = state
        notifyPreparation(key)
    }

    private static func stopsPreparation(_ error: Error) -> Bool {
        guard let error = error as? AssistantError else { return false }
        switch error {
        case .configuration, .unavailable, .unsupported, .endpoint, .modelRequired, .missingKey, .keyStore, .authentication, .rateLimited: return true
        default: return false
        }
    }

    private func stopPreparation(_ error: Error, message: String) {
        preparationStopped = true
        let remaining = enrichmentQueue
        enrichmentQueue.removeAll()
        for request in remaining {
            preparation[request.word.key] = .failed(message)
            notifyPreparation(request.word.key)
            request.receive?(.failure(error))
        }
    }

    private func notifyPreparation(_ key: WordKey) {
        let roundID = round.id
        if pendingPreparationChanges[roundID] != nil {
            pendingPreparationChanges[roundID]?.insert(key); return
        }
        pendingPreparationChanges[roundID] = [key]
        // Publish one update per actor turn, even when an entire round enters the queue.
        Task { [weak self] in
            guard let self, let keys = pendingPreparationChanges.removeValue(forKey: roundID),
                  round.id == roundID, !round.ended else { return }
            preparationChanged?(keys)
        }
    }
}

import Foundation
import StudyCore
import StudyStorage
import StudyAssistant
import StudyRuntime

struct BridgeMessage: Decodable {
    enum Operation: String, Decodable {
        case ready, navigate, reveal, grade, question, endRound, completeRound, startRound
        case search, cancelSearch, closeLibrary, browse, practice, returnToStudy, `import`, moveWindow, windowControlsLayout, windowSurfaceLayout
    }
    let op: Operation
    let roundID: UUID?
    let cardID: UUID?
    let requestID: UUID?
    let wordID: String?
    let question: String?
    let query: String?
    let grade: Int?
    let right: Double?
    let top: Double?
    let controlsEnabled: Bool?
    let surfaceLayout: WindowSurfaceLayout?
}

/// Coordinates effects; the learning rules remain in StudyCore.
@MainActor final class StudyController {
    private let session: StudySession
    var store: StudyStore { session.store }
    var settings: AppSettings { get { session.settings } set { session.settings = newValue } }
    var round: StudyRound { session.round }
    private let emit: ([String: Any]) -> Void
    private let reportError: (Error) -> Void
    var isEnriching: Bool { session.isEnriching }
    var currentPreparation: WordPreparation { round.current.map { session.preparationState(for: $0.word.key) } ?? .idle }
    var hasCurrentEnrichment: Bool {
        guard let word = round.current?.word, let cached = try? store.cachedEnrichment(word.key) else { return false }
        return cached.text == word.text
    }
    var canEnrich: Bool {
        !isLibraryVisible && !round.ended && round.current != nil && currentPreparation != .loading && currentPreparation != .queued
    }
    var enrichmentMenuTitle: String {
        switch currentPreparation {
        case .loading: return "正在补全释义和例句…"
        case .queued: return "等待补全释义和例句…"
        default:
            if hasCurrentEnrichment { return "重新生成释义和例句…" }
            if case .failed = currentPreparation { return "重试补全释义和例句" }
            return "用 AI 补全释义和例句"
        }
    }
    private let searcher: any VocabularySearching
    private var searchTask: Task<Void, Never>?
    private var searchID: UUID?
    private var libraryQuery: (query: String, requestID: UUID)?
    private var searchResults: (query: String, requestID: UUID, words: [Word])?
    private(set) var isLibraryVisible = false
    private var publishedRoundID: UUID?

    init(store: StudyStore, settings: AppSettings, assistant: any AssistantServing = AssistantClient(),
         searcher: (any VocabularySearching)? = nil,
         emit: @escaping ([String: Any]) -> Void, reportError: @escaping (Error) -> Void) {
        session = StudySession(store: store, settings: settings, assistant: assistant)
        self.searcher = searcher ?? store.makeSearchWorker()
        self.emit = emit
        self.reportError = reportError
        session.preparationChanged = { [weak self] _ in
            guard let self, publishedRoundID == round.id, !round.ended else { return }
            snapshot()
        }
    }

    func beginRound(announce: Bool = false, preserveLibrary: Bool = false) throws {
        isLibraryVisible = preserveLibrary && isLibraryVisible
        session.preparationPaused = isLibraryVisible
        try session.begin()
        cancelSearch()
        let language = settings.language == .english ? "英语" : "日语"
        let mode = settings.mode == .learn ? "新词学习" : settings.mode == .review ? "复习" : "学习"
        let message = round.cards.isEmpty ? "暂无待学词卡 · \(language)\(mode)" : "已开始\(language)\(mode) · \(round.cards.count) 张"
        var extra: [String: Any] = ["preserveLibrary": isLibraryVisible]
        if announce && !isLibraryVisible { extra["animateEntry"] = true; extra["announcement"] = message }
        snapshot(type: "round", extra: extra)
    }

    func openLibrary() {
        isLibraryVisible = true
        session.preparationPaused = true
        send(["type": "library"])
    }

    func handle(_ command: BridgeMessage) throws {
        if command.op == .ready { try beginRound(); return }
        guard command.roundID == round.id else { return }
        switch command.op {
        case .startRound: try beginRound(announce: true)
        case .endRound: finishRound()
        case .completeRound:
            guard !round.isBrowsing else { return }
            if let pending = round.pending.first {
                session.navigate(to: pending.id)
                snapshot(extra: ["focusID": pending.id.uuidString.lowercased(), "announcement": "还有 \(round.pending.count) 张卡片未完成，继续学习吧。"])
            } else { finishRound() }
        case .navigate:
            if let id = command.cardID { session.navigate(to: id) }
        case .search:
            searchLibrary(command)
        case .cancelSearch:
            cancelSearch()
        case .closeLibrary:
            isLibraryVisible = false
            cancelSearch()
            session.preparationPaused = false
        case .browse:
            guard let id = command.wordID else { return }
            let query = String((command.query ?? "").prefix(300))
            let key = WordKey(language: settings.language, id: id)
            if let results = searchResults, results.query == query, results.requestID == command.requestID {
                openLibraryWords(results.words, selecting: key)
            } else {
                searchLibrary(command, selecting: key)
            }
        default:
            guard !round.ended, let card = round.current, command.cardID == card.id else { return }
            try handleCard(command, card: card)
        }
    }

    private func cancelSearch() {
        searchID = nil
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
        libraryQuery = nil
    }

    private func searchLibrary(_ command: BridgeMessage, selecting key: WordKey? = nil) {
        isLibraryVisible = true
        session.preparationPaused = true
        cancelSearch()
        let query = String((command.query ?? "").prefix(300))
        let requestID = command.requestID ?? UUID(), token = UUID()
        let roundID = round.id, language = settings.language
        searchID = token
        if key == nil { libraryQuery = (query, requestID) }
        searchTask = Task { [weak self, searcher] in
            do {
                let words = try await searcher.search(query, language: language, limit: 100)
                try Task.checkCancellation()
                guard let self, self.searchID == token, self.round.id == roundID, self.settings.language == language else { return }
                self.searchTask = nil
                if let key {
                    self.openLibraryWords(words, selecting: key)
                } else {
                    self.searchResults = (query, requestID, words)
                    self.send(["type": "search", "query": query, "requestID": requestID.uuidString.lowercased(),
                               "words": words.map { ["id": $0.id, "text": $0.text, "definition": $0.definition,
                                                       "reading": $0.pronunciation, "pos": $0.partOfSpeech] }])
                }
            } catch {
                guard !Task.isCancelled, let self, self.searchID == token, self.round.id == roundID, self.settings.language == language else { return }
                self.searchTask = nil
                if key != nil { self.reportError(error) }
                else {
                    self.send(["type": "search", "query": query, "requestID": requestID.uuidString.lowercased(),
                               "words": [], "error": "搜索暂时不可用，请稍后再试。"])
                }
            }
        }
    }

    private func openLibraryWords(_ words: [Word], selecting key: WordKey) {
        guard words.contains(where: { $0.key == key }) else { return }
        cancelSearch()
        let replacing = round.ended
        if let id = session.browse(words, selecting: key) {
            isLibraryVisible = false
            session.preparationPaused = false
            snapshot(type: replacing ? "round" : "patch", extra: ["focusID": id.uuidString.lowercased()])
        }
    }

    func vocabularyDidChange() {
        let pending = libraryQuery
        cancelSearch()
        if let pending {
            let command = BridgeMessage(op: .search, roundID: round.id, cardID: nil, requestID: pending.requestID,
                                        wordID: nil, question: nil, query: pending.query, grade: nil,
                                        right: nil, top: nil, controlsEnabled: nil, surfaceLayout: nil)
            searchLibrary(command)
        }
    }

    func prepareVocabularyImport() {
        cancelEnrichment()
        searchID = nil
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
    }

    private func handleCard(_ command: BridgeMessage, card: StudyCard) throws {
        switch command.op {
        case .reveal:
            session.reveal(card.id)
            snapshot()
        case .grade:
            guard let raw = command.grade, let grade = Grade(rawValue: raw), round.canGrade(card.id) else { snapshot(); return }
            guard try session.grade(card.id, as: grade) else { snapshot(); return }
            snapshot(extra: ["advanceFrom": card.id.uuidString.lowercased()])
        case .practice:
            if let id = session.practice(card.id) { snapshot(extra: ["focusID": id.uuidString.lowercased()]) }
        case .returnToStudy:
            session.returnToStudy()
            snapshot(extra: ["focusID": round.currentID?.uuidString.lowercased() ?? ""])
        case .question:
            guard card.revealed, let question = command.question, let requestID = command.requestID else { return }
            let roundID = round.id
            session.question(card: card.id, requestID: requestID, text: question) { [weak self] event in
                guard let self, self.round.id == roundID, !self.round.ended else { return }
                var payload: [String: Any] = ["type": "reply", "cardID": card.id.uuidString.lowercased()]
                switch event {
                case .delta(let id, let text): payload["requestID"] = id.uuidString.lowercased(); payload["delta"] = text
                case .completed(let id): payload["requestID"] = id.uuidString.lowercased(); payload["done"] = true
                case .failed(let id, let error): payload["requestID"] = id.uuidString.lowercased(); payload["error"] = error
                }
                self.send(payload)
            }
        default: break
        }
    }

    func finishRound() {
        guard !round.ended else { return }
        let remaining = round.pending.count
        let completed = round.reviewCount
        var lines = [String]()
        if completed > 0 { lines.append("完成了 \(completed) 次回想与复习。") }
        if remaining > 0 { lines.append("还有 \(remaining) 张词卡未完成。") }
        if lines.isEmpty { lines.append("准备好时，再开始新的一轮。") }
        let title = remaining > 0 ? "这一轮先到这里" : completed > 0 ? "这一轮学完了" : "今天先到这里"
        let detail = (completed > 0 ? "进度已保存 · " : "") + "本轮留言已清空"
        cancelSearch()
        isLibraryVisible = false
        session.finish()
        snapshot(type: "round", extra: ["title": title, "caption": "本轮小结", "summary": lines.joined(separator: "\n"), "detail": detail])
    }

    func cancelEnrichment() { session.cancelEnrichment() }

    func cancelWork() {
        session.cancelWork()
        cancelSearch()
    }

    func enrich(force: Bool = false) {
        guard !isLibraryVisible, let word = round.current?.word, !round.ended else { feedback("先打开一张词卡，再用 AI 补全。"); return }
        guard currentPreparation != .loading && currentPreparation != .queued else { return }
        session.enrich(force: force) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let completion):
                if !completion.reused { vocabularyDidChange() }
                let message = completion.reused ? "词条已补全，已使用本地保存的结果。" : "词条已补全，已保存到本地。"
                snapshot(extra: round.current?.word.key == word.key ? ["announcement": message] : [:])
            case .failure(let error):
                feedback("词条未补全，请检查 AI 设置后重试。"); reportError(error)
            }
        }
    }

    func feedback(_ message: String, persistent: Bool = false) {
        send(["type": "feedback", "message": message, "persistent": persistent])
    }

    func acknowledgeFailure() { send(["type": "actionFailed"]) }

    private func snapshot(type: String = "patch", extra: [String: Any] = [:]) {
        if type == "round" { publishedRoundID = round.id }
        var payload: [String: Any] = ["type": type, "language": settings.language.rawValue, "cards": round.cards.map(cardPayload),
                                    "view": round.isBrowsing ? "library" : "study",
                                    "visibleIDs": round.visibleCards.map { $0.id.uuidString.lowercased() }]
        if round.visibleCards.isEmpty && !round.ended {
            payload["title"] = "暂时没有待学词卡"
            payload["caption"] = "学习安排"
            payload["summary"] = "可以到词库看看，\n或在菜单中调整学习安排。"
        }
        if let id = round.currentID { payload["currentID"] = id.uuidString.lowercased() }
        if let id = round.pending.first?.id { payload["pendingID"] = id.uuidString.lowercased() }
        payload.merge(extra) { _, new in new }
        send(payload)
    }

    private func send(_ payload: [String: Any]) {
        var payload = payload
        payload["roundID"] = round.id.uuidString.lowercased()
        emit(payload)
    }

    private func cardPayload(_ card: StudyCard) -> [String: Any] {
        let word = card.word
        var payload: [String: Any] = ["id": card.id.uuidString.lowercased(), "kind": card.kind.rawValue, "direction": card.direction.rawValue,
                "revealed": card.revealed, "graded": card.graded,
                "word": ["word": word.text, "reading": word.pronunciation, "definition": word.definition, "pos": word.partOfSpeech,
                         "example": word.examples.first?.sentence ?? "", "translation": word.examples.first?.translation ?? ""]]
        switch session.preparationState(for: word.key) {
        case .idle, .ready: break
        case .queued: payload["enrichmentStatus"] = "queued"
        case .loading: payload["enrichmentStatus"] = "loading"
        case .failed(let message): payload["enrichmentStatus"] = "failed"; payload["enrichmentError"] = message
        }
        return payload
    }
}

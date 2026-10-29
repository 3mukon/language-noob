import Foundation
import StudyCore
import StudyStorage
import StudyAssistant
import StudyRuntime

@MainActor final class TerminalStudy {
    let session: StudySession
    private let output: (String) -> Void
    private var busy = false
    private var results = [Word]()
    private var stopped = false
    private var renderedCard: UUID?
    private var renderedPreparation = WordPreparation.idle

    init(session: StudySession, output: @escaping (String) -> Void = TerminalText.write) {
        self.session = session; self.output = output
        session.preparationChanged = { [weak self] keys in
            guard let self, !stopped, !busy, let card = session.round.current,
                  keys.contains(card.word.key), card.id == renderedCard,
                  session.preparationState(for: card.word.key) != renderedPreparation else { return }
            render()
        }
    }

    func run(events: AsyncStream<TerminalEvent>) async throws -> Int32 {
        try session.begin()
        output("输入 help 查看操作；q 结束本轮。\n")
        render()
        defer { session.cancelWork() }
        for await event in events {
            switch event {
            case .interrupt: end(); return 130
            case .end: end(); return 0
            case .invalid: end(); throw CommandError("输入必须是 UTF-8 文本，每行不超过 8 KB。")
            case .line(let line):
                do { if try act(line) { return 0 } }
                catch { output("\(error.localizedDescription)\n"); prompt() }
            }
        }
        end(); return 0
    }

    private func act(_ line: String) throws -> Bool {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
        var action = parts.first?.lowercased() ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        if ["q", "quit", "end"].contains(action) { end(); return true }
        if action == "cancel" { session.cancelCurrentReply(); busy = false; output("已停止当前 AI 请求，之前的留言仍保留在本轮。\n"); prompt(); return false }
        if busy { output("正在等待回复；输入 cancel 停止，或 q 结束本轮。\n"); return false }
        if action == "help" || action == "?" { output(Self.help + "\n"); prompt(); return false }
        if action == "new" {
            guard value.isEmpty || StudyMode(rawValue: value) != nil else { throw CommandError("使用 new study、new learn 或 new review。") }
            if let mode = StudyMode(rawValue: value) { session.settings.mode = mode }
            try session.begin(); render(); return false
        }
        if action == "search" {
            results = try session.store.search(value, language: session.settings.language, limit: 30)
            for word in results { output("\(word.id)  \(word.text)  \(word.pronunciation)  \(word.definition)\n") }
            output(results.isEmpty ? "没有匹配的词条。\n" : "输入 open <词条 ID> 浏览；back 返回学习。\n")
            prompt(); return false
        }
        if action == "open" {
            let key = WordKey(language: session.settings.language, id: value)
            guard session.browse(results, selecting: key) != nil else { throw CommandError("请先搜索，再输入结果中的词条 ID。") }
            render(); return false
        }
        if action == "back" { session.returnToStudy(); render(); return false }
        guard let card = session.round.current, !session.round.ended else {
            output("暂无词卡。输入 new 开始新一轮，或 search 搜索词库。\n"); prompt(); return false
        }
        if action.isEmpty { action = card.revealed ? "next" : "reveal" }
        switch action {
        case "n", "next": session.navigate(offset: 1); render()
        case "p", "prev": session.navigate(offset: -1); render()
        case "r", "reveal": session.reveal(card.id); render()
        case "1", "3", "4", "5":
            let grade = Grade(rawValue: Int(action)!)!
            guard try session.grade(card.id, as: grade) else {
                output(card.graded ? "这张卡片已记录，可以继续翻看。\n" : card.requiresGrade ? "先输入 reveal 查看答案，再评价记忆情况。\n" : "这是阅读卡片，切换到回想卡片后再评价。\n")
                prompt(); return false
            }
            output("已记录这次复习。\n")
            if session.advanceAfterGrade() { render() }
            else { let summary = session.finish(); output("本轮完成了 \(summary.completed) 次回想与复习。输入 new 开始新一轮。\n"); prompt() }
        case "practice":
            guard session.practice(card.id) != nil else { throw CommandError("请先打开词库中的词条。") }
            render()
        case "ask":
            guard card.revealed else { throw CommandError("先查看答案，再追问这个词。") }
            guard !value.isEmpty, value.count <= 2000 else { throw CommandError("问题应为 1 到 2,000 个字。") }
            busy = true; output("正在回复…\n")
            session.question(card: card.id, requestID: UUID(), text: value) { [weak self] event in
                guard let self, !stopped else { return }
                switch event {
                case .delta(_, let text): output(text)
                case .completed: busy = false; output("\n"); prompt()
                case .failed(_, let message): busy = false; output("\n\(message)\n"); prompt()
                }
            }
        case "enrich":
            guard value.isEmpty || value == "--force" else { throw CommandError("使用 enrich 补全；已有结果时，enrich --force 确认重新生成。") }
            guard card.revealed else { throw CommandError("先查看答案，再补全释义和例句。") }
            let state = session.preparationState(for: card.word.key)
            guard state != .loading && state != .queued else { output("当前词条已在补全队列中，可以继续翻看，或输入 cancel 停止。\n"); prompt(); return false }
            busy = true
            session.enrich(force: value == "--force") { [weak self] result in
                guard let self, !stopped else { return }; busy = false
                switch result {
                case .success(let completion):
                    output(completion.reused ? "词条已补全，已使用本地保存的结果。输入 enrich --force 可确认重新生成并替换现有结果。\n" : "词条已补全，已保存到本地。\n")
                    render()
                case .failure(let error): output("\(error.localizedDescription)\n"); prompt()
                }
            }
            if busy { output("已加入补全队列…\n") }
        default: output("无法识别操作。输入 help 查看可用命令。\n"); prompt()
        }
        return false
    }

    private func end() {
        guard !stopped else { return }; stopped = true
        let summary = session.finish()
        output("\n已结束本轮，已完成的学习进度保留。本轮留言已清空。\n")
        if summary.remaining > 0 { output("还有 \(summary.remaining) 张回想或复习卡片未完成。\n") }
    }
    private func prompt() { if !stopped { output("> ") } }
    private func render() {
        let cards = session.round.visibleCards
        guard let card = session.round.current, let index = cards.firstIndex(where: { $0.id == card.id }) else {
            output("\n暂时没有待学词卡，可搜索词库或输入 new 开始新一轮。\n"); prompt(); return
        }
        let labels: [CardKind: String] = [.introduction: "初识", .recall: "回想", .review: "复习", .retry: "再回想", .browse: "词库浏览"]
        renderedCard = card.id
        renderedPreparation = session.preparationState(for: card.word.key)
        output("\n\(card.word.language == .english ? "英语" : "日语") · \(labels[card.kind]!)  \(index + 1) / \(cards.count)\n")
        if card.revealed { output(Self.details(card.word, preparing: renderedPreparation == .loading) + "\n") }
        else {
            output((card.direction == .meaningToWord ? card.word.definition : card.word.text) + "\n")
            output("输入 reveal 或回车查看答案。\n")
        }
        if renderedPreparation == .loading { output("正在用 AI 补全释义和例句，仍可翻页或取消。\n") }
        if renderedPreparation == .queued { output("等待补全释义和例句，仍可继续学习。\n") }
        if case .failed = renderedPreparation { output("AI 暂未补全，可继续学习，或在查看答案后输入 enrich 重试。\n") }
        if card.graded { output("这次复习已记录。\n") }
        else if card.requiresGrade && card.revealed { output("1 忘记了 · 3 有点难 · 4 记得 · 5 很轻松\n") }
        else if card.kind == .introduction { output("阅读后按回车或输入 next，稍后会进入回想。\n") }
        else if card.kind == .browse { output("next / prev 翻看词条 · practice 加入本轮 · back 返回学习\n") }
        prompt()
    }

    static func details(_ word: Word, preparing: Bool = false) -> String {
        var lines = [word.text]
        let metadata = [word.pronunciation, word.partOfSpeech].filter { !$0.isEmpty }.joined(separator: " · ")
        if !metadata.isEmpty { lines.append(metadata) }
        lines.append(word.definition.isEmpty ? (preparing ? "正在补全中文释义…" : "暂无中文释义，可输入 enrich 用 AI 补充。") : word.definition)
        for example in word.examples { lines.append(example.sentence); if !example.translation.isEmpty { lines.append(example.translation) } }
        return lines.joined(separator: "\n")
    }
    static let help = """
    next / n、prev / p：前后翻看，首尾相连；阅读和翻页不记分。
    reveal / r：查看答案；回想或复习时再输入 1、3、4、5 评价。
    回车：未揭晓时显示答案，已揭晓时翻到下一张。
    ask <问题>：追问当前已揭晓的词；enrich：补全或复用本地结果。
    enrich --force：确认重新生成并替换已有结果。
    本轮词条会自动排队补全并缓存；默认串行，并发数可在 AI 设置中调整。
    search <关键词>、open <词条 ID>：浏览词库；practice：加入本轮；back：返回学习。
    cancel：停止回复；new [study|learn|review]：开始新一轮；q：结束。
    EOF 或 Ctrl+C 结束本轮；已记录的进度保留，留言不保存。
    """
}

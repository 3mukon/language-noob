import Foundation
import StudyCore
import StudyAssistant

private final class ControlledAssistant: AssistantServing, @unchecked Sendable {
    struct Call {
        let request: AssistantRequest
        let configuration: AssistantConfiguration
        let output: AsyncThrowingStream<String, Error>.Continuation
    }
    let calls: AsyncStream<Call>
    private let incoming: AsyncStream<Call>.Continuation
    init() { (calls, incoming) = AsyncStream.makeStream() }
    func reply(_ request: AssistantRequest, configuration: AssistantConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { output in incoming.yield(Call(request: request, configuration: configuration, output: output)) }
    }
}

extension LanguageNoobTests {
    @MainActor static func conversationRegressionTests() async throws {
        let client = ControlledAssistant(), book = ConversationBook(client: client), card = UUID()
        var calls = client.calls.makeAsyncIterator()
        var word = Word(id: "one", language: .english, text: "one", definition: "旧释义")
        var config = AssistantConfiguration(); config.provider = .claude; config.model = "first"
        let firstID = UUID(), secondID = UUID()
        var firstEvents = [UUID](), secondEvents = [UUID]()
        let (finished, completion) = AsyncStream<UUID>.makeStream()
        var completions = finished.makeAsyncIterator()
        func record(_ event: ConversationBook.Event, into values: inout [UUID]) {
            switch event {
            case .delta(let id, _): values.append(id)
            case .completed(let id), .failed(let id, _): values.append(id); completion.yield(id)
            }
        }
        book.submit(card: card, requestID: firstID, word: word, question: "first", configuration: config) { record($0, into: &firstEvents) }
        book.submit(card: card, requestID: firstID, word: word, question: "duplicate", configuration: config) { _ in }
        word.definition = "新释义"; config.model = "second"
        book.submit(card: card, requestID: secondID, word: word, question: "second", configuration: config) { record($0, into: &secondEvents) }
        let first = await calls.next()!
        first.output.yield("answer:first"); first.output.finish()
        _ = await completions.next()
        let second = await calls.next()!
        try check(first.configuration.model == "first" && second.configuration.model == "second", "queued submissions own configurations")
        try check(second.request.word.definition == "新释义", "queued submission owns its word snapshot")
        try check(second.request.messages.map(\.content) == ["first", "answer:first", "second"], "queue uses ordered completed context")
        second.output.yield("answer:second"); second.output.finish()
        _ = await completions.next()
        try check(firstEvents == [firstID, firstID] && secondEvents == [secondID, secondID], "callbacks belong to the originating submission")

        let failedID = UUID(), recoveryID = UUID()
        book.submit(card: card, requestID: failedID, word: word, question: "failed", configuration: config) { record($0, into: &firstEvents) }
        book.submit(card: card, requestID: recoveryID, word: word, question: "recover", configuration: config) { record($0, into: &secondEvents) }
        let failed = await calls.next()!
        failed.output.yield("partial"); failed.output.finish(throwing: AssistantError.failed)
        _ = await completions.next()
        let recovery = await calls.next()!
        try check(!recovery.request.messages.contains { $0.content == "failed" || $0.content == "partial" }, "failed partial exchange is excluded from context")
        recovery.output.yield("recovered"); recovery.output.finish()
        _ = await completions.next()

        let completedContext = book.messages(for: card)
        var stoppedEvents = 0
        book.submit(card: card, word: word, question: "stop this one", configuration: config) { _ in stoppedEvents += 1 }
        let stopped = await calls.next()!
        let stoppedTasks = book.cancel(card: card)
        for task in stoppedTasks { await task.value }
        stopped.output.yield("obsolete"); stopped.output.finish()
        try check(book.messages(for: card) == completedContext && stoppedEvents == 0, "stopping one reply preserves completed context and rejects late output")
        book.submit(card: card, requestID: UUID(), word: word, question: "continue", configuration: config) { record($0, into: &secondEvents) }
        let continued = await calls.next()!
        try check(continued.request.messages.dropLast() == completedContext[...], "next question reuses successful exchanges after cancellation")
        continued.output.yield("continued"); continued.output.finish()
        _ = await completions.next()

        var lateEvents = 0
        book.submit(card: card, word: word, question: "cancel", configuration: config) { _ in lateEvents += 1 }
        book.submit(card: card, word: word, question: "queued cancel", configuration: config) { _ in lateEvents += 1 }
        let cancelled = await calls.next()!
        book.endRound()
        try check(book.messages(for: card).isEmpty, "ending clears conversation immediately")
        let newCard = UUID(), freshID = UUID()
        book.submit(card: newCard, requestID: freshID, word: word, question: "new card", configuration: config) { record($0, into: &secondEvents) }
        let fresh = await calls.next()!
        cancelled.output.yield("late answer"); cancelled.output.finish()
        try check(fresh.request.messages.map(\.content) == ["new card"], "same word on a new card has fresh context")
        fresh.output.yield("fresh answer"); fresh.output.finish()
        _ = await completions.next()
        try check(lateEvents == 0 && book.messages(for: card).isEmpty, "cancelled callbacks cannot repopulate an ended round")
        book.endRound(); completion.finish()
        print("PASS: conversation ownership, failure, identity and cancellation regressions")
    }
}

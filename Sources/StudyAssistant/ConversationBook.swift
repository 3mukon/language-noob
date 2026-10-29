import Foundation
import StudyCore

/// Temporary, ordered conversations. Each queued submission owns all of its inputs.
@MainActor public final class ConversationBook {
    public enum Event { case delta(UUID, String), completed(UUID), failed(UUID, String) }

    private struct Submission {
        let id: UUID
        let word: Word
        let question: String
        let configuration: AssistantConfiguration
        let receive: (Event) -> Void
    }

    private final class Context {
        var messages = [ConversationMessage]()
        var queue = [Submission]()
        var seen = Set<UUID>()
        var task: Task<Void, Never>?
    }

    private var contexts = [UUID: Context]()
    private let client: any AssistantServing

    public init(client: any AssistantServing = AssistantClient()) { self.client = client }
    public func messages(for card: UUID) -> [ConversationMessage] { contexts[card]?.messages ?? [] }

    @discardableResult public func submit(card: UUID, requestID: UUID = UUID(), word: Word, question: String,
                                         configuration: AssistantConfiguration, receive: @escaping (Event) -> Void) -> UUID {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 2_000 else {
            receive(.failed(requestID, "留言应为 1 到 2,000 个字。"))
            return requestID
        }
        let context = contexts[card] ?? Context()
        guard !context.seen.contains(requestID) else { return requestID }
        guard context.queue.count + (context.task == nil ? 0 : 1) < 5 else {
            receive(.failed(requestID, "先等这几封回复写完，再接着留言吧。"))
            return requestID
        }
        context.seen.insert(requestID)
        context.queue.append(Submission(id: requestID, word: word, question: question, configuration: configuration, receive: receive))
        contexts[card] = context
        startNext(for: card)
        return requestID
    }

    private func startNext(for card: UUID) {
        guard let context = contexts[card], context.task == nil, !context.queue.isEmpty else { return }
        let submission = context.queue.removeFirst()
        context.messages.append(ConversationMessage(role: .user, content: submission.question))
        let request = AssistantRequest(word: submission.word, messages: context.messages)
        context.task = Task { [weak self, weak context] in
            guard let self, let context else { return }
            var answer = ""
            do {
                try Task.checkCancellation()
                for try await delta in client.reply(request, configuration: submission.configuration) {
                    try Task.checkCancellation()
                    guard contexts[card] === context else { return }
                    answer += delta
                    guard answer.utf8.count <= 100_000 else { throw AssistantError.outputLimit }
                    submission.receive(.delta(submission.id, delta))
                }
                try Task.checkCancellation()
                guard contexts[card] === context else { return }
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalidResponse }
                context.messages.append(ConversationMessage(role: .assistant, content: answer))
                submission.receive(.completed(submission.id))
            } catch {
                guard !Task.isCancelled, contexts[card] === context else { return }
                // Partial replies remain visible but cannot become future conversation facts.
                context.messages.removeLast()
                submission.receive(.failed(submission.id, (error as? LocalizedError)?.errorDescription ?? AssistantError.failed.localizedDescription))
            }
            // A callback may itself end the round. Never restart a discarded queue.
            guard contexts[card] === context else { return }
            context.task = nil
            startNext(for: card)
        }
    }

    /// Discard pending exchanges without losing earlier successful answers on this card.
    @discardableResult public func cancel(card: UUID) -> [Task<Void, Never>] {
        guard let old = contexts[card] else { return [] }
        let retained = Context()
        retained.messages = old.messages
        if retained.messages.last?.role == .user { retained.messages.removeLast() }
        retained.seen = old.seen
        contexts[card] = retained
        guard let task = old.task else { return [] }
        task.cancel(); return [task]
    }

    @discardableResult public func endRound() -> [Task<Void, Never>] {
        let discarded = contexts.values
        contexts.removeAll()
        let tasks = discarded.compactMap(\.task)
        for task in tasks { task.cancel() }
        return tasks
    }
}

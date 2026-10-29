import Foundation

public enum Grade: Int, Codable, CaseIterable, Sendable {
    case again = 1, hard = 3, good = 4, easy = 5
}

public struct Progress: Codable, Equatable, Sendable {
    public var key: WordKey
    public var ease: Double = 2.5
    public var interval: Int = 0
    public var repetitions: Int = 0
    public var reviews: Int = 0
    public var correct: Int = 0
    public var firstSeen: Date
    public var lastReview: Date?
    public var due: Date
    public init(key: WordKey, now: Date) { self.key = key; firstSeen = now; due = now }
}

public enum Scheduler {
    public static func review(_ previous: Progress, grade: Grade, now: Date, calendar: Calendar = .current) -> Progress {
        var next = previous
        let distance = Double(5 - grade.rawValue)
        next.ease = max(1.3, previous.ease + 0.1 - distance * (0.08 + distance * 0.02))
        if grade != .again {
            if previous.repetitions == 0 { next.interval = 1 }
            else if previous.repetitions == 1 { next.interval = 6 }
            else { next.interval = Int(min(36_500, max(1, (Double(previous.interval) * next.ease).rounded()))) }
            next.repetitions += 1; next.correct += 1
        } else { next.interval = 1; next.repetitions = 0 }
        next.reviews += 1; next.lastReview = now
        next.due = calendar.date(byAdding: .day, value: next.interval, to: now) ?? now.addingTimeInterval(Double(next.interval) * 86_400)
        return next
    }
}

public enum StudyMode: String, Codable, CaseIterable, Sendable { case study, learn, review }

public struct Workload {
    public let reviews: [Word]
    public let newWords: [Word]
    public static func select(words: [Word], progress: [WordKey: Progress], mode: StudyMode, now: Date, newLimit: Int? = nil,
                              shuffle: ([Word]) -> [Word] = { $0.shuffled() }) -> Workload {
        let due = words.filter { progress[$0.key].map { $0.due <= now } ?? false }.sorted {
            let a = progress[$0.key]!.due, b = progress[$1.key]!.due
            return a == b ? $0.id < $1.id : a < b
        }
        let automatic = due.count > 20 ? 0 : due.count > 10 ? 5 : 10
        let limit = newLimit.map { min(100, max(0, $0)) } ?? (mode == .learn ? 10 : automatic)
        let fresh = words.filter { progress[$0.key] == nil }
        // Preserve due-date eligibility, then randomize the selected batch.
        // New words are sampled from the whole unseen pool, not a sorted prefix.
        return Workload(reviews: mode == .learn ? [] : shuffle(Array(due.prefix(30))),
                        newWords: mode == .review || limit == 0 ? [] : Array(shuffle(fresh).prefix(limit)))
    }

    public func cards(shuffle: ([Word]) -> [Word] = { $0.shuffled() }) -> [StudyCard] {
        let reviews = reviews.enumerated().map { index, word in
            StudyCard(word: word, kind: .review, direction: index % 2 == 0 ? .meaningToWord : .wordToMeaning)
        }
        return reviews + newWords.map { StudyCard(word: $0, kind: .introduction) } + shuffle(newWords).map { StudyCard(word: $0, kind: .recall) }
    }
}


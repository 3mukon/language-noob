import Foundation
import Darwin
import StudyCore
import StudyStorage
import StudyRuntime

@MainActor enum CommandRunner {
    static func run(_ arguments: Arguments) async throws -> Int32 {
        if arguments.command == "help" { TerminalText.write(Arguments.help + "\n"); return 0 }
        let interactive = ["study", "learn", "review"].contains(arguments.command)
        if interactive && !arguments.batch && isatty(STDIN_FILENO) != 1 {
            throw CommandError("学习命令需要终端；脚本或管道请显式使用 --batch。")
        }
        let directory = try StudyEnvironment.dataDirectory(override: arguments.directory)
        let file = directory.appendingPathComponent("settings.json")
        if arguments.command == "config" { try await ConfigurationCommand.run(arguments, file: file); return 0 }
        let loaded = StudySettings.load(from: file)
        if let warning = loaded.warning { TerminalText.error(warning + "\n") }
        var settings = loaded.settings
        if let language = arguments.language { settings.language = language }
        if let limit = arguments.newLimit { settings.newLimit = limit }
        let store = try StudyStore(url: directory.appendingPathComponent("study.sqlite"))
        try BundledVocabulary.install(in: store)
        switch arguments.command {
        case "study", "learn", "review":
            settings.mode = StudyMode(rawValue: arguments.command)!
            let session = StudySession(store: store, settings: settings)
            let input = TerminalInput(); defer { input.stop() }
            do {
                let result = try await TerminalStudy(session: session).run(events: input.events)
                await session.shutdown(); return result
            } catch { await session.shutdown(); throw error }
        case "search":
            let words = try store.search(arguments.values.joined(separator: " "), language: settings.language, limit: arguments.limit)
            if arguments.json { try json(words) }
            else if words.isEmpty { TerminalText.write("没有匹配的词条。\n") }
            else {
                for word in words {
                    TerminalText.write("\(word.text)  \([word.pronunciation, word.partOfSpeech].filter { !$0.isEmpty }.joined(separator: " · "))\n")
                    TerminalText.write("  \(word.definition.isEmpty ? "暂无中文释义" : word.definition)\n  ID: \(word.id)\n")
                }
            }
        case "info":
            let value = arguments.values[0]
            var word = try store.word(WordKey(language: settings.language, id: value))
            if word == nil {
                let exact = try store.search(value, language: settings.language, limit: 200).filter { $0.text == value }
                guard exact.count <= 1 else { throw CommandError("这个词有多个词条，请使用 search 返回的词条 ID。") }
                word = exact.first
            }
            guard let word else { throw CommandError("没有找到这个词条，请确认词条 ID 和语言。") }
            if arguments.json { try json(word) }
            else { TerminalText.write(TerminalStudy.details(word) + "\nID: \(word.id)\n") }
        case "import":
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments.values[0])); defer { try? handle.close() }
            let imported = try VocabularyImport(data: handle.read(upToCount: VocabularyImport.maximumBytes + 1) ?? Data())
            try store.importVocabulary(imported)
            TerminalText.write("已导入 \(imported.words.count) 个\(imported.language == .english ? "英语" : "日语")词条，原有进度保留。\n")
        case "stats":
            let stats = try store.statistics(language: settings.language)
            if arguments.json { try json(stats) }
            else {
                TerminalText.write("\(settings.language == .english ? "英语" : "日语")学习\n词库：\(stats.vocabulary) 个词\n已学习：\(stats.learned) · 已掌握：\(stats.mastered) · 待复习：\(stats.due)\n今天复习：\(stats.todayReviews) 次 · 累计：\(stats.totalReviews) 次\n连续学习：\(stats.streak) 天\n")
            }
        default: throw CommandError("不支持这个命令。")
        }
        return 0
    }
    private static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        TerminalText.write(String(decoding: try encoder.encode(value), as: UTF8.self) + "\n")
    }
}

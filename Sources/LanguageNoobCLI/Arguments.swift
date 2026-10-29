import Foundation
import StudyCore

struct CommandError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct Arguments {
    var command = "help"
    var values = [String]()
    var directory: String?
    var language: StudyLanguage?
    var newLimit: Int?
    var limit = 30
    var json = false
    var batch = false
    var effective = false

    init(_ input: [String]) throws {
        var index = 0, positional = [String](), options = true, seen = Set<String>()
        while index < input.count {
            let value = input[index]; index += 1
            if value == "--" && options { options = false; continue }
            guard options && value.hasPrefix("-") else { positional.append(value); continue }
            guard seen.insert(value).inserted else { throw CommandError("重复的选项：\(value)") }
            func argument() throws -> String {
                guard index < input.count else { throw CommandError("选项缺少值：\(value)") }
                defer { index += 1 }; return input[index]
            }
            switch value {
            case "--help", "-h": command = "help"; return
            case "--data-directory": directory = try argument()
            case "--lang":
                guard let parsed = StudyLanguage(rawValue: try argument()) else { throw CommandError("语言使用 en 或 ja。") }
                language = parsed
            case "--new-limit":
                guard let parsed = Int(try argument()), (0...100).contains(parsed) else { throw CommandError("新词数量应为 0 到 100。") }
                newLimit = parsed
            case "--limit":
                guard let parsed = Int(try argument()), (1...200).contains(parsed) else { throw CommandError("搜索数量应为 1 到 200。") }
                limit = parsed
            case "--json": json = true
            case "--batch": batch = true
            case "--effective": effective = true
            default: throw CommandError("未知选项：\(value)。运行 language-noob --help 查看用法。")
            }
        }
        command = positional.first ?? "help"
        values = Array(positional.dropFirst())
        guard ["help", "study", "learn", "review", "search", "info", "import", "stats", "config"].contains(command) else {
            throw CommandError("未知命令：\(command)。运行 language-noob --help 查看用法。")
        }
        let interactive = ["study", "learn", "review"].contains(command)
        guard !batch || interactive, newLimit == nil || interactive,
              !json || ["search", "info", "stats", "config"].contains(command),
              !effective || command == "config" else { throw CommandError("这个命令不支持所选选项。") }
        if seen.contains("--limit") && command != "search" { throw CommandError("--limit 仅用于搜索。") }
        if interactive || command == "stats" { guard values.isEmpty else { throw CommandError("这个命令不接收额外参数。") }; return }
        if ["info", "import"].contains(command) { guard values.count == 1 else { throw CommandError("请提供一个词条 ID 或文件路径。") } }
    }

    static let help = """
    Language Noob · 命令行

    language-noob study [--lang en|ja] [--new-limit 10]   新词与到期复习
    language-noob learn [--lang en|ja]                   只学新词
    language-noob review [--lang en|ja]                  只复习
    language-noob search "单词或释义" [--lang en|ja] [--limit 30] [--json]
    language-noob info <词条 ID> [--lang en|ja] [--json]
    language-noob import <词库.json>
    language-noob stats [--lang en|ja] [--json]
    language-noob config show [--effective] [--json]
    language-noob config set <字段> <值> [<字段> <值> ...]
    language-noob config unset <字段>
    language-noob config key set|remove

    设置字段：language、mode、new-limit、provider、model、effort、executable、base-url、enrichment-concurrency
    provider：automatic、codex、claude、messagesAPI、responsesAPI
    effort：low、medium、high、xhigh、max；unset 恢复继承。
    enrichment-concurrency：补全并发数 1–8，默认 1（串行）。
    API 模型与接入方式可在一次 config set 中同时设置，密钥只通过隐藏输入保存。

    --data-directory <目录> 使用独立数据；默认与桌面版共用词库、进度和设置。
    学习命令需要终端。自动化输入请显式使用 --batch；输入结束即结束本轮。
    每轮新词随机抽取，英语与日语分开。学习中输入 help 查看操作。
    """
}

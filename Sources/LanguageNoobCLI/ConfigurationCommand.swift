import Foundation
import Darwin
import StudyCore
import StudyAssistant
import StudyRuntime

enum ConfigurationCommand {
    static func run(_ arguments: Arguments, file: URL) async throws {
        let baseline = StudySettings.load(from: file)
        if let warning = baseline.warning { TerminalText.error(warning + "\n") }
        var settings = baseline.settings
        let values = arguments.values
        let action = values.first ?? "show"
        if action == "show" {
            guard values.count <= 1 else { throw CommandError("config show 不接收额外参数。") }
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
            if arguments.effective {
                let inherited = await LocalAssistantPreferencesReader().read(for: settings.assistant)
                let effective = inherited.applying(to: settings.assistant)
                object["effective"] = ["provider": inherited.provider?.rawValue ?? effective.provider.rawValue,
                                       "model": effective.model.isEmpty ? "默认" : effective.model,
                                       "effort": effective.effort.isEmpty ? "默认" : effective.effort,
                                       "executable": effective.executablePath.isEmpty ? inherited.executablePath : effective.executablePath]
            }
            if settings.assistant.provider.isAPI { object["hasKey"] = try AssistantKeyStore().contains(settings.assistant) }
            // Ordinary configuration only. No credential value is ever loaded for display.
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            TerminalText.write(String(decoding: data, as: UTF8.self) + "\n"); return
        }
        guard !arguments.json && !arguments.effective else { throw CommandError("--json 和 --effective 仅用于 config show。") }
        if action == "key" {
            guard values.count == 2, ["set", "remove"].contains(values[1]), settings.assistant.provider.isAPI else {
                throw CommandError("先配置 API 模型与接入方式，再使用 config key set 或 config key remove。密钥不能放在命令参数中。")
            }
            let keys = AssistantKeyStore()
            if values[1] == "remove" { try keys.remove(settings.assistant); TerminalText.write("已移除此 API 地址的密钥。\n"); return }
            guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else { throw CommandError("密钥需要在终端中隐藏输入，不能通过管道或命令参数传入。") }
            var bytes = [CChar](repeating: 0, count: 4098)
            defer { _ = bytes.withUnsafeMutableBytes { memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
            guard readpassphrase("API Key（不显示）: ", &bytes, bytes.count, RPP_REQUIRE_TTY) != nil else { throw CommandError("没有保存密钥。") }
            try keys.save(String(cString: bytes), for: settings.assistant)
            TerminalText.write("密钥已保存到钥匙串。\n"); return
        }
        if action == "set" {
            guard values.count >= 3, values.count % 2 == 1 else { throw CommandError("使用 config set <字段> <值>，可连续设置多对字段。") }
            var seen = Set<String>()
            for index in stride(from: 1, to: values.count, by: 2) {
                let field = values[index], value = values[index + 1]
                guard seen.insert(field).inserted else { throw CommandError("字段重复。") }
                switch field {
                case "language":
                    guard let language = StudyLanguage(rawValue: value) else { throw CommandError("语言使用 en 或 ja。") }; settings.language = language
                case "mode":
                    guard let mode = StudyMode(rawValue: value) else { throw CommandError("学习模式使用 study、learn 或 review。") }; settings.mode = mode
                case "new-limit":
                    guard let limit = Int(value), (0...100).contains(limit) else { throw CommandError("新词数量应为 0 到 100。") }; settings.newLimit = limit
                case "provider":
                    guard let provider = AssistantProvider(rawValue: value) else { throw CommandError("请使用帮助中列出的接入方式。") }; settings.assistant.provider = provider
                case "model": settings.assistant.model = value
                case "effort": settings.assistant.effort = value
                case "executable": settings.assistant.executablePath = value
                case "base-url": settings.assistant.baseURL = value
                case "enrichment-concurrency":
                    guard let limit = Int(value), (1...8).contains(limit) else { throw CommandError("补全并发数应为 1 到 8，默认为 1（串行）。") }
                    settings.assistant.enrichmentConcurrency = limit
                default: throw CommandError("未知设置字段。运行 language-noob --help 查看可用字段。")
                }
            }
            if settings.assistant.provider == .automatic {
                guard seen.isDisjoint(with: ["model", "effort", "executable"]) else { throw CommandError("自动接入时模型、思考程度和执行文件只读。请先选择 codex 或 claude。") }
                settings.assistant.executablePath = ""
            }
        } else if action == "unset" {
            guard values.count == 2 else { throw CommandError("使用 config unset <字段>。") }
            switch values[1] {
            case "new-limit": settings.newLimit = nil
            case "model": settings.assistant.model = ""
            case "effort": settings.assistant.effort = ""
            case "executable": settings.assistant.executablePath = ""
            case "base-url": settings.assistant.baseURL = ""
            case "enrichment-concurrency": settings.assistant.enrichmentConcurrency = 1
            default: throw CommandError("可恢复默认的字段：new-limit、model、effort、executable、base-url、enrichment-concurrency。")
            }
        } else { throw CommandError("config 支持 show、set、unset 和 key。") }
        try settings.assistant.validate()
        try settings.save(to: file, replacing: baseline.settings)
        TerminalText.write("设置已保存。正在进行的其他轮次会保留自己的状态。\n")
    }
}

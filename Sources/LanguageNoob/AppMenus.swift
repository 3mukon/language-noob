import AppKit
import UniformTypeIdentifiers
import StudyCore
import StudyStorage
import StudyAssistant

extension LanguageNoobApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(changeLanguage):
            item.state = (item.tag == 0 ? settings.language == .english : settings.language == .japanese) ? .on : .off
        case #selector(learnOnly): item.state = settings.mode == .learn ? .on : .off
        case #selector(reviewOnly): item.state = settings.mode == .review ? .on : .off
        case #selector(newRound): item.state = settings.mode == .study ? .on : .off
        case #selector(endRound): return !controller.round.ended && !controller.round.cards.isEmpty
        case #selector(enrich):
            item.title = controller.enrichmentMenuTitle
            return controller.canEnrich
        case #selector(previousCard), #selector(nextCard): return !controller.round.visibleCards.isEmpty && !controller.round.ended
        default: break
        }
        return true
    }
    func makeMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.tag = tag; menu.addItem(item)
        }
        let app = menu("Language Noob")
        add(app, "关于 Language Noob", #selector(about))
        add(app, "便笺怎么用", #selector(help))
        app.addItem(.separator())
        add(app, "学习设置…", #selector(studySettings))
        add(app, "AI 设置…", #selector(assistantSettings), ",")
        app.addItem(.separator())
        add(app, "退出 Language Noob", #selector(quit), "q")

        let study = menu("学习")
        add(study, "新一轮学习", #selector(newRound), "n")
        add(study, "只学新词", #selector(learnOnly))
        add(study, "只复习", #selector(reviewOnly))
        add(study, "结束本轮", #selector(endRound), "e")

        study.addItem(.separator())
        add(study, "上一张", #selector(previousCard), "[")
        add(study, "下一张", #selector(nextCard), "]")
        add(study, "用 AI 补全释义和例句", #selector(enrich))
        study.items.last?.toolTip = "补全当前词条的读音、词性、中文释义和例句；已有本地结果时，确认后才重新生成。"

        study.addItem(.separator())
        add(study, "搜索词库…", #selector(showLibrary), "f")
        add(study, "导入 JSON 词库…", #selector(importVocabulary), "o")
        add(study, "学习统计…", #selector(showStatistics), "i")

        study.addItem(.separator())
        add(study, "英语", #selector(changeLanguage), "1", tag: 0)
        add(study, "日语", #selector(changeLanguage), "2", tag: 1)

        // Keep standard responder-chain shortcuts without extra menu headings.
        func shortcut(_ item: NSMenuItem) {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            app.addItem(item)
        }
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v")] { shortcut(NSMenuItem(title: title, action: selector, keyEquivalent: key)) }
        shortcut(makeSelectAllMenuItem())
        for (title, selector, key) in [("显示便笺", #selector(showWindow), "0"), ("缩到 Dock", #selector(minimize), "m"), ("关闭窗口", #selector(closeWindow), "w")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            shortcut(item)
        }
    }

    @objc func about() { alert("Language Noob", "一张词卡，一点新发现。") }
    @objc func help() {
        alert("便笺怎么用", """
        拖动可选中文字，双击可选中一个词。⌘C 复制，⌘A 全选当前便笺的文字；在输入框中，⌘A 只选中输入内容。

        在词卡空白处左右拖动、用双指左右滑动，或按 ← / →，都能切换词卡。选中文字或编辑内容时，方向键不会切换词卡。

        双击便笺空白处可放大阅读；再次双击空白处，或按 Esc，即可还原。

        有疑问时，在右下角的小纸条里留言。回车发送，Shift＋回车换行。对话仅在本轮保留，结束后会清空。

        拖动词卡或词库顶部，或按住 ⌥ 拖动纸张，可移动窗口。便笺外的空白区域可以直接点击后面的应用。

        移动鼠标时，便笺右上方会出现操作按钮。点「−」收起到 Dock；点「×」关闭窗口并结束本轮，已记录的学习进度会保留。

        顶部「学习」菜单可以开始或结束一轮、切换语言、搜索与导入词库，以及查看统计。学习设置、AI 设置和这份使用说明，都在左侧的应用菜单中。
        """)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func minimize() { window.miniaturize(nil) }
    @objc func closeWindow() { window.close() }
    @objc func previousCard() { emit(["type": "navigate", "direction": -1]) }
    @objc func nextCard() { emit(["type": "navigate", "direction": 1]) }
    @objc func endRound() { finishRound() }
    @objc func newRound() { settings.mode = .study; run { try saveSettings(); try beginRound() } }
    @objc func learnOnly() { settings.mode = .learn; run { try saveSettings(); try beginRound() } }
    @objc func reviewOnly() { settings.mode = .review; run { try saveSettings(); try beginRound() } }
    @objc func changeLanguage(_ sender: NSMenuItem) {
        let language: StudyLanguage = sender.tag == 0 ? .english : .japanese
        guard settings.language != language else { return }
        settings.language = language
        run { try saveSettings(); try beginRound(preserveLibrary: true) }
    }
    @objc func showLibrary() { controller.openLibrary() }
    @objc func showStatistics() {
        run {
            let stats = try store.statistics(language: settings.language)
            alert(settings.language == .english ? "英语学习" : "日语学习", "词库：\(stats.vocabulary) 个词\n已学习：\(stats.learned) 个　已掌握：\(stats.mastered) 个\n待复习：\(stats.due) 个\n\n今天复习：\(stats.todayReviews) 次\n累计复习：\(stats.totalReviews) 次\n记住比例：\(Int((stats.accuracy * 100).rounded()))%\n连续学习：\(stats.streak) 天\n\n复习间隔达到 21 天且连续记住至少 3 次，计为已掌握。")
        }
    }
    @objc func importVocabulary(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "导入词库"; panel.prompt = "导入"
        // An attached sheet dims the entire transparent parent rectangle.
        let response = panel.runModal()
        panel.orderOut(nil)
        guard response == .OK, let url = panel.url else { return }
        run {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= VocabularyImport.maximumBytes else { throw VocabularyError.invalid("词库文件不能超过 20 MB。") }
            let imported = try VocabularyImport(data: Data(contentsOf: url, options: .mappedIfSafe))
            willImportVocabulary()
            do { try store.importVocabulary(imported) }
            catch { didImportVocabulary(); throw error }
            didImportVocabulary()
            alert("词库已导入", "已加入或更新 \(imported.words.count) 个\(imported.language == .english ? "英语" : "日语")词条。原有学习进度保留。\n\n下一轮学习即可使用，也可以在词库中搜索。")
        }
    }

    @objc func studySettings() {
        let alert = NSAlert(); alert.messageText = "每轮新词"; alert.informativeText = "自动安排：通常 10 个；待复习超过 10 个时减为 5 个，超过 20 个时先复习。只学新词时默认为 10 个。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        popup.addItems(withTitles: ["自动安排", "5 个", "10 个", "20 个", "不添加新词"])
        let limits: [Int?] = [nil, 5, 10, 20, 0]; popup.selectItem(at: limits.firstIndex(where: { $0 == settings.newLimit }) ?? 0)
        alert.accessoryView = popup; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { settings.newLimit = limits[popup.indexOfSelectedItem]; run { try saveSettings() } }
    }

    @objc func assistantSettings() {
        let alert = NSAlert(); alert.messageText = "AI 设置"
        alert.informativeText = "选择本机服务，或通过 API Key 接入。"
        let view = AssistantSettingsView(configuration: settings.assistant)
        defer { view.stopLoading() }
        view.resized = { [weak alert] in alert?.layout() }
        alert.accessoryView = view; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        while alert.runModal() == .alertFirstButtonReturn {
            let original = settings
            do {
                let configuration = try view.validatedConfiguration()
                try view.applyKeyChange(for: configuration)
                settings.assistant = configuration
                try saveSettings(); return
            } catch {
                settings = original
                self.alert("AI 设置未保存", (error as? LocalizedError)?.errorDescription ?? "保存失败，请重试。")
            }
        }
    }

}

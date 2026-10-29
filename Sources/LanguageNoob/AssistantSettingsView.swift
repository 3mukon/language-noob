import AppKit
import StudyAssistant

@MainActor final class AssistantSettingsView: NSView, NSTextFieldDelegate {
    private let provider = NSPopUpButton()
    private let model = NSTextField(), effort = NSPopUpButton(), location = NSTextField()
    private let concurrency = NSPopUpButton()
    private let effortDisplay = NSTextField(labelWithString: "")
    private let key = NSSecureTextField()
    private let removeKey = NSButton(checkboxWithTitle: "移除这个地址已保存的密钥", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var labels = [NSTextField]()
    private var current: AssistantConfiguration
    private var drafts = [AssistantProvider: AssistantConfiguration]()
    private var efforts = [String]()
    private var local = LocalAssistantPreferences()
    private var modelText = AssistantInheritedText(), locationText = AssistantInheritedText()
    private var effortInherited = true, loading = false
    private var readID = UUID()
    private var readTask: LocalAssistantPreferencesLoad?
    private let keys: any AssistantKeyStoring
    var resized: (() -> Void)?

    init(configuration: AssistantConfiguration, keys: any AssistantKeyStoring = AssistantKeyStore()) {
        current = configuration; self.keys = keys
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 292))
        for title in ["接入方式", "模型", "思考程度", "", "补全并发数", "API Key"] {
            let label = NSTextField(labelWithString: title); labels.append(label); addSubview(label)
        }
        for view in [provider, model, effort, effortDisplay, location, concurrency, key, removeKey, hint] as [NSView] { addSubview(view) }
        concurrency.addItems(withTitles: (1...8).map { $0 == 1 ? "1（串行）" : String($0) })
        concurrency.setAccessibilityLabel("补全并发数")
        concurrency.toolTip = "同时补全的词条数量。默认 1，按顺序逐个补全；已保存的词条会自动跳过。"
        provider.addItems(withTitles: AssistantProvider.allCases.map(\.title))
        provider.selectItem(at: AssistantProvider.allCases.firstIndex(of: current.provider) ?? 0)
        provider.target = self; provider.action = #selector(changeProvider)
        model.delegate = self; location.delegate = self
        effort.target = self; effort.action = #selector(changeEffort)
        key.delegate = self
        removeKey.target = self; removeKey.action = #selector(toggleRemoval)
        key.placeholderString = "填写新密钥；留空保留已保存的密钥"
        key.setAccessibilityLabel("API Key")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        removeKey.font = .systemFont(ofSize: 11)
        render()
        readLocalPreferences()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { readTask?.cancel() }
    func stopLoading() { readTask?.cancel(); readID = UUID() }
    private func capture() -> AssistantConfiguration {
        var value = current
        value.enrichmentConcurrency = concurrency.indexOfSelectedItem + 1
        value.model = modelText.storedValue
        value.effort = effortInherited ? "" : selectedEffort
        let address = location.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.provider.isAPI { value.baseURL = address; value.executablePath = "" }
        else { value.executablePath = locationText.storedValue; value.baseURL = "" }
        if value.provider == .automatic { value.executablePath = "" }
        return value
    }
    func validatedConfiguration() throws -> AssistantConfiguration {
        let value = capture(); try value.validate()
        if value.provider.isAPI && removeKey.state != .on && enteredKey.isEmpty {
            guard try keys.contains(value) else { throw AssistantError.missingKey }
        }
        return value
    }
    func applyKeyChange(for configuration: AssistantConfiguration) throws {
        guard configuration.provider.isAPI else { return }
        if removeKey.state == .on { try keys.remove(configuration) }
        else if !enteredKey.isEmpty { try keys.save(enteredKey, for: configuration) }
        key.stringValue = ""
    }
    private var enteredKey: String { key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedEffort: String { efforts.indices.contains(effort.indexOfSelectedItem) ? efforts[effort.indexOfSelectedItem] : "" }
    @objc private func toggleRemoval() {
        if removeKey.state == .on { key.stringValue = "" }
        key.isEnabled = removeKey.state != .on
    }
    @objc private func changeProvider() {
        let previous = capture()
        drafts[current.provider] = previous
        let selected = AssistantProvider.allCases[provider.indexOfSelectedItem]
        current = drafts[selected] ?? AssistantConfiguration(); current.provider = selected
        current.enrichmentConcurrency = previous.enrichmentConcurrency
        local = LocalAssistantPreferences(); loading = false
        key.stringValue = ""; removeKey.state = .off
        key.isEnabled = true
        render(); readLocalPreferences(); resized?()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === model {
            modelText.edit(model.stringValue)
            stopLoading(); loading = false
        }
        else if notification.object as? NSTextField === location {
            locationText.edit(location.stringValue)
            stopLoading(); loading = false
            removeKey.state = .off; key.isEnabled = true
        } else { removeKey.state = .off; key.isEnabled = true }
        updateHint()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === model {
            guard modelText.isEditing else { return }
            modelText.finishEditing()
            readLocalPreferences()
        } else if notification.object as? NSTextField === location {
            guard locationText.isEditing else { return }
            locationText.finishEditing()
            readLocalPreferences()
        }
    }
    @objc private func changeEffort() {
        effortInherited = selectedEffort.isEmpty
        if effortInherited { renderEffort(local.effort) }
        updateHint()
    }
    private func renderEffort(_ selected: String) {
        efforts = current.allowedEfforts
        let inheritedExtra = !selected.isEmpty && !efforts.contains(selected)
        if inheritedExtra { efforts.append(selected) }
        let fallback = loading && local.effort.isEmpty ? "读取中…" : (local.effort.isEmpty ? "默认" : "跟随本机配置")
        effort.removeAllItems(); effort.addItems(withTitles: efforts.map { $0.isEmpty ? fallback : $0 })
        if inheritedExtra { effort.lastItem?.isEnabled = false }
        effort.selectItem(at: efforts.firstIndex(of: selected) ?? 0)
        effortDisplay.stringValue = selected.isEmpty ? (loading ? "读取中…" : "默认") : selected
        let automatic = current.provider == .automatic
        effort.isHidden = automatic; effortDisplay.isHidden = !automatic
        effortDisplay.isSelectable = true
    }
    private func readLocalPreferences() {
        stopLoading()
        guard !current.provider.isAPI else { loading = false; updateHint(); return }
        loading = true
        let configuration = capture(), identity = readID
        let read = LocalAssistantPreferencesLoad(configuration: configuration) { [weak self] result in
            // NSAlert runs a nested modal loop; deliver even while that loop is active.
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.receive(result, identity: identity)
                }
            }
        }
        readTask = read
        // Do not paint default/loading values for a read that completes within
        // one short interaction budget. A slower CLI still leaves the form usable.
        if let result = read.wait() { receive(result, identity: identity) }
        else { refreshValues() }
    }
    private func receive(_ result: LocalAssistantPreferences, identity: UUID) {
        guard readID == identity, loading else { return }
        local = result; loading = false; refreshValues()
    }
    private func refreshValues() {
        let automatic = current.provider == .automatic
        modelText.receive(local.model)
        if !modelText.isEditing {
            let value = modelText.displayedValue
            model.stringValue = automatic && value.isEmpty ? (loading ? "读取中…" : "默认") : value
        }
        model.placeholderString = current.provider.isAPI ? "填写服务提供的模型名称" : (loading ? "读取中…" : "默认")
        renderEffort(effortInherited ? local.effort : selectedEffort)
        if !current.provider.isAPI {
            let path = local.executablePath
            locationText.receive(path)
            if !locationText.isEditing {
                let value = locationText.displayedValue
                location.stringValue = automatic && value.isEmpty ? (loading ? "读取中…" : "未找到") : value
            }
            location.placeholderString = "留空自动查找，或填写绝对路径"
            location.toolTip = locationText.displayedValue
        }
        updateHint()
    }
    private func render() {
        let api = current.provider.isAPI, automatic = current.provider == .automatic
        setFrameSize(NSSize(width: 440, height: api ? 372 : 292))
        concurrency.selectItem(at: min(8, max(1, current.enrichmentConcurrency)) - 1)
        modelText = AssistantInheritedText(override: current.model)
        locationText = AssistantInheritedText(override: current.executablePath)
        modelText.receive(local.model); locationText.receive(local.executablePath)
        effortInherited = current.effort.isEmpty
        model.stringValue = modelText.displayedValue
        for field in [model, location] {
            field.isEditable = !automatic; field.isSelectable = true
            field.isBezeled = !automatic; field.drawsBackground = !automatic
        }
        model.placeholderString = api ? "填写服务提供的模型名称" : "留空使用服务默认模型"
        labels[3].stringValue = api ? "API 地址" : "执行文件"
        location.setAccessibilityLabel(api ? "API 地址" : "执行文件")
        location.stringValue = api ? current.baseURL : locationText.displayedValue
        location.toolTip = nil
        location.placeholderString = api ? current.provider.defaultBaseURL : "留空自动查找，或填写绝对路径"
        location.cell?.lineBreakMode = .byTruncatingMiddle
        renderEffort(effortInherited ? local.effort : current.effort)
        labels[5].isHidden = !api; key.isHidden = !api; removeKey.isHidden = !api
        model.setAccessibilityLabel("模型"); effort.setAccessibilityLabel("思考程度")
        effortDisplay.setAccessibilityLabel("思考程度")
        layoutFields()
        updateHint()
    }
    private func layoutFields() {
        let top = frame.height - 32
        let fields: [NSControl] = [provider, model, current.provider == .automatic ? effortDisplay : effort, location, concurrency, key]
        for (index, field) in fields.enumerated() {
            let rect = NSRect(x: 100, y: top - CGFloat(index) * 42, width: 330, height: 26)
            field.frame = field.frame(forAlignmentRect: rect)
            let textLeft = field.frame.minX + (field.cell?.titleRect(forBounds: field.bounds).minX ?? 0)
            let adjustment = textLeft - 104 - (field is NSPopUpButton ? 2 : 0)
            if field is NSPopUpButton {
                // Popup cells include extra decoration on both sides. Align the
                // actual title with text fields, keeping the visible edges close.
                field.frame = field.frame.insetBy(dx: -adjustment, dy: 0)
            } else if let text = field as? NSTextField, !text.isBezeled {
                field.frame.origin.x -= adjustment
                field.frame.size.width += adjustment
            }
            let label = labels[index]
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: 0, y: rect.midY - height / 2, width: 90, height: height)
            if field is NSPopUpButton, let cell = field.cell {
                // Popup titles are vertically centered inside their native bezel.
                let title = convert(cell.titleRect(forBounds: field.bounds), from: field)
                label.frame.origin.y = title.midY - height / 2
            } else {
                // Baseline offsets are relative to alignment rectangles, not frames.
                // Single-line fields draw from the top even when their boxes are taller.
                let fieldBaseline = field.alignmentRect(forFrame: field.frame).maxY - field.firstBaselineOffsetFromTop
                let labelBaseline = label.alignmentRect(forFrame: label.frame).maxY - label.firstBaselineOffsetFromTop
                label.frame.origin.y += fieldBaseline - labelBaseline
            }
        }
        removeKey.frame = NSRect(x: 100, y: top - 246, width: 330, height: 22)
        hint.frame = NSRect(x: 0, y: 0, width: 430, height: 48)
    }
    private func updateHint() {
        if current.provider.isAPI {
            let hasKey = (try? keys.contains(capture())) == true
            removeKey.isEnabled = hasKey
            hint.stringValue = (hasKey ? "此地址已有密钥，留空即可继续使用。" : "填写 API Key 后即可接入。") + "密钥仅保存在本机钥匙串。回复会逐段显示。"
            hint.stringValue += "思考档位需模型支持，不确定时可选「默认」。"
        } else {
            let source = loading ? "读取中…" : (local.provider.map { "来自 \($0.title) 配置" } ?? "默认")
            let modelSource = modelText.isInherited ? (loading || !local.model.isEmpty ? source : "默认") : "自行设置"
            let effortSource = effortInherited ? (loading || !local.effort.isEmpty ? source : "默认") : "自行设置"
            let guidance = current.provider == .automatic
                ? "自动模式下模型、思考程度和路径只读；补全并发数可直接调整。"
                : "清空模型或路径可恢复自动读取；思考程度选首项可跟随配置。"
            hint.stringValue = "模型：\(modelSource)；思考程度：\(effortSource)。" + guidance
        }
    }
}

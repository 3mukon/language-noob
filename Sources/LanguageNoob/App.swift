import AppKit
import WebKit
import StudyCore
import StudyStorage
import StudyRuntime

@main @MainActor final class LanguageNoobApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var window: PaperWindow!
    private var webView: WKWebView!
    private(set) var controller: StudyController!
    private var page: StudyPage!
    private var dataDirectory: URL!
    private var savedSettings = AppSettings()
    private var selectAllMenuItem: NSMenuItem?
    var settings: AppSettings {
        get { controller.settings }
        set { controller.settings = newValue }
    }
    var store: StudyStore { controller.store }

    static func main() {
        let app = NSApplication.shared
        let delegate = LanguageNoobApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            dataDirectory = try dataLocation()
            let store = try StudyStore(url: dataDirectory.appendingPathComponent("study.sqlite"))
            let loaded = AppSettings.load(from: dataDirectory.appendingPathComponent("settings.json"))
            savedSettings = loaded.settings
            guard let resources = Bundle.module.url(forResource: "Resources", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            page = StudyPage(resources: resources)
            try BundledVocabulary.install(in: store)
            controller = StudyController(store: store, settings: loaded.settings,
                                         emit: { [weak self] in self?.emit($0) }, reportError: { [weak self] in self?.showError($0) })
            makeMenu()
            makeWindow()
            NSApp.activate(ignoringOtherApps: true)
            if let warning = loaded.warning { alert("设置已恢复为默认值", warning) }
        } catch {
            showError(error)
            NSApp.terminate(nil)
        }
    }

    private func dataLocation() throws -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--data-directory"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return try StudyEnvironment.dataDirectory()
    }

    func saveSettings() throws {
        let merged = try settings.save(to: dataDirectory.appendingPathComponent("settings.json"), replacing: savedSettings)
        settings = merged; savedSettings = merged
    }
    func beginRound(preserveLibrary: Bool = false) throws { try controller.beginRound(announce: true, preserveLibrary: preserveLibrary) }
    func finishRound() { controller.finishRound() }
    func willImportVocabulary() { controller.prepareVocabularyImport() }
    func didImportVocabulary() { controller.vocabularyDidChange() }
    @objc func enrich() {
        guard controller.canEnrich else { return }
        if controller.hasCurrentEnrichment {
            let roundID = controller.round.id, key = controller.round.current?.word.key
            let entry = controller.round.current.map { $0.revealed ? "「\($0.word.text)」" : "当前词条" } ?? "当前词条"
            let alert = NSAlert()
            alert.messageText = "重新生成这个词条？"
            alert.informativeText = "\(entry)已有补全结果保存在本地。重新生成会再次调用 AI，并在成功后替换现有结果。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新生成")
            guard alert.runModal() == .alertSecondButtonReturn,
                  controller.round.id == roundID, controller.round.current?.word.key == key else { return }
            controller.enrich(force: true)
        } else { controller.enrich() }
    }

    private func makeWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "study")
        webView = StudyWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_024, height: 800)
        let size = NSSize(width: min(940, visible.width), height: min(850, visible.height))
        window = PaperWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Language Noob"
        window.minSize = NSSize(width: 700, height: 650)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        let controls = WindowControls(frame: NSRect(x: 0, y: 0, width: 68, height: 30),
                                      target: self, minimize: #selector(minimize), close: #selector(closeWindow))
        content.addSubview(controls)
        window.paperControls = controls
        controls.hitRegionChanged = { [weak window] in window?.refreshMouseRouting() }
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.startPointerRouting()
        webView.loadFileURL(page.index, allowingReadAccessTo: page.resources)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = page.accepts(navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame == true)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { window.resetSurfaceLayout(); controller.cancelWork(); webView.reload() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error) }

    func emit(_ payload: [String: Any]) {
        webView?.callAsyncJavaScript("window.nativeReceive(payload)", arguments: ["payload": payload], in: nil, in: .page) { _ in }
    }

    func makeSelectAllMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllMenuItem = item
        return item
    }

    @objc func selectAllText(_ sender: Any?) {
        guard let webView, let responder = NSApp.keyWindow?.firstResponder as? NSView,
              responder === webView || responder.isDescendant(of: webView) else {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
            return
        }
        // WebKit's document-wide select-all includes covered, inert papers.
        // Let the page scope the command; native dialogs retain their responder.
        emit(["type": "selectAll"])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard page.accepts(message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame),
              let object = message.body as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object), data.count < 32_000,
              let command = try? JSONDecoder().decode(BridgeMessage.self, from: data) else { return }
        do {
            switch command.op {
            case .windowControlsLayout:
                if let right = command.right, let top = command.top {
                    window.paperControls?.anchor(right: right, top: top, enabled: command.controlsEnabled ?? true)
                }
            case .windowSurfaceLayout:
                if let layout = command.surfaceLayout { window.updateSurfaceLayout(layout) }
            case .moveWindow:
                window.beginPointerDrag()
            case .import: importVocabulary(nil)
            default: try controller.handle(command)
            }
        } catch {
            controller.acknowledgeFailure()
            showError(error)
        }
    }

    func run(_ operation: () throws -> Void) { do { try operation() } catch { showError(error) } }
    func showError(_ error: Error) { alert("暂时无法完成", (error as? LocalizedError)?.errorDescription ?? "操作未完成，请检查文件格式或访问权限后重试。") }
    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { window?.stopPointerRouting(); controller?.cancelWork(); return .terminateNow }
    func applicationDidHide(_ notification: Notification) { window?.stopPointerRouting() }
    func applicationDidUnhide(_ notification: Notification) { if window?.isVisible == true { window.startPointerRouting() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowDidBecomeKey(_ notification: Notification) {
        window.startPointerRouting()
        selectAllMenuItem?.target = self
        selectAllMenuItem?.action = #selector(selectAllText(_:))
    }
    func windowDidResignKey(_ notification: Notification) {
        window.paperControls?.suspend()
        // AppKit disables app-targeted actions during modal editing. Restore
        // the responder-chain action while another window owns the keyboard.
        selectAllMenuItem?.target = nil
        selectAllMenuItem?.action = #selector(NSText.selectAll(_:))
    }
    func windowDidMove(_ notification: Notification) { window.refreshMouseRouting() }
    func windowDidResize(_ notification: Notification) { window.refreshMouseRouting() }
    func windowDidMiniaturize(_ notification: Notification) { window.stopPointerRouting(); window.paperControls?.suspend() }
    func windowDidDeminiaturize(_ notification: Notification) { window.startPointerRouting() }
    func windowWillClose(_ notification: Notification) { window.stopPointerRouting(); window.paperControls?.suspend(); controller.finishRound() }
}

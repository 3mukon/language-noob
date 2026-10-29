import Foundation
import AppKit
import WebKit
import StudyCore
import StudyStorage
import StudyAssistant

struct ApplicationFailure: Error { let message: String }

@MainActor enum ApplicationChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw ApplicationFailure(message: message) }
    }

    static func run() async throws {
        try assistantTextEditingChecks()
        try await windowRoutingChecks()
        try await controllerChecks()
        try await searchLifecycleChecks()
        try await enrichmentChecks()
        let renderer = WebKitFixture(), interactions = WebKitFixture(), reading = WebKitFixture()
        defer { renderer.close(); interactions.close(); reading.close() }
        // A fully occluded WebKit page pauses requestAnimationFrame. Leave a
        // visible strip of each fixture, above other apps, while the suites run.
        let origin = NSScreen.main!.visibleFrame.origin
        renderer.window.level = .floating
        interactions.window.level = .floating
        reading.window.level = .floating
        renderer.window.setFrameOrigin(origin)
        interactions.window.setFrameOrigin(NSPoint(x: origin.x + 120, y: origin.y))
        reading.window.setFrameOrigin(NSPoint(x: origin.x + 240, y: origin.y))
        renderer.window.orderFrontRegardless()
        interactions.window.orderFrontRegardless()
        reading.window.orderFrontRegardless()
        try await renderer.load()
        try await interactions.load()
        try await reading.load()
        // These suites have separate pages, message handlers and transient data.
        // Overlap their frame waits without changing the process watchdog or assertions.
        async let pixels: Void = renderedMotionChecks(renderer)
        async let behavior: Void = interactionChecks(interactions, section: "interaction")
        async let readingBehavior: Void = interactionChecks(reading, section: "reading")
        try await pixels
        try await behavior
        try await readingBehavior
    }

    private static func assistantTextEditingChecks() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-editing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        for provider in [AssistantProvider.codex, .claude] {
            let discovered = "/fixture/discovered/" + provider.rawValue
            let chosen = "/fixture/chosen/" + provider.rawValue
            var text = AssistantInheritedText()
            text.receive(discovered)
            text.finishEditing()
            try check(text.displayedValue == discovered && text.storedValue.isEmpty, "focusing inherited text does not pin a path")
            var settings = AppSettings(); settings.assistant.provider = provider
            settings.assistant.executablePath = text.storedValue
            try settings.save(to: file)
            try check(AppSettings.load(from: file).settings.assistant.executablePath.isEmpty, "saving a discovered path retains discovery")

            text.edit(chosen)
            text.receive("/fixture/late-result")
            try check(text.displayedValue == chosen && text.storedValue == chosen, "late lookup cannot replace an executable edit")
            settings.assistant.executablePath = text.storedValue
            try settings.save(to: file)
            let saved = AppSettings.load(from: file)
            try check(saved.warning == nil && saved.settings.assistant.executablePath == chosen, "a CLI path saves even before editing loses focus")
            var reopened = AssistantInheritedText(override: saved.settings.assistant.executablePath)
            reopened.receive(discovered)
            try check(reopened.displayedValue == chosen, "reopened explicit path outranks discovery")
            reopened.edit("   "); reopened.finishEditing()
            try check(reopened.storedValue.isEmpty && reopened.displayedValue == discovered, "clearing the path restores discovery")
        }
        var model = AssistantInheritedText()
        model.receive("local-model")
        model.edit("chosen-model")
        model.receive("changed-local-model")
        model.finishEditing()
        try check(model.displayedValue == "chosen-model" && model.storedValue == "chosen-model", "model edits retain the same precedence as executable edits")
        model.edit(""); model.finishEditing()
        try check(model.displayedValue == "changed-local-model" && model.storedValue.isEmpty, "cleared model follows the latest configuration")
        print("PASS: editable inherited model/path values, save/reopen, clearing and late-read ownership")
    }

    static func interactionChecks(_ renderer: WebKitFixture, section: String) async throws {
        let diagnostics = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            let value = try? await renderer.webView.evaluateJavaScript("JSON.stringify(window.testUICheckProgress)")
            FileHandle.standardError.write(Data("WebKit interaction progress: \(value ?? "unavailable")\n".utf8))
        }
        defer { diagnostics.cancel() }
        let script = try String(contentsOf: testDirectory.appendingPathComponent("ui-checks.js"), encoding: .utf8)
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            renderer.webView.callAsyncJavaScript(script + "\nreturn await runUIChecks(section);", arguments: ["section": section], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        print("PASS: WebKit \(result)")
    }

    static var testDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    static var productDirectory: URL { testDirectory.deletingLastPathComponent().deletingLastPathComponent() }

    static func controllerChecks() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = StudyPage(resources: directory)
        try check(page.accepts(directory.appendingPathComponent("index.html"), isMainFrame: true), "canonical file aliases load the page")
        try check(!page.accepts(page.index, isMainFrame: false), "subframes cannot navigate or send commands")
        try check(!page.accepts(directory.appendingPathComponent("other.html"), isMainFrame: true), "other local files cannot navigate or send commands")
        try check(!page.accepts(URL(string: "https://example.com/index.html"), isMainFrame: true), "remote pages cannot navigate or send commands")
        let store = try StudyStore(url: directory.appendingPathComponent("study.sqlite"))
        try store.seed([Word(id: "one", language: .english, text: "one", definition: "一"), Word(id: "two", language: .english, text: "two", definition: "二")])
        for word in try store.words(language: .english) { try store.cacheEnrichment(word) }
        var settings = AppSettings(); settings.newLimit = 1
        var events = [[String: Any]]()
        let (changes, updates) = AsyncStream<Void>.makeStream()
        var changesIterator = changes.makeAsyncIterator()
        let controller = StudyController(store: store, settings: settings, emit: { events.append($0); updates.yield(()) }, reportError: { _ in })
        func command(_ op: String, _ fields: [String: Any] = [:], roundID: UUID? = nil) throws {
            var object: [String: Any] = ["op": op, "roundID": (roundID ?? controller.round.id).uuidString]
            object.merge(fields) { _, new in new }
            try controller.handle(JSONDecoder().decode(BridgeMessage.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        func libraryCommand(_ op: String, _ fields: [String: Any]) async throws {
            let before = events.count
            try command(op, fields)
            while !events.dropFirst(before).contains(where: {
                op == "search" ? $0["type"] as? String == "search" : $0["focusID"] != nil
            }) { _ = await changesIterator.next() }
        }
        try controller.beginRound()
        let initial = controller.round.cards
        try check(events.last?["pendingID"] as? String == initial.last!.id.uuidString.lowercased(), "snapshots carry the core's pending destination for animated continuation")
        try command("grade", ["cardID": initial.first!.id.uuidString, "grade": 4])
        try command("navigate", ["cardID": initial.last!.id.uuidString])
        try check(try store.progress(language: .english).isEmpty, "reading and navigation do not save learning progress")
        try command("completeRound")
        try check(!controller.round.ended && controller.round.currentID == initial.last!.id, "unfinished tail returns to recall rather than buttonless reading")
        let oldRound = controller.round.id
        try command("grade", ["cardID": initial.last!.id.uuidString, "grade": 4])
        try check(controller.round.reviewCount == 0, "unrevealed recall cannot be graded")
        try command("reveal", ["cardID": initial.last!.id.uuidString])
        try command("grade", ["cardID": initial.last!.id.uuidString, "grade": 4])
        try command("grade", ["cardID": initial.last!.id.uuidString, "grade": 4])
        let persisted = try store.progress(language: .english)[initial.last!.word.key]
        try check(controller.round.reviewCount == 1 && persisted?.reviews == 1, "recall creates progress once without introduction acknowledgment")
        try command("completeRound")
        try check(controller.round.ended && events.last?["title"] as? String == "这一轮学完了", "graded recall completes a round without introduction acknowledgment")
        try check((events.last?["summary"] as? String)?.contains("1 次回想与复习") == true, "round summary counts recorded assessments")
        try controller.beginRound()
        let activeIDs = Set(controller.round.cards.map(\.id))
        let studyPosition = controller.round.currentID
        try await libraryCommand("search", ["query": "o"])
        let searched = events.last { $0["type"] as? String == "search" }!
        let results = searched["words"] as! [[String: String]]
        try await libraryCommand("browse", ["wordID": "two", "query": "o", "requestID": searched["requestID"]!])
        let browse = controller.round.current!
        try check(controller.round.visibleCards.map(\.word.id) == results.map { $0["id"]! }, "library bridge carries ordered search neighbors")
        try check(events.last?["visibleIDs"] as? [String] == controller.round.visibleCards.map { $0.id.uuidString.lowercased() }, "snapshot exposes only the chosen browsing sequence")
        try command("completeRound")
        try check(controller.round.currentID == browse.id && !controller.round.ended, "library boundary cannot finish or redirect study")
        try command("returnToStudy", ["cardID": browse.id.uuidString])
        try check(controller.round.currentID == studyPosition && !controller.round.isBrowsing, "library bridge restores the study selection")
        try await libraryCommand("browse", ["wordID": "two", "query": "two"])
        try check(controller.round.visibleCards.count == 1 && controller.round.currentID == browse.id, "exact search shows one retained browse card")
        try command("practice", ["cardID": browse.id.uuidString])
        try check(activeIDs.isSubset(of: Set(controller.round.cards.map(\.id))) && !controller.round.isBrowsing, "library practice preserves and restores active cards")
        try check(try store.statistics(language: .english).totalReviews == 1, "searching and practicing never write a grade")
        try controller.beginRound()
        let newID = controller.round.id
        try command("endRound", roundID: oldRound)
        try check(controller.round.id == newID && !controller.round.ended, "old bridge commands cannot end a new round")
        controller.finishRound()
        try check(events.last?["title"] as? String == "这一轮先到这里", "unfinished exit is not labeled complete")
        let endedID = controller.round.id
        try await libraryCommand("browse", ["wordID": "one", "query": "o"])
        try check(controller.round.id != endedID && controller.round.isBrowsing && controller.round.visibleCards.count == 2 && controller.round.pending.isEmpty, "browsing after completion opens the result sequence without restarting study")
        try command("returnToStudy", ["cardID": controller.round.currentID!.uuidString])
        try check(controller.round.visibleCards.isEmpty && events.last?["title"] as? String == "暂时没有待学词卡", "returning with no study cards reports an empty workload")

        settings.assistant.provider = .automatic; settings.assistant.model = "configured-model"; settings.assistant.effort = "xhigh"
        let url = directory.appendingPathComponent("settings.json")
        try settings.save(to: url)
        let configured = AppSettings.load(from: url)
        try check(configured.warning == nil && configured.settings.assistant == settings.assistant, "automatic model and effort restore from saved configuration")
        settings.assistant.model = "-invalid-model"
        try JSONEncoder().encode(settings).write(to: url)
        let loaded = AppSettings.load(from: url)
        try check(loaded.warning != nil && loaded.settings.assistant == AssistantConfiguration(), "invalid assistant settings retain offline startup")
        try check(loaded.settings.newLimit == 1, "recovering assistant settings retains learning preferences")
        var retiredSettings = settings; retiredSettings.assistant = AssistantConfiguration()
        let retiredJSON = String(decoding: try JSONEncoder().encode(retiredSettings), as: UTF8.self).replacingOccurrences(of: "\"automatic\"", with: "\"grok\"")
        try Data(retiredJSON.utf8).write(to: url)
        let migrated = AppSettings.load(from: url)
        try check(migrated.warning == nil && migrated.settings.newLimit == settings.newLimit && migrated.settings.language == settings.language && migrated.settings.assistant == AssistantConfiguration(), "retired provider migration preserves learning settings")
        controller.cancelWork()
        updates.finish()
        print("PASS: native bridge, library, completion and settings regressions")
    }
}

@MainActor final class WebKitFixture: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    private var ready: CheckedContinuation<Void, Error>?
    private let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("language-noob-webkit-" + UUID().uuidString)
    private var page: StudyPage!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Deterministic accessibility preference without changing system settings.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        (()=>{const original=window.matchMedia.bind(window),listeners=[];let reduced=false;
          const media={get matches(){return reduced;},addEventListener(type,fn){listeners.push(fn);}};
          window.matchMedia=query=>query==='(prefers-reduced-motion: reduce)'?media:original(query);
          window.testReducedMotion=value=>{reduced=value;listeners.forEach(fn=>fn({matches:value}));};
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = StudyWebView(frame: NSRect(x: 0, y: 0, width: 940, height: 850), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        configuration.userContentController.add(self, name: "study")
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderBack(nil)
    }

    func load() async throws {
        let resources = ApplicationChecks.productDirectory.appendingPathComponent("Sources/LanguageNoob/Resources")
        try FileManager.default.copyItem(at: resources, to: directory)
        page = StudyPage(resources: directory)
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            webView.loadFileURL(page.index, allowingReadAccessTo: page.resources)
        }
    }
    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "study")
        webView.navigationDelegate = nil
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(page.accepts(navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame == true) ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard page.accepts(message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame) else { return }
        if (message.body as? [String: Any])?["op"] as? String == "ready" { ready?.resume(); ready = nil }
        else {
            webView.callAsyncJavaScript("if(message.surfaceLayout)window.testSurfaceLayout=message.surfaceLayout;window.testMessages?.push(message)", arguments: ["message": message.body], in: nil, in: .page)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ready?.resume(throwing: error); ready = nil
    }
}

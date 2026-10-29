import Foundation
import WebKit

final class StudyWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit identifies this independently of the system menu language.
        // Leave native selection, copying and editor actions in place.
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierReload" {
            menu.removeItem(item)
        }
    }
}

/// One canonical resource location for both navigation and native messages.
struct StudyPage {
    let resources: URL
    var index: URL { resources.appendingPathComponent("index.html") }

    init(resources: URL) {
        self.resources = resources.standardizedFileURL
    }

    func accepts(_ url: URL?, isMainFrame: Bool) -> Bool {
        isMainFrame && url?.isFileURL == true && url?.standardizedFileURL.path == index.path
    }
}

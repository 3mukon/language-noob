import AppKit
import WebKit

@main @MainActor struct ApplicationTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Fail a stalled renderer or asynchronous test instead of hanging the check command.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            FileHandle.standardError.write(Data("FAIL: application test timeout\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            do {
                try await ApplicationChecks.run()
                print("PASS: native study controller and WebKit interaction tests")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: application checks: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}

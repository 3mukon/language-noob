import Foundation
import Darwin
import StudyAssistant

@main struct LanguageNoobCLI {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let code = try await CommandRunner.run(arguments)
            await AssistantClient.waitForIdle()
            exit(code)
        } catch {
            await AssistantClient.waitForIdle()
            TerminalText.error("\(error.localizedDescription)\n")
            exit(error is CommandError ? 2 : 1)
        }
    }
}

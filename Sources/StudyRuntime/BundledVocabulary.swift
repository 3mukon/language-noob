import Foundation
import StudyCore
import StudyStorage

public enum BundledVocabulary {
    public static let version = "2026-10-28"

    public static func install(in store: StudyStore, resources supplied: URL? = nil) throws {
        guard try !store.hasBundledVocabulary(version) else { return }
        let resources = try supplied ?? resourceDirectory()
        var words = [Word](), samples = [Word]()
        for language in StudyLanguage.allCases {
            let data = try Data(contentsOf: resources.appendingPathComponent("dictionary-\(language.rawValue).json"), options: .mappedIfSafe)
            words += try VocabularyImport(data: data).words
            let legacy = try Data(contentsOf: resources.appendingPathComponent("sample-\(language.rawValue).json"))
            samples += try VocabularyImport(data: legacy).words
        }
        try store.installBundledVocabulary(words, version: version, legacySamples: samples)
    }
    public static func resourceDirectory() throws -> URL {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "Resources", withExtension: nil) { return url }
        #else
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Vocabulary"),
                          executable.deletingLastPathComponent().appendingPathComponent("../Resources/Vocabulary").standardizedFileURL]
        if let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("dictionary-en.json").path)
        }) { return url }
        #endif
        throw CocoaError(.fileNoSuchFile)
    }

}

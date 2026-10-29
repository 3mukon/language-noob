// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanguageNoob",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LanguageNoob", targets: ["LanguageNoob"]),
               .executable(name: "language-noob", targets: ["LanguageNoobCLI"])],
    targets: [
        .target(name: "StudyCore", exclude: ["README.md"]),
        .target(name: "StudyStorage", dependencies: ["StudyCore"], exclude: ["README.md"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "StudyAssistant", dependencies: ["StudyCore"], exclude: ["README.md"]),
        .target(name: "StudyRuntime", dependencies: ["StudyCore", "StudyStorage", "StudyAssistant"], exclude: ["README.md"], resources: [.copy("Resources")]),
        .executableTarget(name: "LanguageNoob", dependencies: ["StudyCore", "StudyStorage", "StudyAssistant", "StudyRuntime"], exclude: ["README.md"], resources: [.copy("Resources")]),
        .executableTarget(name: "LanguageNoobCLI", dependencies: ["StudyCore", "StudyStorage", "StudyAssistant", "StudyRuntime"], exclude: ["README.md"]),
        .executableTarget(name: "LanguageNoobTests", dependencies: ["StudyCore", "StudyStorage", "StudyAssistant", "StudyRuntime"], path: "Tests/LanguageNoobTests")
    ]
)

import Foundation
import StudyRuntime

typealias AppSettings = StudySettings

/// An inherited value is editable text, but only an actual edit creates an override.
struct AssistantInheritedText {
    private var override: String
    private var inherited = ""
    private var draft: String?

    init(override: String = "") { self.override = override }
    var storedValue: String { (draft ?? override).trimmingCharacters(in: .whitespacesAndNewlines) }
    var isInherited: Bool { storedValue.isEmpty }
    var isEditing: Bool { draft != nil }
    var displayedValue: String { draft ?? (isInherited ? inherited : override) }

    mutating func receive(_ value: String) { inherited = value }
    mutating func edit(_ value: String) { draft = value }
    mutating func finishEditing() {
        if draft != nil { override = storedValue }
        draft = nil
    }
}

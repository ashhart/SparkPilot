import Foundation
import SparkAPI

/// One named part of what the app tells a model before a conversation starts.
struct SparkChatInstructionSection: Equatable, Sendable {
    let name: String
    let text: String
}

/// The ordered sections every chat request carries, joined into exactly one system message.
enum SparkChatInstructionAssembly {
    // Keep sections in one ordered system message so SparkChat.send has one assembly point.
    @TaskLocal static var sections: [SparkChatInstructionSection] = []

    /// Sections a conversation supplies for itself, such as its plain-style choice, follow the standing ones.
    static func systemMessage(extra: [SparkChatInstructionSection] = []) -> String? {
        let text =
            (sections + extra)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}

extension SparkChatModel {
    /// What this conversation adds to the app's standing instructions.
    var instructionSections: [SparkChatInstructionSection] {
        [
            SparkChartInstruction.section,
            SparkChatPlainStyle.section(isEnabled: usesPlainStyle),
            SparkChatInstructionSection(name: "personal-context", text: personal.systemMessage()),
        ]
    }
}

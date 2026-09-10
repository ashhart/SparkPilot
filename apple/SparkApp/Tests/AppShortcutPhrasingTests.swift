import Foundation
import Testing

@testable import SparkAppComposition

private func shortcutsSource() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return try String(
        contentsOf: appRoot.appending(path: "ExecutableShared/SparkPilotShortcuts.swift"),
        encoding: .utf8
    )
}

private func quoted(after key: String, in source: String) -> [String] {
    source.components(separatedBy: "\(key): \"").dropFirst().compactMap { rest in
        let value = String(rest.prefix(while: { $0 != "\"" }))
        return value.isEmpty ? nil : value
    }
}

/// QA-23: the Shortcuts app listed tiles named like internal types beside "Ask Spark" and "Check Spark"; a tile is a thing a person says, never a type.
@Test func noAppShortcutTileReadsLikeAnInternalType() throws {
    let titles = quoted(after: "shortTitle", in: try shortcutsSource())
    let internalWords = [
        "action", "intent", "entity", "object", "handler", "provider", "payload", "config",
        "request", "response", "saved", "item",
    ]

    #expect(titles.count == 10, "every shortcut is checked")
    for title in titles {
        let words = title.lowercased().split(separator: " ").map(String.init)
        for word in words {
            #expect(!internalWords.contains(word), "\"\(title)\" reads like an internal name")
        }
        #expect(words.count <= 3, "\"\(title)\" is longer than a tile can show")
    }
}

/// QA-23: one stiff phrase per shortcut is one way of asking; Siri needs the ways people actually ask.
@Test func everyAppShortcutOffersMoreThanOneWayOfAskingForIt() throws {
    let source = try shortcutsSource()
    let shortcuts = source.components(separatedBy: "AppShortcut(").dropFirst()

    #expect(shortcuts.count == 10)
    for shortcut in shortcuts {
        let phrases =
            shortcut
            .components(separatedBy: "phrases: [").dropFirst().first?
            .components(separatedBy: "]").first ?? ""
        let spoken = phrases.components(separatedBy: "\"").filter { $0.contains("applicationName") }
        #expect(spoken.count >= 2, "a shortcut with only \(spoken.count) phrase(s)")
        for phrase in spoken {
            #expect(phrase.contains("\\(.applicationName)"), "a phrase that never names the app")
        }
    }
}

import Foundation
import Testing

/// PLAN 48.2's CI gate checks built metadata against a hand-written list that silently drifts.
private func appIntentsGateSources() throws -> (registered: [String], expected: [String]) {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let repoRoot = appRoot.deletingLastPathComponent().deletingLastPathComponent()
    let shortcuts = try String(
        contentsOf: appRoot.appending(path: "ExecutableShared/SparkPilotShortcuts.swift"),
        encoding: .utf8
    )
    let gate = try String(
        contentsOf: repoRoot.appending(path: "tools/test-app-intents-metadata.sh"),
        encoding: .utf8
    )

    let registered = shortcuts.split(separator: "\n").compactMap { line -> String? in
        guard let marker = line.range(of: "intent: ") else { return nil }
        let rest = line[marker.upperBound...]
        guard let open = rest.firstIndex(of: "(") else { return nil }
        return String(rest[..<open])
    }
    let expectedLine =
        gate
        .split(separator: "\n")
        .first { $0.hasPrefix("expected=") } ?? ""
    let expected =
        expectedLine
        .split(separator: "\"")
        .map(String.init)
        .filter { $0.hasSuffix("Intent") }
    return (registered, expected)
}

@Test func theAppIntentsGateExpectsEveryShortcutTheAppRegisters() throws {
    let (registered, expected) = try appIntentsGateSources()

    #expect(!registered.isEmpty)
    #expect(Set(registered).count == registered.count, "a shortcut is registered twice")
    #expect(Set(expected) == Set(registered))
}

/// Both drafting intents ship, and both are the ones the gate most recently lost track of.
@Test func theDraftingIntentsAreRegisteredAndChecked() throws {
    let (registered, expected) = try appIntentsGateSources()

    for identifier in ["DraftReplyWithSparkIntent", "DraftEmailWithSparkIntent"] {
        #expect(registered.contains(identifier))
        #expect(expected.contains(identifier))
    }
}

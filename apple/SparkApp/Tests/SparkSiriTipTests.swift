import Foundation
import Testing

@testable import SparkAppComposition

/// QA-16: Settings drew the Siri glyph beside a blank grey pill, because `SiriTipView` had no donated phrase to quote.
@Test func theSiriTipNeverRendersWithoutAPhrase() throws {
    let phrase = try #require(SparkSiriTip.spokenPhrase)
    #expect(!phrase.isEmpty)

    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let view = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkAppleAppsView.swift"),
        encoding: .utf8
    )
    #expect(!view.contains("SiriTipView"), "the empty capsule came from the system tip view")
    #expect(view.contains("SparkSiriTip.spokenPhrase"))
}

/// QA-16: a tip is worthless if it quotes something Siri will not accept, so it says exactly what the app registers.
@Test func theSiriTipQuotesAPhraseTheAppActuallyRegisters() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let shortcuts = try String(
        contentsOf: appRoot.appending(path: "ExecutableShared/SparkPilotShortcuts.swift"),
        encoding: .utf8
    )
    let registered =
        shortcuts
        .components(separatedBy: "\"")
        .filter { $0.contains("\\(.applicationName)") }
        .map { $0.replacingOccurrences(of: "\\(.applicationName)", with: "SparkPilot") }

    #expect(registered.contains(try #require(SparkSiriTip.spokenPhrase)))
}

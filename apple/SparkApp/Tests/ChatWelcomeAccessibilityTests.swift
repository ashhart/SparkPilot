import Foundation
import SwiftUI
import Testing

@testable import SparkAppComposition

/// QA-10: at AX5 the welcome block was taller than the transcript viewport, so its heading was clipped and its three starters sat below the fold.
@Test func theChatWelcomeDropsItsSupportingLineAtAccessibilitySizes() {
    #expect(SparkChatWelcomeLayout.resolve(.large).showsSupportingLine)
    #expect(SparkChatWelcomeLayout.resolve(.xxxLarge).showsSupportingLine)
    #expect(!SparkChatWelcomeLayout.resolve(.accessibility1).showsSupportingLine)
    #expect(!SparkChatWelcomeLayout.resolve(.accessibility5).showsSupportingLine)
}

/// QA-10: the heading drops to a shorter ramp at accessibility sizes; it still scales, it just stops spending five lines saying it.
@Test func theChatWelcomeHeadingUsesAShorterRampAtAccessibilitySizes() {
    #expect(!SparkChatWelcomeLayout.resolve(.large).usesCompactHeading)
    #expect(SparkChatWelcomeLayout.resolve(.accessibility3).usesCompactHeading)
    #expect(
        SparkChatWelcomeLayout.resolve(.accessibility5).blockSpacing
            < SparkChatWelcomeLayout.resolve(.large).blockSpacing
    )
}

/// QA-10: a starter row with a fixed height clips its own label, so the welcome may not declare one.
@Test func theChatWelcomeStartersHaveNoFixedHeight() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkChatWelcomeView.swift"),
        encoding: .utf8
    )

    #expect(!source.contains("minHeight:"))
    #expect(!source.contains("maxHeight:"))
    #expect(!source.contains("minimumScaleFactor"))
    #expect(source.contains("fixedSize(horizontal: false, vertical: true)"))
}

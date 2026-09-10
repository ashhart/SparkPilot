import Foundation
import SparkWidgetSupport
import Testing

private func widgetCardSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appending(path: "WidgetShared/SparkWidgetCard.swift"),
        encoding: .utf8
    )
}

/// QA-24: the small tile cut off its target name, and one warning was orange and nothing else.
@Suite struct SparkWidgetCardPresentationTests {
    @Test func theSmallTileGivesANameASecondLineRatherThanCuttingItOff() {
        #expect(SparkWidgetCardPresentation.titleLineLimit(.small) == 2)
        #expect(SparkWidgetCardPresentation.titleLineLimit(.medium) == 1)
        #expect(SparkWidgetCardPresentation.titleLineLimit(.large) == 1)
        #expect(SparkWidgetCardPresentation.titleMinimumScale < 1)
        #expect(SparkWidgetCardPresentation.titleMinimumScale > 0.5)
    }

    @Test func fullCoverageCarriesNoWarningAtAll() {
        #expect(SparkWidgetCardPresentation.coverageLine(reporting: 3, expected: 3) == nil)
        #expect(SparkWidgetCardPresentation.coverageLine(reporting: 0, expected: 0) == nil)
    }

    @Test func aPartialReadingSaysSoWithASymbolAndNotOnlyWithOrange() throws {
        let line = try #require(SparkWidgetCardPresentation.coverageLine(reporting: 2, expected: 3))
        #expect(line.text == "2 of 3 reporting")
        #expect(!line.symbol.isEmpty)
    }

    @Test func theCardDrawsBothRatherThanRelyingOnTheColour() throws {
        let source = try widgetCardSource()
        #expect(source.contains("SparkWidgetCardPresentation.coverageLine"))
        #expect(source.contains("Image(systemName: line.symbol)"))
        #expect(source.contains("SparkWidgetCardPresentation.titleLineLimit(size)"))
        #expect(
            !source.contains(".lineLimit(1)\n                    Spacer(minLength: 0)"),
            "the header still truncates the target name at one line"
        )
    }
}

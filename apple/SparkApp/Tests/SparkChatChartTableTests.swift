import Foundation
import Testing

@testable import SparkAppComposition

@Test func aNumericMarkdownTableBecomesTheSameChartWithoutAskingTheModel() throws {
    let text = """
        Here is the month:

        | Month | Requests | Errors |
        | --- | ---: | :---: |
        | Jan | 1,024 | 3 |
        | Feb | 980 | 5 |
        | Mar | 1,190 | 2 |

        That is all.
        """
    let table = try #require(SparkChatTable.first(in: text))
    #expect(table.headers == ["Month", "Requests", "Errors"])
    #expect(table.rows.count == 3)
    let spec = try #require(SparkChatTable.chart(table))
    #expect(spec.kind == .bar)
    #expect(spec.valueKind == .category)
    #expect(spec.title.contains("Requests"))
    #expect(spec.title.contains("Month"))
    #expect(spec.x.label == "Month")
    #expect(spec.series.map(\.name) == ["Requests", "Errors"])
    #expect(spec.series[0].points.map(\.y) == [1024, 980, 1190])
    #expect(spec.series[0].points.first?.x == .category("Jan"))
    #expect(spec.series[1].points.map(\.y) == [3, 5, 2])
}

@Test func aTableColumnCarriesItsUnitAndItsDatesIntoTheChart() throws {
    let single = try #require(
        SparkChatTable.first(
            in: """
                | Day | Memory (GiB) |
                | --- | --- |
                | 2026-03-01 | 12.5 |
                | 2026-03-02 | 13 |
                """
        )
    )
    let spec = try #require(SparkChatTable.chart(single))
    #expect(spec.kind == .line)
    #expect(spec.valueKind == .date)
    #expect(spec.y.unit == "GiB")
    #expect(spec.y.label == "Memory")
    #expect(spec.series[0].points.map(\.y) == [12.5, 13])

    let shares = try #require(
        SparkChatTable.first(in: "Share | Amount\n---|---\nModels | 70%\nFree | 30%")
    )
    #expect(try #require(SparkChatTable.chart(shares)).y.unit == "%")
}

@Test func aTableTheAppCannotChartOffersNothing() throws {
    #expect(SparkChatTable.first(in: "No table here at all.") == nil)
    #expect(SparkChatTable.first(in: "| Month | Requests |\n| Jan | 3 |") == nil)
    let words = try #require(
        SparkChatTable.first(in: "| Spark | State |\n| --- | --- |\n| One | Ready |")
    )
    #expect(SparkChatTable.chart(words) == nil)
    let repeated = try #require(
        SparkChatTable.first(in: "| Day | N |\n| --- | --- |\n| Mon | 1 |\n| Mon | 2 |")
    )
    #expect(SparkChatTable.chart(repeated) == nil)
    let rows = (0...SparkChartLimits.pointsPerSeries).map { "| r\($0) | \($0) |" }
    let long = try #require(
        SparkChatTable.first(in: (["| Row | N |", "| --- | --- |"] + rows).joined(separator: "\n"))
    )
    #expect(SparkChatTable.chart(long) == nil)
}

@Test func aTableKnowsWhichLinesItOccupiesSoTheRestStaysProse() throws {
    let text = """
        Here is the month:

        | Month | Requests |
        | --- | --- |
        | Jan | 1,024 |

        That is all.
        """
    let table = try #require(SparkChatTable.first(in: text))
    #expect(table.lines == 2..<5)
    let lines = text.components(separatedBy: "\n")
    #expect(lines[..<table.lines.lowerBound].joined() == "Here is the month:")
    #expect(lines[table.lines.upperBound...].joined(separator: " ") == " That is all.")
}

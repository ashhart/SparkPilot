import Foundation
import Testing

@testable import SparkAppComposition

private let lineChart = """
    {"type":"line","title":"Requests answered","y":{"unit":"req"},
     "series":[{"name":"Spark","points":[{"x":1,"y":128},{"x":2,"y":143},{"x":3,"y":97}]}]}
    """

private func onlyBlock(_ text: String) throws -> SparkChatMarkdown.Block {
    let blocks = SparkChatMarkdown.blocks(in: text)
    #expect(blocks.count == 1, "\(blocks)")
    return try #require(blocks.first)
}

@Test func aClosedChartFenceBecomesADrawableBlockBesideOrdinaryMarkdown() throws {
    let text = "Here it is.\n\n```spark-chart\n\(lineChart)\n```\n\nThat is the trend."
    let blocks = SparkChatMarkdown.blocks(in: text)
    #expect(blocks.count == 3, "\(blocks)")
    guard case .chart(.ready(let spec)) = blocks[1] else {
        Issue.record("the fence did not become a chart: \(blocks)")
        return
    }
    #expect(spec.title == "Requests answered")
    #expect(blocks[0] == .paragraph("Here it is."))
    #expect(blocks[2] == .paragraph("That is the trend."))
    // The info string is the whole word, whatever case the model wrote it in.
    #expect(SparkChatMarkdown.blocks(in: "```SPARK-CHART\n\(lineChart)\n```") == [blocks[1]])
    #expect(
        SparkChatMarkdown.blocks(in: "```spark-charts\n\(lineChart)\n```")
            == [.code(language: "spark-charts", text: lineChart + "\n")]
    )
}

@Test func anUnfinishedChartFenceWaitsForTheModelToCloseIt() throws {
    let partial = String(lineChart.prefix(40))
    guard case .chart(.pending(let source)) = try onlyBlock("```spark-chart\n" + partial) else {
        Issue.record("a half-written chart was treated as finished")
        return
    }
    #expect(source == partial)
    #expect(try onlyBlock("```spark-chart\n") == .chart(.pending("")))
    // Closing it later produces the chart without losing a character on the way.
    guard case .chart(.ready) = try onlyBlock("```spark-chart\n\(lineChart)\n```") else {
        Issue.record("the closed fence did not parse")
        return
    }
}

@Test func anInvalidChartKeepsItsSourceAndSaysWhyInOneLine() throws {
    let block = try onlyBlock("```spark-chart\n{\"type\":\"pyramid\"}\n```")
    guard case .chart(.invalid(let source, let reason)) = block else {
        Issue.record("an unreadable chart was not refused: \(block)")
        return
    }
    #expect(source == "{\"type\":\"pyramid\"}\n")
    #expect(reason == .unknownType)
    #expect(!reason.message.isEmpty)
}

@Test func aChartSpeaksItsTypeItsSeriesAndTheirLowestHighestAndLatestValues() throws {
    let spec = try SparkChartSpec.parse(lineChart).get()
    let summary = SparkChartAccessibility.summary(spec)
    #expect(summary.contains("Line chart"), "\(summary)")
    #expect(summary.contains("Requests answered"), "\(summary)")
    #expect(summary.contains("Spark"), "\(summary)")
    #expect(summary.contains("latest 97 req"), "\(summary)")
    #expect(summary.contains("lowest 97 req"), "\(summary)")
    #expect(summary.contains("highest 143 req"), "\(summary)")

    let pie = try SparkChartSpec.parse(
        """
        {"type":"donut","title":"Storage",
         "series":[{"name":"Use","points":[{"x":"Models","y":180},{"x":"Free","y":76}]}]}
        """
    ).get()
    let spoken = SparkChartAccessibility.summary(pie)
    #expect(spoken.contains("Donut chart"), "\(spoken)")
    #expect(spoken.contains("Use"), "\(spoken)")
    #expect(!spoken.contains("req"), "\(spoken)")

    let stacked = try SparkChartSpec.parse(
        """
        {"type":"bar","title":"Hours","stacked":true,"series":[
          {"name":"A","points":[{"x":"Mon","y":1}]},
          {"name":"B","points":[{"x":"Mon","y":2}]}]}
        """
    ).get()
    let both = SparkChartAccessibility.summary(stacked)
    #expect(both.contains("Stacked bar chart"), "\(both)")
    #expect(both.contains("A"), "\(both)")
    #expect(both.contains("B"), "\(both)")
}

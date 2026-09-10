import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

@Test func namedInstructionSectionsBecomeOneSystemMessageInDeclaredOrder() throws {
    let extra = [
        SparkChartInstruction.section,
        SparkChatInstructionSection(name: "switched-off", text: ""),
        SparkChatInstructionSection(name: "personal-context", text: "The owner's day."),
    ]
    let joined = try #require(SparkChatInstructionAssembly.systemMessage(extra: extra))
    #expect(joined.hasPrefix(SparkChartInstruction.instruction))
    #expect(joined.hasSuffix("The owner's day."))
    #expect(!joined.contains("\n\n\n"), "a section with nothing to say adds nothing")
    #expect(SparkChatInstructionAssembly.systemMessage(extra: []) == nil)

    let standing = SparkChatInstructionSection(name: "standing", text: "Standing text.")
    let withStanding = SparkChatInstructionAssembly.$sections.withValue([standing]) {
        SparkChatInstructionAssembly.systemMessage(extra: extra)
    }
    #expect(try #require(withStanding).hasPrefix("Standing text."))
}

@Test func theChartInstructionTellsAModelExactlyWhatTheAppWillAccept() throws {
    let charts = SparkChartInstruction.section.text
    #expect(SparkChartInstruction.section.name == "charts")
    for kind in SparkChartKind.allCases {
        #expect(charts.contains(kind.rawValue), "\(kind) is not named in the instruction")
    }
    for value in SparkChartValueKind.allCases {
        #expect(charts.contains(value.rawValue), "\(value) is not named in the instruction")
    }
    #expect(charts.contains("```\(SparkChatChartFence.info)"))
    #expect(charts.contains("\(SparkChartLimits.series)"))
    #expect(charts.contains("\(SparkChartLimits.pointsPerSeries)"))
    // The example the instruction shows must be one the parser accepts.
    let fenced = SparkChatMarkdown.blocks(in: charts).compactMap { block -> SparkChartSpec? in
        guard case .chart(.ready(let spec)) = block else { return nil }
        return spec
    }
    #expect(fenced.count == 1, "the instruction's own example does not parse")
}

@MainActor
@Test func everyChatRequestCarriesTheChartInstructionAheadOfTheConversation() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    #expect(model.instructionSections.first?.name == "charts")
    model.draft = "Chart my week"
    // BH-23: a standing section is bound so a second emitter cannot hide behind an empty list.
    let standing = SparkChatInstructionSection(name: "standing", text: "Standing text.")
    let task = try SparkChatInstructionAssembly.$sections.withValue([standing]) {
        try #require(model.send())
    }
    try await chatTestWaitUntil { await streamer.requests.count == 1 }
    await streamer.finish()
    await task.value

    let request = try #require(await streamer.requests.first)
    #expect(request.messages.first?.role == "system")
    #expect(request.messages.filter { $0.role == "system" }.count == 1)
    #expect(request.messages.first?.content.hasPrefix("Standing text.") == true)
    #expect(request.messages.first?.content.contains(SparkChartInstruction.instruction) == true)
    #expect(request.messages.last?.content == "Chart my week")
}

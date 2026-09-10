import Foundation
import Testing

@testable import SparkAppComposition

/// The documented example in `docs/protocol/chat-chart-spec.md`, verbatim.
private let documentedChart = """
    {
      "type": "line",
      "title": "Requests answered",
      "x": { "label": "Day", "kind": "date" },
      "y": { "label": "Requests", "unit": "req" },
      "series": [
        {
          "name": "Spark",
          "points": [
            { "x": "2026-03-01", "y": 128 },
            { "x": "2026-03-02", "y": 143 },
            { "x": "2026-03-03", "y": 97 }
          ]
        }
      ],
      "annotations": [{ "x": "2026-03-03", "text": "Model reload" }]
    }
    """

private func rejection(_ source: String) throws -> SparkChartSpecError {
    switch SparkChartSpec.parse(source) {
    case .success(let spec):
        Issue.record("accepted a chart it should have refused: \(spec.title)")
        throw SparkChartSpecError.malformed
    case .failure(let error):
        return error
    }
}

private func accepted(_ source: String) throws -> SparkChartSpec {
    try SparkChartSpec.parse(source).get()
}

@Test func theDocumentedChartExampleParsesIntoSomethingDrawable() throws {
    let spec = try accepted(documentedChart)
    #expect(spec.kind == .line)
    #expect(spec.title == "Requests answered")
    #expect(spec.valueKind == .date)
    #expect(spec.x.label == "Day")
    #expect(spec.y.unit == "req")
    #expect(spec.series.map(\.name) == ["Spark"])
    #expect(spec.series[0].points.map(\.y) == [128, 143, 97])
    #expect(spec.annotations.map(\.text) == ["Model reload"])
    let first = try #require(spec.series.first?.points.first)
    let expected = try #require(
        ISO8601DateFormatter.sparkChartDate.date(from: "2026-03-01T00:00:00Z")
    )
    #expect(first.x == .date(expected))
    #expect(spec.isStacked == false)
}

@Test func everyDocumentedChartTypeIsAccepted() throws {
    for type in ["line", "bar", "area", "pie", "donut", "scatter"] {
        let source = """
            {"type":"\(type)","title":"T",
             "series":[{"name":"S","points":[{"x":"a","y":1},{"x":"b","y":2}]}]}
            """
        #expect(try accepted(source).kind.rawValue == type)
    }
    let grouped = try accepted(
        """
        {"type":"bar","title":"T","stacked":true,
         "series":[{"name":"S","points":[{"x":"a","y":1}]}]}
        """
    )
    #expect(grouped.isStacked)
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","stacked":true,
             "series":[{"name":"S","points":[{"x":"a","y":1}]}]}
            """
        ) == .stackingUnsupported
    )
}

@Test func aChartRejectsMoreSeriesPointsOrTextThanTheAppWillDraw() throws {
    let series = (0...SparkChartLimits.series).map {
        "{\"name\":\"S\($0)\",\"points\":[{\"x\":1,\"y\":1}]}"
    }
    #expect(
        try rejection(
            "{\"type\":\"line\",\"title\":\"T\",\"series\":[\(series.joined(separator: ","))]}"
        )
            == .tooManySeries
    )

    let points = (0...SparkChartLimits.pointsPerSeries).map { "{\"x\":\($0),\"y\":1}" }
    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[\(points.joined(separator: ","))]}]}
            """
        ) == .tooManyPoints
    )

    let title = String(repeating: "t", count: SparkChartLimits.titleCharacters + 1)
    #expect(
        try rejection(
            "{\"type\":\"line\",\"title\":\"\(title)\",\"series\":[{\"name\":\"S\",\"points\":[{\"x\":1,\"y\":1}]}]}"
        ) == .textTooLong
    )

    let padding = String(repeating: " ", count: SparkChartLimits.sourceBytes)
    #expect(try rejection(documentedChart + padding) == .tooLarge)
}

@Test func aChartRejectsEveryShapeTheAppDoesNotUnderstand() throws {
    #expect(try rejection("not json at all") == .malformed)
    #expect(try rejection("[1, 2, 3]") == .malformed)
    #expect(try rejection("") == .malformed)
    #expect(
        try rejection("{\"type\":\"pyramid\",\"title\":\"T\",\"series\":[]}") == .unknownType
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","href":"https://example.invalid",
             "series":[{"name":"S","points":[{"x":1,"y":1}]}]}
            """
        ) == .unknownField
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[{"x":1,"y":1,"colour":"red"}]}]}
            """
        ) == .unknownField
    )
    #expect(try rejection("{\"type\":\"line\",\"series\":[]}") == .missingField)
    #expect(
        try rejection("{\"type\":\"line\",\"title\":\"T\",\"series\":[]}") == .emptySeries
    )
    #expect(
        try rejection(
            "{\"type\":\"line\",\"title\":\"T\",\"series\":[{\"name\":\"S\",\"points\":[]}]}"
        ) == .emptySeries
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","series":[
              {"name":"S","points":[{"x":1,"y":1}]},
              {"name":"S","points":[{"x":1,"y":2}]}]}
            """
        ) == .duplicateSeries
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[{"x":1,"y":"3"}]}]}
            """
        ) == .notANumber
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[{"x":1,"y":true}]}]}
            """
        ) == .notANumber
    )
    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[{"x":1,"y":1},{"x":1,"y":2}]}]}
            """
        ) == .repeatedValue
    )
}

@Test func chartXValuesAreNumbersDatesOrLabelsAndNeverACoercion() throws {
    let numbers = try accepted(
        "{\"type\":\"line\",\"title\":\"T\",\"series\":[{\"name\":\"S\",\"points\":[{\"x\":1,\"y\":2}]}]}"
    )
    #expect(numbers.valueKind == .number)
    #expect(numbers.series[0].points[0].x == .number(1))

    let labels = try accepted(
        """
        {"type":"bar","title":"T",
         "series":[{"name":"S","points":[{"x":"2026 total","y":2}]}]}
        """
    )
    #expect(labels.valueKind == .category)
    #expect(labels.series[0].points[0].x == .category("2026 total"))

    let stamped = try accepted(
        """
        {"type":"line","title":"T",
         "series":[{"name":"S","points":[{"x":"2026-03-01T09:30:00Z","y":2}]}]}
        """
    )
    #expect(stamped.valueKind == .date)

    #expect(
        try rejection(
            """
            {"type":"line","title":"T",
             "series":[{"name":"S","points":[{"x":1,"y":2},{"x":"two","y":3}]}]}
            """
        ) == .mixedValues
    )
    // A declared kind is a promise, not a hint: a label where dates were declared is refused.
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","x":{"kind":"date"},
             "series":[{"name":"S","points":[{"x":"Monday","y":2}]}]}
            """
        ) == .mixedValues
    )
    // A second series may name a subset of the first series' labels but not another kind.
    let shared = try accepted(
        """
        {"type":"bar","title":"T","series":[
          {"name":"A","points":[{"x":"one","y":1},{"x":"two","y":2}]},
          {"name":"B","points":[{"x":"two","y":4}]}]}
        """
    )
    #expect(shared.categories == ["one", "two"])
}

@Test func aPieChartNeedsOneSeriesOfLabelledValuesThatAreNotNegative() throws {
    #expect(
        try rejection(
            """
            {"type":"pie","title":"T","series":[
              {"name":"A","points":[{"x":"one","y":1}]},
              {"name":"B","points":[{"x":"two","y":1}]}]}
            """
        ) == .pieShape
    )
    #expect(
        try rejection(
            """
            {"type":"donut","title":"T",
             "series":[{"name":"A","points":[{"x":"one","y":-1}]}]}
            """
        ) == .pieShape
    )
    #expect(
        try rejection(
            "{\"type\":\"pie\",\"title\":\"T\",\"series\":[{\"name\":\"A\",\"points\":[{\"x\":1,\"y\":1}]}]}"
        ) == .pieShape
    )
    let pie = try accepted(
        """
        {"type":"donut","title":"Storage","y":{"unit":"GiB"},"series":[
          {"name":"Use","points":[{"x":"Models","y":180},{"x":"Free","y":76}]}]}
        """
    )
    #expect(pie.series[0].points.map(\.y) == [180, 76])
}

@Test func anAnnotationIsBoundedTextAndNeverAnInstruction() throws {
    let text = String(repeating: "a", count: SparkChartLimits.annotationCharacters + 1)
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","annotations":[{"text":"\(text)"}],
             "series":[{"name":"S","points":[{"x":1,"y":1}]}]}
            """
        ) == .textTooLong
    )
    let many = (0...SparkChartLimits.annotations).map { "{\"text\":\"a\($0)\"}" }
    #expect(
        try rejection(
            """
            {"type":"line","title":"T","annotations":[\(many.joined(separator: ","))],
             "series":[{"name":"S","points":[{"x":1,"y":1}]}]}
            """
        ) == .tooManyAnnotations
    )
    let spec = try accepted(
        """
        {"type":"line","title":"T","annotations":[{"x":2,"y":9,"text":"Reload"}],
         "series":[{"name":"S","points":[{"x":1,"y":1},{"x":2,"y":9}]}]}
        """
    )
    #expect(spec.annotations[0].x == .number(2))
    #expect(spec.annotations[0].y == 9)
}

@Test func everyRejectionSaysWhyInWordsAnOwnerCanRead() {
    for error in SparkChartSpecError.allCases {
        let message = error.message
        #expect(!message.isEmpty, "\(error)")
        #expect(!message.contains("_"), "\(error) reads like an identifier: \(message)")
        #expect(message.hasSuffix("."), "\(error) is not a sentence: \(message)")
    }
}

@Test func anAxisNamesItselfWithItsUnitBesideIt() {
    #expect(SparkChartAxis(label: "Requests", unit: "req").title == "Requests (req)")
    #expect(SparkChartAxis(label: "Requests").title == "Requests")
    #expect(SparkChartAxis(unit: "req").title == "req")
    #expect(SparkChartAxis.none.title == nil)
}

@Test func aChartOfAFewDaysNamesEveryDayItDraws() throws {
    let days = (1...3).map { "{\"x\":\"2026-03-0\($0)\",\"y\":\($0)}" }.joined(separator: ",")
    let daily = try SparkChartSpec.parse(
        "{\"type\":\"line\",\"title\":\"Requests\",\"series\":[{\"name\":\"Spark\",\"points\":[\(days)]}]}"
    ).get()
    #expect(daily.datedPositions.count == 3)
    #expect(daily.datedPositions == daily.datedPositions.sorted())

    let many = (1...9).map { "{\"x\":\"2026-03-0\($0)\",\"y\":\($0)}" }.joined(separator: ",")
    let crowded = try SparkChartSpec.parse(
        "{\"type\":\"line\",\"title\":\"Requests\",\"series\":[{\"name\":\"Spark\",\"points\":[\(many)]}]}"
    ).get()
    #expect(crowded.datedPositions.isEmpty, "a crowded axis is left to the framework to thin out")

    let labelled = try SparkChartSpec.parse(
        """
        {"type":"bar","title":"Hours","series":[{"name":"A","points":[
        {"x":"Mon","y":1},{"x":"Tue","y":2}]}]}
        """
    ).get()
    #expect(labelled.datedPositions.isEmpty)
}

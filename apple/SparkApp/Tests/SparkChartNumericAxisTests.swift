import Foundation
import Testing

@testable import SparkAppComposition

private func numericChart(_ xValues: [Int]) throws -> SparkChartSpec {
    let points = xValues.map { "{\"x\":\($0),\"y\":\($0 * 2)}" }.joined(separator: ",")
    return try SparkChartSpec.parse(
        "{\"type\":\"line\",\"title\":\"Requests\",\"series\":[{\"name\":\"Spark\",\"points\":[\(points)]}]}"
    ).get()
}

/// QA-11: ticks were labelled 0…3 for data at x = 1…4 — a phantom gridline at the left and the last point on a nameless one.
@Test func aNumericAxisLabelsExactlyTheGridlinesThatCarryPoints() throws {
    let chart = try numericChart([1, 2, 3, 4])

    #expect(chart.numberedPositions == [1, 2, 3, 4])
    #expect(!chart.numberedPositions.contains(0), "no gridline is drawn where there is no point")
    #expect(chart.numberedPositions.last == 4, "the right-most point carries a label of its own")
}

/// QA-11: out-of-order and repeated readings still produce one ascending run of gridlines.
@Test func aNumericAxisIsOrderedAndDrawnOnce() throws {
    let chart = try numericChart([5, 2, 9])

    #expect(chart.numberedPositions == [2, 5, 9])
}

/// QA-11: past the labelling budget the framework thins the axis, exactly as it already does for dates.
@Test func aCrowdedNumericAxisIsLeftToTheFramework() throws {
    #expect(try numericChart(Array(1...9)).numberedPositions.isEmpty)
    #expect(try numericChart(Array(1...8)).numberedPositions.count == 8)
}

/// QA-11: dates and categories keep their own axis handling.
@Test func onlyANumericAxisGetsNumericGridlines() throws {
    let categories = try SparkChartSpec.parse(
        """
        {"type":"bar","title":"Hours","series":[{"name":"A","points":[
        {"x":"Mon","y":1},{"x":"Tue","y":2}]}]}
        """
    ).get()
    #expect(categories.numberedPositions.isEmpty)

    let days = (1...3).map { "{\"x\":\"2026-03-0\($0)\",\"y\":\($0)}" }.joined(separator: ",")
    let dated = try SparkChartSpec.parse(
        "{\"type\":\"line\",\"title\":\"Requests\",\"series\":[{\"name\":\"Spark\",\"points\":[\(days)]}]}"
    ).get()
    #expect(dated.numberedPositions.isEmpty)
    #expect(dated.datedPositions.count == 3)
}

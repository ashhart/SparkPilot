import Foundation

/// Hard bounds on a `spark-chart` block, checked while parsing so nothing oversized reaches a view.
enum SparkChartLimits {
    static let sourceBytes = 16 * 1024
    static let series = 8
    static let pointsPerSeries = 500
    static let points = 2000
    static let annotations = 12
    static let titleCharacters = 120
    static let labelCharacters = 60
    static let unitCharacters = 16
    static let nameCharacters = 60
    static let categoryCharacters = 60
    static let annotationCharacters = 120
}

enum SparkChartKind: String, Equatable, Sendable, CaseIterable {
    case line
    case bar
    case area
    case pie
    case donut
    case scatter

    var isCircular: Bool { self == .pie || self == .donut }
    var allowsStacking: Bool { self == .bar || self == .area }
}

/// What a chart's x axis carries. Every point in the chart agrees on one of these.
enum SparkChartValueKind: String, Equatable, Sendable, CaseIterable {
    case number
    case date
    case category
}

enum SparkChartValue: Hashable, Sendable {
    case number(Double)
    case date(Date)
    case category(String)

    var kind: SparkChartValueKind {
        switch self {
        case .number: .number
        case .date: .date
        case .category: .category
        }
    }
}

struct SparkChartPoint: Equatable, Sendable {
    let x: SparkChartValue
    let y: Double
}

struct SparkChartSeries: Equatable, Sendable {
    let name: String
    let points: [SparkChartPoint]
}

struct SparkChartAxis: Equatable, Sendable {
    var label: String?
    var unit: String?

    static let none = SparkChartAxis()

    /// A unit belongs beside the axis name so every reading below it does not have to repeat it.
    var title: String? {
        switch (label, unit) {
        case (.some(let label), .some(let unit)):
            String(localized: .chartAxisWithUnit(label: label, unit: unit))
        case (.some(let label), nil): label
        case (nil, .some(let unit)): unit
        case (nil, nil): nil
        }
    }
}

struct SparkChartAnnotation: Equatable, Sendable {
    let text: String
    var x: SparkChartValue?
    var y: Double?
}

/// A chart the app is willing to draw: already bounded, already consistent, already text-only.
struct SparkChartSpec: Equatable, Sendable {
    let kind: SparkChartKind
    let title: String
    var isStacked = false
    var x = SparkChartAxis.none
    var y = SparkChartAxis.none
    let valueKind: SparkChartValueKind
    let series: [SparkChartSeries]
    var annotations: [SparkChartAnnotation] = []

    /// Category order comes from the order the series introduce their labels, never from sorting.
    var categories: [String] {
        var seen: Set<String> = []
        return series.flatMap(\.points).compactMap { point in
            guard case .category(let label) = point.x, seen.insert(label).inserted else {
                return nil
            }
            return label
        }
    }

    var values: [Double] { series.flatMap(\.points).map(\.y) }

    /// Beyond this many positions an axis has to thin its own labels; below it every drawn point is named.
    static let labelledPositions = 8

    /// The dates this chart draws, when there are few enough for each to carry its own axis label.
    var datedPositions: [Date] {
        guard valueKind == .date else { return [] }
        var seen: Set<Date> = []
        let dates = series.flatMap(\.points).compactMap { point -> Date? in
            guard case .date(let date) = point.x, seen.insert(date).inserted else { return nil }
            return date
        }
        return dates.count <= Self.labelledPositions ? dates.sorted() : []
    }

    /// QA-11: the numeric x positions this chart actually draws, so no gridline appears where no point does.
    var numberedPositions: [Double] {
        guard valueKind == .number else { return [] }
        var seen: Set<Double> = []
        let numbers = series.flatMap(\.points).compactMap { point -> Double? in
            guard case .number(let value) = point.x, seen.insert(value).inserted else {
                return nil
            }
            return value
        }
        return numbers.count <= Self.labelledPositions ? numbers.sorted() : []
    }

    static func parse(_ source: String) -> Result<SparkChartSpec, SparkChartSpecError> {
        SparkChartSpecReader().read(source)
    }
}

/// Why a chart was refused, in one sentence the owner can act on. There is no partial acceptance.
enum SparkChartSpecError: Error, Equatable, Sendable, CaseIterable {
    case tooLarge
    case malformed
    case unknownField
    case missingField
    case unknownType
    case textTooLong
    case tooManySeries
    case tooManyPoints
    case tooManyAnnotations
    case emptySeries
    case duplicateSeries
    case mixedValues
    case notANumber
    case repeatedValue
    case pieShape
    case stackingUnsupported

    var message: String {
        switch self {
        case .tooLarge: String(localized: "This chart is larger than the app will read.")
        case .malformed: String(localized: "This chart is not written as valid JSON.")
        case .unknownField: String(localized: "This chart has a field the app does not know.")
        case .missingField: String(localized: "This chart is missing something it needs.")
        case .unknownType: String(localized: "This is not a chart type the app can draw.")
        case .textTooLong: String(localized: "Some text in this chart is too long.")
        case .tooManySeries:
            String(localized: "This chart has more series than the app will draw.")
        case .tooManyPoints: String(localized: "This chart has more points than the app will draw.")
        case .tooManyAnnotations:
            String(localized: "This chart has more notes than the app will draw.")
        case .emptySeries: String(localized: "This chart has no values to draw.")
        case .duplicateSeries: String(localized: "This chart names the same series twice.")
        case .mixedValues:
            String(localized: "This chart mixes numbers, dates and labels along one axis.")
        case .notANumber: String(localized: "A value in this chart is not a number.")
        case .repeatedValue: String(localized: "This chart puts two values in the same place.")
        case .pieShape:
            String(localized: "A pie needs one series of labelled values that are not negative.")
        case .stackingUnsupported: String(localized: "Only bar and area charts can be stacked.")
        }
    }
}

extension ISO8601DateFormatter {
    /// Chart dates are read from two ISO-8601 spellings only; anything else is a category.
    nonisolated(unsafe) static let sparkChartDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let sparkChartDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func sparkChartValue(_ text: String) -> Date? {
        sparkChartDate.date(from: text) ?? sparkChartDay.date(from: text)
    }
}

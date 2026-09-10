import Foundation

/// Says what a chart shows for a reader who cannot see its shape (§51.1, §62.5).
enum SparkChartAccessibility {
    static func summary(_ spec: SparkChartSpec) -> String {
        let opening = String(localized: .chartTitled(kind: kindName(spec), title: spec.title))
        return spec.series.reduce(opening) { spoken, series in
            String(localized: .sentencePair(spoken, range(of: series, unit: spec.y.unit)))
        }
    }

    /// Stacking changes what a bar means, so it is part of the chart's spoken name rather than a detail.
    static func kindName(_ spec: SparkChartSpec) -> String {
        switch (spec.kind, spec.isStacked) {
        case (.line, _): String(localized: "Line chart")
        case (.bar, false): String(localized: "Bar chart")
        case (.bar, true): String(localized: "Stacked bar chart")
        case (.area, false): String(localized: "Area chart")
        case (.area, true): String(localized: "Stacked area chart")
        case (.pie, _): String(localized: "Pie chart")
        case (.donut, _): String(localized: "Donut chart")
        case (.scatter, _): String(localized: "Scatter chart")
        }
    }

    private static func range(of series: SparkChartSeries, unit: String?) -> String {
        let values = series.points.map(\.y)
        // A parsed series always carries at least one point, so these substitutions never happen.
        let latest = values.last ?? 0
        return String(
            localized: .chartSeriesRange(
                name: series.name,
                latest: reading(latest, unit: unit),
                lowest: reading(values.min() ?? latest, unit: unit),
                highest: reading(values.max() ?? latest, unit: unit)
            )
        )
    }

    static func reading(_ value: Double, unit: String?) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        guard let unit else { return number }
        return String(localized: .chartReadingWithUnit(value: number, unit: unit))
    }

    /// Names an x position the way it is drawn, so a spoken point matches the axis beside it.
    static func label(_ value: SparkChartValue) -> String {
        switch value {
        case .number(let number): number.formatted(.number.precision(.fractionLength(0...2)))
        case .date(let date): date.formatted(date: .abbreviated, time: .omitted)
        case .category(let text): text
        }
    }
}

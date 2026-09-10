import Accessibility
import Foundation
import SwiftUI

/// Offers the chart as an audio graph on the platforms that play one, from the drawn values only.
struct SparkChartDescriptor: AXChartDescriptorRepresentable {
    let spec: SparkChartSpec

    func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: spec.title,
            summary: SparkChartAccessibility.summary(spec),
            xAxis: positions(),
            yAxis: readings(),
            additionalAxes: [],
            series: spec.series.map(describe)
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = spec.title
        descriptor.summary = SparkChartAccessibility.summary(spec)
    }

    private func positions() -> AXDataAxisDescriptor {
        let title = spec.x.title ?? String(localized: "Position")
        if spec.valueKind == .category {
            return AXCategoricalDataAxisDescriptor(title: title, categoryOrder: spec.categories)
        }
        let values = spec.series.flatMap(\.points).map { plotted($0.x) }
        let dated = spec.valueKind == .date
        return AXNumericDataAxisDescriptor(
            title: title,
            range: bounds(values),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                dated
                    ? Date(timeIntervalSince1970: value)
                        .formatted(date: .abbreviated, time: .shortened)
                    : SparkChartAccessibility.reading(value, unit: spec.x.unit)
            }
        )
    }

    private func readings() -> AXNumericDataAxisDescriptor {
        AXNumericDataAxisDescriptor(
            title: spec.y.title ?? spec.title,
            range: bounds(spec.values),
            gridlinePositions: [],
            valueDescriptionProvider: { SparkChartAccessibility.reading($0, unit: spec.y.unit) }
        )
    }

    /// Lines and areas are read as a continuous shape; bars, points and sectors as separate values.
    private func describe(_ series: SparkChartSeries) -> AXDataSeriesDescriptor {
        AXDataSeriesDescriptor(
            name: series.name,
            isContinuous: spec.kind == .line || spec.kind == .area,
            dataPoints: series.points.map { point in
                if case .category(let label) = point.x {
                    return AXDataPoint(x: label, y: point.y)
                }
                return AXDataPoint(x: plotted(point.x), y: point.y)
            }
        )
    }

    private func plotted(_ value: SparkChartValue) -> Double {
        switch value {
        case .number(let number): number
        case .date(let date): date.timeIntervalSince1970
        case .category(let label): Double(spec.categories.firstIndex(of: label) ?? 0)
        }
    }

    /// An axis whose values never move still needs a range with width, or nothing can be played.
    private func bounds(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max(), low < high else {
            return (values.first ?? 0)...((values.first ?? 0) + 1)
        }
        return low...high
    }
}

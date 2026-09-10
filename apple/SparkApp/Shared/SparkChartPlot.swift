import Charts
import SwiftUI

/// Draws a parsed chart. Every kind reads the same points; nothing here interprets the model's text.
struct SparkChartPlot: View {
    let spec: SparkChartSpec

    private var seriesKey: String { String(localized: "Series") }
    private var pointKey: String { spec.x.label ?? String(localized: "Position") }
    private var valueKey: String { spec.y.label ?? String(localized: "Value") }

    var body: some View {
        chart
            .chartXAxisLabel(alignment: .center) { axisTitle(spec.x) }
            .chartYAxisLabel(alignment: .center) { axisTitle(spec.y) }
            .chartLegend(showsLegend ? .visible : .hidden)
    }

    private var showsLegend: Bool { spec.series.count > 1 || spec.kind.isCircular }

    @ViewBuilder
    private var chart: some View {
        if spec.kind.isCircular {
            Chart(slices, id: \.label) { slice in
                SectorMark(
                    angle: .value(valueKey, slice.value),
                    innerRadius: .ratio(spec.kind == .donut ? 0.58 : 0),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value(pointKey, slice.label))
                .cornerRadius(4)
            }
        } else {
            Chart {
                ForEach(spec.series.indices, id: \.self) { index in
                    ForEach(spec.series[index].points.indices, id: \.self) { position in
                        mark(spec.series[index].points[position], name: spec.series[index].name)
                    }
                }
                ForEach(spec.annotations.indices, id: \.self) { index in
                    rule(spec.annotations[index])
                }
            }
            .chartXAxis { xAxis }
            // Room at the trailing edge so the last point is not drawn against the frame.
            .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 18))
            // Readings sit on the leading edge, the way a chart is read, and clear of any note above the plot.
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }

    private struct Slice {
        let label: String
        let value: Double
    }

    private var slices: [Slice] {
        (spec.series.first?.points ?? []).map {
            Slice(label: SparkChartAccessibility.label($0.x), value: $0.y)
        }
    }

    // MARK: - Marks

    @ChartContentBuilder
    private func mark(_ point: SparkChartPoint, name: String) -> some ChartContent {
        switch point.x {
        case .number(let x): shape(.value(pointKey, x), point.y, name)
        case .date(let x): shape(.value(pointKey, x), point.y, name)
        case .category(let x): shape(.value(pointKey, x), point.y, name)
        }
    }

    /// One generic body over the three x kinds, so a chart cannot end up half drawn in two of them.
    @ChartContentBuilder
    private func shape<X: Plottable>(_ x: PlottableValue<X>, _ value: Double, _ name: String)
        -> some ChartContent
    {
        let y = PlottableValue.value(valueKey, value)
        let series = PlottableValue.value(seriesKey, name)
        switch spec.kind {
        case .line:
            LineMark(x: x, y: y)
                .foregroundStyle(by: series)
                .symbol(by: series)
                .interpolationMethod(.monotone)
        case .area where spec.isStacked:
            AreaMark(x: x, y: y).foregroundStyle(by: series)
        case .area:
            AreaMark(x: x, y: y, stacking: .unstacked)
                .foregroundStyle(by: series)
                .opacity(0.6)
        case .bar where spec.isStacked:
            BarMark(x: x, y: y).foregroundStyle(by: series)
        case .bar:
            BarMark(x: x, y: y).foregroundStyle(by: series).position(by: series)
        default:
            // Scatter draws points; circular charts never reach here because they draw sectors.
            PointMark(x: x, y: y).foregroundStyle(by: series).symbol(by: series)
        }
    }

    @ChartContentBuilder
    private func rule(_ annotation: SparkChartAnnotation) -> some ChartContent {
        switch annotation.x {
        case .number(let x): marker(.value(pointKey, x), annotation.text)
        case .date(let x): marker(.value(pointKey, x), annotation.text)
        case .category(let x): marker(.value(pointKey, x), annotation.text)
        case nil:
            if let y = annotation.y {
                RuleMark(y: .value(valueKey, y))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        spacing: 2,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) { note(annotation.text) }
            }
        }
    }

    @ChartContentBuilder
    private func marker<X: Plottable>(_ x: PlottableValue<X>, _ text: String) -> some ChartContent {
        RuleMark(x: x)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.secondary)
            .annotation(
                position: .top,
                alignment: .leading,
                spacing: 2,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) { note(text) }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Axes

    @ViewBuilder
    private func axisTitle(_ axis: SparkChartAxis) -> some View {
        if let text = axis.title {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Day and month is enough beside a plot; a chart that crosses a year boundary adds the year.
    private var dateAxisFormat: Date.FormatStyle {
        let calendar = Calendar.current
        let years = Set(spec.datedPositions.map { calendar.component(.year, from: $0) })
        let base = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return years.count > 1 ? base.year() : base
    }

    /// QA-11: a few points are named where they are drawn, so no gridline is empty and the last point is not nameless.
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        let dates = spec.datedPositions
        let numbers = spec.numberedPositions
        if !dates.isEmpty {
            AxisMarks(values: dates) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(dateAxisFormat))
                    }
                }
            }
        } else if !numbers.isEmpty {
            AxisMarks(values: numbers) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number))
                    }
                }
            }
        } else {
            AxisMarks()
        }
    }
}

import Charts
import SwiftUI

/// Shows runtime history with its source, newest-reading age and accounting method beside the chart.
struct SparkTelemetryHistoryCard: View {
    let history: SparkTelemetryHistoryModel
    var now: () -> Date = Date.init

    @State private var isShowingAccounting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch history.origin {
            case .none(let absence):
                emptyState(absence)
            case .runtime, .deviceCache:
                if case .deviceCache = history.origin {
                    notice(SparkTelemetryHistoryCopy.deviceCacheNotice, symbol: "iphone.gen3")
                }
                if let stale = staleNotice {
                    notice(stale, symbol: "clock.badge.exclamationmark")
                }
                charts
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .popover(isPresented: $isShowingAccounting) {
            ScrollView {
                Text(SparkTelemetryAccountingCopy.help)
                    .font(.callout)
                    .padding(20)
                    .frame(maxWidth: 380)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Recent activity")
                .font(.headline)
            Spacer(minLength: 0)
            Button {
                isShowingAccounting = true
            } label: {
                Label("How these numbers are counted", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How these numbers are counted")
        }
    }

    /// Explain each unavailable-history state instead of displaying an empty chart that implies idle hardware.
    private func emptyState(_ absence: SparkTelemetryHistoryAbsence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SparkTelemetryHistoryCopy.emptyMessage(absence))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private var staleNotice: String? {
        guard let latest = history.latestObservedAt else { return nil }
        let age = now().timeIntervalSince(latest)
        // Two sampling intervals: one missed tick is not a stale Spark.
        guard age > 30 else { return nil }
        return SparkTelemetryHistoryCopy.staleNotice(age)
    }

    @ViewBuilder
    private var charts: some View {
        VStack(alignment: .leading, spacing: 14) {
            trend(
                title: String(localized: "Processor"),
                accounting: SparkTelemetryAccountingCopy.derivedEstimate,
                points: history.points,
                value: \.cpuUtilisation,
                format: { ($0).formatted(.percent.precision(.fractionLength(0))) }
            )
            trend(
                title: String(localized: "Accelerator"),
                accounting: SparkTelemetryAccountingCopy.derivedEstimate,
                points: history.points,
                value: \.acceleratorUtilisation,
                format: { ($0).formatted(.percent.precision(.fractionLength(0))) }
            )
            trend(
                title: String(localized: "Active requests"),
                accounting: SparkTelemetryAccountingCopy.derivedEstimate,
                points: history.points,
                value: \.activeRequests,
                format: { $0.formatted(.number.precision(.fractionLength(0))) }
            )
        }
    }

    /// Labels empty series explicitly instead of drawing a zero-valued trend.
    @ViewBuilder
    private func trend(
        title: String,
        accounting: String,
        points: [SparkTelemetryHistoryPoint],
        value: KeyPath<SparkTelemetryHistoryPoint, Double?>,
        format: (Double) -> String
    ) -> some View {
        let series = points.filter { $0[keyPath: value] != nil }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                if let latest = series.last?[keyPath: value] {
                    Text(format(latest))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if series.isEmpty {
                Text(SparkTelemetryAccountingCopy.unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart(series) { point in
                    LineMark(
                        x: .value(String(localized: "Time"), point.observedAt),
                        y: .value(title, point[keyPath: value] ?? 0)
                    )
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 44)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue(series, value: value, format: format))
            }
            Text(accounting)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Provide a spoken summary of the chart's evidence (§51.1).
    private func accessibilityValue(
        _ series: [SparkTelemetryHistoryPoint],
        value: KeyPath<SparkTelemetryHistoryPoint, Double?>,
        format: (Double) -> String
    ) -> String {
        let readings = series.compactMap { $0[keyPath: value] }
        guard let low = readings.min(), let high = readings.max(), let latest = readings.last
        else {
            return SparkTelemetryAccountingCopy.unavailable
        }
        return String(
            localized: .trendLowHighLatest(
                low: format(low),
                high: format(high),
                latest: format(latest)
            )
        )
    }
}

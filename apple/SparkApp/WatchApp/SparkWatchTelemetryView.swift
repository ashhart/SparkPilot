import SparkWatchSupport
import SwiftUI

struct SparkWatchTelemetryView: View {
    @Bindable var store: SparkWatchStore
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SparkWatchPage {
            if let value = store.telemetry {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    HStack(spacing: 5) {
                        Image(systemName: value.isStale(at: context.date) ? "clock" : "circle.fill")
                            .font(value.isStale(at: context.date) ? .caption2 : .system(size: 6))
                        Text(
                            value.isStale(at: context.date)
                                ? "Out of date" : store.isPreview ? "Sample data" : "Updated"
                        )
                        if !store.isPreview {
                            Text(value.observedAt.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(
                        value.isStale(at: context.date) ? SparkWatchStyle.warning : .secondary
                    )
                }
                VStack(spacing: 8) {
                    percentage("GPU", value.gpuPercent)
                    percentage("Memory", value.memoryPercent)
                    percentage("CPU", value.cpuPercent)
                }
                .padding(10)
                .background(SparkWatchStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                measurementLayout {
                    measurement("Temperature", value.temperatureCelsius, unit: "°C")
                    measurement("GPU power", value.powerWatts, unit: "W")
                }
                .padding(.vertical, 4)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.modelName ?? "No model loaded")
                        .font(.footnote.weight(.medium))
                    HStack {
                        Text(value.modelState.capitalized)
                        Spacer()
                        Text("\(value.queuedRequests) queued")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle).foregroundStyle(SparkWatchStyle.accent)
                        .accessibilityHidden(true)
                    Text("No reading yet").font(.headline)
                    Text("Connect your iPhone and refresh to see Spark activity.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            SparkWatchFeedback(store: store)
            SparkWatchRefresh(store: store)
        }
        .navigationTitle("Telemetry")
    }

    private var readingLayout: AnyLayout {
        typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    private var measurementLayout: AnyLayout {
        typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
    }

    private func percentage(_ title: String, _ reading: Double?) -> some View {
        let value = reading.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
        return VStack(spacing: 5) {
            readingLayout {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                if typeSize < .xxLarge { Spacer() }
                Text(value.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                    .font(.body.weight(.semibold).monospacedDigit())
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        if let value {
                            Capsule()
                                .fill(
                                    value >= 90 ? SparkWatchStyle.warning : SparkWatchStyle.accent
                                )
                                .frame(width: geometry.size.width * value / 100)
                        }
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }

    private func measurement(_ title: String, _ reading: Double?, unit: String) -> some View {
        let value = reading.flatMap { $0.isFinite ? $0 : nil }
        return VStack(alignment: .leading, spacing: 3) {
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0))) + unit } ?? "—")
                .font(.title3.weight(.medium).monospacedDigit())
            Text(title == "Temperature" ? "Temp" : "Power")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0.formatted()) \(unit)" } ?? "Unavailable")
    }
}

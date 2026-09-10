import Foundation
import SparkAPI
import SwiftUI

struct SparkInferenceExperiencePanel: View {
    let sample: SparkInferenceExperienceSample?
    let history: [SparkInferenceExperienceSample]
    let isLive: Bool
    let isLoading: Bool
    let errorMessage: String?
    var inferenceTestTarget: SparkInferenceTestTarget? = nil
    var openModels: (() -> Void)? = nil
    @State private var presentedTest: SparkInferenceTestTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let sample {
                servingCard(sample)
                counters(sample)
                trends
                freshness(sample)
            } else if isLoading {
                SparkSkeletonList(
                    rowCount: 3,
                    accessibilityLabel: String(localized: "Loading inference activity")
                )
            } else {
                ContentUnavailableView(
                    "Inference activity unavailable",
                    systemImage: "waveform.path.ecg",
                    description: Text(
                        errorMessage
                            ?? "SparkPilot will show serving activity when this Spark reports it."
                    )
                )
            }
            // Keep the test visible in every state; when nothing is loaded, say what to do instead of hiding it.
            if let inferenceTestTarget {
                HStack(spacing: 12) {
                    Button {
                        presentedTest = inferenceTestTarget
                    } label: {
                        Label("Test inference", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)
                    NavigationLink {
                        SparkRequestHistoryView(target: inferenceTestTarget.chat)
                    } label: {
                        Label("Request history", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                    } label: {
                        Label("Test inference", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    Text("Load a model to test inference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let openModels {
                        Button("Open Models", action: openModels)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .sheet(item: $presentedTest) { target in
            SparkInferenceTestView(target: target)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Serving now"))
                .font(.title2.bold())
            SparkTooltipButton(
                title: String(localized: "Serving now"),
                message:
                    String(
                        localized:
                            "Live inference counters come from this Spark. SparkPilot stores a short trend history only on this Apple device."
                    )
            )
            Spacer()
            if let sample {
                let metricsAreLive = sample.metricsAvailability == "live"
                let sourceIsLive = sample.metricsAvailability == nil ? isLive : metricsAreLive
                Label(
                    SparkInferenceExperiencePresentation.sourceLabel(
                        availability: sample.metricsAvailability,
                        ageSeconds: sample.metricsSampleAgeSeconds,
                        transportIsLive: isLive
                    ),
                    systemImage: sourceIsLive ? "dot.radiowaves.left.and.right" : "clock"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(sourceIsLive ? Color.green : Color.secondary)
            }
        }
    }

    private func servingCard(_ sample: SparkInferenceExperienceSample) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(SparkInferenceExperiencePresentation.verdict(sample))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sample.engine.label)
                        .font(.headline)
                    Text(sample.modelDisplayName ?? sample.modelID ?? "Model name not reported")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(SparkInferenceExperiencePresentation.state(sample.state))
                    .font(.callout.weight(.semibold))
            }
            Label(
                sample.ownership.label,
                systemImage: sample.ownership == .managed ? "checkmark.shield" : "eye"
            )
            .font(.caption)
            .foregroundStyle(sample.ownership == .external ? Color.orange : Color.secondary)
            if sample.ownership == .external || sample.ownership == .mixed {
                Text(
                    "SparkPilot monitors external engines and does not start, stop, or replace them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func counters(_ sample: SparkInferenceExperienceSample) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 138), spacing: 12)],
            spacing: 12
        ) {
            counter(
                String(localized: "Prompt tokens"),
                SparkInferenceExperiencePresentation.count(sample.promptTokens)
            )
            counter(
                String(localized: "Generated tokens"),
                SparkInferenceExperiencePresentation.count(sample.generatedTokens)
            )
            counter(
                String(localized: "Total tokens"),
                SparkInferenceExperiencePresentation.count(sample.totalTokens)
            )
            counter(
                sample.metricsAvailability == nil
                    ? String(localized: "Requests today") : String(localized: "Requests served"),
                SparkInferenceExperiencePresentation.count(sample.requestCount)
            )
            counter(
                String(localized: "Request rate"),
                SparkInferenceExperiencePresentation.rate(sample.requestsPerMinute)
            )
            counter(
                sample.metricsAvailability == nil
                    ? String(localized: "Failed today") : String(localized: "Request failures"),
                SparkInferenceExperiencePresentation.count(sample.failedRequestCount)
            )
            counter(
                String(localized: "Active requests"),
                SparkInferenceExperiencePresentation.activeRequests(sample.activeRequests)
            )
            counter(
                String(localized: "Queue"),
                SparkInferenceExperiencePresentation.queuedRequests(sample.queueDepth)
            )
            counter(
                String(localized: "Throughput"),
                SparkInferenceExperiencePresentation.throughput(sample.tokensPerSecond)
            )
            counter(
                String(localized: "Prompt processing"),
                SparkInferenceExperiencePresentation.throughput(sample.promptTokensPerSecond)
            )
            counter(
                String(localized: "Generation"),
                SparkInferenceExperiencePresentation.throughput(sample.generatedTokensPerSecond)
            )
            counter(
                String(localized: "First token"),
                SparkInferenceExperiencePresentation.latency(
                    sample.timeToFirstTokenMilliseconds
                )
            )
            counter(
                String(localized: "Average latency"),
                SparkInferenceExperiencePresentation.latency(sample.averageLatencyMilliseconds)
            )
            counter(
                String(localized: "Time per output token"),
                SparkInferenceExperiencePresentation.latency(
                    sample.timePerOutputTokenMilliseconds
                )
            )
            counter(
                String(localized: "Engine uptime"),
                SparkInferenceExperiencePresentation.uptime(sample.engineUptimeSeconds)
            )
            counter(
                String(localized: "Spark uptime"),
                SparkInferenceExperiencePresentation.uptime(sample.sparkUptimeSeconds)
            )
        }
    }

    private func counter(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(.pair(title, value)))
    }

    @ViewBuilder
    private var trends: some View {
        let throughput = history.compactMap(\.tokensPerSecond)
        let queue = history.compactMap { $0.queueDepth.map(Double.init) }
        if throughput.count >= 2 || queue.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last 24 hours")
                    .font(.headline)
                if throughput.count >= 2 {
                    SparkInferenceMiniTrend(
                        values: throughput,
                        tint: .accentColor,
                        accessibilityLabel: String(localized: "Recent token throughput")
                    )
                }
                if queue.count >= 2 {
                    SparkInferenceMiniTrend(
                        values: queue,
                        tint: .orange,
                        accessibilityLabel: String(localized: "Recent inference queue depth")
                    )
                }
            }
        } else {
            Text("Recent trends appear after two live samples.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func freshness(_ sample: SparkInferenceExperienceSample) -> some View {
        Text(
            isLive
                ? .sampledAt(sample.observedAt.formatted(date: .abbreviated, time: .standard))
                : .lastGoodSampleAt(
                    sample.observedAt.formatted(date: .abbreviated, time: .standard)
                )
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SparkInferenceMiniTrend: View {
    let values: [Double]
    let tint: Color
    let accessibilityLabel: String

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard let minimum = values.min(), let maximum = values.max() else { return }
                let span = max(maximum - minimum, 0.000_001)
                let step = values.count > 1 ? proxy.size.width / Double(values.count - 1) : 0
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: Double(index) * step,
                        y: proxy.size.height - ((value - minimum) / span * proxy.size.height)
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 38)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        // Summarize plotted values accessibly because a sparkline's shape is not readable by VoiceOver (§51.1).
        .accessibilityValue(Text(SparkTrendAccessibility.summary(values)))
    }
}

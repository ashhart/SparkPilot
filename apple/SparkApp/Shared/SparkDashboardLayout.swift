import Foundation
import SwiftUI

enum SparkDashboardSection: String, Identifiable, Sendable {
    case health
    case models
    case remote
    case settings

    var id: String { rawValue }
}

public enum SparkDashboardMetric: String, CaseIterable, Identifiable, Sendable {
    case gpu
    case cpu
    case temperature
    case power
    case unifiedMemory = "unified_memory"
    case gpuMemory = "gpu_memory"
    case memoryStalls = "memory_stalls"
    case storage
    case inference
    case usage
    case uptime

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .gpu: "GPU"
        case .cpu: "CPU"
        case .temperature: String(localized: "Temperature")
        case .power: String(localized: "Power")
        case .unifiedMemory: String(localized: "Unified memory")
        case .gpuMemory: String(localized: "GPU memory")
        case .memoryStalls: String(localized: "Memory stalls")
        case .storage: String(localized: "Storage")
        case .inference: String(localized: "Inference")
        case .usage: String(localized: "Usage")
        case .uptime: String(localized: "Uptime")
        }
    }

    var symbol: String {
        switch self {
        case .gpu: "gauge.with.dots.needle.67percent"
        case .cpu: "cpu"
        case .temperature: "thermometer.medium"
        case .power: "bolt.fill"
        case .unifiedMemory: "memorychip"
        case .gpuMemory: "memorychip.fill"
        case .memoryStalls: "waveform.path"
        case .storage: "internaldrive"
        case .inference: "waveform.path.ecg"
        case .usage: "chart.bar.xaxis"
        case .uptime: "clock"
        }
    }
}

public struct SparkDashboardMetricSelection: Equatable, Sendable {
    public static let maximumCount = 6
    public static let defaults: [SparkDashboardMetric] = [
        .gpu,
        .temperature,
        .unifiedMemory,
        .inference,
    ]

    public let metrics: [SparkDashboardMetric]

    public init(encoded: String) {
        let requested = Set(
            encoded.split(separator: ",").compactMap {
                SparkDashboardMetric(rawValue: String($0))
            }
        )
        let ordered = SparkDashboardMetric.allCases.filter(requested.contains)
        metrics = ordered.isEmpty ? Self.defaults : Array(ordered.prefix(Self.maximumCount))
    }

    public init(metrics: [SparkDashboardMetric]) {
        let requested = Set(metrics)
        let ordered = SparkDashboardMetric.allCases.filter(requested.contains)
        self.metrics =
            ordered.isEmpty
            ? Self.defaults
            : Array(ordered.prefix(Self.maximumCount))
    }

    public var encoded: String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    public static func storageKey(targetID: String) -> String {
        let encodedTarget = Data(targetID.utf8).base64EncodedString()
        return "sparkpilot.dashboard.metrics.\(encodedTarget)"
    }
}

struct SparkDashboardMetricEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var encodedSelection: String

    private var selection: SparkDashboardMetricSelection {
        SparkDashboardMetricSelection(encoded: encodedSelection)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SparkDashboardMetric.allCases) { metric in
                        Toggle(
                            isOn: binding(for: metric),
                            label: {
                                Label(metric.title, systemImage: metric.symbol)
                            }
                        )
                        .disabled(
                            !selection.metrics.contains(metric)
                                && selection.metrics.count
                                    >= SparkDashboardMetricSelection.maximumCount
                        )
                    }
                } header: {
                    Text("Metrics")
                } footer: {
                    Text("Choose up to six metrics for this Spark.")
                }
            }
            .navigationTitle("At a glance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding(for metric: SparkDashboardMetric) -> Binding<Bool> {
        Binding(
            get: { selection.metrics.contains(metric) },
            set: { enabled in
                var metrics = selection.metrics
                if enabled {
                    metrics.append(metric)
                } else if metrics.count > 1 {
                    metrics.removeAll { $0 == metric }
                }
                encodedSelection = SparkDashboardMetricSelection(metrics: metrics).encoded
            }
        )
    }
}

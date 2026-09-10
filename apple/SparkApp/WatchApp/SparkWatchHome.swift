import SparkWatchSupport
import SwiftUI

struct SparkWatchHome: View {
    @Bindable var store: SparkWatchStore
    @State private var path: [String] = Self.initialPath
    @State private var choosingSpark = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private static var initialPath: [String] {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--spark-watch-preview"),
                let route = arguments.first(where: { $0.hasPrefix("--watch-page=") })?.split(
                    separator: "="
                ).last,
                ["talk", "models", "telemetry"].contains(String(route))
            {
                return [String(route)]
            }
        #endif
        return []
    }

    var body: some View {
        NavigationStack(path: $path) {
            SparkWatchPage {
                SparkWatchFeedback(store: store)
                if store.targets.isEmpty {
                    connectionSetup
                } else {
                    targetControl
                    NavigationLink(value: "talk") {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform").font(.title3)
                            Text("Talk to AI")
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(SparkWatchControlStyle(prominent: true))
                    if typeSize >= .xxLarge {
                        destination("Models", symbol: "cpu", route: "models")
                        destination("Stats", symbol: "chart.bar.xaxis", route: "telemetry")
                    } else {
                        HStack(spacing: 8) {
                            destination("Models", symbol: "cpu", route: "models")
                            destination("Stats", symbol: "chart.bar.xaxis", route: "telemetry")
                        }
                    }
                    if let telemetry = store.telemetry {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(telemetry.modelName ?? "No model loaded")
                                .font(.footnote.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(telemetry.modelState.capitalized)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
                if store.isPreview {
                    SparkWatchPreviewBadge()
                } else {
                    SparkWatchRefresh(store: store)
                    Text(store.connection.connectionMessage)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SparkPilot")
            .navigationDestination(for: String.self) { route in
                switch route {
                case "talk": SparkWatchChat(store: store)
                case "models": SparkWatchModels(store: store)
                default: SparkWatchTelemetryView(store: store)
                }
            }
            .sheet(isPresented: $choosingSpark) {
                NavigationStack {
                    List(store.targets) { target in
                        Button {
                            store.select(target.id)
                            choosingSpark = false
                        } label: {
                            HStack {
                                Text(target.name)
                                Spacer()
                                if target.id == store.targetID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SparkWatchStyle.accent)
                                }
                            }
                        }
                    }
                    .navigationTitle("Choose Spark")
                    .toolbarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(SparkWatchStyle.accent)
    }

    @ViewBuilder private var targetControl: some View {
        if store.targets.count > 1 {
            Button {
                choosingSpark = true
            } label: {
                targetLabel.frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(store.busy || store.pendingID != nil)
            .accessibilityHint("Choose a different Spark")
        } else {
            targetLabel.frame(minHeight: 22)
        }
    }

    private var targetLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: store.isPreview ? "eye" : "circle.fill")
                .font(.caption2)
                .foregroundStyle(
                    store.isPreview
                        ? Color.secondary
                        : store.connection.reachable ? SparkWatchStyle.healthy : .secondary
                )
            Text(store.target?.name ?? "Choose Spark")
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if store.targets.count > 1 {
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(store.target?.name ?? "Spark"), \(store.isPreview ? "sample data" : store.connection.reachable ? "iPhone connected" : "iPhone disconnected")"
        )
    }

    private func destination(_ title: String, symbol: String, route: String) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .font(.title3).foregroundStyle(SparkWatchStyle.accent)
                    .accessibilityHidden(true)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .buttonStyle(SparkWatchControlStyle(horizontalPadding: 8))
    }

    private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.largeTitle).foregroundStyle(SparkWatchStyle.accent)
                .accessibilityHidden(true)
            Text(store.connection.reachable ? "Connect your Spark" : "Open SparkPilot on iPhone")
                .font(.headline)
            Text(
                store.connection.reachable
                    ? "Add a Spark in the iPhone app to talk, manage models and check activity here."
                    : "Keep your paired iPhone nearby and open SparkPilot to connect."
            )
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

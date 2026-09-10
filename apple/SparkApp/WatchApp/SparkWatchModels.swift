import SparkWatchSupport
import SwiftUI

struct SparkWatchModels: View {
    @Bindable var store: SparkWatchStore
    @State private var selectedModel: SparkWatchModel?
    @State private var confirmingStart = false
    @State private var confirmingStop = false

    var body: some View {
        SparkWatchPage {
            SparkWatchFeedback(store: store)
            if let telemetry = store.telemetry, let name = telemetry.modelName {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(telemetry.modelState.capitalized)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(SparkWatchStyle.accent)
                    Text(name).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Label("Stop model", systemImage: "stop.fill")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(SparkWatchControlStyle())
                    .disabled(!store.canManage)
                }
                .padding(12)
                .background(SparkWatchStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SparkWatchCaption(text: "No active model")
                    Text("Choose an installed model to start.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            SparkWatchCaption(text: "Installed")
            ForEach(store.installedModels) { model in
                Button {
                    selectedModel = model
                    confirmingStart = true
                } label: {
                    HStack(spacing: 10) {
                        Text(model.name)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "play.fill")
                            .font(.footnote).foregroundStyle(SparkWatchStyle.accent)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(SparkWatchControlStyle())
                .disabled(!store.canManage)
                .accessibilityLabel("Start \(model.name)")
            }
            if store.installedModels.isEmpty {
                Text("Install a model with a compatible profile in the iPhone app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.target?.canManageModels == false && !store.isPreview {
                Label("Model controls need owner access.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !store.connection.reachable && !store.isPreview {
                Text("Connect your iPhone to manage models.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.isPreview { SparkWatchPreviewBadge() }
        }
        .navigationTitle("Models")
        .confirmationDialog(
            "Start \(selectedModel?.name ?? "model") on \(store.target?.name ?? "Spark")?",
            isPresented: $confirmingStart,
            titleVisibility: .visible
        ) {
            Button("Start model") {
                if let selectedModel { store.changeModel(selectedModel) }
            }
        } message: {
            Text("Uses Spark memory and power; a running workload will not be replaced.")
        }
        .confirmationDialog(
            "Stop the active model on \(store.target?.name ?? "Spark")?",
            isPresented: $confirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop model", role: .destructive) { store.changeModel(nil) }
        } message: {
            Text("The Spark checks active work before accepting the stop.")
        }
    }
}

import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsMemorySection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Memory guard"),
            symbol: "memorychip",
            help:
                String(
                    localized:
                        "Protect the shared CPU and GPU memory pool before pressure makes the Spark unstable."
                )
        ) {
            Stepper(
                SparkMemoryGuardPresentation.label(.warning, gibFree: model.warningGiB),
                value: $model.warningGiB,
                in: 3...64
            )
            Stepper(
                SparkMemoryGuardPresentation.label(.critical, gibFree: model.criticalGiB),
                value: $model.criticalGiB,
                in: 2...63
            )
            Stepper(
                SparkMemoryGuardPresentation.label(.emergency, gibFree: model.emergencyGiB),
                value: $model.emergencyGiB,
                in: 1...62
            )
            Text("Warning must stay above critical, and critical above emergency.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Save Memory Guard") { Task { await model.saveMemoryGuard() } }
                .buttonStyle(.bordered)
                .disabled(
                    !(model.warningGiB > model.criticalGiB
                        && model.criticalGiB > model.emergencyGiB)
                )
        }

    }
}

struct SparkSettingsIdleSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Model idle policy"),
            symbol: "moon.zzz",
            help: String(
                localized:
                    "Keep a model ready or automatically unload it after a supported idle period."
            )
        ) {
            let models = model.catalogue?.items.filter { !$0.profiles.isEmpty } ?? []
            if models.isEmpty {
                Text("Install a model to set its idle behaviour.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { item in
                    DisclosureGroup(item.displayName) {
                        ForEach(item.profiles) { profile in
                            IdlePolicyRow(model: model, modelID: item.id, profile: profile)
                        }
                    }
                }
            }
        }

    }
}

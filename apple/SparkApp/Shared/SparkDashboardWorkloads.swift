import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

/// External workloads require exact signed-recipe adoption; SGLang, Open WebUI and unknown workloads remain observed-only.
struct SparkDashboardWorkloads: View {
    let inventory: GeneratedAPI.WorkloadInventory?
    let errorMessage: String?
    let installedModels: [SparkModel]
    let ownership: SparkWorkloadOwnershipModel

    var body: some View {
        if let inventory = inventory {
            VStack(alignment: .leading, spacing: 12) {
                Text("Workloads on this Spark")
                    .font(.title2.bold())
                if let unavailable = SparkWorkloadPresentation.unavailableMessage(inventory) {
                    Text(unavailable)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let empty = SparkWorkloadPresentation.emptyMessage(inventory) {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let truncated = SparkWorkloadPresentation.truncationNotice(inventory) {
                    Label(truncated, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(SparkWorkloadPresentation.sections(inventory)) { section in
                    workloadSection(section)
                }
                Text(.observedAt(inventory.observedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(.workloadsObservedAt(inventory.observedAt)))
            }
        } else if let message = errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workloads on this Spark")
                    .font(.title2.bold())
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

    }
    private func workloadSection(
        _ section: SparkWorkloadPresentation.Section
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
            ForEach(section.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    Text(row.ownership)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !row.servedModels.isEmpty {
                        ForEach(row.servedModels, id: \.self) { servedModel in
                            Label(servedModel, systemImage: "brain")
                                .font(.caption)
                        }
                    }
                    if let apiSummary = row.apiSummary {
                        Text(apiSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(row.endpoints, id: \.self) { endpoint in
                        Text(endpoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let image = row.imageReference {
                        DisclosureGroup(String(localized: "Technical details")) {
                            Text(image)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                    if row.canReviewAdoption {
                        let installed = installedModels
                        Menu(String(localized: "Review adoption")) {
                            if installed.isEmpty {
                                Text("Install a matching signed model first")
                            } else {
                                ForEach(installed) { item in
                                    ForEach(item.profiles) { profile in
                                        Button(.joined(item.displayName, profile.displayName)) {
                                            Task {
                                                await ownership.prepareAdoption(
                                                    workloadID: row.id,
                                                    workloadName: row.title,
                                                    model: item,
                                                    profile: profile
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .disabled(installed.isEmpty || ownership.isWorking)
                        .accessibilityLabel(Text(.reviewExactAdoption(row.title)))
                    }
                    if row.canRelinquish {
                        Button("Relinquish management", role: .destructive) {
                            Task {
                                await ownership.prepareRelinquish(
                                    workloadID: row.id,
                                    workloadName: row.title
                                )
                            }
                        }
                        .disabled(ownership.isWorking)
                        .accessibilityHint("Leaves the original container and files running")
                    }
                    if let ownershipError = ownership.errorMessage,
                        ownership.pendingConfirmation == nil
                    {
                        Label(ownershipError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.accessibilityLabel)
            }
            Text(section.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

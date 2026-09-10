import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardOperationRecovery: View {
    let model: SparkDashboardModel
    let providerCredentialModel: ProviderCredentialModel?
    var restartSpark: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if !model.unlistedModelIDsNeedingRecovery.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Unfinished actions")
                    .font(.title2.bold())
                ForEach(model.unlistedModelIDsNeedingRecovery, id: \.self) { modelID in
                    if let state = model.lifecycleState(for: modelID) {
                        let actionTitle = SparkDashboardOwnerPresentation.unfinishedActionTitle(
                            state.action
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text(actionTitle)
                                .font(.headline)
                            Text(
                                state.errorMessage
                                    ?? String(localized: "This action needs attention.")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            SparkDashboardRecoveryButton(
                                state: state,
                                modelID: modelID,
                                displayName: actionTitle,
                                retryStatus: { await model.retryStatus(modelID: modelID) },
                                retryIncompleteOperation: {
                                    await model.retryIncompleteOperation(modelID: modelID)
                                },
                                refreshPreview: {
                                    await model.refreshPreview(
                                        modelID: modelID,
                                        providerCredentialID: selectedCredentialID(modelID: modelID)
                                    )
                                },
                                restartSpark: restartSpark
                            )
                            DisclosureGroup(String(localized: "Technical details")) {
                                Text(modelID)
                                    .font(.caption.monospaced())
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .quaternary.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                }
            }
        }

    }
    private func selectedCredentialID(for item: SparkModel) -> String? {
        guard item.gated == true else { return nil }
        return providerCredentialModel?.selectedCredentialID(
            for: item.sourceProvider ?? "huggingface"
        )
    }

    private func selectedCredentialID(modelID: String) -> String? {
        guard let item = model.models.first(where: { $0.id == modelID }) else { return nil }
        return selectedCredentialID(for: item)
    }

}

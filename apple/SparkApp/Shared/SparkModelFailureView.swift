import Foundation
import SparkAPI
import SwiftUI

/// What a failed model action says and offers, kept out of the card so both stay type-checkable.
@MainActor
struct SparkModelFailureView: View {
    let item: SparkModel
    let state: ModelLifecycleState
    let model: SparkDashboardModel
    let providerCredentialID: String?
    var restartSpark: (() -> Void)? = nil
    @State private var showingDetails = false
    @State private var dismissed = false

    private var memoryStop: SparkMemoryStopPresentation? {
        SparkMemoryStopPresentation.resolve(
            errorCode: state.operation?.errorCode,
            profiles: SparkMemoryStopPresentation.profiles(item.profiles)
        )
    }

    var body: some View {
        if let memoryStop, !dismissed {
            memoryStopBlock(memoryStop)
        } else {
            standardBlock
        }
    }

    /// PLAN 41.9: the exact wording, then Restart at the smaller context, Diagnostics, Not now.
    @ViewBuilder
    private func memoryStopBlock(_ stop: SparkMemoryStopPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: stop.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(verbatim: stop.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            details
            HStack {
                if let profileID = stop.restartProfileID, let title = stop.restartTitle {
                    Button(title) {
                        Task {
                            await model.prepareLoad(
                                modelID: item.id,
                                replaceActive: false,
                                profileID: profileID
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(Text(.restartResourceAt(item.displayName, title)))
                }
                Button(String(localized: "Diagnostics")) { showingDetails = true }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(.diagnosticsForResource(item.displayName)))
                Button(String(localized: "Not now")) { dismissed = true }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(.leaveResourceStopped(item.displayName)))
            }
        }
    }

    @ViewBuilder
    private var standardBlock: some View {
        if let title = state.errorTitle {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
        if let error = state.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        details
        SparkDashboardRecoveryButton(
            state: state,
            modelID: item.id,
            displayName: item.displayName,
            retryStatus: { await model.retryStatus(modelID: item.id) },
            retryIncompleteOperation: { await model.retryIncompleteOperation(modelID: item.id) },
            refreshPreview: {
                await model.refreshPreview(
                    modelID: item.id,
                    providerCredentialID: providerCredentialID
                )
            },
            restartSpark: restartSpark
        )
    }

    @ViewBuilder
    private var details: some View {
        if let code = state.technicalErrorCode {
            DisclosureGroup(String(localized: "Technical details"), isExpanded: $showingDetails) {
                Text(code).font(.caption.monospaced())
            }
        }
    }
}

import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardRecoveryButton: View {
    let state: ModelLifecycleState
    let modelID: String
    let displayName: String
    let retryStatus: () async -> Void
    let retryIncompleteOperation: () async -> Void
    let refreshPreview: () async -> Void
    /// Routes to the dashboard's reboot control; nil leaves the owner a plain instruction.
    var restartSpark: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let recovery = state.recoveryAction {
            Text(recovery.guidance)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch state.recoveryAction {
        case .retryStatus:
            Button("Check status") {
                Task { await retryStatus() }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(
                ModelOperationRecoveryAction.retryStatus.accessibilityLabel(modelName: displayName)
            )
        case .retryIncompleteOperation:
            Button("Retry incomplete operation") {
                Task { await retryIncompleteOperation() }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(
                ModelOperationRecoveryAction.retryIncompleteOperation.accessibilityLabel(
                    modelName: displayName
                )
            )
        case .refreshPreview:
            Button("Review again") {
                Task {
                    await refreshPreview()
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(
                ModelOperationRecoveryAction.refreshPreview.accessibilityLabel(
                    modelName: displayName
                )
            )
        case .retryTerminalFailure:
            Button("Retry") {
                Task {
                    await refreshPreview()
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(
                ModelOperationRecoveryAction.retryTerminalFailure.accessibilityLabel(
                    modelName: displayName
                )
            )
        case .restartSpark:
            if let restartSpark {
                Button("Restart Spark", systemImage: "arrow.clockwise.circle") {
                    restartSpark()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    ModelOperationRecoveryAction.restartSpark.accessibilityLabel(
                        modelName: displayName
                    )
                )
            } else {
                Text("Restart the Spark, then launch again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Launch again") {
                Task { await refreshPreview() }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(
                ModelOperationRecoveryAction.retryTerminalFailure.accessibilityLabel(
                    modelName: displayName
                )
            )
        case nil:
            EmptyView()
        }

    }
}

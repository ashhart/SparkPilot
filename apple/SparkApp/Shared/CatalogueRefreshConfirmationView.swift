import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers

public struct CatalogueRefreshConfirmationView: View {
    public let confirmation: CatalogueRefreshConfirmation
    public let isApplying: Bool
    public let stageLabel: String
    public let errorMessage: String?
    public let cancel: () -> Void
    public let apply: () -> Void

    public init(
        confirmation: CatalogueRefreshConfirmation,
        isApplying: Bool,
        stageLabel: String,
        errorMessage: String?,
        cancel: @escaping () -> Void,
        apply: @escaping () -> Void
    ) {
        self.confirmation = confirmation
        self.isApplying = isApplying
        self.stageLabel = stageLabel
        self.errorMessage = errorMessage
        self.cancel = cancel
        self.apply = apply
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Signed snapshot") {
                    LabeledContent("File", value: confirmation.fileName)
                    if let bytes = confirmation.preview.evidence.downloadBytes {
                        LabeledContent("Size") {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(bytes),
                                    countStyle: .file
                                )
                            )
                        }
                    }
                    Text(
                        "Only this JSON is sent directly to the Spark over its trusted local connection."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Safety") {
                    Label(
                        "The Spark will verify the catalogue signature.",
                        systemImage: "checkmark.shield"
                    )
                    Label(
                        "The running model will stay active.",
                        systemImage: "bolt.horizontal.circle"
                    )
                    Text(
                        "A failed promotion automatically keeps or restores the previous verified snapshot."
                    )
                }

                if !confirmation.preview.warnings.isEmpty {
                    Section("Before you continue") {
                        ForEach(confirmation.preview.warnings, id: \.code) { warning in
                            Label(warning.ownerExplanation, systemImage: "exclamationmark.triangle")
                            if let recovery = warning.recoveryAction {
                                Text(recovery).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !confirmation.preview.blockers.isEmpty {
                    Section("This refresh cannot start") {
                        ForEach(confirmation.preview.blockers, id: \.code) { blocker in
                            Label(blocker.ownerExplanation, systemImage: "xmark.octagon.fill")
                            if let recovery = blocker.recoveryAction {
                                Text(recovery).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if isApplying {
                    Section("Progress") {
                        ProgressView(stageLabel)
                    }
                }
                if let errorMessage {
                    Section("Refresh not completed") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Technical details") {
                    LabeledContent("Preview digest") {
                        Text(confirmation.preview.previewDigest)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Refresh signed catalogue?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                        .disabled(!confirmation.canApply || isApplying)
                        .accessibilityLabel("Apply signed catalogue refresh")
                }
            }
        }
    }
}

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

public struct ProfileReenableConfirmationView: View {
    public let confirmation: ProfileReenableConfirmation
    public let isApplying: Bool
    public let errorMessage: String?
    public let cancel: () -> Void
    public let apply: () -> Void

    public init(
        confirmation: ProfileReenableConfirmation,
        isApplying: Bool,
        errorMessage: String?,
        cancel: @escaping () -> Void,
        apply: @escaping () -> Void
    ) {
        self.confirmation = confirmation
        self.isApplying = isApplying
        self.errorMessage = errorMessage
        self.cancel = cancel
        self.apply = apply
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Disabled profile") {
                    LabeledContent("Model", value: confirmation.modelName)
                    LabeledContent("Profile", value: confirmation.profileName)
                    if let measured = confirmation.preview.evidence.requiredMemoryBytes {
                        LabeledContent("Recorded memory") {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(measured),
                                    countStyle: .memory
                                )
                            )
                        }
                    }
                    if let available = confirmation.preview.evidence.availableMemoryBytes {
                        LabeledContent("Available now") {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(available),
                                    countStyle: .memory
                                )
                            )
                        }
                    }
                }

                Section("Safety warning") {
                    Label(
                        "This profile was disabled after a memory safety event.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    Text(
                        "Re-enabling only allows this profile through admission again. It does not start the model or prove that the original condition is gone."
                    )
                    Text(
                        "If this change fails, the profile stays disabled. The memory guard can disable it again if pressure returns."
                    )
                }

                if !confirmation.preview.warnings.isEmpty {
                    Section("Spark review") {
                        ForEach(confirmation.preview.warnings, id: \.code) { warning in
                            Label(warning.ownerExplanation, systemImage: "exclamationmark.triangle")
                            if let recovery = warning.recoveryAction {
                                Text(recovery).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !confirmation.preview.blockers.isEmpty {
                    Section("This profile cannot be re-enabled") {
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
                        ProgressView(String(localized: "Re-enabling the reviewed profile"))
                    }
                }
                if let errorMessage {
                    Section("Profile not re-enabled") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Technical details") {
                    LabeledContent("Model ID") {
                        Text(confirmation.modelID).font(.caption.monospaced())
                    }
                    LabeledContent("Profile ID") {
                        Text(confirmation.profileID).font(.caption.monospaced())
                    }
                    if let failureCode = confirmation.preview.evidence.profileFailureCode {
                        LabeledContent("Recorded safety event") {
                            Text(failureCode).font(.caption.monospaced())
                        }
                    }
                    LabeledContent("Preview digest") {
                        Text(confirmation.preview.previewDigest)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Re-enable this profile?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Re-enable", action: apply)
                        .disabled(!confirmation.canApply || isApplying)
                        .accessibilityLabel(
                            Text(
                                .reEnable(
                                    profile: confirmation.profileName,
                                    model: confirmation.modelName
                                )
                            )
                        )
                }
            }
        }
    }
}

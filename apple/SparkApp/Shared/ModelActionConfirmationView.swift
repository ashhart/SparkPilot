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

public struct ModelActionConfirmationView: View {
    public let confirmation: ModelActionConfirmation
    public let cancel: () -> Void
    public let apply: () -> Void
    public let changeProfile: (() -> Void)?

    /// Only actions that transfer or remove disk bytes have storage estimates.
    private var storageIsRelevant: Bool {
        let evidence = confirmation.preview.evidence
        return evidence.downloadBytes != nil || evidence.requiredDiskBytes != nil
            || evidence.expectedDiskFreeAfterBytes != nil
            || evidence.locallyReusableBytes != nil
    }

    @State private var showsTechnicalDetails = false

    public init(
        confirmation: ModelActionConfirmation,
        cancel: @escaping () -> Void,
        apply: @escaping () -> Void,
        changeProfile: (() -> Void)? = nil
    ) {
        self.confirmation = confirmation
        self.cancel = cancel
        self.apply = apply
        self.changeProfile = changeProfile
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("What will happen") {
                    consequenceSummary
                    if confirmation.preview.consequences.routeWithdrawal {
                        Label(
                            "Requests will stop using this model during the change.",
                            systemImage: "point.3.filled.connected.trianglepath.dotted"
                        )
                    }
                    interruptionSummary
                }

                // Omit storage rows when a start or stop reports no disk transfer.
                if storageIsRelevant {
                    Section("Storage") {
                        amountRow(
                            String(localized: "Download"),
                            confirmation.preview.evidence.downloadBytes
                        )
                        amountRow(
                            String(localized: "Already on this Spark"),
                            confirmation.preview.evidence.locallyReusableBytes
                        )
                        amountRow(
                            String(localized: "Disk needed"),
                            confirmation.preview.evidence.requiredDiskBytes
                        )
                        amountRow(
                            String(localized: "Disk free now"),
                            confirmation.preview.evidence.diskFreeBytes
                        )
                        amountRow(
                            String(localized: "Disk free afterwards"),
                            confirmation.preview.evidence.expectedDiskFreeAfterBytes
                        )
                        removalSummary
                    }
                } else if let installedBytes = confirmation.preview.evidence.installedBytes {
                    Section("Model files") {
                        amountRow(String(localized: "Model files on disk"), installedBytes)
                    }
                }

                if let profile = confirmation.profile {
                    Section("Model limits") {
                        LabeledContent("Profile", value: profile.displayName)
                        LabeledContent("Context tokens", value: profile.maxModelLength.formatted())
                        LabeledContent(
                            "Maximum simultaneous requests",
                            value: profile.maxSequences.formatted()
                        )
                        Text(
                            "Context includes input and output tokens. Simultaneous requests share the available cache, so long requests may queue."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        if let changeProfile { Button("Change profile", action: changeProfile) }
                    }
                }

                Section("Memory") {
                    if confirmation.profile == nil, let profileName = confirmation.profileName {
                        LabeledContent("Profile", value: profileName)
                    }
                    if let weights = confirmation.preview.evidence.weightBytes {
                        amountRow(String(localized: "Weights"), weights)
                    }
                    if let cache = confirmation.contextCacheBytes {
                        LabeledContent {
                            Text(Self.byteString(cache))
                        } label: {
                            Text("Context cache")
                            if let detail = confirmation.contextCacheDetail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let overhead = confirmation.preview.evidence.engineOverheadBytes {
                        amountRow(String(localized: "Engine overhead"), overhead)
                    }
                    amountRow(
                        String(localized: "Engine and cache reservation"),
                        confirmation.preview.evidence.requiredMemoryBytes
                    )
                    amountRow(
                        confirmation.preview.action == .replace
                            ? String(localized: "Available after stop")
                            : String(localized: "Available now"),
                        confirmation.preview.evidence.availableMemoryBytes
                    )
                    if let reserve = confirmation.preview.evidence.systemReserveBytes {
                        amountRow(String(localized: "System reserve"), reserve)
                    }
                    amountRow(
                        confirmation.memoryBalanceLabel,
                        confirmation.memoryBalanceBytes
                    )
                    if let active = confirmation.preview.evidence.activeEngine {
                        amountRow(
                            String(localized: "Running model reservation estimate"),
                            active.reservedMemoryBytes
                        )
                    }
                    if let line = confirmation.largestContextNowLine {
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let clusterSummary = confirmation.clusterSummary {
                    Section("Cluster members") {
                        Text(clusterSummary)
                    }
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
                    Section("This action cannot start yet") {
                        ForEach(confirmation.preview.blockers, id: \.code) { blocker in
                            Label(blocker.ownerExplanation, systemImage: "xmark.octagon.fill")
                            if let recovery = blocker.recoveryAction {
                                Text(recovery).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Review validity") {
                    LabeledContent("Evidence recorded") {
                        Text(confirmation.evidenceDateText)
                    }
                    LabeledContent("Review expires") {
                        Text(confirmation.expiryDateText)
                    }
                    DisclosureGroup(
                        String(localized: "Technical details"),
                        isExpanded: $showsTechnicalDetails
                    ) {
                        LabeledContent("Preview digest") {
                            Text(confirmation.preview.previewDigest)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Evidence timestamp") {
                            Text(confirmation.preview.evidenceTimestamps.systemObservedAt)
                                .font(.caption.monospaced())
                        }
                        LabeledContent("Expiry timestamp") {
                            Text(confirmation.preview.expiresAt)
                                .font(.caption.monospaced())
                        }
                        if let cluster = confirmation.preview.evidence.cluster {
                            ForEach(cluster.members, id: \.nodeId) { member in
                                Text(.joined(member.nodeId, member.role.rawValue))
                                    .font(.caption.monospaced())
                            }
                        }
                        ForEach(confirmation.preview.warnings, id: \.code) { warning in
                            Text(warning.code).font(.caption.monospaced())
                        }
                        ForEach(confirmation.preview.blockers, id: \.code) { blocker in
                            Text(blocker.code).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(confirmation.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityLabel(confirmation.cancelAccessibilityLabel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmation.confirmTitle, action: apply)
                        .disabled(!confirmation.canApply)
                        .accessibilityLabel(confirmation.applyAccessibilityLabel)
                }
            }
        }
    }

    @ViewBuilder
    private var consequenceSummary: some View {
        if let model = confirmation.preview.consequences.modelToStop {
            Label(.runningModelWillStop(model), systemImage: "stop.circle")
        } else {
            Text("No other running model will be stopped.")
        }
    }

    @ViewBuilder
    private var interruptionSummary: some View {
        switch confirmation.preview.consequences.serviceInterruption {
        case .none:
            Text("The inference service will stay available.")
        case .untilModelReady:
            Text("Inference will pause until the selected model is ready.")
        case .untilReloaded:
            Text("Inference will stay stopped until a model is started again.")
        }
    }

    @ViewBuilder
    private var removalSummary: some View {
        let removed = confirmation.preview.consequences.filesRemoved
        if let reinstallSummary = confirmation.reinstallSummary {
            Text(reinstallSummary)
        }
        if !removed.isEmpty {
            Text("Files to remove")
            ForEach(removed, id: \.self) { file in
                Text(file).font(.caption.monospaced())
            }
        } else if let retainedContentSummary = confirmation.retainedContentSummary {
            Text(retainedContentSummary)
        }
    }

    private func amountRow(_ label: String, _ bytes: Int?) -> some View {
        LabeledContent(label) {
            Text(bytes.map(Self.byteString) ?? String(localized: "Not reported"))
        }
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardModelCard: View {
    let item: SparkModel
    let model: SparkDashboardModel
    let providerCredentialModel: ProviderCredentialModel?
    let showProviderCredentials: () -> Void
    var restartSpark: (() -> Void)? = nil
    /// The recipe's full description is a tap away; the card itself stays short.
    @State private var showsDescription = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ModelPublisherMark(
                publisher: item.publisher,
                stateSymbol: modelSymbol(item.installState),
                stateTint: modelColor(item.installState)
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(.headline)
                // Display publisher and serving-recipe provenance when reported.
                if let provenance = item.provenanceLine {
                    Text(provenance)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let description = item.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsDescription ? nil : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showsDescription.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(
                            showsDescription
                                ? String(localized: "Shows less") : String(localized: "Shows more")
                        )
                }
                HStack {
                    Text(installLabel(item.installState))
                    if let totalBytes = item.totalBytes {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: totalBytes,
                                countStyle: .file
                            )
                        )
                    }
                    if let fit = item.fit, let label = ModelTargetFit.label(forWireValue: fit) {
                        Text(verbatim: label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                lifecycleStatus(item)
                unsafeProfileActions(item)
                gatedModelAccess(item)
                modelActions(item)
            }
            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .id("model-\(item.id)")
    }
    @ViewBuilder
    private func lifecycleStatus(_ item: SparkModel) -> some View {
        if let state = model.lifecycleState(for: item.id) {
            if let operation = state.operation, !operation.state.isTerminal {
                let stage = SparkDashboardOwnerPresentation.operationStageLabel(
                    operation.stage,
                    action: state.action
                )
                Group {
                    if let progress = SparkDashboardOwnerPresentation.determinateProgress(
                        operation
                    ) {
                        // Show numeric progress alongside the bar during long model loads.
                        ProgressView(value: progress, total: 1) {
                            Text(
                                String(
                                    localized: .stageWithPercent(
                                        stage: stage,
                                        percent: progress.localisedPercent
                                    )
                                )
                            )
                        }
                    } else {
                        ProgressView(stage)
                    }
                }
                .accessibilityLabel(
                    state.progressAccessibilityLabel(modelName: item.displayName)
                        ?? String(localized: .actionInProgressFor(item.displayName))
                )
                if let steps = SparkDashboardOwnerPresentation.stepPlan(for: state.action) {
                    SparkOperationSteps(steps: steps, current: operation.stage)
                }
                if let detail = SparkDashboardOwnerPresentation.operationStageDetail(
                    operation.stage
                ) {
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.action == .install && model.canShowDownloadActivity {
                    Button("Show progress on Lock Screen", systemImage: "lock.rectangle") {
                        model.showDownloadActivity(modelID: item.id)
                    }
                    .font(.caption)
                    Text(
                        "Progress refreshes while SparkPilot can run; delayed readings are labelled."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let message = model.downloadActivityError {
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SparkModelFailureView(
                item: item,
                state: state,
                model: model,
                providerCredentialID: selectedCredentialID(for: item),
                restartSpark: restartSpark
            )
        }
    }
    @ViewBuilder
    private func unsafeProfileActions(_ item: SparkModel) -> some View {
        if model.profileReenableSupported {
            ForEach(item.profiles.filter { !$0.safe }) { profile in
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        .profileDisabledAfterMemoryEvent(profile.displayName),
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("Review re-enable") {
                        Task {
                            await model.prepareProfileReenable(
                                modelID: item.id,
                                profileID: profile.id
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        model.isPreparingProfileReenable || model.isReenablingProfile
                            || model.pendingProfileReenable != nil
                    )
                    .accessibilityLabel(
                        Text(
                            .reviewReEnabling(
                                profile: profile.displayName,
                                model: item.displayName
                            )
                        )
                    )
                }
                .padding(.top, 4)
            }
        }
    }
    @ViewBuilder
    private func modelActions(_ item: SparkModel) -> some View {
        let state = model.lifecycleState(for: item.id)
        let busy = state?.isRunning == true
        let needsRecovery = state?.recoveryAction != nil
        ViewThatFits(in: .horizontal) {
            HStack { modelActionButtons(item) }
            VStack(alignment: .leading) { modelActionButtons(item) }
        }
        .disabled(
            busy || needsRecovery || model.isPreparingConfirmation
                || !model.containerRuntimeAvailable || !model.signedCatalogueAvailable
        )
    }
    @ViewBuilder
    private func modelActionButtons(_ item: SparkModel) -> some View {
        switch item.installState {
        case .available, .failed:
            if item.gated == true, selectedCredentialID(for: item) == nil {
                Button("Add Hugging Face access") {
                    showProviderCredentials()
                }
                .buttonStyle(.borderedProminent)
                .disabled(providerCredentialModel?.canManage != true)
                .accessibilityHint(
                    "This gated model needs a read-only token saved on the Spark before download."
                )
            } else {
                Button("Download") {
                    Task {
                        await model.prepareInstall(
                            modelID: item.id,
                            providerCredentialID: selectedCredentialID(for: item)
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text(.downloadResource(item.displayName)))
            }
        case .installed:
            if model.inference?.modelID == item.id {
                Button("Stop") { Task { await model.prepareStopActiveModel() } }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Text(.stopResource(item.displayName)))
            } else {
                let replacesActive = model.inference?.modelID != nil
                let presetID = SparkModelDefaults.preferred(
                    targetID: model.targetID,
                    modelID: item.id,
                    profiles: item.profiles
                )
                let preset = item.profiles.first { $0.id == presetID }
                Button {
                    Task {
                        await model.startModel(
                            modelID: item.id,
                            replaceActive: replacesActive
                        )
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(replacesActive ? "Replace running model" : "Launch model")
                        if let preset { Text(preset.displayName).font(.caption) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    replacesActive
                        ? String(localized: .replaceRunningModelWith(item.displayName))
                        : String(localized: .startResource(item.displayName))
                )
                .accessibilityValue(preset?.displayName ?? "")
                Button("Change preset", systemImage: "slider.horizontal.3") {
                    Task {
                        await model.prepareLoad(modelID: item.id, replaceActive: replacesActive)
                    }
                }
                .buttonStyle(.bordered)
                Button("Remove", role: .destructive) {
                    Task { await model.prepareRemove(modelID: item.id) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(.removeResource(item.displayName)))
            }
        case .downloading, .verifying, .incompatible, .unverified:
            EmptyView()
        }
    }
    @ViewBuilder
    private func gatedModelAccess(_ item: SparkModel) -> some View {
        if item.gated == true {
            let provider = item.sourceProvider ?? "huggingface"
            let credentials = providerCredentialModel?.credentials(for: provider) ?? []
            if credentials.count > 1 {
                Picker(
                    "Download access",
                    selection: Binding(
                        get: { selectedCredentialID(for: item) ?? "" },
                        set: { providerCredentialModel?.selectCredential($0, for: provider) }
                    )
                ) {
                    ForEach(credentials, id: \.id) { credential in
                        Text(credential.displayName).tag(credential.id)
                    }
                }
                .pickerStyle(.menu)
            } else if let credential = credentials.first {
                Label(.usingCredential(credential.displayName), systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    providerCredentialModel?.canManage == true
                        ? String(
                            localized:
                                "Add a read-only Hugging Face token to download this gated model."
                        )
                        : String(
                            localized: "Ask an owner or administrator to add Hugging Face access."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func installLabel(_ state: SparkModelInstallState) -> String {
        switch state {
        case .available: String(localized: "Available to download")
        case .downloading: String(localized: "Downloading")
        case .verifying: String(localized: "Verifying")
        case .installed: String(localized: "Installed")
        case .failed: String(localized: "Download failed")
        case .incompatible: String(localized: "Not compatible")
        case .unverified: String(localized: "Not verified")
        }
    }
    private func modelSymbol(_ state: SparkModelInstallState) -> String {
        switch state {
        case .installed: "checkmark.circle.fill"
        case .downloading, .verifying: "arrow.down.circle"
        case .failed, .incompatible, .unverified: "exclamationmark.triangle.fill"
        case .available: "arrow.down.circle.fill"
        }
    }
    private func modelColor(_ state: SparkModelInstallState) -> Color {
        switch state {
        case .installed: .green
        case .failed, .incompatible, .unverified: .orange
        default: .accentColor
        }
    }
}

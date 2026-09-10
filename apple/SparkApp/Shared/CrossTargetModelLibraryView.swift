import SwiftUI

enum ModelLibraryActionPresentation {
    static let refreshAccessibilityLabel = String(localized: "Refresh model library")
}

/// Hand the selected model target to the existing preview, confirmation and recovery controller on every Apple platform.
public struct CrossTargetModelLibraryView: View {
    @Bindable private var model: CrossTargetModelLibraryModel
    private let onOpenTarget: ((String) -> Void)?
    private let onManageModel: ((String, String, ModelLibraryManagementAction) -> Void)?
    private let clusterLaunchAvailable: ((String) -> Bool)?
    private let onStartClusterModel: ((String, String, String) -> Void)?
    private let refreshClusterLaunches: (() async -> Void)?

    public init(
        model: CrossTargetModelLibraryModel,
        onOpenTarget: ((String) -> Void)? = nil,
        onManageModel: ((String, String, ModelLibraryManagementAction) -> Void)? = nil,
        clusterLaunchAvailable: ((String) -> Bool)? = nil,
        onStartClusterModel: ((String, String, String) -> Void)? = nil,
        refreshClusterLaunches: (() async -> Void)? = nil
    ) {
        self.model = model
        self.onOpenTarget = onOpenTarget
        self.onManageModel = onManageModel
        self.clusterLaunchAvailable = clusterLaunchAvailable
        self.onStartClusterModel = onStartClusterModel
        self.refreshClusterLaunches = refreshClusterLaunches
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text(.refreshFailed(errorMessage)))
                }
                Text(
                    "Nemotron Lightning is our first tested model for DGX Spark, for questions, writing and everyday planning. More models are planned."
                )
                .font(.callout).foregroundStyle(.secondary)
                content
                if model.hasLoaded, !model.snapshot.targets.isEmpty {
                    DisclosureGroup(String(localized: "Configure services")) {
                        ModelServiceDashboardSection(
                            targets: model.snapshot.targets,
                            onOpenTarget: onOpenTarget
                        )
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityLabel(
                    ModelLibraryActionPresentation.refreshAccessibilityLabel
                )
                .accessibilityHint("Checks every paired target for current model evidence.")
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await refreshClusterLaunches?()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model Library")
                .font(.largeTitle.bold())
            Text("Compare where each model is installed and where it can run.")
                .foregroundStyle(.secondary)
            Text("Choose a target here to download, start, stop, or recover a model safely.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.hasLoaded {
                Text(summaryLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(summaryAccessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, !model.hasLoaded {
            SparkSkeletonList(
                rowCount: 3,
                accessibilityLabel: String(
                    localized: "Checking signed model catalogues on paired targets"
                )
            )
        } else if model.snapshot.targets.isEmpty {
            ContentUnavailableView(
                "No Sparks in your library",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Add a Spark from Home before comparing models.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
            .accessibilityElement(children: .combine)
        } else if model.snapshot.models.isEmpty {
            VStack(spacing: 18) {
                ContentUnavailableView(
                    emptyModelsTitle,
                    systemImage: "network.slash",
                    description: Text(emptyModelsDescription)
                )
                targetEvidenceSummary
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            LazyVStack(spacing: 16) {
                ForEach(model.snapshot.models) { item in
                    ModelLibraryCard(
                        item: item,
                        onManageModel: onManageModel,
                        clusterLaunchAvailable: clusterLaunchAvailable,
                        onStartClusterModel: onStartClusterModel
                    )
                }
            }
        }
    }

    private var summaryLabel: String {
        let targets = model.snapshot.targets.count
        let models = model.snapshot.models.count
        return String(localized: .modelsAcrossTargets(models: models, targets: targets))
    }

    private var summaryAccessibilityLabel: String {
        let current = model.snapshot.targets.count(where: { $0.freshness.isCurrent })
        return String(
            localized: .summaryWithCurrentEvidence(summary: summaryLabel, current: current)
        )
    }

    private var emptyModelsTitle: String {
        model.snapshot.targets.contains(where: { $0.freshness.isCurrent })
            ? String(localized: "No signed models reported")
            : String(localized: "Model evidence unavailable")
    }

    private var emptyModelsDescription: String {
        model.snapshot.targets.contains(where: { $0.freshness.isCurrent })
            ? String(localized: "The connected targets did not report a signed model recipe.")
            : String(
                localized:
                    "Targets remain in the library, but none supplied fresh authenticated inventory."
            )
    }

    private var targetEvidenceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.snapshot.targets) { target in
                HStack {
                    Text(target.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(evidenceLabel(target.freshness))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Text(
                        .targetEvidence(
                            name: target.name,
                            topology: target.topology.label,
                            freshness: evidenceAccessibilityLabel(target.freshness)
                        )
                    )
                )
            }
        }
        .frame(maxWidth: 560)
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ModelLibraryCard: View {
    let item: CrossTargetModelLibraryItem
    let onManageModel: ((String, String, ModelLibraryManagementAction) -> Void)?
    let clusterLaunchAvailable: ((String) -> Bool)?
    let onStartClusterModel: ((String, String, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modelHeader
            metadata
            coverage
            distributedLaunch
            recommendation
            placements
            technicalDetails
        }
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var distributedLaunch: some View {
        if item.verification == .verified,
            let placement = item.placements.first(where: {
                $0.topology.isCompleteCluster && $0.isInstalled
            }),
            item.profiles.contains(where: \.isSafe),
            clusterLaunchAvailable?(placement.id) == true,
            let onStartClusterModel
        {
            Menu {
                ForEach(item.profiles, id: \.id) { profile in
                    Button {
                        onStartClusterModel(placement.id, item.technicalDetails.modelID, profile.id)
                    } label: {
                        Text(
                            .modelProfileChoice(
                                name: profile.name,
                                context: profile.maxModelLength?.formatted()
                                    ?? String(localized: "Not reported"),
                                requests: profile.maxSequences?.formatted()
                                    ?? String(localized: "Not reported")
                            )
                        )
                    }
                    .disabled(!profile.isSafe)
                    .accessibilityHint(Text(.startSignedProfileAcrossCluster(profile.name)))
                }
            } label: {
                Label(
                    .startOnTarget(placement.targetName),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                "Choose a profile to set the context window and simultaneous request limit."
            )
        }
    }

    private var modelHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.title3.bold())
                if let summary = item.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VerificationBadge(verification: item.verification)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            metadataRow(String(localized: "Version"), item.versionLabel)
            metadataRow(String(localized: "Task"), item.taskLabel)
            metadataRow(String(localized: "Download"), downloadLabel)
            metadataRow(String(localized: "Capabilities"), capabilitiesLabel)
            metadataRow(String(localized: "Topology"), item.topologyLabel)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                .modelRowSummary(
                    version: item.versionLabel,
                    task: item.taskLabel,
                    download: downloadLabel,
                    capabilities: capabilitiesLabel,
                    topology: item.topologyLabel
                )
            )
        )
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }

    private var downloadLabel: String {
        item.downloadBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? String(localized: "Not reported")
    }

    private var capabilitiesLabel: String {
        item.capabilityLabels.isEmpty
            ? String(localized: "Not reported") : item.capabilityLabels.joined(separator: ", ")
    }

    private var coverage: some View {
        Label(item.coverage.label, systemImage: "checkmark.circle")
            .font(.subheadline.weight(.medium))
            .accessibilityLabel(Text(.coverageSummary(item.coverage.label)))
    }

    @ViewBuilder
    private var recommendation: some View {
        if let recommendation = item.recommendation,
            let placement = item.placements.first(where: { $0.id == recommendation.targetID })
        {
            VStack(alignment: .leading, spacing: 9) {
                Text("Recommended target")
                    .font(.headline)
                HStack(alignment: .firstTextBaseline) {
                    Text(recommendation.targetName)
                        .font(.subheadline.bold())
                    Spacer()
                    FitBadge(fit: recommendation.fit)
                }
                Text(recommendation.explanation)
                    .font(.subheadline)
                Text(
                    .capacityEvidenceAt(
                        recommendation.evidenceAt.formatted(date: .abbreviated, time: .standard)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let onManageModel,
                    let action = placement.managementAction
                {
                    Button(action.label(targetName: placement.targetName)) {
                        onManageModel(
                            placement.id,
                            item.technicalDetails.modelID,
                            action
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(
                        "Opens this Spark and uses its signed preview and confirmation flow."
                    )
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        } else {
            Label(
                "No target has fresh evidence that supports this model.",
                systemImage: "questionmark.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                "No recommendation. No target has fresh evidence that supports this model."
            )
        }
    }

    @ViewBuilder
    private var placements: some View {
        if !item.eligibleAlternatives.isEmpty {
            placementGroup(
                title: String(localized: "Eligible alternatives"),
                placements: item.eligibleAlternatives
            )
        }
        if !item.otherTargets.isEmpty {
            placementGroup(title: String(localized: "Other targets"), placements: item.otherTargets)
        }
    }

    private func placementGroup(
        title: String,
        placements: [ModelLibraryTargetPlacement]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(placements) { placement in
                TargetPlacementRow(
                    placement: placement,
                    modelID: item.technicalDetails.modelID,
                    onManageModel: onManageModel
                )
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(String(localized: "Technical details")) {
            VStack(alignment: .leading, spacing: 7) {
                technicalRow(String(localized: "Model identifier"), item.technicalDetails.modelID)
                technicalRow(
                    String(localized: "Recipe revision"),
                    item.technicalDetails.recipeRevision ?? String(localized: "Not reported")
                )
                technicalRow(
                    String(localized: "Source revision"),
                    item.technicalDetails.sourceRevision ?? String(localized: "Not reported")
                )
            }
            .padding(.top, 8)
        }
        .font(.caption)
        .accessibilityHint("Expands model identifiers and revision details.")
    }

    private func technicalRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
        }
    }
}

private struct TargetPlacementRow: View {
    let placement: ModelLibraryTargetPlacement
    let modelID: String
    let onManageModel: ((String, String, ModelLibraryManagementAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(placement.targetName)
                        .font(.subheadline.bold())
                    Text(.joined(placement.topology.label, placement.state.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                FitBadge(fit: placement.fit)
            }
            Text(placement.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: evidenceSymbol(placement.freshness))
                    .accessibilityHidden(true)
                Text(evidenceLabel(placement.freshness))
            }
            .font(.caption2)
            .foregroundStyle(evidenceColor(placement.freshness))
            if let onManageModel,
                let action = placement.managementAction
            {
                Button(action.label(targetName: placement.targetName)) {
                    onManageModel(placement.id, modelID, action)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(
                    "Opens this Spark and uses its signed preview and confirmation flow."
                )
            }
        }
        .padding(11)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct FitBadge: View {
    let fit: ModelTargetFit

    var body: some View {
        Text(fit.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(fitColor(fit))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fitColor(fit).opacity(0.12), in: Capsule())
            .accessibilityLabel(Text(.targetFit(fit.label)))
    }
}

private struct VerificationBadge: View {
    let verification: ModelLibraryRecipeVerification

    var body: some View {
        Label(verification.label, systemImage: verificationSymbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(verificationColor)
            .accessibilityLabel(Text(.recipeVerification(verification.label)))
    }

    private var verificationSymbol: String {
        switch verification {
        case .verified: "checkmark.seal.fill"
        case .unverified: "exclamationmark.shield.fill"
        case .unavailable: "questionmark.diamond"
        }
    }

    private var verificationColor: Color {
        switch verification {
        case .verified: .green
        case .unverified: .orange
        case .unavailable: .secondary
        }
    }
}

private func fitColor(_ fit: ModelTargetFit) -> Color {
    switch fit {
    case .fitsNow: .green
    case .fitsAfterStop, .smallerProfile, .clusterRequired: .orange
    case .incompatible: .red
    case .evidenceUnavailable: .secondary
    }
}

private func evidenceLabel(_ freshness: ModelLibraryEvidenceFreshness) -> String {
    switch freshness {
    case .current(let observedAt):
        String(
            localized: .currentAsOf(observedAt.formatted(date: .abbreviated, time: .standard))
        )
    case .stale(let observedAt):
        String(
            localized: .cachedFrom(observedAt.formatted(date: .abbreviated, time: .standard))
        )
    case .unavailable:
        String(localized: "No authenticated evidence")
    }
}

private func evidenceAccessibilityLabel(_ freshness: ModelLibraryEvidenceFreshness) -> String {
    switch freshness {
    case .current(let observedAt):
        String(
            localized: .evidenceCurrentFrom(
                observedAt.formatted(date: .complete, time: .standard)
            )
        )
    case .stale(let observedAt):
        String(
            localized: .evidenceStaleFrom(
                observedAt.formatted(date: .complete, time: .standard)
            )
        )
    case .unavailable:
        String(localized: "Authenticated evidence unavailable")
    }
}

private func evidenceSymbol(_ freshness: ModelLibraryEvidenceFreshness) -> String {
    switch freshness {
    case .current: "checkmark.circle.fill"
    case .stale: "clock.badge.exclamationmark"
    case .unavailable: "questionmark.circle"
    }
}

private func evidenceColor(_ freshness: ModelLibraryEvidenceFreshness) -> Color {
    switch freshness {
    case .current: .green
    case .stale: .orange
    case .unavailable: .secondary
    }
}

import SparkAPI
import SwiftUI

struct ModelServiceDashboardSection: View {
    let targets: [ModelLibraryTargetEvidence]
    let onOpenTarget: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Services and updates")
                    .font(.title2.bold())
                Text(
                    "What is installed, what is running, and what needs attention on each Spark."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 290), spacing: 14)],
                spacing: 14
            ) {
                ForEach(targets) { target in
                    ModelServiceTargetCard(target: target, onOpenTarget: onOpenTarget)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModelServiceTargetCard: View {
    let target: ModelLibraryTargetEvidence
    let onOpenTarget: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let services = target.services {
                runtimeRow(services)
                ForEach(services.engines) { engine in
                    engineRow(engine)
                }
                openWebUIRow(services.openWebUI)
                modelsRow(services)
                updatesBlock(services.updates)
            } else {
                Label(
                    target.freshness.isCurrent
                        ? "Service details are not available from this runtime."
                        : "Reconnect to check services and updates.",
                    systemImage: "questionmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if let onOpenTarget {
                Button("Manage on this Spark") { onOpenTarget(target.id) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(target.name)
                    .font(.headline)
                Text(target.topology.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(freshnessLabel, systemImage: freshnessSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(target.freshness.isCurrent ? Color.green : Color.secondary)
        }
    }

    private func runtimeRow(_ services: ModelServiceTargetSnapshot) -> some View {
        serviceRow(
            title: String(localized: "Spark Runtime"),
            value: services.runtimeHealthy
                ? String(localized: "Healthy") : String(localized: "Needs attention"),
            detail: String(localized: .versionLabelled(services.runtimeVersion)),
            state: services.runtimeHealthy ? .running : .needsAttention,
            symbol: "server.rack"
        )
    }

    private func engineRow(_ engine: ModelEngineServiceSnapshot) -> some View {
        let ownership = ModelServicePresentation.ownershipLabel(engine.ownership)
        let models =
            engine.servedModels.isEmpty
            ? nil
            : String(
                localized: .servingModels(
                    engine.servedModels.formatted(.list(type: .and))
                )
            )
        let detail = ModelServicePresentation.joined(ownership, models)
        return serviceRow(
            title: engine.name,
            value: serviceLabel(engine.state),
            detail: detail.isEmpty ? serviceDetail(engine.state) : detail,
            state: engine.state,
            symbol: "bolt.horizontal.circle"
        )
    }

    private func openWebUIRow(_ service: ModelOptionalServiceSnapshot?) -> some View {
        Group {
            if let service {
                let value =
                    service.updateAvailable
                    ? String(localized: "Update available") : serviceLabel(service.state)
                let gateway =
                    service.gatewayHealthy == false
                    ? String(localized: "Inference gateway needs attention") : nil
                let detail = ModelServicePresentation.joined(
                    service.version.map { String(localized: .versionLabelled($0)) },
                    gateway
                )
                serviceRow(
                    title: String(localized: "Open WebUI"),
                    value: value,
                    detail: detail.isEmpty ? serviceDetail(service.state) : detail,
                    state: service.updateAvailable ? .needsAttention : service.state,
                    symbol: "rectangle.on.rectangle"
                )
            } else {
                serviceRow(
                    title: String(localized: "Open WebUI"),
                    value: String(localized: "Unavailable"),
                    detail: String(
                        localized: "This runtime did not return verified service status."
                    ),
                    state: .unknown,
                    symbol: "rectangle.on.rectangle"
                )
            }
        }
    }

    private func modelsRow(_ services: ModelServiceTargetSnapshot) -> some View {
        let installed = target.recipes.filter { recipe in
            recipe.installState == .installed
                || recipe.operationalState == .running
                || recipe.operationalState == .installed
        }
        let value =
            installed.isEmpty
            ? String(localized: "None installed")
            : String(localized: .modelsInstalled(installed.count))
        let detail =
            installed.isEmpty
            ? String(localized: .verifiedRecipesAvailable(services.catalogueRecipeCount))
            : installed.map(\.displayName).sorted().joined(separator: ", ")
        return serviceRow(
            title: String(localized: "Models"),
            value: value,
            detail: detail,
            state: installed.isEmpty ? .readyToInstall : .installed,
            symbol: "square.stack.3d.up"
        )
    }

    @ViewBuilder
    private func updatesBlock(_ updates: ModelSoftwareUpdateSnapshot?) -> some View {
        Divider()
        if let updates {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Software updates", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(updateHeadline(updates))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(updateColor(updates))
                }
                LabeledContent(
                    "DGX OS packages",
                    value: updateCount(updates.systemPackagesAvailable)
                )
                LabeledContent("Firmware", value: updateCount(updates.firmwareUpdatesAvailable))
                LabeledContent(
                    "Spark Runtime",
                    value: updates.runtimeReleaseID == nil ? "Current" : "Update available"
                )
                .font(.caption)
                if updates.rebootRequired {
                    Label("Restart required", systemImage: "arrow.clockwise.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text(.lastChecked(checkedAtLabel(updates.checkedAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(
                "Update status is unavailable. Open this Spark to check again.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func serviceRow(
        title: String,
        value: String,
        detail: String,
        state: ModelServiceRunState,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(serviceColor(state))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(serviceColor(state))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var freshnessLabel: String {
        ModelServicePresentation.freshnessLabel(target.freshness)
    }

    private var freshnessSymbol: String {
        target.freshness.isCurrent ? "dot.radiowaves.left.and.right" : "clock"
    }

    private func serviceLabel(_ state: ModelServiceRunState) -> String {
        ModelServicePresentation.stateLabel(state)
    }

    private func serviceDetail(_ state: ModelServiceRunState) -> String {
        ModelServicePresentation.stateDetail(state)
    }

    private func serviceColor(_ state: ModelServiceRunState) -> Color {
        switch state {
        case .running: .green
        case .installed, .readyToInstall: .blue
        case .needsAttention: .orange
        case .unavailable, .unknown: .secondary
        }
    }

    private func updateHeadline(_ updates: ModelSoftwareUpdateSnapshot) -> String {
        ModelServicePresentation.updateHeadline(updates.totalKnownUpdates)
    }

    private func updateColor(_ updates: ModelSoftwareUpdateSnapshot) -> Color {
        (updates.totalKnownUpdates ?? 0) == 0 && !updates.rebootRequired ? .green : .orange
    }

    private func updateCount(_ count: Int?) -> String {
        ModelServicePresentation.updateCount(count)
    }

    private func checkedAtLabel(_ checkedAt: String) -> String {
        ModelServicePresentation.checkedAtLabel(checkedAt)
    }
}

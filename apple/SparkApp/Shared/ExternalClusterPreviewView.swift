import SparkAPI
import SparkDesignSystem
import SwiftUI

public struct ExternalClusterPreviewView: View {
    @State private var model: ExternalClusterPreviewModel

    public init(model: ExternalClusterPreviewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        @Bindable var model = model
        List {
            let registered = model.registeredClusters()
            if !registered.isEmpty {
                Section("Registered clusters") {
                    ForEach(registered) { cluster in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cluster.name).font(.headline)
                            Text(.independentlyPairedSparks(cluster.memberCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label(
                                cluster.topologyIsStale
                                    ? "Saved topology needs a fresh check"
                                    : "Signed topology is current",
                                systemImage: cluster.topologyIsStale
                                    ? "clock.badge.exclamationmark" : "checkmark.shield.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(cluster.topologyIsStale ? .orange : .green)
                            Button {
                                Task { await model.refreshRegistration(cluster.id) }
                            } label: {
                                if model.refreshingRegistrationID == cluster.id {
                                    Label(
                                        "Checking topology",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                } else {
                                    Label("Check topology", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(model.refreshingRegistrationID != nil)
                            Button("Remove cluster grouping", role: .destructive) {
                                model.removeRegistration(cluster.id)
                            }
                            .help(
                                String(
                                    localized:
                                        "Removes only this device's grouping and restores each Spark card."
                                )
                            )
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            if let message = model.actionMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            ForEach(model.launchModels, id: \.clusterID) { launchModel in
                ManagedClusterLaunchView(model: launchModel)
            }

            Section {
                Label(
                    "Build or add a cluster",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.headline)
                Text(
                    "Select two standalone Sparks to let SparkPilot configure and verify their ConnectX link, or review a cluster that was configured elsewhere without changing it."
                )
                .foregroundStyle(.secondary)
            }

            switch model.accessGate {
            case .noSparkSaved:
                Section {
                    ContentUnavailableView(
                        "No Standalone Sparks",
                        systemImage: "externaldrive.badge.xmark",
                        description: Text(
                            "Pair at least two standalone Sparks as an owner before registering another existing cluster."
                        )
                    )
                }
            case .noUsableSpark:
                Section {
                    ContentUnavailableView(
                        "No Standalone Spark You Own Here",
                        systemImage: "person.badge.key",
                        description: Text(
                            "Your standalone Sparks are paired, but this device holds no owner trust record for them. Open each one from Home as its owner, then come back."
                        )
                    )
                }
            case .ready:
                Section("Choose Sparks") {
                    ForEach(model.targets) { target in
                        Button {
                            model.toggle(target.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(
                                    systemName: model.selectedTargetIDs.contains(target.id)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    model.selectedTargetIDs.contains(target.id)
                                        ? Color.accentColor : Color.secondary
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(target.displayName)
                                        .foregroundStyle(.primary)
                                    Text("Paired standalone Spark")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isReviewing || model.isAuthorizing)
                        .accessibilityLabel(Text(.selectForClusterReview(target.displayName)))
                    }
                    if model.selectedTargetIDs.count < 2 {
                        Label(
                            "Select at least two Sparks.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Display name") {
                    TextField("Cluster name", text: $model.name)
                        .sparkField()
                        .disabled(model.isReviewing || model.isAuthorizing)
                }

                if model.selectedTargets.count == 2 {
                    Section("Coordinator") {
                        Picker("Original Spark", selection: $model.coordinatorTargetID) {
                            ForEach(model.selectedTargets) { target in
                                Text(target.displayName).tag(Optional(target.id))
                            }
                        }
                        Text(
                            String(
                                localized:
                                    "The original Spark stays coordinator. SparkPilot starts the other member first and names both roles before it changes the link."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await model.authorizeNewCluster() }
                    } label: {
                        if model.isAuthorizing {
                            HStack {
                                ProgressView()
                                Text("Linking and testing both Sparks")
                            }
                        } else {
                            Label("Set Up Two-Spark Cluster", systemImage: "cable.connector")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAuthorize)
                    Text(
                        "SparkPilot prepares both members, proves the reciprocal 200 GbE path, runs a two-rank NCCL test, then commits both or rolls both back."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button {
                        Task { await model.review() }
                    } label: {
                        if model.isReviewing {
                            HStack {
                                ProgressView()
                                Text("Reading cluster evidence")
                            }
                        } else {
                            Label("Review Connection Evidence", systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(!model.canReview)
                    .help(
                        String(
                            localized:
                                "Reads signed identity, ConnectX port and reciprocal peer evidence from the selected Sparks."
                        )
                    )
                }
            }

            if let message = model.errorMessage {
                Section("Review not completed") {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let presentation = model.presentation {
                evidenceSections(presentation)
                if model.canRegister {
                    Section {
                        Button {
                            model.register()
                        } label: {
                            Label("Register Existing Cluster", systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.borderedProminent)
                        Text(
                            "This saves one cluster card on this device. It does not change Netplan, Ray, vLLM, models, containers or services."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Clusters")
        .task {
            await model.reconcilePendingAuthorization()
            model.refreshManagedLaunchModels()
        }
    }

    @ViewBuilder
    private func evidenceSections(_ presentation: ExternalClusterPreviewPresentation) -> some View {
        Section("Result") {
            LabeledContent("Configuration", value: presentation.configurationLabel)
            Label(
                presentation.evidenceComplete
                    ? "Identity and reciprocal fabric evidence is complete."
                    : "The cluster evidence has blockers.",
                systemImage: presentation.evidenceComplete
                    ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(presentation.evidenceComplete ? .green : .orange)
            Text(
                "SparkPilot has not registered this cluster, changed its topology or taken over its workloads."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Member identity") {
            ForEach(presentation.memberRows) { member in
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name)
                        Text(member.identityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(
                        systemName: member.identityAuthenticated
                            ? "person.badge.shield.checkmark.fill"
                            : "person.badge.shield.exclamationmark.fill"
                    )
                    .foregroundStyle(member.identityAuthenticated ? .green : .orange)
                }
            }
        }

        Section("ConnectX evidence") {
            if presentation.fabricRows.isEmpty {
                Label(
                    "No ConnectX port evidence was returned.",
                    systemImage: "cable.connector.slash"
                ).foregroundStyle(.secondary)
            }
            ForEach(presentation.fabricRows) { port in
                VStack(alignment: .leading, spacing: 5) {
                    Text(port.targetName).font(.headline)
                    LabeledContent("Interface", value: port.interfacesLabel)
                    LabeledContent("Link", value: port.physicalLinkLabel)
                    if let speed = port.speedLabel {
                        LabeledContent("Speed", value: speed)
                    }
                    LabeledContent("Peer", value: port.peerLabel)
                    LabeledContent("Fabric owner", value: port.ownershipLabel)
                }
                .padding(.vertical, 3)
            }
        }

        Section("Authenticated links") {
            if presentation.linkRows.isEmpty {
                Label("No reciprocal Spark link is authenticated.", systemImage: "link.badge.plus")
                    .foregroundStyle(.secondary)
            }
            ForEach(presentation.linkRows) { link in
                VStack(alignment: .leading, spacing: 4) {
                    Text(.clusterLink(link.firstName, link.secondName))
                        .font(.headline)
                    Text(link.proofLabel)
                    Text(link.topologyLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }

        if !presentation.blockerRows.isEmpty {
            Section("Blockers") {
                ForEach(presentation.blockerRows) { blocker in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(blocker.title)
                            Text(blocker.recovery)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }

        Section("Left unchanged") {
            ForEach(presentation.preservedItems, id: \.self) { item in
                Label(item, systemImage: "checkmark")
            }
        }
    }
}

private struct ManagedClusterLaunchView: View {
    @Bindable var model: ManagedClusterLaunchModel

    var body: some View {
        Group {
            if model.isVisible {
                Section("Distributed runtime") {
                    Text(model.name).font(.headline)
                    if model.statuses.isEmpty {
                        Label(
                            "Distributed runtime monitoring is ready",
                            systemImage: "waveform.path.ecg"
                        )
                        .foregroundStyle(.green)
                        Text(
                            "Choose an installed signed recipe in Models to start it across both qualified Sparks."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.statuses, id: \.targetID) { member in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.targetName).font(.headline)
                                LabeledContent(
                                    "State",
                                    value: member.status.state.rawValue.capitalized
                                )
                                LabeledContent("Recipe", value: member.status.recipeId)
                                LabeledContent("Profile", value: member.status.profileId)
                                if let failure = ManagedClusterLaunchFailureCopy.presentation(
                                    for: member.status
                                ) {
                                    Label(
                                        failure.title,
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    .foregroundStyle(.orange)
                                    Text(failure.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        ForEach(model.missingMemberNames, id: \.self) { memberName in
                            Label(
                                .clusterLaunchMissingMember(memberName),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                        Button {
                            Task { await model.refreshStatus() }
                        } label: {
                            Label("Refresh both Sparks", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isWorking)
                        Button(role: .destructive) {
                            Task { await model.stop() }
                        } label: {
                            Label("Stop distributed runtime", systemImage: "stop.circle.fill")
                        }
                        .disabled(!model.canStop)
                        if model.canPrepareSingleNodeRecovery {
                            Button {
                                Task { await model.prepareSingleNodeRecovery() }
                            } label: {
                                Label(
                                    "Review single-Spark recovery",
                                    systemImage: "shield.lefthalf.filled"
                                )
                            }
                            .disabled(model.isWorking)
                        }
                    }
                    if let message = model.recoveryMessage {
                        Label(message, systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .task {
            await model.refresh()
            while !Task.isCancelled, model.launchID != nil, model.canStop {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await model.refreshStatus()
            }
        }
        .sheet(
            item: Binding(
                get: { model.pendingRecoveryConfirmation },
                set: { if $0 == nil { model.cancelSingleNodeRecovery() } }
            )
        ) { confirmation in
            ModelActionConfirmationView(
                confirmation: confirmation,
                cancel: model.cancelSingleNodeRecovery,
                apply: { Task { await model.confirmSingleNodeRecovery() } }
            )
            .interactiveDismissDisabled(model.isWorking)
        }
    }
}

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

public struct SparkDashboardView: View {
    private struct RefreshIdentity: Equatable {
        let model: ObjectIdentifier
        let phase: ScenePhase
    }
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var model: SparkDashboardModel
    @AppStorage private var dashboardMetricSelection: String
    @State private var selectedSection: SparkDashboardSection?
    @State private var showingMetricEditor = false
    @State private var confirmingOpenWebUIRemoval = false
    @State private var confirmingOpenWebUIRepair = false
    @State private var showingCatalogueImporter = false
    @State private var showingProviderCredentials = false
    @State private var catalogueFileError: String?
    @State private var launchModel: SparkQuickLaunchModel?
    private let providerCredentialModel: ProviderCredentialModel?
    private let deviceManagementModel: DeviceManagementModel?
    private let powerControlModel: SparkPowerControlModel?
    private let identitySettingsModel: SparkIdentitySettingsModel?
    private let networkStatusModel: SparkNetworkStatusModel?
    private let settingsModel: SparkSettingsModel?
    private let remoteAccessModel: RemoteAccessModel?
    private let library: SparkLibrary?

    public init(
        model: SparkDashboardModel,
        providerCredentialModel: ProviderCredentialModel? = nil,
        deviceManagementModel: DeviceManagementModel? = nil,
        powerControlModel: SparkPowerControlModel? = nil,
        identitySettingsModel: SparkIdentitySettingsModel? = nil,
        networkStatusModel: SparkNetworkStatusModel? = nil,
        settingsModel: SparkSettingsModel? = nil,
        remoteAccessModel: RemoteAccessModel? = nil,
        library: SparkLibrary? = nil
    ) {
        self.model = model
        _dashboardMetricSelection = AppStorage(
            wrappedValue: SparkDashboardMetricSelection(
                metrics: SparkDashboardMetricSelection.defaults
            ).encoded,
            SparkDashboardMetricSelection.storageKey(targetID: model.targetID)
        )
        self.providerCredentialModel = providerCredentialModel
        self.deviceManagementModel = deviceManagementModel
        self.powerControlModel = powerControlModel
        self.identitySettingsModel = identitySettingsModel
        self.networkStatusModel = networkStatusModel
        self.settingsModel = settingsModel
        self.remoteAccessModel = remoteAccessModel
        self.library = library
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let settingsModel,
                    let notice = SparkDashboardOwnerPresentation.runtimeUpdateNotice(
                        canInstallBundledRuntime: settingsModel.canInstallBundledRuntime
                    )
                {
                    SparkDashboardRuntimeNotice(notice: notice, settingsModel: settingsModel)
                }
                if let evidence = model.inference?.lastUnload, !evidence.memoryRecovered,
                    model.inference?.modelID == nil
                {
                    SparkDashboardUnloadNotice(
                        evidence: evidence,
                        checkAgain: { Task { await refreshDashboard() } },
                        openSettings: { selectedSection = .settings }
                    )
                }
                if let pressure = model.pressurePresentation {
                    // Free memory in one tap: stop the running model or go straight to Models.
                    MemoryPressureBanner(
                        presentation: pressure,
                        stopModel: model.inference?.modelID == nil
                            ? nil : { Task { await model.prepareStopActiveModel() } },
                        openModels: { selectedSection = .models }
                    )
                }
                SparkDashboardOverviewMetrics(
                    model: model,
                    dashboardMetricSelection: dashboardMetricSelection,
                    edit: { showingMetricEditor = true }
                )
                dashboardSections
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(identitySettingsModel?.displayName ?? model.nodeName)
        .onAppear {
            if let section = SparkWidgetNavigation.shared.takePendingDashboardSection()
                .flatMap(SparkDashboardSection.init(rawValue:))
            {
                selectedSection = section
            }
        }
        .navigationDestination(item: $selectedSection) { section in
            dashboardDestination(section)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshDashboard() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || settingsModel?.isLoading == true)
                .accessibilityLabel("Refresh Spark status")
                .sparkHelp(
                    String(localized: "Checks this Spark for current health, services, and models.")
                )
            }
        }
        .refreshable { await refreshDashboard() }
        .task(id: RefreshIdentity(model: ObjectIdentifier(model), phase: scenePhase)) {
            guard scenePhase == .active else { return }
            await model.runLiveUpdates(interval: SparkDashboardRefreshPolicy.liveTelemetryInterval)
        }
        .task(id: model.requestedModelID) {
            guard model.requestedModelID != nil else { return }
            selectedSection = .models
        }
        .task(id: model.requestedServiceID) {
            guard model.requestedServiceID != nil else { return }
            selectedSection = .models
        }
        .task(id: settingsModel.map(ObjectIdentifier.init)) {
            await settingsModel?.loadIfNeeded()
        }
        .task(id: ObjectIdentifier(model)) {
            await deviceManagementModel?.loadIfNeeded()
            await providerCredentialModel?.load()
        }
        .sheet(isPresented: $showingMetricEditor) {
            SparkDashboardMetricEditor(encodedSelection: $dashboardMetricSelection)
        }
        .sheet(item: $launchModel) { launchModel in
            SparkQuickLaunchView(model: launchModel)
        }
        .sheet(isPresented: $showingProviderCredentials) {
            if let providerCredentialModel {
                ProviderCredentialManagementView(model: providerCredentialModel)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingConfirmation != nil || model.pendingLoadConfiguration != nil },
                set: { if !$0 { model.cancelConfirmation() } }
            )
        ) {
            if let confirmation = model.pendingConfirmation {
                ModelActionConfirmationView(
                    confirmation: confirmation,
                    cancel: { model.cancelConfirmation() },
                    apply: { Task { await model.applyConfirmation() } },
                    changeProfile: model.canChangeLoadProfile
                        ? { Task { await model.changeLoadProfile() } } : nil
                )
            } else if let configuration = model.pendingLoadConfiguration {
                ModelLoadConfigurationView(
                    configuration: configuration,
                    isPreparing: model.isPreparingConfirmation,
                    errorMessage: model.lifecycleState(for: configuration.modelID)?.errorMessage,
                    cancel: { model.cancelConfirmation() },
                    review: { profileID in
                        Task { await model.previewLoadConfiguration(profileID: profileID) }
                    },
                    saveIdleSetting: settingsModel.map { settings in
                        { profile, setting in
                            guard model.identityIssue == nil else {
                                throw SparkChatConnectionError.identityMismatch
                            }
                            try await settings.saveModelIdleSetting(
                                setting,
                                modelID: configuration.modelID,
                                profile: profile
                            )
                        }
                    }
                )
            }
        }
        .sheet(
            item: Binding(
                get: { model.pendingCatalogueRefresh },
                set: { if $0 == nil { model.cancelCatalogueRefresh() } }
            )
        ) { confirmation in
            CatalogueRefreshConfirmationView(
                confirmation: confirmation,
                isApplying: model.isRefreshingCatalogue,
                stageLabel: model.catalogueRefreshStageLabel,
                errorMessage: model.catalogueErrorMessage,
                cancel: model.cancelCatalogueRefresh,
                apply: { Task { await model.applyCatalogueRefresh() } }
            )
            .interactiveDismissDisabled(model.isRefreshingCatalogue)
        }
        .sheet(
            item: Binding(
                get: { model.pendingProfileReenable },
                set: { if $0 == nil { model.cancelProfileReenable() } }
            )
        ) { confirmation in
            ProfileReenableConfirmationView(
                confirmation: confirmation,
                isApplying: model.isReenablingProfile,
                errorMessage: model.profileReenableErrorMessage,
                cancel: model.cancelProfileReenable,
                apply: { Task { await model.applyProfileReenable() } }
            )
            .interactiveDismissDisabled(model.isReenablingProfile)
        }
        .sheet(
            item: Binding(
                get: { model.workloadOwnership.pendingConfirmation },
                set: { if $0 == nil { model.workloadOwnership.cancel() } }
            )
        ) { confirmation in
            WorkloadOwnershipConfirmationView(
                confirmation: confirmation,
                isWorking: model.workloadOwnership.isWorking,
                operation: model.workloadOwnership.operation,
                errorMessage: model.workloadOwnership.errorMessage,
                cancel: model.workloadOwnership.cancel,
                apply: {
                    Task {
                        if await model.workloadOwnership.apply() {
                            await model.refresh()
                        }
                    }
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { model.openWebUIAccessPath != nil },
                set: { if !$0 { model.dismissOpenWebUI() } }
            )
        ) {
            if let accessPath = model.openWebUIAccessPath,
                let fingerprint = model.tlsFingerprint,
                let openWebUIRoute = try? PinnedOpenWebUIRoute(
                    baseRoute: model.route,
                    accessPath: accessPath
                )
            {
                PinnedOpenWebUISheet(
                    route: openWebUIRoute,
                    tlsFingerprint: fingerprint,
                    dismiss: model.dismissOpenWebUI
                )
            }
        }
        .alert(
            "Repair Open WebUI?",
            isPresented: $confirmingOpenWebUIRepair
        ) {
            Button("Repair") { Task { await model.repairOpenWebUI() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Restart the unhealthy managed service once, keeping its data. Open WebUI sessions may disconnect during recovery."
            )
        }
        .alert(
            model.openWebUIService?.adopted == true
                ? "Disconnect Open WebUI?" : "Remove Open WebUI?",
            isPresented: $confirmingOpenWebUIRemoval
        ) {
            Button(
                model.openWebUIService?.adopted == true ? "Disconnect" : "Remove and keep data",
                role: .destructive
            ) {
                Task { await model.removeOpenWebUI(eraseData: false) }
            }
            if model.openWebUIService?.adopted != true {
                Button("Remove and erase data", role: .destructive) {
                    Task { await model.removeOpenWebUI(eraseData: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.openWebUIService?.adopted == true
                    ? "Only the SparkPilot connection is removed; your existing Open WebUI keeps running with its data and settings."
                    : "Keeping data lets a later verified installation reuse its local configuration."
            )
        }
        .fileImporter(
            isPresented: $showingCatalogueImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: catalogueFileSelected
        )
    }

    private func refreshDashboard() async {
        async let dashboardRefresh: Void = model.refresh()
        async let settingsRefresh: Void? = settingsModel?.refresh()
        _ = await (dashboardRefresh, settingsRefresh)
    }

    private var dashboardSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage this Spark")
                .font(.title2.bold())
            dashboardSectionRow(
                section: .health,
                title: String(localized: "Health and telemetry"),
                detail: String(localized: "Live hardware, memory, inference and uptime readings"),
                value: model.telemetryIsLive
                    ? String(localized: "Live") : String(localized: "Saved"),
                symbol: "waveform.path.ecg.rectangle"
            )
            dashboardSectionRow(
                section: .models,
                title: String(localized: "Models and services"),
                detail: String(
                    localized: "Models, inference engines, Open WebUI and running workloads"
                ),
                value: model.vllmStatus,
                symbol: "square.stack.3d.up"
            )
            dashboardSectionRow(
                section: .remote,
                title: String(localized: "Remote management"),
                detail: String(localized: "Connect away from home with Tailscale"),
                value: nil,
                symbol: "network"
            )
            dashboardSectionRow(
                section: .settings,
                title: String(localized: "Settings"),
                detail: String(
                    localized: "Name, network, hardware, updates, storage and paired devices"
                ),
                value: nil,
                symbol: "slider.horizontal.3"
            )
        }
    }

    @ViewBuilder
    private func dashboardDestination(_ section: SparkDashboardSection) -> some View {
        switch section {
        case .health:
            SparkDashboardHealthView(
                model: model,
                displayName: identitySettingsModel?.displayName,
                openModels: { selectedSection = .models }
            )
        case .models:
            SparkDashboardModelsView(
                model: model,
                library: library,
                providerCredentialModel: providerCredentialModel,
                showProviderCredentials: { showingProviderCredentials = true },
                // Open Settings, where the power controls confirm the reboot.
                restartSpark: powerControlModel.map { power in
                    {
                        selectedSection = .settings
                        power.request(.reboot)
                    }
                },
                confirmingOpenWebUIRemoval: $confirmingOpenWebUIRemoval,
                confirmingOpenWebUIRepair: $confirmingOpenWebUIRepair,
                showingCatalogueImporter: $showingCatalogueImporter,
                catalogueFileError: $catalogueFileError
            )
        case .remote:
            if let remoteAccessModel {
                RemoteAccessSettingsView(model: remoteAccessModel)
            } else {
                ContentUnavailableView(
                    "Remote management unavailable",
                    systemImage: "network",
                    description: Text("Reconnect to your Spark to manage remote access.")
                )
            }
        case .settings:
            SparkDashboardSettingsPanel(
                identitySettingsModel: identitySettingsModel,
                settingsModel: settingsModel,
                networkStatusModel: networkStatusModel,
                remoteAccessModel: remoteAccessModel,
                deviceManagementModel: deviceManagementModel,
                powerControlModel: powerControlModel,
                refresh: { await model.refresh() }
            )
        }
    }

    private func dashboardSectionRow(
        section: SparkDashboardSection,
        title: String,
        detail: String,
        value: String?,
        symbol: String
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let value {
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(.openResource(title)))
        .accessibilityHint(detail)
    }

    /// Launch, switch, or show the load in progress; never offer a launch while one is running.
    @ViewBuilder
    private func modelAction(library: SparkLibrary) -> some View {
        let modelID = model.inference?.modelID
        let action = SparkModelActionPresentation.action(
            inference: model.inference,
            lifecycle: modelID.flatMap { model.lifecycle[$0] }
                ?? model.lifecycle.values.first { $0.isRunning && $0.action == .load },
            modelName: model.models.first { $0.id == modelID }?.displayName
        )
        switch action {
        case .loading(let line, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Label(line, systemImage: "hourglass").font(.subheadline.weight(.semibold))
                if let fraction { ProgressView(value: fraction).frame(maxWidth: 260) }
            }
            .accessibilityElement(children: .combine)
        case .switchModel:
            Button {
                launchModel = SparkQuickLaunchModel(library: library, targetID: model.targetID)
            } label: {
                Label("Switch model", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("spark.dashboard.switch-model")
        case .launch:
            // One button: the sheet lists this Spark's models with their presets and launches from there.
            Button {
                launchModel = SparkQuickLaunchModel(library: library, targetID: model.targetID)
            } label: {
                VStack(spacing: 3) {
                    Label("Launch model", systemImage: "play.circle")
                    let installed = model.models.filter { $0.installState == .installed }
                    if installed.count == 1, let item = installed.first,
                        let presetID = SparkModelDefaults.preferred(
                            targetID: model.targetID,
                            modelID: item.id,
                            profiles: item.profiles
                        ),
                        let preset = item.profiles.first(where: { $0.id == presetID })
                    {
                        Text(item.displayName).font(.caption)
                        Text(preset.displayName).font(.caption)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("spark.dashboard.launch-model")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SparkDashboardOwnerPresentation.overviewTitle)
                .font(.largeTitle.bold())
            Text(SparkDashboardOwnerPresentation.overviewSubtitle)
                .foregroundStyle(.secondary)
            if let path = SparkConnectionPath.resolve(
                entry: library?.entry(id: model.targetID),
                activeRouteURL: model.route
            ) {
                SparkConnectionPathBadge(path: path)
            }
            if let library {
                modelAction(library: library)
                    .padding(.top, 4)
            }
            if let cachedAt = model.cachedAt {
                Label(
                    .showingSavedDataFrom(
                        cachedAt.formatted(date: .abbreviated, time: .shortened)
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Showing locally saved Spark data while SparkPilot checks for an update."
                )
            }
            if let errorMessage = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    HStack(spacing: 12) {
                        Button("Try Again") { Task { await refreshDashboard() } }
                            .buttonStyle(.bordered)
                            .disabled(model.isRefreshing)
                        // An identity problem is resolved on the paired-devices screen, not by refreshing.
                        if model.identityIssue != nil, deviceManagementModel != nil {
                            Button("Review paired devices") { selectedSection = .settings }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    private func catalogueFileSelected(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure:
            catalogueFileError = SparkCatalogueFileGate.Rejection.unopenable.message
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                // Refuse oversized catalogue files from metadata before mapping their bytes.
                if let rejection = SparkCatalogueFileGate.inspect(
                    isRegularFile: values.isRegularFile,
                    fileSizeBytes: values.fileSize
                ) {
                    catalogueFileError = rejection.message
                    return
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                switch SparkCatalogueFileGate.decode(data) {
                case .failure(let rejection):
                    catalogueFileError = rejection.message
                case .success(let json):
                    catalogueFileError = nil
                    Task {
                        await model.prepareCatalogueRefresh(
                            candidateJSON: json,
                            fileName: url.lastPathComponent
                        )
                    }
                }
            } catch {
                catalogueFileError = SparkCatalogueFileGate.Rejection.unreadable.message
            }
        }
    }

}

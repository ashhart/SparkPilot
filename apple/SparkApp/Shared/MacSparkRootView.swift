#if os(macOS)
    import AppKit
    import Network
    import SparkAPI
    import SparkCore
    import SparkDesignSystem
    import SparkDiscovery
    import SparkLibrary
    import SparkProjects
    import SparkSecurity
    import SwiftUI

    @MainActor
    public struct MacSparkRootView: View {
        @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
        @Environment(\.scenePhase) private var scenePhase
        @State private var discovery: SparkDiscoveryService
        @State private var selection: MacSidebarItem? = .home
        @State private var detailPath = NavigationPath()
        @State private var showingAddSpark = false
        @State private var showingNearby = false
        @State private var onboarding: RetailOnboardingModel
        @State private var modelLibrary: CrossTargetModelLibraryModel
        @State private var fleet: FleetModel
        @State private var workloads: WorkloadComparisonModel
        @State private var chat: SparkChatWorkspace
        @State private var developerTools: SparkDeveloperToolsModel
        @State private var notifications: SparkNotificationModel
        @State private var notificationOperation: SparkNotificationOperationRoute?
        @State private var notificationApproval: SparkAgentApprovalRoute?
        @State private var pendingNotification: SparkNotificationDestination?
        @State private var spotlight: SparkSpotlightModel
        @State private var externalClusters: ExternalClusterPreviewModel
        private let appLock: AppLockModel
        @State private var buildProjects: BuildProjectModel
        @State private var buildWorker: BuildWorkerSettingsModel
        @State private var projects: ProjectsModel

        public init(
            discovery: SparkDiscoveryService = SparkDiscoveryService(),
            onboarding: RetailOnboardingModel,
            modelLibraryProvider: (any CrossTargetModelLibraryDataProviding)? = nil,
            chatModel: SparkChatModel? = nil,
            appLock: AppLockModel = AppLockModel(),
            notificationModel: SparkNotificationModel = SparkNotificationModel(),
            spotlightModel: SparkSpotlightModel = SparkSpotlightModel()
        ) {
            let provider =
                modelLibraryProvider
                ?? SignedCrossTargetModelLibraryProvider(library: onboarding.library)
            self.appLock = appLock
            _discovery = State(initialValue: discovery)
            _onboarding = State(initialValue: onboarding)
            _modelLibrary = State(
                initialValue: CrossTargetModelLibraryModel(provider: provider)
            )
            _fleet = State(initialValue: FleetModel(library: onboarding.library))
            _workloads = State(
                initialValue: WorkloadComparisonModel(
                    snapshot: WorkloadLibraryAdapter.snapshot(
                        from: onboarding.library,
                        at: Date()
                    )
                )
            )
            _chat = State(
                initialValue: chatModel.map { SparkChatWorkspace(initialModel: $0) }
                    ?? SparkChatWorkspace.shared(library: onboarding.library)
            )
            _developerTools = State(
                initialValue: SparkDeveloperToolsModel(
                    targetProvider: LocalSparkChatTargetProvider(library: onboarding.library),
                    launcher: MacSparkDeveloperToolLauncher()
                )
            )
            _notifications = State(initialValue: notificationModel)
            _spotlight = State(initialValue: spotlightModel)
            _externalClusters = State(
                initialValue: ExternalClusterPreviewModel(
                    targets: ExternalClusterTargetList.pairedStandaloneTargets(
                        in: onboarding.library
                    ),
                    library: onboarding.library
                )
            )
            _buildProjects = State(initialValue: BuildProjectModel(library: onboarding.library))
            _buildWorker = State(
                initialValue: BuildWorkerSettingsModel(library: onboarding.library)
            )
            _projects = State(
                initialValue: ProjectsModel(
                    provider: SignedProjectDataProvider(library: onboarding.library)
                )
            )
        }

        public var body: some View {
            NavigationSplitView {
                List(
                    MacSidebarItem.allCases.filter {
                        engineeringMode || ($0 != .projects && $0 != .launch)
                    },
                    selection: $selection
                ) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
                .navigationTitle("SparkPilot")
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            } detail: {
                NavigationStack(path: $detailPath) {
                    detail
                }
                // Present host-key confirmation in this window unless the active Add Spark sheet owns the prompt.
                .hostKeyConfirmationPrompt()
            }
            .frame(minWidth: 760, minHeight: 520)
            .sheet(isPresented: $showingAddSpark) {
                RetailOnboardingRootView(model: onboarding)
                    .frame(minWidth: 720, minHeight: 560)
            }
            .sheet(isPresented: $showingNearby) {
                MacSparkHomeView(discovery: discovery) { discovered in
                    showingNearby = false
                    startOnboarding(for: discovered)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { onboarding.isBatchInvitingDevice },
                    set: { if !$0 { onboarding.cancelBatchInvitation() } }
                )
            ) {
                NavigationStack {
                    BatchInviteDeviceView(
                        model: onboarding,
                        onDone: onboarding.cancelBatchInvitation
                    )
                }
                .frame(minWidth: 620, minHeight: 700)
            }
            .onChange(of: onboarding.dashboardModel != nil) { _, hasDashboard in
                // A completed setup opens the card; return to the library UI.
                if hasDashboard {
                    showingAddSpark = false
                    selection = .home
                }
            }
            .onChange(of: addSparkIsActive) { _, isActive in
                // Dismiss the sheet when back navigation exits its flow.
                if !isActive { showingAddSpark = false }
            }
            .sparkWidgets(library: onboarding.library, appLock: appLock)
            .modifier(
                SparkNavigationRequestObserver(openTarget: { openWidgetTarget($0) })
            )
            .receivesSparkChatShares(library: onboarding.library, appLock: appLock)
            .onChange(of: onboarding.library.entries) { _, _ in
                refreshWorkloads()
                chat.refreshTargets()
                developerTools.refresh()
                refreshExternalClusterTargets()
                buildProjects.refreshTargets()
                buildWorker.refreshTargets()
                Task { await notifications.observe(onboarding.library.entries) }
                Task { await refreshSpotlight() }
                Task { await projects.load() }
            }
            .onChange(of: modelLibrary.snapshot) { _, _ in
                Task { await refreshSpotlight() }
            }
            .onChange(of: selection) { previous, section in
                if MacRootPresentationPlan.shouldResetDetailPath(from: previous, to: section) {
                    detailPath = NavigationPath()
                }
                guard section == .activity else { return }
                Task { await refreshOperationalSurfaces() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshAfterActivation() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sparkModelReadyChatRequested)) {
                notification in
                guard let target = notification.object as? SparkChatTarget,
                    onboarding.library.entry(id: target.id) != nil
                else { return }
                guard chat.openReadyTarget(target) else { return }
                selection = .chats
            }
            .onReceive(NotificationCenter.default.publisher(for: .sparkNotificationOpened)) {
                notification in
                guard let destination = notification.object as? SparkNotificationDestination else {
                    return
                }
                openNotification(destination)
            }
            .onChange(of: appLock.isLocked) { _, locked in
                if locked, let route = notificationApproval {
                    pendingNotification = .projectChange(
                        targetID: route.targetID,
                        projectID: route.projectID,
                        changeID: route.changeID
                    )
                    notificationApproval = nil
                } else if !locked, let pending = pendingNotification {
                    pendingNotification = nil
                    openNotification(pending)
                }
            }
            .sheet(item: $notificationApproval) { route in
                NavigationStack {
                    ProjectChangeNotificationReviewView(
                        model: projects,
                        targetID: route.targetID,
                        projectID: route.projectID,
                        changeID: route.changeID
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { notificationApproval = nil }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sparkManagedServiceObservation)) {
                event in
                guard let observation = event.object as? SparkManagedServiceObservation else {
                    return
                }
                Task { await notifications.observeManagedService(observation) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sparkAgentApprovalObservation)) {
                event in
                guard let observation = event.object as? SparkAgentApprovalObservation else {
                    return
                }
                Task { await notifications.observeAgentApprovals(observation) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sparkInferenceObservation)) {
                notification in
                guard
                    let observation = notification.object
                        as? SparkInferenceNotificationObservation
                else { return }
                Task { await notifications.observeInference(observation) }
            }
            .task {
                await externalClusters.reconcilePendingAuthorization()
                await notifications.prepare()
                await spotlight.prepare()
                await refreshAfterActivation()
                await notifications.observe(onboarding.library.entries)
                await refreshSpotlight()
                await buildWorker.resumeIfEnabled()
            }
        }

        private func openWidgetTarget(_ targetID: String) {
            if targetID == "all" {
                onboarding.closeDashboard()
            } else if onboarding.library.entry(id: targetID) != nil {
                _ = onboarding.openLibraryEntry(targetID)
            }
            selection = .home
            detailPath = NavigationPath()
        }

        private func refreshWorkloads() {
            workloads.replaceSnapshot(
                WorkloadLibraryAdapter.snapshot(from: onboarding.library, at: Date())
            )
        }

        private func refreshExternalClusterTargets() {
            externalClusters.replaceTargets(
                ExternalClusterTargetList.pairedStandaloneTargets(in: onboarding.library)
            )
        }

        private func refreshOperationalSurfaces() async {
            await OperationalSurfaceRefresh.run(
                modelLibrary: modelLibrary,
                library: onboarding.library,
                workloads: workloads
            )
        }

        private func refreshAfterActivation() async {
            await onboarding.refreshSavedSparks()
            await refreshOperationalSurfaces()
            await notifications.observe(onboarding.library.entries)
        }

        private func refreshSpotlight() async {
            await spotlight.observe(
                entries: onboarding.library.entries,
                modelSnapshot: modelLibrary.snapshot
            )
        }

        private func openNotification(_ destination: SparkNotificationDestination) {
            guard !appLock.isLocked else {
                pendingNotification = destination
                return
            }
            switch destination {
            case .service(let targetID, let serviceID):
                guard onboarding.library.entry(id: targetID) != nil else { return }
                selection = .home
                Task {
                    await onboarding.openLibraryEntry(targetID)?.value
                    guard onboarding.dashboardModel?.targetID == targetID else { return }
                    onboarding.dashboardModel?.requestServiceManagement(serviceID: serviceID)
                }
            case .projectChange(let targetID, let projectID, let changeID):
                guard onboarding.library.entry(id: targetID) != nil else { return }
                notificationApproval = SparkAgentApprovalRoute(
                    targetID: targetID,
                    projectID: projectID,
                    changeID: changeID
                )

            case .activity:
                selection = .activity
            case .operation(let targetID, let operationID):
                guard onboarding.library.entry(id: targetID) != nil,
                    let route = SparkNotificationOperationRoute(
                        targetID: targetID,
                        operationID: operationID
                    )
                else { return }
                notificationOperation = route
                selection = .activity
            case .home(let targetID):
                _ = onboarding.openLibraryEntry(targetID)
                selection = .home
            }
        }

        /// Whether anything in the Add Spark sheet still has somewhere to go.
        private var addSparkIsActive: Bool {
            onboarding.isChoosingSpark || onboarding.isAddingSpark
                || onboarding.pairingDeviceTarget != nil || onboarding.isBatchPairingDevice
                || onboarding.dashboardModel != nil
        }

        private var batchInvitationAction: (() -> Void)? {
            guard onboarding.canInviteDeviceToSeveralSparks else { return nil }
            return { onboarding.beginInvitingDeviceToSeveralSparks() }
        }

        @ViewBuilder
        private var detail: some View {
            switch selection ?? .home {
            case .home:
                if MacRootPresentationPlan.homeDestination(
                    hasDashboard: onboarding.dashboardModel != nil
                ) == .dashboard,
                    let dashboard = onboarding.dashboardModel
                {
                    SparkDashboardView(
                        model: dashboard,
                        providerCredentialModel: onboarding.providerCredentialModel,
                        deviceManagementModel: onboarding.deviceManagementModel,
                        powerControlModel: onboarding.powerControlModel,
                        identitySettingsModel: onboarding.identitySettingsModel,
                        networkStatusModel: onboarding.networkStatusModel,
                        settingsModel: onboarding.settingsModel,
                        remoteAccessModel: onboarding.remoteAccessModel,
                        library: onboarding.library
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Your Sparks") {
                                onboarding.closeDashboard()
                            }
                        }
                        if onboarding.canInviteDevice {
                            ToolbarItem {
                                Button(action: onboarding.beginInvitingDevice) {
                                    Label("Add a Device", systemImage: "person.badge.plus")
                                }
                            }
                        }
                    }
                    .sheet(
                        isPresented: Binding(
                            get: { onboarding.invitation != nil },
                            set: { if !$0 { onboarding.cancelInvitingDevice() } }
                        )
                    ) {
                        if let invitation = onboarding.invitation {
                            NavigationStack {
                                InviteDeviceView(
                                    model: invitation,
                                    onDone: onboarding.cancelInvitingDevice
                                )
                            }
                            .frame(minWidth: 520, minHeight: 620)
                        }
                    }
                } else {
                    // Use the local-library Fleet as the Mac home surface.
                    FleetView(
                        model: fleet,
                        onAddSpark: startAddSpark,
                        onOpen: { entryID in _ = onboarding.openLibraryEntry(entryID) },
                        onRemove: { entryID in onboarding.removeLibraryEntry(entryID) },
                        onCheckAgain: { entryID in
                            await onboarding.updateFromProbe(entryID: entryID)
                            await refreshOperationalSurfaces()
                        },
                        onRetryStorage: onboarding.retryLibraryStorage,
                        onAddDeviceToSeveralSparks: batchInvitationAction
                    )
                    .toolbar {
                        ToolbarItem {
                            Button {
                                showingNearby = true
                                discovery.stop()
                                discovery.start()
                            } label: {
                                Label(
                                    "Find Nearby",
                                    systemImage: "antenna.radiowaves.left.and.right"
                                )
                            }
                        }
                    }
                }
            case .chats:
                SparkChatView(workspace: chat, onAddSpark: startAddSpark)
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        await chat.runTargetRefreshes()
                    }
            case .launch:
                if engineeringMode {
                    SparkDeveloperToolsView(model: developerTools)
                } else {
                    SparkEngineeringModeRequiredView()
                }
            case .models:
                CrossTargetModelLibraryView(
                    model: modelLibrary,
                    onOpenTarget: { targetID in
                        _ = onboarding.openLibraryEntry(targetID)
                        selection = .home
                    },
                    onManageModel: { targetID, modelID, action in
                        selection = .home
                        Task {
                            await onboarding.prepareModelManagement(
                                entryID: targetID,
                                modelID: modelID,
                                action: action
                            )
                        }
                    },
                    clusterLaunchAvailable: { targetID in
                        guard
                            case .cluster(let clusterID) = SparkTargetIdentity(
                                rawValue: targetID
                            )
                        else { return false }
                        return externalClusters.launchModels.contains {
                            $0.clusterID == clusterID.rawValue && $0.availability == .available
                        }
                    },
                    onStartClusterModel: { targetID, modelID, profileID in
                        Task {
                            await externalClusters.startVerifiedModel(
                                clusterTargetID: targetID,
                                recipeID: modelID,
                                profileID: profileID
                            )
                        }
                    },
                    refreshClusterLaunches: {
                        await externalClusters.refreshLaunchMonitoring()
                    }
                )
            case .projects:
                if engineeringMode {
                    SparkDevelopmentView(library: onboarding.library)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                NavigationLink("Project Tools") {
                                    if engineeringMode {
                                        ProjectsWorkspaceView(
                                            projects: projects,
                                            builds: buildProjects
                                        )
                                    } else {
                                        SparkEngineeringModeRequiredView()
                                    }
                                }
                            }
                        }
                } else {
                    SparkEngineeringModeRequiredView()
                }
            case .clusters:
                ExternalClusterPreviewView(model: externalClusters)
            case .activity:
                if let notificationOperation {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Selected operation").font(.headline)
                            Spacer()
                            Button("Open Spark") {
                                Task {
                                    await openNotificationOperation(notificationOperation)
                                }
                            }
                            Button("Show all") { self.notificationOperation = nil }
                        }
                        .padding()
                        ActivityListView(
                            operations: AppleNavigationPlan.activityCards(
                                for: onboarding.library.entries,
                                selected: notificationOperation
                            )
                        )
                    }
                } else {
                    CrossTargetWorkloadsView(model: workloads)
                }
            case .settings:
                MacAppSettingsView(
                    onboarding: onboarding,
                    appLock: appLock,
                    buildWorker: buildWorker,
                    notifications: notifications,
                    spotlight: spotlight,
                    chat: chat.selected.model,
                    onOpenSpark: { id in
                        _ = onboarding.openLibraryEntry(id)
                        selection = .home
                    }
                )
            }
        }

        private func openNotificationOperation(
            _ route: SparkNotificationOperationRoute
        ) async {
            notificationOperation = nil
            selection = .home
            guard let task = onboarding.openLibraryEntry(route.targetID) else { return }
            await task.value
            onboarding.dashboardModel?.requestOperationFocus(route.operationID)
        }

        /// Opens the Add Spark choice so Mac users can select a supported setup path.
        private func startAddSpark() {
            AppleShellActions.beginAddingSpark(with: onboarding)
            showingAddSpark = true
        }

        /// Routes known discovery hosts through authenticated saved-card opening and unknown hosts through prefilled pairing.
        private func startOnboarding(for discovered: DiscoveredSpark) {
            let probe = onboarding.handleDiscovered(discovered)
            // Present setup only for unknown targets; an identity-blocked saved card must not open a second add flow.
            if onboarding.shouldPresentDiscoveryAddSheet(probe: probe) {
                showingAddSpark = true
            }
        }

        static func describe(_ error: NodeTrustError, name: String) -> String {
            switch error {
            case .ambiguousDiscoveryHint:
                return
                    String(localized: .duplicateShortIdentifier(name))
            default:
                return String(localized: .couldNotBeOpened(name))
            }
        }
    }

#endif

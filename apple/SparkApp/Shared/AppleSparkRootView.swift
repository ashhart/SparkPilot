import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkProjects
import SwiftUI

#if os(iOS)
    import UIKit

    /// Provides a six-section iPad workspace and compact four-tab iPhone shell.
    @MainActor
    public struct AppleSparkRootView: View {
        @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        private let model: RetailOnboardingModel
        private let deviceClass: AppleDeviceClass
        private let appLock: AppLockModel
        @State private var splitSelection: AppleNavigationSection? = .home
        @State private var tabSelection: AppleNavigationSection = .home
        @State private var morePath: [AppleNavigationSection] = []
        @State private var modelLibrary: CrossTargetModelLibraryModel
        @State private var fleet: FleetModel
        @State private var workloads: WorkloadComparisonModel
        @State private var chat: SparkChatWorkspace
        @State private var sharedChat: SparkSharedChatReceptionModel
        @State private var executionPolicy = SparkExecutionPolicyModel()
        @State private var notifications: SparkNotificationModel
        @State private var notificationOperation: SparkNotificationOperationRoute?
        @State private var notificationApproval: SparkAgentApprovalRoute?
        @State private var pendingNotification: SparkNotificationDestination?
        @State private var spotlight: SparkSpotlightModel
        @State private var externalClusters: ExternalClusterPreviewModel
        @State private var buildProjects: BuildProjectModel
        @State private var projects: ProjectsModel

        public init(
            model: RetailOnboardingModel,
            deviceClass: AppleDeviceClass? = nil,
            modelLibraryProvider: (any CrossTargetModelLibraryDataProviding)? = nil,
            chatModel: SparkChatModel? = nil,
            appLock: AppLockModel = AppLockModel(),
            notificationModel: SparkNotificationModel = SparkNotificationModel(),
            spotlightModel: SparkSpotlightModel = SparkSpotlightModel()
        ) {
            self.model = model
            self.appLock = appLock
            self.deviceClass =
                deviceClass
                ?? (UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone)
            let provider =
                modelLibraryProvider
                ?? SignedCrossTargetModelLibraryProvider(library: model.library)
            _modelLibrary = State(
                initialValue: CrossTargetModelLibraryModel(provider: provider)
            )
            _fleet = State(initialValue: FleetModel(library: model.library))
            _workloads = State(
                initialValue: WorkloadComparisonModel(
                    snapshot: WorkloadLibraryAdapter.snapshot(
                        from: model.library,
                        at: Date()
                    )
                )
            )
            _chat = State(
                initialValue: chatModel.map { SparkChatWorkspace(initialModel: $0) }
                    ?? SparkChatWorkspace.shared(library: model.library)
            )
            _sharedChat = State(
                initialValue: SparkSharedChatReceptionModel(
                    library: model.library,
                    appLock: appLock
                )
            )
            _notifications = State(initialValue: notificationModel)
            _notificationOperation = State(initialValue: nil)
            _spotlight = State(initialValue: spotlightModel)
            _externalClusters = State(
                initialValue: ExternalClusterPreviewModel(
                    targets: ExternalClusterTargetList.pairedStandaloneTargets(
                        in: model.library
                    ),
                    library: model.library
                )
            )
            _buildProjects = State(initialValue: BuildProjectModel(library: model.library))
            _projects = State(
                initialValue: ProjectsModel(
                    provider: SignedProjectDataProvider(library: model.library)
                )
            )
        }

        public var body: some View {
            navigationContent
                .sparkWidgets(library: model.library, appLock: appLock)
                .modifier(
                    SparkNavigationRequestObserver(
                        openTarget: { targetID in
                            if targetID == "all" {
                                model.closeDashboard()
                            } else if model.library.entry(id: targetID) != nil {
                                _ = model.openLibraryEntry(targetID)
                            }
                            splitSelection = .home
                            tabSelection = .home
                        }
                    )
                )
                .observesSparkChatShares(sharedChat)
                .onChange(of: sharedChat.session?.id) { _, id in
                    guard id != nil else { return }
                    splitSelection = .chats
                    tabSelection = .chats
                }
                .onChange(of: model.library.entries) { _, _ in
                    refreshWorkloads()
                    chat.refreshTargets()
                    refreshExternalClusterTargets()
                    Task { await notifications.observe(model.library.entries) }
                    Task { await refreshSpotlight() }
                    Task { await projects.load() }
                }
                .onChange(of: modelLibrary.snapshot) { _, _ in
                    Task { await refreshSpotlight() }
                }
                .onChange(of: splitSelection) { _, section in
                    guard section == .activity else { return }
                    Task { await refreshOperationalSurfaces() }
                }
                .onChange(of: tabSelection) { _, section in
                    guard section == .activity else { return }
                    Task { await refreshOperationalSurfaces() }
                }
                .onChange(of: engineeringMode) { _, enabled in
                    tabSelection = AppleNavigationPlan.phoneSelection(
                        tabSelection,
                        engineeringMode: enabled
                    )
                    if !enabled, splitSelection == .projects { splitSelection = .home }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await refreshAfterActivation() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .sparkModelReadyChatRequested))
            {
                notification in
                guard let target = notification.object as? SparkChatTarget,
                    model.library.entry(id: target.id) != nil
                else { return }
                guard chat.openReadyTarget(target) else { return }
                if let session = sharedChat.session { sharedChat.keepForLater(session) }
                splitSelection = .chats
                tabSelection = .chats
            }
                .onReceive(NotificationCenter.default.publisher(for: .sparkNotificationOpened)) {
                    notification in
                    guard let destination = notification.object as? SparkNotificationDestination
                    else {
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
                .onReceive(
                    NotificationCenter.default.publisher(for: .sparkManagedServiceObservation)
                ) {
                    event in
                    guard let observation = event.object as? SparkManagedServiceObservation else {
                        return
                    }
                    Task { await notifications.observeManagedService(observation) }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .sparkAgentApprovalObservation)
                ) {
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
                    await notifications.observe(model.library.entries)
                    await refreshSpotlight()
                }
        }

        private var navigationContent: some View {
            Group {
                switch AppleNavigationPlan.layout(for: deviceClass) {
                case .splitView:
                    NavigationSplitView {
                        List(
                            AppleNavigationPlan.visibleSections(
                                AppleNavigationPlan.sidebarSections,
                                hasSparks: !model.library.entries.isEmpty,
                                engineeringMode: engineeringMode
                            ),
                            selection: $splitSelection
                        ) {
                            item in
                            NavigationLink(value: item) {
                                SparkNavigationLabel(
                                    title: item == .settings && model.library.entries.isEmpty
                                        ? String(localized: "Help and settings")
                                        : item.title(for: .pad),
                                    systemImage: item.symbol(for: .pad)
                                )
                            }
                            .accessibilityIdentifier("spark.sidebar.\(item.id)")
                        }
                        .navigationTitle("SparkPilot")
                        .navigationSplitViewColumnWidth(
                            min: dynamicTypeSize.isAccessibilitySize ? 380 : 250,
                            ideal: dynamicTypeSize.isAccessibilitySize ? 480 : 320,
                            max: dynamicTypeSize.isAccessibilitySize ? 560 : 380
                        )
                    } detail: {
                        NavigationStack {
                            destination(splitSelection ?? .home)
                        }
                    }
                case .tabs:
                    phoneNavigation
                }
            }
        }

        private var phoneNavigation: some View {
            TabView(selection: $tabSelection) {
                ForEach(AppleNavigationPlan.phoneTabs(engineeringMode: engineeringMode)) {
                    item in
                    Group {
                        if item == .more {
                            NavigationStack(path: $morePath) {
                                destination(item)
                                    .navigationDestination(for: AppleNavigationSection.self) {
                                        destination($0)
                                    }
                            }
                        } else {
                            NavigationStack { destination(item) }
                        }
                    }
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
                }
            }
        }

        private func refreshWorkloads() {
            workloads.replaceSnapshot(
                WorkloadLibraryAdapter.snapshot(from: model.library, at: Date())
            )
        }

        private func refreshExternalClusterTargets() {
            externalClusters.replaceTargets(
                ExternalClusterTargetList.pairedStandaloneTargets(in: model.library)
            )
        }

        private func refreshOperationalSurfaces() async {
            await OperationalSurfaceRefresh.run(
                modelLibrary: modelLibrary,
                library: model.library,
                workloads: workloads
            )
        }

        private func refreshAfterActivation() async {
            await model.refreshSavedSparks()
            await refreshOperationalSurfaces()
            await notifications.observe(model.library.entries)
            notifications.scheduleNextBackgroundRefresh()
            await notifications.refreshHarnessUpdates(
                provider: SignedProjectDataProvider(library: model.library)
            )
        }

        private func refreshSpotlight() async {
            await spotlight.observe(
                entries: model.library.entries,
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
                guard model.library.entry(id: targetID) != nil else { return }
                splitSelection = .home
                tabSelection = .home
                Task {
                    await model.openLibraryEntry(targetID)?.value
                    guard model.dashboardModel?.targetID == targetID else { return }
                    model.dashboardModel?.requestServiceManagement(serviceID: serviceID)
                }
            case .projectChange(let targetID, let projectID, let changeID):
                guard model.library.entry(id: targetID) != nil else { return }
                notificationApproval = SparkAgentApprovalRoute(
                    targetID: targetID,
                    projectID: projectID,
                    changeID: changeID
                )

            case .activity:
                splitSelection = .activity
                showPhoneActivity()
            case .operation(let targetID, let operationID):
                guard model.library.entry(id: targetID) != nil,
                    let route = SparkNotificationOperationRoute(
                        targetID: targetID,
                        operationID: operationID
                    )
                else { return }
                notificationOperation = route
                splitSelection = .activity
                showPhoneActivity()
            case .home(let targetID):
                _ = model.openLibraryEntry(targetID)
                splitSelection = .home
                tabSelection = .home
            }
        }

        private func showPhoneActivity() {
            guard deviceClass == .phone else { return }
            if engineeringMode {
                tabSelection = .more
                morePath = [.activity]
            } else {
                tabSelection = .activity
            }
        }

        @ViewBuilder
        private var activityDestination: some View {
            if let notificationOperation {
                VStack(spacing: 0) {
                    HStack {
                        Text("Selected operation").font(.headline)
                        Spacer()
                        Button("Open Spark") {
                            Task { await openNotificationOperation(notificationOperation) }
                        }
                        Button("Show all") { self.notificationOperation = nil }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    ActivityListView(
                        operations: AppleNavigationPlan.activityCards(
                            for: model.library.entries,
                            selected: notificationOperation
                        )
                    )
                }
            } else {
                ActivityListView(
                    operations: AppleNavigationPlan.activityTimeline(for: model.library.entries)
                )
                .refreshable { await refreshOperationalSurfaces() }
                .toolbar {
                    if deviceClass == .pad, !model.library.entries.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            NavigationLink("Compare workloads") {
                                CrossTargetWorkloadsView(model: workloads)
                            }
                        }
                    }
                }
            }
        }

        private func openNotificationOperation(
            _ route: SparkNotificationOperationRoute
        ) async {
            notificationOperation = nil
            splitSelection = .home
            tabSelection = .home
            guard let task = model.openLibraryEntry(route.targetID) else { return }
            await task.value
            model.dashboardModel?.requestOperationFocus(route.operationID)
        }

        @ViewBuilder
        private func destination(_ section: AppleNavigationSection) -> some View {
            switch section {
            case .home:
                // Use Fleet on iPad and the compact Your Sparks list on iPhone.
                RetailOnboardingRootView(
                    model: model,
                    fleet: AppleNavigationPlan.usesFleetHome(on: deviceClass) ? fleet : nil,
                    checkAgain: { entryID in
                        await model.updateFromProbe(entryID: entryID)
                        if deviceClass == .pad {
                            await refreshOperationalSurfaces()
                        }
                    }
                )
            case .more:
                SparkMoreView(hasSparks: !model.library.entries.isEmpty)
                    .navigationTitle("More")
            case .models:
                if AppleNavigationPlan.showsModelLibrary(in: section, on: deviceClass) {
                    CrossTargetModelLibraryView(
                        model: modelLibrary,
                        onOpenTarget: { targetID in
                            _ = model.openLibraryEntry(targetID)
                            splitSelection = .home
                            tabSelection = .home
                        },
                        onManageModel: { targetID, modelID, action in
                            splitSelection = .home
                            tabSelection = .home
                            Task {
                                await model.prepareModelManagement(
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
                } else {
                    placeholder(section)
                }
            case .clusters:
                ExternalClusterPreviewView(model: externalClusters)
            case .automations:
                SparkAutomationsLibraryView(onboarding: model) {
                    AppleShellActions.beginAddingSpark(with: model)
                    splitSelection = .home
                    tabSelection = .home
                }
            case .activity:
                activityDestination
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        await OperationalSurfaceRefresh.runUntilCancelled(
                            modelLibrary: modelLibrary,
                            library: model.library,
                            workloads: workloads
                        )
                    }
            case .chats:
                if let item = sharedChat.session {
                    SparkSharedChatView(reception: sharedChat, item: item)
                        .id(item.id)
                } else {
                    SparkChatView(workspace: chat) {
                        AppleShellActions.beginAddingSpark(with: model)
                        splitSelection = .home
                        tabSelection = .home
                    }
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        await chat.runTargetRefreshes()
                    }
                }
            case .projects:
                if engineeringMode {
                    SparkDevelopmentView(library: model.library)
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
            case .settings:
                AppleSparkSettingsView(
                    model: model,
                    chat: chat.selected.model,
                    appLock: appLock,
                    executionPolicy: executionPolicy,
                    notifications: notifications,
                    spotlight: spotlight
                ) { entryID in
                    _ = model.openLibraryEntry(entryID)
                    splitSelection = .home
                    tabSelection = .home
                }
            }
        }

        private func placeholder(_ section: AppleNavigationSection) -> some View {
            ContentUnavailableView(
                section.title,
                systemImage: section.symbol,
                description: Text(description(for: section))
            )
            .navigationTitle(section.title)
        }

        private func description(for section: AppleNavigationSection) -> String {
            switch section {
            case .chats: String(localized: "Open a paired Spark to start a private conversation.")
            case .projects:
                String(localized: "Spark-backed projects and agent workspaces appear here.")
            case .models: String(localized: "Open a paired Spark from Home to manage its models.")
            case .clusters:
                String(localized: "Review paired Sparks that were clustered outside SparkPilot.")
            case .automations:
                String(
                    localized:
                        "Open a paired Spark from Home to set up work it runs on its own."
                )
            case .activity:
                String(localized: "Downloads, installs, and inference jobs appear here.")
            case .settings:
                String(localized: "Manage paired devices, security, and networking here.")
            case .home, .more: ""
            }
        }
    }
#endif

import Observation
import SparkDesignSystem
import SwiftUI

@MainActor
/// Public so the app entry points can route a spark:// invitation into pairing.
public enum AppleShellActions {
    public static func beginAddingSpark(with model: RetailOnboardingModel) {
        model.chooseSparkToAdd()
    }
}

public struct RetailOnboardingRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable private var model: RetailOnboardingModel
    @StateObject private var preparation = RetailOnboardingPreparationModel()
    /// Allow the iPad shell to supply Fleet while iPhone retains its compact library list.
    private let fleet: FleetModel?
    @State private var phoneFleet: FleetModel?
    @State private var showsVoiceSetup = false
    @State private var installVoiceOnOpen = false
    @State private var webSetupTarget: SparkVoiceTarget?
    /// QA-01: the scanner sheet's way out opens the manual Wi-Fi fields on the screen behind it.
    @State private var showsManualSetupDetails = false
    private let checkAgain: (@MainActor (String) async -> Void)?

    public init(
        model: RetailOnboardingModel,
        fleet: FleetModel? = nil,
        checkAgain: (@MainActor (String) async -> Void)? = nil
    ) {
        self.model = model
        self.fleet = fleet
        self.checkAgain = checkAgain
    }

    public var body: some View {
        Group {
            if let dashboardModel = model.dashboardModel {
                SparkDashboardView(
                    model: dashboardModel,
                    providerCredentialModel: model.providerCredentialModel,
                    deviceManagementModel: model.deviceManagementModel,
                    powerControlModel: model.powerControlModel,
                    identitySettingsModel: model.identitySettingsModel,
                    networkStatusModel: model.networkStatusModel,
                    settingsModel: model.settingsModel,
                    remoteAccessModel: model.remoteAccessModel,
                    library: model.library
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Your Sparks") {
                            model.closeDashboard()
                        }
                    }
                    if model.canInviteDevice {
                        ToolbarItem {
                            Button(action: model.beginInvitingDevice) {
                                Label("Add a Device", systemImage: "person.badge.plus")
                            }
                        }
                    }
                }
            } else if model.isBatchPairingDevice {
                BatchPairThisDeviceView(model: model)
            } else if model.pairingDeviceTarget != nil {
                PairThisDeviceView(model: model)
            } else if model.isChoosingSpark {
                AddSparkChoiceView(model: model)
            } else if !model.isAddingSpark {
                if let fleet {
                    FleetView(
                        model: fleet,
                        onAddSpark: { AppleShellActions.beginAddingSpark(with: model) },
                        onOpen: { entryID in _ = model.openLibraryEntry(entryID) },
                        onRemove: { entryID in model.removeLibraryEntry(entryID) },
                        onCheckAgain: { entryID in
                            if let checkAgain {
                                await checkAgain(entryID)
                            } else {
                                await model.updateFromProbe(entryID: entryID)
                            }
                        },
                        onRetryStorage: model.retryLibraryStorage,
                        onAddDeviceToSeveralSparks: batchInvitationAction
                    )
                } else {
                    phoneLibrary
                }
            } else if model.state.phase == .nvidiaSetup,
                model.state.issue == nil,
                let nativeSetupModel = model.nativeSetupModel
            {
                NativeSparkSetupView(model: nativeSetupModel, onExit: model.goBack)
            } else {
                RetailOnboardingView(
                    state: model.state,
                    detail: model.failureDetail,
                    retryActionTitle: model.retryActionTitle,
                    canJoinSetupNetwork: model.canJoinSetupNetwork,
                    canScanQuickStartCode: model.canScanQuickStartCode,
                    manualSetupDetailsRequested: showsManualSetupDetails,
                    detectedSetupSSID: model.detectedSetupSSID,
                    setupSSID: $model.setupSSID,
                    setupPassphrase: $model.setupPassphrase,
                    administratorUsername: Binding(
                        get: { model.administratorUsername ?? "" },
                        set: { model.administratorUsername = $0 }
                    ),
                    administratorPassword: $model.administratorPassword,
                    machineName: $model.machineName,
                    customLabel: $model.setupCustomLabel,
                    runtimePreparation: preparation.runtime,
                    aiPreparation: preparation.ai,
                    isRuntimeInstalling: preparation.isInstallingRuntime,
                    isCheckingAIServices: preparation.isCheckingAIServices,
                    sparkSetupNetworkStillActive: model.sparkSetupNetworkStillActive,
                    onPrimary: {
                        Task {
                            // Existing-Spark credentials authorise preflight inspection here; installation requires the subsequent owner approval.
                            if model.needsExistingSparkReview {
                                await model.checkExistingSpark()
                            } else {
                                await model.performPrimaryAction(preparation: preparation)
                            }
                        }
                    },
                    onSecondary: {
                        model.performSecondaryAction(preparation: preparation)
                    },
                    onRetry: recoverFromIssue,
                    onBack: model.goBack,
                    onUseDetectedNetwork: model.useDetectedSetupNetwork,
                    onRetrySparkWiFi: model.retrySparkWiFi,
                    onVoiceSetup: {
                        installVoiceOnOpen = false
                        showsVoiceSetup = true
                    },
                    onWebSetup: {
                        webSetupTarget = model.setupVoiceTarget
                    },
                    rediscovery: model.rediscoveryStartedAt.map {
                        RetailRediscoveryProgress(startedAt: $0, limit: model.rediscoveryLimit)
                    },
                    onLookAgain: model.lookAgainForSpark,
                    restart: model.restartStartedAt.map {
                        RetailRestartProgress(
                            startedAt: $0,
                            hold: model.restartHold,
                            limit: model.restartLimit,
                            stage: model.restartStage
                        )
                    },
                    isCheckingRestart: model.isCheckingRestart,
                    restartCheckDetail: model.restartCheckDetail,
                    onSparkIsBack: { Task { await model.checkSparkIsBack() } },
                    changedHostKeyHost: model.changedHostKeyHost,
                    onTrustNewHostKey: {
                        Task { await model.trustNewHostKey(preparation: preparation) }
                    },
                    // 10.1 failure 2: an address the owner types reaches the Spark directly.
                    onConnectByAddress: { _ = model.chooseExistingSpark(host: $0) }
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            savedSparkOpenFeedback
        }
        .alert("Name could not be saved", isPresented: $model.setupLabelSaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Spark setup can continue. Try saving the name again from this Spark's settings.")
        }
        .sheet(isPresented: $showsVoiceSetup) {
            SparkVoiceChatView(
                model: SparkChatModel(library: model.library),
                mode: .setup,
                initialTarget: model.setupVoiceTarget,
                installOnOpen: installVoiceOnOpen
            )
        }
        .sheet(item: $webSetupTarget) { target in
            SparkWebAccessSetupView(target: target) {
                webSetupTarget = nil
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.existingSparkReport != nil },
                set: { if !$0 { model.clearExistingSparkCheck() } }
            )
        ) {
            if let report = model.existingSparkReport {
                NavigationStack {
                    ExistingSparkPreflightView(
                        report: report,
                        sparkName: model.machineName.isEmpty
                            ? String(localized: "this Spark") : model.machineName,
                        isChecking: model.isCheckingSpark,
                        onContinue: {
                            // Require owner acceptance and a fresh installer preflight before mutation.
                            model.clearExistingSparkCheck()
                            Task { await model.performPrimaryAction(preparation: preparation) }
                        },
                        onCheckAgain: { Task { await model.checkExistingSpark() } },
                        onCancel: model.clearExistingSparkCheck
                    )
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.isBatchInvitingDevice },
                set: { if !$0 { model.cancelBatchInvitation() } }
            )
        ) {
            NavigationStack {
                BatchInviteDeviceView(model: model, onDone: model.cancelBatchInvitation)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.invitation != nil },
                set: { if !$0 { model.cancelInvitingDevice() } }
            )
        ) {
            if let invitation = model.invitation {
                NavigationStack {
                    InviteDeviceView(model: invitation, onDone: model.cancelInvitingDevice)
                }
            }
        }
        .onChange(of: model.handoffMonitor.state) { _, state in
            Task { await model.networkHandoffChanged(state) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, model.state.issue == .localNetworkDenied else { return }
            model.retry(preparation: preparation)
        }
        .onChange(of: model.bootstrapDiscovery.candidates) { _, candidates in
            Task { await model.bootstrapCandidatesChanged(candidates) }
        }
        .task(id: model.state.phase) {
            switch model.state.phase {
            case .connectToSpark:
                if model.isAddingSpark {
                    preparation.reset()
                    await model.detectExistingSparkConnection()
                }
            case .sparkConnected:
                do {
                    try await Task.sleep(for: .seconds(1.6))
                } catch {
                    return
                }
                model.connectionCelebrationFinished()
            case .sparkRestarting:
                // Nothing is attempted over SSH until the Spark answers again after its first-boot restart.
                await model.awaitSparkRestart()
            case .securing:
                // Proceed with the already produced invitation and surface any pairing failure without a redundant continue step.
                await model.pairFirstOwner()
            case .runtimeInstall:
                // Reuse the native setup session credential when present; interrupted setup waits for a new password.
                if !model.administratorPassword.isEmpty {
                    await model.performPrimaryAction(preparation: preparation)
                }
            case .starterModel:
                await model.checkAIServices(preparation: preparation)
            default:
                break
            }
        }
        .hostKeyConfirmationPrompt()
        .task(id: model.isAddingSpark) {
            guard model.isAddingSpark, model.state.phase == .connectToSpark else { return }
            await model.detectExistingSparkConnection()
        }
        #if os(iOS)
            .sheet(isPresented: $model.isShowingQuickStartScanner) { quickStartSheet }
            .alert(
                String(localized: "Code not recognised"),
                isPresented: Binding(
                    get: { model.scanErrorMessage != nil },
                    set: { if !$0 { model.scanErrorMessage = nil } }
                )
            ) {
                Button("Enter Details") {
                    model.scanErrorMessage = nil
                    model.isShowingQuickStartScanner = false
                }
                Button("Scan Again", role: .cancel) {
                    model.scanErrorMessage = nil
                }
            } message: {
                Text(model.scanErrorMessage ?? "")
            }
        #endif
    }

    @ViewBuilder
    private var savedSparkOpenFeedback: some View {
        if let entryID = model.openingLibraryEntryID {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting to Spark").font(.headline)
                    if let entry = model.library.entry(id: entryID) {
                        Text(entry.displayName).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Cancel", action: model.cancelOpeningLibraryEntry)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityIdentifier("saved-spark-opening")
        } else if let failure = model.libraryOpenFailure {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn’t Open Spark", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                if let entry = model.library.entry(id: failure.entryID) {
                    Text(entry.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Text(failure.reason.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    if failure.canRetry {
                        Button("Try Again") { _ = model.openLibraryEntry(failure.entryID) }
                            .buttonStyle(.bordered)
                    }
                    Button("Dismiss", action: model.dismissLibraryOpenFailure)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("saved-spark-open-failure")
        }
    }

    /// Home for the phone: the library scroll view with the fleet overview embedded above its cards.
    private var phoneLibrary: some View {
        SparkLibraryView(
            library: model.library,
            onAddSpark: { AppleShellActions.beginAddingSpark(with: model) },
            onOpen: { entryID in _ = model.openLibraryEntry(entryID) },
            onRemove: { entryID in model.removeLibraryEntry(entryID) },
            onRetryStorage: model.retryLibraryStorage,
            home: phoneFleet?.home ?? .empty,
            header: phoneFleet.map { fleet in
                AnyView(
                    FleetDashboardSection(home: fleet.home, dashboard: fleet.dashboard) { entryID in
                        _ = model.openLibraryEntry(entryID)
                    }
                )
            },
            onAddDeviceToSeveralSparks: batchInvitationAction,
            onRefresh: model.refreshSavedSparks
        )
        .task {
            if phoneFleet == nil {
                phoneFleet = FleetModel(library: model.library)
            }
        }
    }

    #if os(iOS)
        /// QA-01: the scanner sheet, with its own way out when no camera can answer.
        private var quickStartSheet: some View {
            QuickStartScannerSheet(
                onPayload: model.quickStartCodeScanned,
                onEnterDetailsManually: {
                    model.isShowingQuickStartScanner = false
                    showsManualSetupDetails = true
                },
                onCancel: { model.isShowingQuickStartScanner = false }
            )
        }
    #endif

    private func recoverFromIssue() {
        #if os(iOS)
            if model.state.issue == .localNetworkDenied,
                let settings = URL(string: UIApplication.openSettingsURLString)
            {
                UIApplication.shared.open(settings)
                return
            }
        #endif
        model.retry(preparation: preparation)
    }

    private var batchInvitationAction: (() -> Void)? {
        guard model.canInviteDeviceToSeveralSparks else { return nil }
        return { model.beginInvitingDeviceToSeveralSparks() }
    }
}

#if os(iOS)
    import UIKit
#endif

import Foundation
import SparkCore
import SwiftUI

/// Renders onboarding with injected system actions so previews and UI tests remain deterministic.
public struct RetailOnboardingView: View {

    public let state: RetailOnboardingState
    /// Provides a specific failure explanation when the model has more detail than the generic issue copy.
    public let detail: String?
    /// Whether this platform can join the Spark's temporary Wi-Fi in-app.
    public let canJoinSetupNetwork: Bool
    public let canScanQuickStartCode: Bool
    /// QA-01: set when the scanner sheet could not scan and the owner chose to type the details instead.
    public let manualSetupDetailsRequested: Bool
    /// Offers the currently joined setup network as an explicit choice so returning to this screen does not advance automatically.
    public let detectedSetupSSID: String?
    @Binding var setupSSID: String
    @Binding var setupPassphrase: String
    @State private var manualSetupDetailsOpened = false
    @State var isSetupPasswordVisible = false
    @Binding var administratorUsername: String
    @Binding var administratorPassword: String
    @State var isAdministratorPasswordVisible = false
    private let retryActionTitle: String?
    public let runtimePreparation: [RetailPreparationItem]
    public let aiPreparation: [RetailPreparationItem]
    public let isRuntimeInstalling: Bool
    public let isCheckingAIServices: Bool
    public let sparkSetupNetworkStillActive: Bool
    /// Lets the owner correct the hostname during discovery recovery without scanning the subnet.
    @Binding private var machineName: String
    @Binding var customLabel: String
    private let onPrimary: () -> Void
    private let onSecondary: () -> Void
    private let onRetry: () -> Void
    private let onBack: () -> Void
    private let onUseDetectedNetwork: () -> Void
    let onRetrySparkWiFi: () -> Void
    let onVoiceSetup: (() -> Void)?
    let onWebSetup: (() -> Void)?
    let rediscovery: RetailRediscoveryProgress?
    let onLookAgain: (() -> Void)?
    /// The restart wait after NVIDIA setup: when it began and when the owner may skip ahead.
    let restart: RetailRestartProgress?
    let isCheckingRestart: Bool
    let restartCheckDetail: String?
    let onSparkIsBack: (() -> Void)?
    /// A Spark whose SSH identity changed; the owner may trust the new one after a factory reset.
    private let changedHostKeyHost: String?
    private let onTrustNewHostKey: (() -> Void)?
    /// 10.1 failure 2: reach the Spark by address when mDNS never arrives.
    private let onConnectByAddress: ((String) -> Void)?

    public init(
        state: RetailOnboardingState,
        detail: String? = nil,
        retryActionTitle: String? = nil,
        canJoinSetupNetwork: Bool = true,
        canScanQuickStartCode: Bool = true,
        manualSetupDetailsRequested: Bool = false,
        detectedSetupSSID: String? = nil,
        setupSSID: Binding<String>,
        setupPassphrase: Binding<String>,
        administratorUsername: Binding<String> = .constant(""),
        administratorPassword: Binding<String> = .constant(""),
        machineName: Binding<String> = .constant(""),
        customLabel: Binding<String> = .constant(""),
        runtimePreparation: [RetailPreparationItem] = [],
        aiPreparation: [RetailPreparationItem] = [],
        isRuntimeInstalling: Bool = false,
        isCheckingAIServices: Bool = false,
        sparkSetupNetworkStillActive: Bool = false,
        onPrimary: @escaping () -> Void,
        onSecondary: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onUseDetectedNetwork: @escaping () -> Void = {},
        onRetrySparkWiFi: @escaping () -> Void = {},
        onVoiceSetup: (() -> Void)? = nil,
        onWebSetup: (() -> Void)? = nil,
        rediscovery: RetailRediscoveryProgress? = nil,
        onLookAgain: (() -> Void)? = nil,
        restart: RetailRestartProgress? = nil,
        isCheckingRestart: Bool = false,
        restartCheckDetail: String? = nil,
        onSparkIsBack: (() -> Void)? = nil,
        changedHostKeyHost: String? = nil,
        onTrustNewHostKey: (() -> Void)? = nil,
        onConnectByAddress: ((String) -> Void)? = nil
    ) {
        self.state = state
        self.detail = detail
        self.retryActionTitle = retryActionTitle
        self.canJoinSetupNetwork = canJoinSetupNetwork
        self.canScanQuickStartCode = canScanQuickStartCode
        self.manualSetupDetailsRequested = manualSetupDetailsRequested
        self.detectedSetupSSID = detectedSetupSSID
        self._setupSSID = setupSSID
        self._setupPassphrase = setupPassphrase
        self._administratorUsername = administratorUsername
        self._administratorPassword = administratorPassword
        self._machineName = machineName
        self._customLabel = customLabel
        self.runtimePreparation = runtimePreparation
        self.aiPreparation = aiPreparation
        self.isRuntimeInstalling = isRuntimeInstalling
        self.isCheckingAIServices = isCheckingAIServices
        self.sparkSetupNetworkStillActive = sparkSetupNetworkStillActive
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onRetry = onRetry
        self.onBack = onBack
        self.onUseDetectedNetwork = onUseDetectedNetwork
        self.onRetrySparkWiFi = onRetrySparkWiFi
        self.onVoiceSetup = onVoiceSetup
        self.onWebSetup = onWebSetup
        self.rediscovery = rediscovery
        self.onLookAgain = onLookAgain
        self.restart = restart
        self.isCheckingRestart = isCheckingRestart
        self.restartCheckDetail = restartCheckDetail
        self.onSparkIsBack = onSparkIsBack
        self.changedHostKeyHost = changedHostKeyHost
        self.onTrustNewHostKey = onTrustNewHostKey
        self.onConnectByAddress = onConnectByAddress
        self._manualSetupDetailsOpened = State(initialValue: !canScanQuickStartCode)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                progress

                if let issue = state.issue {
                    issueContent(issue)
                } else {
                    phaseContent
                }
                if let changedHostKeyHost {
                    changedHostKeyNotice(host: changedHostKeyHost)
                }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .modifier(RetailOnboardingScrollEdge(chrome: chrome))
        .safeAreaInset(edge: .bottom, spacing: 0) { pinnedActions }
        .navigationTitle("")
        .sensoryFeedback(.success, trigger: state.phase) { oldPhase, newPhase in
            RetailOnboardingFeedback.shouldPlaySuccess(from: oldPhase, to: newPhase)
        }
        .toolbar {
            if state.canGoBack {
                ToolbarItem(placement: .navigation) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            } else if state.phase == .connectToSpark
                || (state.phase == .runtimeInstall && state.completedPhases.isEmpty
                    && !isRuntimeInstalling)
            {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onBack)
                }
            }
        }
    }

    private var chrome: RetailOnboardingChrome { .resolve(issue: state.issue) }

    /// A changed SSH key is refused until a person says the Spark was reset; the fingerprint prompt follows.
    private func changedHostKeyNotice(host: String) -> some View {
        VStack(spacing: 12) {
            Label(
                "This Spark's identity has changed",
                systemImage: "exclamationmark.shield.fill"
            )
            .foregroundStyle(.orange)
            Text(.hostKeyChanged(host: host))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let onTrustNewHostKey {
                Button(
                    "Trust its new identity",
                    systemImage: "checkmark.shield",
                    action: onTrustNewHostKey
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("spark.setup.hostkey.trust")
            }
        }
        .frame(maxWidth: 440)
    }

    /// Pin actions above the tab bar; waiting phases omit the bar to avoid an empty grey band.
    private var hasPinnedActions: Bool {
        (state.phase == .connectToSpark && canJoinSetupNetwork)
            || screenForPhase.primaryAction != nil || screenForPhase.secondaryAction != nil
    }

    @ViewBuilder
    private var pinnedActions: some View {
        if chrome.pinsActions, hasPinnedActions {
            VStack(spacing: 0) {
                Divider()
                phaseActions
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var phaseActions: some View {
        if state.phase == .connectToSpark, canJoinSetupNetwork {
            setupConnectionActions
        } else {
            actionButtons(
                primary: screenForPhase.primaryAction,
                secondary: screenForPhase.secondaryAction
            )
        }
    }

    private var screenForPhase: RetailOnboardingScreen {
        RetailOnboardingScreen(
            phase: state.phase,
            canJoinSetupNetwork: canJoinSetupNetwork,
            canScanQuickStartCode: canScanQuickStartCode
        )
    }

    var progress: some View {
        let phases = RetailOnboardingPhase.allCases
        let index = phases.firstIndex(of: state.phase) ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stageTitle)
                Spacer()
                Text(.stepOf(stageNumber, 3))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: Double(index + 1), total: Double(phases.count))
                .accessibilityLabel("Setup progress")
                .accessibilityValue(Text(.stepOf(stageNumber, 3)))
        }
    }

    private var stageNumber: Int {
        switch state.phase {
        case .connectToSpark, .joiningSetupNetwork, .sparkConnected: 1
        case .nvidiaSetup, .reconnecting, .rediscovering, .finishingSparkSetup, .sparkRestarting:
            2
        case .runtimeInstall, .securing, .starterModel, .ready: 3
        }
    }

    private var stageTitle: String {
        if state.phase == .ready { return String(localized: "Ready") }
        switch stageNumber {
        case 1: return String(localized: "Connect your Spark")
        case 2: return String(localized: "Join your home network")
        default: return String(localized: "Prepare your intelligence")
        }
    }

    private var setupConnectionActions: some View {
        VStack(spacing: 12) {
            if isShowingManualSetupDetails {
                Button("Join Spark", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!setupFieldsAreComplete)

                if canScanQuickStartCode {
                    Button("Scan Quick Start Code", action: onSecondary)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            } else {
                Button(String(localized: "Auto-connect to Spark Wi-Fi"), action: onSecondary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button(String(localized: "Enter details manually")) {
                    manualSetupDetailsOpened = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    /// Presents the associated setup network as a tappable row so back navigation does not immediately restart setup.
    func detectedNetworkRow(_ ssid: String) -> some View {
        Button(action: onUseDetectedNetwork) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ssid)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("This device is on this Spark's setup Wi-Fi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 440)
        .accessibilityHint("Continues setup using the Spark this device is connected to.")
    }

    var isWaitingPhase: Bool {
        switch state.phase {
        case .joiningSetupNetwork, .reconnecting, .rediscovering, .finishingSparkSetup,
            .sparkRestarting, .securing:
            return true
        default:
            return state.phase == .runtimeInstall && isRuntimeInstalling
                || state.phase == .starterModel && isCheckingAIServices
        }
    }

    @ViewBuilder
    private func actionButtons(primary: String?, secondary: String?) -> some View {
        VStack(spacing: 12) {
            if let primary {
                Button(primary, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(primaryActionIsDisabled)
            }
            if let secondary {
                Button(secondary, action: onSecondary)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(state.phase == .starterModel && isCheckingAIServices)
            }
        }
    }

    /// QA-01: the fields open either because the owner asked here, or because the scanner sheet sent them here.
    var isShowingManualSetupDetails: Bool {
        manualSetupDetailsOpened || manualSetupDetailsRequested
    }

    /// QA-02: one rule decides both whether Join Spark is offered and what the field says about why.
    private var setupFieldsAreComplete: Bool {
        RetailSetupNetworkStatus.resolve(
            ssid: setupSSID,
            detectedSSID: detectedSetupSSID,
            passphrase: setupPassphrase
        ).isComplete
    }

    private var primaryActionIsDisabled: Bool {
        if state.phase == .connectToSpark {
            // Platforms without in-app Wi-Fi joining discover an existing network Spark without requiring setup fields.
            return canJoinSetupNetwork && !setupFieldsAreComplete
        }
        if state.phase == .runtimeInstall {
            return administratorPassword.isEmpty || isRuntimeInstalling
        }
        if state.phase == .starterModel {
            return isCheckingAIServices
                || !RetailPreparationItem.requiredServicesAreReady(aiPreparation)
        }
        return false
    }

    func preparationList(_ items: [RetailPreparationItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 13) {
                    preparationSymbol(item.status)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if item.id != items.last?.id { Divider().padding(.leading, 51) }
            }
        }
        .frame(maxWidth: 440)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func preparationSymbol(_ status: RetailPreparationStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unavailable:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    func phaseArtwork(screen: RetailOnboardingScreen) -> some View {
        switch state.phase {
        case .connectToSpark:
            SparkProductArtwork(isConnected: false)
        case .sparkConnected:
            SparkProductArtwork(isConnected: true)
        case .ready:
            Image(systemName: screen.symbol)
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
        default:
            SparkProductArtwork(isConnected: false)
        }
    }

    private func issueContent(_ issue: RetailOnboardingIssue) -> some View {
        let screen = RetailOnboardingIssueScreen(issue: issue)
        return VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(screen.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(screen.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail, detail != screen.message {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(Text(detail))
            }
            if issue == .sparkNotFoundAfterSetup {
                machineNameField
            }
            Button(retryActionTitle ?? screen.retryAction, action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    /// Correct a renamed hostname, or reach the Spark by address when discovery never will.
    private var machineNameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spark name or address")
                .font(.headline)
            #if os(iOS)
                TextField("spark-a1b2", text: $machineName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .sparkField()
            #else
                TextField("spark-a1b2", text: $machineName)
                    .sparkField()
            #endif
            Text(
                "The name printed on the Quick Start card, without “.local”. An IP address works here too."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let onConnectByAddress {
                Button("Connect by Address") { onConnectByAddress(machineName) }
                    .buttonStyle(.bordered)
                    .disabled(
                        machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityHint(
                        "Goes straight to this address instead of waiting to be found."
                    )
            }
        }
        .frame(maxWidth: 440)
    }
}

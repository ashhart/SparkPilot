import SparkAppComposition
import SwiftUI

@main
struct SparkApp: App {
    /// Own the async SSH host-key confirmation coordinator at app composition so onboarding can present its prompt.
    @State private var hostKeyCoordinator = HostKeyConfirmationCoordinator()
    @State private var onboarding: RetailOnboardingModel?
    @State private var compositionError: String?
    @State private var compositionAttempt = 0
    @State private var retriedCompositionAutomatically = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var appLock = AppLockModel()
    @State private var notifications = SparkNotificationModel()

    init() {
        let hostKeys = HostKeyConfirmationCoordinator()
        let lock = AppLockModel()
        _hostKeyCoordinator = State(initialValue: hostKeys)
        _appLock = State(initialValue: lock)
        SparkCarPlayBridge.shared.configure(appLock: lock) {
            try BootstrapComposition.onboardingModel(
                hostKeyCoordinator: hostKeys,
                deviceName: UIDevice.current.name,
                platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
            )
        }
        BootstrapComposition.prepareIntentServices(
            refreshShortcutParameters: SparkPilotShortcuts.updateAppShortcutParameters
        )
        SparkCarPlayComposition.prepare()
        SparkWatchPhoneBridge.shared.activate(appLock: lock)
    }

    private func retryComposition() {
        compositionError = nil
        compositionAttempt += 1
    }

    var body: some Scene {
        WindowGroup {
            AppLockGate(model: appLock) {
                Group {
                    if let onboarding {
                        AppleSparkRootView(
                            model: onboarding,
                            appLock: appLock,
                            notificationModel: notifications
                        )
                        .environment(hostKeyCoordinator)
                        .sparkDrivingEnvironment()
                    } else if let compositionError {
                        ContentUnavailableView {
                            Label(
                                String(localized: "SparkPilot could not start"),
                                systemImage: "exclamationmark.triangle"
                            )
                        } description: {
                            Text(compositionError)
                        } actions: {
                            Button(String(localized: "Try Again")) { retryComposition() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .onChange(of: appLock.isLocked) { _, _ in
                SparkWatchPhoneBridge.shared.privacyChanged()
            }
            .onOpenURL { url in
                SparkWidgetNavigation.shared.open(url)
                if SparkWidgetNavigation.pairingPayload(from: url) != nil, let onboarding {
                    AppleShellActions.beginAddingSpark(with: onboarding)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Keychain access can fail transiently before the app is fully active; retry once by itself.
                guard phase == .active, compositionError != nil, !retriedCompositionAutomatically
                else { return }
                retriedCompositionAutomatically = true
                retryComposition()
            }
            .task(id: compositionAttempt) {
                guard onboarding == nil, compositionError == nil else { return }
                do {
                    let composed = try SparkCarPlayBridge.shared.composedOnboarding()
                    onboarding = composed
                    SparkCarPlayComposition.register(onboarding: composed, appLock: appLock)
                } catch {
                    compositionError = BootstrapComposition.failureDescription(for: error)
                }
            }
        }
        .backgroundTask(.appRefresh(SparkWidgetBackgroundRefresh.identifier)) {
            await BootstrapComposition.refreshWidgetsInBackground()
        }
        .backgroundTask(.appRefresh(SparkNotificationBackgroundTask.identifier)) {
            guard let onboarding = await onboarding else { return }
            let notifications = await notifications
            await SparkNotificationBackgroundRefresh.run(
                library: onboarding.library,
                notifications: notifications
            )
        }
        WindowGroup(String(localized: "Develop"), id: SparkDevelopmentView.windowID, for: UUID.self)
        { workspaceID in
            AppLockGate(model: appLock) {
                if let onboarding {
                    SparkDevelopmentView(
                        library: onboarding.library,
                        workspaceID: workspaceID.wrappedValue
                    )
                    .sparkDrivingEnvironment()
                } else {
                    ProgressView(String(localized: "Opening Spark Pilot…"))
                }
            }
        }

    }
}

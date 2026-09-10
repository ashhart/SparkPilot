import Foundation
import SparkAppComposition
import SwiftUI

@main
struct SparkMacApp: App {
    @State private var hostKeyCoordinator = HostKeyConfirmationCoordinator()
    @State private var onboarding: RetailOnboardingModel?
    @State private var compositionError: String?
    @State private var compositionAttempt = 0
    @State private var retriedCompositionAutomatically = false
    @Environment(\.scenePhase) private var scenePhase
    /// Apply the same opt-in app lock to macOS windows using Touch ID or account authentication.
    @State private var appLock = AppLockModel()

    init() {
        BootstrapComposition.prepareIntentServices(
            refreshShortcutParameters: SparkPilotShortcuts.updateAppShortcutParameters
        )
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
                        MacSparkRootView(onboarding: onboarding, appLock: appLock)
                            .environment(hostKeyCoordinator)
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
                    onboarding = try BootstrapComposition.onboardingModel(
                        hostKeyCoordinator: hostKeyCoordinator,
                        deviceName: Host.current().localizedName ?? "Mac",
                        platform: "macos"
                    )
                } catch {
                    compositionError = BootstrapComposition.failureDescription(for: error)
                }
            }
        }
        .defaultSize(width: 1_080, height: 720)
        .commands { MacSparkCommands() }

        Window(String(localized: "Send feedback"), id: MacSparkWindowID.feedback) {
            AppLockGate(model: appLock) {
                NavigationStack { SparkBugFeedbackView() }
            }
        }
        .defaultSize(width: 560, height: 680)

        // 41.3: Ask Spark has a window of its own so the shortcut works from any app state.
        Window(String(localized: "Ask Spark"), id: MacSparkWindowID.askSpark) {
            if let onboarding {
                MacAskSparkWindow(library: onboarding.library)
            } else {
                ProgressView()
            }
        }
        .defaultSize(width: 520, height: 520)

        // 41.3: project windows, one model each, opened from the Projects pane.
        WindowGroup(id: MacSparkWindowID.project, for: MacProjectWindowRequest.self) { request in
            if let onboarding {
                MacProjectWindow(request: request.wrappedValue, library: onboarding.library)
            } else {
                ProgressView()
            }
        }
        .defaultSize(width: 980, height: 660)

        // 41.3: the menu-bar status item.
        MenuBarExtra {
            if let onboarding {
                MacSparkMenuBarView(library: onboarding.library)
            } else {
                Text("SparkPilot is starting…")
            }
        } label: {
            MacSparkMenuBarLabel(library: onboarding?.library)
        }
        WindowGroup(String(localized: "Develop"), id: SparkDevelopmentView.windowID, for: UUID.self)
        { workspaceID in
            AppLockGate(model: appLock) {
                if let onboarding {
                    SparkDevelopmentView(
                        library: onboarding.library,
                        workspaceID: workspaceID.wrappedValue
                    )
                } else {
                    ProgressView(String(localized: "Opening Spark Pilot…"))
                }
            }
        }

    }
}

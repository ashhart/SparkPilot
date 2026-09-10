import Foundation
import SparkCore
import SwiftUI

public struct RetailOnboardingScreen: Sendable, Equatable {
    public let title: String
    public let message: String
    public let symbol: String
    public let primaryAction: String?
    public let secondaryAction: String?

    /// The platform can join the Spark's temporary Wi-Fi inside the app only when canJoinSetupNetwork is true.
    public init(
        phase: RetailOnboardingPhase,
        canJoinSetupNetwork: Bool = true,
        canScanQuickStartCode: Bool = true
    ) {
        switch phase {
        case .connectToSpark where !canJoinSetupNetwork:
            self.init(
                title: String(localized: "Connect from another Apple device"),
                message:
                    String(
                        localized:
                            "This device cannot join the Spark's temporary Wi-Fi from inside the app. Continue setup on an iPhone, iPad, or Mac that supports in-app joining. A Spark that is already set up can still be added from here."
                    ),
                symbol: "laptopcomputer.and.iphone",
                primaryAction: String(localized: "Find Sparks on This Network"),
                secondaryAction: nil
            )
        case .connectToSpark:
            self.init(
                title: String(localized: "Connect to your Spark"),
                message: canScanQuickStartCode
                    ? String(
                        localized:
                            "Scan the Quick Start code once. This device will join the Spark Wi-Fi and keep setup inside the app."
                    )
                    : String(
                        localized:
                            "Enter the Wi-Fi name and password from the Quick Start card. This Mac will join the Spark and keep setup inside the app."
                    ),
                symbol: "wifi",
                primaryAction: String(localized: "Auto-connect to Spark Wi-Fi"),
                secondaryAction: String(localized: "Enter details manually")
            )
        case .joiningSetupNetwork:
            self.init(
                title: String(localized: "Connecting to Spark"),
                message:
                    String(
                        localized:
                            "This device is joining the Spark Wi-Fi. If the system asks, approve the connection."
                    ),
                symbol: "wifi",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .sparkConnected:
            self.init(
                title: String(localized: "Connected"),
                message: String(localized: "This device is connected directly to your Spark."),
                symbol: "checkmark",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .nvidiaSetup:
            self.init(
                title: String(localized: "Set up your Spark"),
                message:
                    String(
                        localized:
                            "Create your Spark account and choose the Wi-Fi it will use every day. NVIDIA setup stays inside the app."
                    ),
                symbol: "checklist",
                primaryAction: String(localized: "Continue Setup"),
                secondaryAction: String(localized: "I've Finished Setup")
            )
        case .reconnecting:
            self.init(
                title: String(localized: "Checking your Spark joined your Wi-Fi"),
                message:
                    String(
                        localized:
                            "Your Spark is joining the Wi-Fi you chose. SparkPilot keeps checking until it answers there; this device moves back to your usual Wi-Fi by itself."
                    ),
                symbol: "arrow.triangle.2.circlepath",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .rediscovering:
            self.init(
                title: String(localized: "Finding your Spark"),
                message:
                    String(
                        localized:
                            "The first restart can take up to 10 minutes. Leave the Spark powered on while we look for it."
                    ),
                symbol: "magnifyingglass",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .finishingSparkSetup:
            self.init(
                title: String(localized: "Finishing Spark setup"),
                message:
                    String(
                        localized:
                            "Your Spark is applying its required first-boot updates. Keep it powered on while this finishes."
                    ),
                symbol: "arrow.down.circle",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .sparkRestarting:
            self.init(
                title: String(localized: "Your Spark is restarting"),
                message:
                    String(
                        localized:
                            "NVIDIA setup is complete and your Spark restarts to apply it, usually twice. SparkPilot watches for the restarts and checks every few seconds until the Spark answers and stays up. Keep it powered on; this can take a few minutes."
                    ),
                symbol: "arrow.clockwise.circle",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .runtimeInstall:
            self.init(
                title: String(localized: "Add Spark features"),
                message:
                    String(
                        localized:
                            "SparkPilot will verify and install its signed software on your Spark using the account you created."
                    ),
                symbol: "shippingbox",
                primaryAction: String(localized: "Install"),
                secondaryAction: nil
            )
        case .securing:
            self.init(
                title: String(localized: "Securing your Spark"),
                message: String(
                    localized:
                        "This device is creating its private key and pairing with your Spark."
                ),
                symbol: "lock.shield",
                primaryAction: nil,
                secondaryAction: nil
            )
        case .starterModel:
            self.init(
                title: String(localized: "Your Spark is paired"),
                message:
                    String(
                        localized:
                            "We will check that your Spark can run a model, then help you download one and ask your first question."
                    ),
                symbol: "checklist.checked",
                primaryAction: String(localized: "Choose your first model"),
                secondaryAction: String(localized: "Check Again")
            )
        case .ready:
            self.init(
                title: String(localized: "Pairing complete"),
                message: String(
                    localized: "Next, download and launch a model to start chatting."
                ),
                symbol: "checkmark.circle.fill",
                primaryAction: String(localized: "Choose your first model"),
                secondaryAction: nil
            )
        }
    }

    private init(
        title: String,
        message: String,
        symbol: String,
        primaryAction: String?,
        secondaryAction: String?
    ) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }
}

public enum RetailPreparationStatus: String, Sendable, Equatable {
    case pending
    case working
    case ready
    case unavailable
    case failed
}

public struct RetailPreparationItem: Identifiable, Sendable, Equatable {
    public static func requiredServicesAreReady(_ items: [Self]) -> Bool {
        ["runtime-health", "vllm", "catalogue"].allSatisfy { id in
            items.first(where: { $0.id == id })?.status == .ready
        }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let status: RetailPreparationStatus

    public init(
        id: String,
        title: String,
        detail: String,
        status: RetailPreparationStatus
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct RetailOnboardingIssueScreen: Sendable, Equatable {
    public let title: String
    public let message: String
    public let retryAction: String

    public init(issue: RetailOnboardingIssue) {
        switch issue {
        case .localNetworkDenied:
            self.init(
                title: String(localized: "Local network access is off"),
                message: String(
                    localized:
                        "Open Settings, allow Local Network access for Spark, then come back."
                ),
                retryAction: String(localized: "Open Settings")
            )
        case .setupHotspotUnavailable:
            self.init(
                title: String(localized: "Spark Wi-Fi was not found"),
                message:
                    String(
                        localized:
                            "Check that the white light is on and the Wi-Fi name on your screen matches the Quick Start card."
                    ),
                retryAction: String(localized: "Look Again")
            )
        case .setupNetworkJoinDenied:
            self.init(
                title: String(localized: "The Wi-Fi change was cancelled"),
                message: String(
                    localized:
                        "Spark needs to join the temporary setup network before it can continue."
                ),
                retryAction: String(localized: "Try Again")
            )
        case .nvidiaSetupInterrupted:
            self.init(
                title: String(localized: "NVIDIA setup did not finish"),
                message:
                    String(
                        localized:
                            "Reconnect to the Spark Wi-Fi if it is still listed, then reopen NVIDIA setup."
                    ),
                retryAction: String(localized: "Reopen Setup")
            )
        case .homeNetworkUnavailable:
            self.init(
                title: String(localized: "Your usual Wi-Fi is not connected"),
                message: String(
                    localized: "Connect this device to the same home Wi-Fi you chose for the Spark."
                ),
                retryAction: String(localized: "Check Again")
            )
        case .sparkNotFoundAfterSetup:
            self.init(
                title: String(localized: "The Spark has not appeared yet"),
                message:
                    String(
                        localized:
                            "A first restart can take 10 minutes. If the setup Wi-Fi is still visible, retry its Wi-Fi details. If it has gone, the Spark is probably on the network but hidden: some routers keep devices from seeing each other, and some networks do not carry the discovery messages this search relies on. Type the Spark’s name or IP address below to reach it directly, or connect it to this network with an Ethernet cable."
                    ),
                retryAction: String(localized: "Look Again")
            )
        case .nvidiaFinalizationFailed:
            self.init(
                title: String(localized: "Spark setup did not finish"),
                message:
                    String(
                        localized:
                            "The Spark is on your Wi-Fi, but its first-boot setup is incomplete. Keep it powered on and try again."
                    ),
                retryAction: String(localized: "Finish Setup")
            )
        case .sparkNotBackAfterRestart:
            self.init(
                title: String(localized: "Your Spark has not answered yet"),
                message:
                    String(
                        localized:
                            "A restart after first-boot updates can take up to 10 minutes. Keep the Spark powered on and on your Wi-Fi, then check again. If it has a display, wait for the login screen first."
                    ),
                retryAction: String(localized: "Check Again")
            )
        case .runtimeInstallFailed:
            self.init(
                title: String(localized: "Spark features were not installed"),
                message:
                    String(
                        localized:
                            "Nothing unsafe was installed. Make sure the Spark is powered on and on your Wi-Fi, then try the signed installation again."
                    ),
                retryAction: String(localized: "Try Again")
            )
        case .pairingFailed:
            self.init(
                title: String(localized: "This device could not pair"),
                message:
                    String(
                        localized:
                            "The Spark is set up, but this device is not trusted yet. Keep both devices on the same Wi-Fi and retry."
                    ),
                retryAction: String(localized: "Try Again")
            )
        case .identityUnavailable:
            self.init(
                title: String(localized: "The Spark could not verify its identity"),
                message:
                    String(
                        localized:
                            "Setup finished, but this device could not authenticate the Spark's identity. Nothing was changed on the Spark. Make sure both devices are on the same network, then try again."
                    ),
                retryAction: String(localized: "Verify Again")
            )
        case .deviceKeyUnavailable:
            self.init(
                title: String(localized: "This device's key could not be opened"),
                message:
                    String(
                        localized:
                            "Your Spark is set up and this device is its owner. The problem is on this device: the key it signs with could not be read. Restart the app and try again."
                    ),
                retryAction: String(localized: "Try Again")
            )
        }
    }

    private init(title: String, message: String, retryAction: String) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }
}

/// QA-07, QA-08: how the onboarding screen sits between the floating toolbar pill above it and the floating tab bar below it.
public struct RetailOnboardingChrome: Equatable, Sendable {
    /// The phase's actions live in a pinned bottom bar, so the tab bar never covers them and nothing has to be scrolled to find them.
    public let pinsActions: Bool
    /// Content passing under the toolbar gets a hard edge effect rather than meeting the pill on bare text.
    public let usesHardTopEdgeEffect: Bool

    public static func resolve(issue: RetailOnboardingIssue?) -> RetailOnboardingChrome {
        RetailOnboardingChrome(pinsActions: issue == nil, usesHardTopEdgeEffect: true)
    }
}

/// QA-07: applies the edge effect the chrome asks for without lengthening the onboarding view's own chain.
public struct RetailOnboardingScrollEdge: ViewModifier {
    let chrome: RetailOnboardingChrome

    public init(chrome: RetailOnboardingChrome = .resolve(issue: nil)) { self.chrome = chrome }

    public func body(content: Content) -> some View {
        #if os(iOS)
            if chrome.usesHardTopEdgeEffect {
                content.scrollEdgeEffectStyle(.hard, for: .top)
            } else {
                content
            }
        #else
            content
        #endif
    }
}

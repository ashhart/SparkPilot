import Foundation
import SparkCore
import Testing
@testable import SparkDesignSystem

/// Provide each connection state with a title, secondary detail and correct primary action (§62.1).
@Test func connectionStateMatrixMatchesContract() {
    let expectations: [(SparkConnectionState, String, String, NodeAction)] = [
        (.discovering, "Finding your Spark", "Looking on nearby networks", .none),
        (.foundUnpaired, "DGX Spark found", "Ready to set up or pair", .continueSetup),
        (.connecting, "Connecting", "Establishing a secure connection", .none),
        (.connectedWiFi, "Ready", "Local Wi-Fi", .open),
        (.connectedDirect, "Ready", "Direct 10 GbE", .open),
        (.connectedRemote, "Ready", "Secure remote connection", .open),
        (.offlineCached, "Spark is offline", "Showing last known status", .retry),
        (.identityMismatch, "Connection blocked", "Spark's identity has changed", .reviewRecovery),
        (.updateRequired, "Update required", "App and runtime are incompatible", .update),
    ]

    for (state, title, secondary, action) in expectations {
        let p = NodeStatusPresentation.resolve(state)
        #expect(p.title == title, "state \(state) title")
        #expect(p.secondary == secondary, "state \(state) secondary")
        #expect(p.action == action, "state \(state) action")
    }
}

/// Badge cues must change with state so health is never colour-only (§51.1).
@Test func statusHasNonColourCues() {
    #expect(NodeStatusPresentation.badge(for: .identityMismatch) == .blocked)
    #expect(NodeStatusPresentation.badge(for: .connectedDirect) == .ready)
    #expect(NodeStatusPresentation.badge(for: .discovering) == .probing)
    let card = sampleCard()
    #expect(card.presentation.action == .open)
    #expect(card.badge == .ready)
}

/// Offer chat only when the node is usable.
@Test func chatAvailabilityFollowsConnection() {
    #expect(sampleCard(connection: .connectedDirect).canChat)
    #expect(sampleCard(connection: .connectedWiFi).canChat)

    #expect(!sampleCard(connection: .offlineCached).canChat)
    #expect(!sampleCard(connection: .identityMismatch).canChat)
    #expect(!sampleCard(connection: .foundUnpaired).canChat)
    #expect(!sampleCard(connection: .discovering).canChat)
}

@Test func memorySummaryFormatsGiB() {
    let card = NodeCardState(
        nodeID: SparkNodeID(rawValue: UUID()),
        name: "n",
        connection: .connectedDirect,
        activeModel: nil,
        usedMemoryBytes: 1_230_000_000,
        totalMemoryBytes: 137_438_953_472
    )
    #expect(card.formattedMemory == "1.2 / 137.4 GB")
}

@Test func onboardingCopyKeepsSystemStepsPlain() {
    let setup = RetailOnboardingScreen(phase: .connectToSpark)
    let connected = RetailOnboardingScreen(phase: .sparkConnected)
    let nvidia = RetailOnboardingScreen(phase: .nvidiaSetup)
    let reconnecting = RetailOnboardingScreen(phase: .reconnecting)
    let install = RetailOnboardingScreen(phase: .runtimeInstall)

    #expect(setup.title == "Connect to your Spark")
    #expect(setup.primaryAction == "Auto-connect to Spark Wi-Fi")
    #expect(setup.secondaryAction == "Enter details manually")
    #expect(setup.message.localizedCaseInsensitiveContains("scan"))
    #expect(connected.title == "Connected")
    #expect(connected.primaryAction == nil)
    #expect(nvidia.title == "Set up your Spark")
    #expect(reconnecting.title == "Checking your Spark joined your Wi-Fi")
    #expect(install.message.contains("signed software"))
    #expect(!install.message.localizedCaseInsensitiveContains("ssh"))
    #expect(
        !install.message.localizedCaseInsensitiveContains("asked for"),
        "the password is already held"
    )
}

@Test func theRestartWaitTellsTheOwnerWhatIsHappeningAndWhenTheyMayStepIn() {
    let restarting = RetailOnboardingScreen(phase: .sparkRestarting)
    #expect(restarting.title == "Your Spark is restarting")
    #expect(restarting.message.localizedCaseInsensitiveContains("watches for the restart"))
    #expect(
        restarting.primaryAction == nil,
        "the button lives with the countdown, not the pinned bar"
    )

    let progress = RetailRestartProgress(
        startedAt: Date(timeIntervalSince1970: 0),
        hold: .seconds(30),
        limit: .seconds(600)
    )
    #expect(!progress.holdHasElapsed(at: Date(timeIntervalSince1970: 29)))
    #expect(progress.holdHasElapsed(at: Date(timeIntervalSince1970: 30)))
    let holding = RetailRestartProgress.status(elapsed: 12, hold: .seconds(30), limitMinutes: 10)
    #expect(holding.contains("18"), "counts the hold down: \(holding)")
    let checking = RetailRestartProgress.status(
        elapsed: 95,
        hold: .seconds(30),
        limitMinutes: 10,
        stage: .checking
    )
    #expect(checking.contains("1:35") && checking.contains("10"), "\(checking)")
    let restartingLine = RetailRestartProgress.status(
        elapsed: 40,
        hold: .seconds(120),
        limitMinutes: 10,
        stage: .restarting
    )
    #expect(restartingLine.localizedCaseInsensitiveContains("restarting"))
    let seen = RetailRestartProgress(
        startedAt: Date(timeIntervalSince1970: 0),
        hold: .seconds(120),
        limit: .seconds(600),
        stage: .restarting
    )
    #expect(
        !seen.manualCheckIsOffered(at: Date(timeIntervalSince1970: 5)),
        "a Spark often restarts twice; no manual check in the first minute"
    )
    #expect(seen.manualCheckIsOffered(at: Date(timeIntervalSince1970: 61)))
    let unseen = RetailRestartProgress(
        startedAt: Date(timeIntervalSince1970: 0),
        hold: .seconds(120),
        limit: .seconds(600)
    )
    #expect(!unseen.manualCheckIsOffered(at: Date(timeIntervalSince1970: 59)))
    #expect(unseen.manualCheckIsOffered(at: Date(timeIntervalSince1970: 60)))

    let gaveUp = RetailOnboardingIssueScreen(issue: .sparkNotBackAfterRestart)
    #expect(gaveUp.retryAction == "Check Again")
    #expect(gaveUp.message.localizedCaseInsensitiveContains("10 minutes"))
}

@Test func sharedOnboardingCopyDoesNotCallEveryAppleDeviceAnIPhone() {
    for phase in RetailOnboardingPhase.allCases {
        let screen = RetailOnboardingScreen(phase: phase)
        let copy = "\(screen.title) \(screen.message)"
        #expect(
            !copy.localizedCaseInsensitiveContains("iPhone"),
            "\(phase) is shared by iPhone, iPad, and Mac"
        )
    }
}

@Test func connectedArtworkHonoursReducedMotion() {
    #expect(
        !SparkProductArtworkMotion.shouldPulse(isConnected: true, reduceMotion: true),
        "Reduce Motion must disable the repeating connection pulse"
    )
    #expect(SparkProductArtworkMotion.shouldPulse(isConnected: true, reduceMotion: false))
    #expect(!SparkProductArtworkMotion.shouldPulse(isConnected: false, reduceMotion: false))
}

@Test func setupArtworkUsesTheStaticSparkImage() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot.appending(
        path: "Sources/SparkDesignSystem/SparkProductArtwork.swift"
    )
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(!source.contains("@State private var spin"))
    #expect(!source.contains(".rotation3DEffect("))
    #expect(!source.contains("isSettingUp"))
}

@Test func interruptedSetupUsesThePolishedCredentialRows() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot.appending(
        path: "Sources/SparkDesignSystem/RetailAdministratorCredentials.swift"
    )
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let onboarding = try String(
        contentsOf: packageRoot.appending(
            path: "Sources/SparkDesignSystem/RetailOnboardingPhaseContent.swift"
        ),
        encoding: .utf8
    )

    #expect(onboarding.contains("RetailAdministratorCredentials("))
    #expect(source.contains("@FocusState private var focusedCredentialField"))
    // Assert the catalogue lookup rather than an obsolete bare visible literal.
    #expect(
        source.contains(
            "administratorCredentialInput(\n"
                + "                String(localized: \"Username\")"
        )
    )
    #expect(
        source.contains(
            "administratorCredentialInput(\n"
                + "                String(localized: \"Password\")"
        )
    )
    #expect(source.contains("systemImage: \"person.fill\""))
    #expect(source.contains("systemImage: \"lock.fill\""))
    #expect(source.contains("RoundedRectangle(cornerRadius: 16, style: .continuous)"))
    #expect(source.contains("focusedCredentialField = focus"))
    #expect(source.contains(".simultaneousGesture("))
}

@Test func onboardingSuccessFeedbackOnlyFiresAtRealMilestones() {
    #expect(
        RetailOnboardingFeedback.shouldPlaySuccess(
            from: .joiningSetupNetwork,
            to: .sparkConnected
        )
    )
    #expect(RetailOnboardingFeedback.shouldPlaySuccess(from: .starterModel, to: .ready))
    #expect(!RetailOnboardingFeedback.shouldPlaySuccess(from: .ready, to: .ready))
    #expect(!RetailOnboardingFeedback.shouldPlaySuccess(from: .reconnecting, to: .rediscovering))
}

@Test func onboardingFailuresAlwaysOfferConcreteRecovery() {
    // Enumerate all issue cases so newly added failures cannot silently lack copy.
    #expect(!RetailOnboardingIssue.allCases.isEmpty)
    for issue in RetailOnboardingIssue.allCases {
        let screen = RetailOnboardingIssueScreen(issue: issue)
        #expect(!screen.title.isEmpty, "\(issue) has no title")
        #expect(!screen.message.isEmpty, "\(issue) has no message")
        #expect(!screen.retryAction.isEmpty, "\(issue) has no recovery action")
    }
}

@Test func deniedLocalNetworkAccessOpensSettingsInsteadOfBlindlyRetrying() {
    let screen = RetailOnboardingIssueScreen(issue: .localNetworkDenied)

    #expect(screen.retryAction == "Open Settings")
}

@Test func aDeviceKeyFailureDoesNotBlamePairingOrTheSpark() {
    // Avoid suggesting repeated pairing or installation after those steps have succeeded.
    let screen = RetailOnboardingIssueScreen(issue: .deviceKeyUnavailable)
    let text = "\(screen.title) \(screen.message)".lowercased()
    #expect(!text.contains("could not pair"))
    #expect(!text.contains("not trusted"))
    #expect(!text.contains("were not installed"))
    #expect(text.contains("this device"), "it names where the problem is")
}

@MainActor
@Test func theDetailIsShownAlongsideAnIssuesCannedCopy() {
    // Present the model's specific failure reason instead of dropping it from the view.
    let view = RetailOnboardingView(
        state: RetailOnboardingState(phase: .securing, issue: .pairingFailed),
        detail: "The pairing invitation expired.",
        setupSSID: .constant(""),
        setupPassphrase: .constant(""),
        onPrimary: {}
    )
    #expect(view.detail == "The pairing invitation expired.")
}

@Test func emptyStatesOfferRecovery() {
    let denied = DashboardEmptyState(kind: .permissionDenied)
    #expect(denied.actionLabel == "Open Settings")
    let restricted = DashboardEmptyState(kind: .permissionRestricted)
    #expect(restricted.actionLabel == nil, "restricted status offers no false remedy")
    let offline = DashboardEmptyState(kind: .allOffline)
    #expect(offline.actionLabel == "Retry")
}

private func sampleCard(connection: SparkConnectionState = .connectedDirect) -> NodeCardState {
    NodeCardState(
        nodeID: SparkNodeID(rawValue: UUID()),
        name: "Alex's Spark",
        connection: connection,
        activeModel: .init(displayName: "Reasoning 32B", performanceSummary: "41.8 tok/s"),
        usedMemoryBytes: 40_000_000_000,
        totalMemoryBytes: 137_438_953_472
    )
}

// MARK: - Pairing invitation code

@Test func aPairingInvitationEncodesToAScannableCode() throws {
    // A realistic package payload: base64url of the invitation envelope.
    let payload = "spark://pair/" + String(repeating: "A", count: 800)
    let image = try #require(SparkQRCodeRenderer.makeCGImage(payload: payload))

    #expect(image.width > 0)
    #expect(image.width == image.height, "a QR symbol is square")
}

@Test func anUnencodableInvitationIsNilRatherThanABlankSquare() {
    #expect(SparkQRCodeRenderer.makeCGImage(payload: "") == nil)
    #expect(
        SparkQRCodeRenderer.makeCGImage(
            payload: String(repeating: "A", count: SparkQRCodeRenderer.maximumPayloadBytes + 1)
        ) == nil,
        "a payload too dense to scan must not be presented as one that can be"
    )
}

@Test func theConnectScreenTellsAMacWhichDeviceToUse() {
    let mac = RetailOnboardingScreen(phase: .connectToSpark, canJoinSetupNetwork: false)

    #expect(mac.title != RetailOnboardingScreen(phase: .connectToSpark).title)
    #expect(mac.primaryAction == "Find Sparks on This Network")
    #expect(mac.secondaryAction == nil, "there is no Quick Start form to scan into")
    #expect(mac.message.localizedCaseInsensitiveContains("iPad"))
}

@Test func aMacThatCanJoinUsesTheSameJourneyWithCardDetails() {
    let mac = RetailOnboardingScreen(
        phase: .connectToSpark,
        canJoinSetupNetwork: true,
        canScanQuickStartCode: false
    )

    #expect(mac.title == RetailOnboardingScreen(phase: .connectToSpark).title)
    #expect(mac.message.localizedCaseInsensitiveContains("Mac"))
    #expect(mac.message.localizedCaseInsensitiveContains("Quick Start card"))
}

@Test func aiReadinessCopyNamesRealLocalServices() {
    let screen = RetailOnboardingScreen(phase: .starterModel)

    #expect(screen.title == "Your Spark is paired")
    #expect(screen.message.localizedCaseInsensitiveContains("first question"))
    #expect(screen.primaryAction == "Choose your first model")
}

@Test func manualSetupNamesMustResolveBeforeTheJoinStarts() {
    for name in [
        "my spark", "spark_name", "spark.name", "-spark", "spark-", "",
        String(repeating: "a", count: 64),
    ] {
        #expect(SparkSetupAddress.hostname(for: name) == nil)
    }
    #expect(SparkSetupAddress.hostname(for: "Spark-A1B2") == "spark-a1b2.local")
    #expect(SparkSetupAddress.hostname(for: "Spark-A1B2.local") == "spark-a1b2.local")
}

/// UX-08: the post-setup wait shows elapsed time against its limit.
@Test func rediscoveryWaitReportsElapsedAgainstTheLimit() {
    let progress = RetailRediscoveryProgress(
        startedAt: Date(timeIntervalSince1970: 0),
        limit: .seconds(600)
    )
    #expect(progress.limitMinutes == 10)
    #expect(progress.fraction(at: Date(timeIntervalSince1970: 300)) == 0.5)
    #expect(progress.fraction(at: Date(timeIntervalSince1970: 900)) == 1)
    #expect(
        RetailRediscoveryProgress.status(elapsed: 83, limitMinutes: 10)
            == "1:23 elapsed. Sparks usually come back within a few minutes; the search stops after 10 minutes."
    )
}

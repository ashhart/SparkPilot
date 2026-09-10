import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

@Test func emptySparkHomeWelcomesTheOwnerToTheirDGXSpark() {
    #expect(SparkHomeCopy.navigationTitle == "Home")
    #expect(SparkHomeCopy.emptyTitle == "Welcome to your DGX Spark")
}

@Test func nativeSetupInputRowsForwardTheirFirstTapToTheTextField() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let sourceFile =
        testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Shared/NativeSparkSetupView.swift")
    let source = try String(contentsOf: sourceFile, encoding: .utf8)

    #expect(source.contains("focus: FocusedField"))
    #expect(source.contains("focus: .username"))
    #expect(source.contains("focus: .password"))
    #expect(source.contains("focus: .passwordConfirmation"))
    #expect(source.contains("focus: .wifiPassword"))
    #expect(source.contains(".simultaneousGesture("))
    #expect(source.contains("focusedField = focus"))
}

@Test func eachShippingTargetHasExactlyOneAppShortcutsProvider() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let appleRoot = appRoot.deletingLastPathComponent()
    let project = try String(
        contentsOf: appRoot.appending(path: "SparkApp.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )
    let executableSource = try String(
        contentsOf: appRoot.appending(path: "ExecutableShared/SparkPilotShortcuts.swift"),
        encoding: .utf8
    )
    let iOSAppSource = try String(
        contentsOf: appRoot.appending(path: "iPhone/SparkApp.swift"),
        encoding: .utf8
    )
    let macAppSource = try String(
        contentsOf: appRoot.appending(path: "macOS/SparkMacApp.swift"),
        encoding: .utf8
    )

    let libraryConformances = try compositionLibraryTestAppShortcutsProviderConformanceCount(
        in: [appleRoot.appending(path: "Packages"), appRoot.appending(path: "Shared")]
    )
    let executableConformances = try compositionLibraryTestAppShortcutsProviderConformanceCount(
        in: [appRoot.appending(path: "ExecutableShared")]
    )
    let iOSConformances = try compositionLibraryTestAppShortcutsProviderConformanceCount(
        in: [appRoot.appending(path: "iPhone")]
    )
    let macConformances = try compositionLibraryTestAppShortcutsProviderConformanceCount(
        in: [appRoot.appending(path: "macOS")]
    )

    #expect(libraryConformances + executableConformances + iOSConformances == 1)
    #expect(libraryConformances + executableConformances + macConformances == 1)
    #expect(executableSource.components(separatedBy: "AppShortcut(").count - 1 == 10)
    #expect(executableSource.contains("DraftEmailWithSparkIntent()"))
    #expect(iOSAppSource.contains("SparkPilotShortcuts.updateAppShortcutParameters"))
    #expect(macAppSource.contains("SparkPilotShortcuts.updateAppShortcutParameters"))
    #expect(
        project.components(separatedBy: "A10000000000000000000005").count - 1 == 2,
        "the iOS target must compile the one executable provider"
    )
    #expect(
        project.components(separatedBy: "A20000000000000000000005").count - 1 == 2,
        "the macOS target must compile the one executable provider"
    )
}

func compositionLibraryTestAppShortcutsProviderConformanceCount(in roots: [URL]) throws -> Int {
    var count = 0
    for root in roots {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        else { continue }
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            count += source.components(separatedBy: ": AppShortcutsProvider").count - 1
        }
    }
    return count
}

@Test func spotlightSystemIntegrationIsOptInAndObservesBothShippingRoots() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let iOSRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/AppleSparkRootView.swift"),
        encoding: .utf8
    )
    let macRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/MacSparkRootView.swift"),
        encoding: .utf8
    )

    let macSettings = try String(
        contentsOf: appRoot.appending(path: "Shared/MacAppSettingsView.swift"),
        encoding: .utf8
    )

    let iOSSettings = try String(
        contentsOf: appRoot.appending(path: "Shared/AppleSparkSettingsView.swift"),
        encoding: .utf8
    )
    #expect(iOSRoot.contains("AppleSparkSettingsView("))
    for source in [iOSRoot + iOSSettings, macRoot + macSettings] {
        #expect(source.contains("SparkSpotlightModel"))
        #expect(source.contains("spotlight.observe("))
        #expect(source.contains("SparkSpotlightSettingsView"))
    }
}

@Test func batchDevicePairingShipsOnPhonePadAndMacWithBothLocalRoles() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let iOSRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/RetailOnboardingRootView.swift"),
        encoding: .utf8
    )
    let macRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/MacSparkRootView.swift"),
        encoding: .utf8
    )
    let recipientView = try String(
        contentsOf: appRoot.appending(path: "Shared/AdditionalDevicePairingView.swift"),
        encoding: .utf8
    )
    let ownerView = try String(
        contentsOf: appRoot.appending(path: "Shared/BatchInviteDeviceView.swift"),
        encoding: .utf8
    )

    #expect(iOSRoot.contains("BatchPairThisDeviceView"))
    #expect(macRoot.contains("RetailOnboardingRootView(model: onboarding)"))
    for root in [iOSRoot, macRoot] {
        #expect(root.contains("BatchInviteDeviceView"))
    }
    #expect(recipientView.contains("struct BatchPairThisDeviceView"))
    #expect(recipientView.contains("retryBatchPairing"))
    #expect(ownerView.contains("Create Multi-Spark Package"))
    #expect(ownerView.contains("revokeBatchInvitationGrants"))
}

@Test func projectsJourneyIsReachableAndComposedOnEveryAppleShell() throws {
    #expect(AppleNavigationPlan.sidebarSections.contains(.projects))
    #expect(AppleNavigationPlan.phoneMoreSections.contains(.projects))

    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let phoneAndPadRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/AppleSparkRootView.swift"),
        encoding: .utf8
    )
    let macRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/MacSparkRootView.swift"),
        encoding: .utf8
    )
    let composition = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkProjectsComposition.swift"),
        encoding: .utf8
    )
    for source in [phoneAndPadRoot, macRoot] {
        #expect(source.contains("ProjectsModel("))
        #expect(source.contains("SignedProjectDataProvider(library:"))
        #expect(source.contains("SparkDevelopmentView(library:"))
        #expect(source.contains("engineeringMode"))
        #expect(source.contains("await projects.load()"))
    }
    #expect(composition.contains("ProjectsView(model: projects)"))
    #expect(composition.contains("BuildProjectView(model: builds)"))
}

/// adapt Stage 2: the iPhone card carries the same five facts the iPad and Mac card does.
@MainActor
@Test func theCompactCardCarriesLastContactMemoryModelAndCount() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = activityTimelineTestEntry(name: "Desk Spark", instant: instant)
    let summary = LibraryCardSummary.resolve(entry: entry)

    #expect(summary != nil)
    #expect(summary?.lastContact.isEmpty == false)
    #expect(summary?.availableMemory.isEmpty == false)
    #expect(summary?.activeModel.isEmpty == false)
    #expect(summary?.installedModels.isEmpty == false)
    #expect(summary?.nextAction == .open)
}

/// The one next action names what it does, and a blocked Spark never offers Open.
@MainActor
@Test func theCompactCardsNextActionFollowsTheTargetState() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    var entry = activityTimelineTestEntry(name: "Desk Spark", instant: instant)
    #expect(LibraryCardSummary.action(for: entry) == .open)

    entry.connectionState = SparkConnectionState.offlineCached
    #expect(LibraryCardSummary.action(for: entry) == .checkAgain)
    entry.connectionState = SparkConnectionState.updateRequired
    #expect(LibraryCardSummary.action(for: entry) == .update)
    entry.connectionState = SparkConnectionState.identityMismatch
    #expect(LibraryCardSummary.action(for: entry) == .reviewRecovery)
    #expect(LibraryCardSummary.NextAction.reviewRecovery.title == "Review Recovery")
}

/// §41.6 fixes the route vocabulary; the library card used its own wording for the cable.
@Test func theCompactCardNamesTheDirectRouteTheWayTheSpecDoes() {
    #expect(LibraryConnectionPresentation.resolve(.connectedDirect).label == "Direct 10 GbE")
    #expect(LibraryConnectionPresentation.resolve(.connectedWiFi).label == "Local Wi-Fi")
    #expect(LibraryConnectionPresentation.resolve(.connectedRemote).label == "Remote")
}

@Test func theSiriScreenIsReachableAndSaysWhatAppleIntelligenceCanDo() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let phoneAndPadRoot = try String(
        contentsOf: appRoot.appending(path: "Shared/AppleSparkRootView.swift"),
        encoding: .utf8
    )
    let macSettings = try String(
        contentsOf: appRoot.appending(path: "Shared/MacAppSettingsView.swift"),
        encoding: .utf8
    )
    let screen = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkAppleAppsView.swift"),
        encoding: .utf8
    )

    let phoneAndPadSettings = try String(
        contentsOf: appRoot.appending(path: "Shared/AppleSparkSettingsView.swift"),
        encoding: .utf8
    )
    #expect(phoneAndPadRoot.contains("AppleSparkSettingsView("))
    for source in [phoneAndPadRoot + phoneAndPadSettings, macSettings] {
        #expect(source.contains("SparkAppleAppsView(chat:"))
        #expect(source.contains("Siri & Apple Apps"))
    }
    // QA-16: the system tip drew an empty capsule, so the screen quotes the phrase itself.
    #expect(screen.contains("SparkSiriTip.spokenPhrase"))
    #expect(screen.contains("ShortcutsLink()"))
    #expect(screen.contains("shortcuts://"), "macOS has no ShortcutsLink, so it keeps the URL")
    #expect(screen.contains("SparkAppleIntelligence.state"))
    #expect(screen.contains("ForEach(SparkAppleAction.allCases)"))
}

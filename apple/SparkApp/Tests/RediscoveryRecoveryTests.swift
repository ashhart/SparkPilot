import Foundation
import SparkCore
import SparkDesignSystem
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// PLAN 10.1 failure 2: name the likely cause and offer a way past it.
@Test func theNotFoundRecoveryNamesIsolationDiscoveryAndEthernet() {
    let screen = RetailOnboardingIssueScreen(issue: RetailOnboardingIssue.sparkNotFoundAfterSetup)

    #expect(screen.message.contains("keep devices from seeing each other"))
    #expect(screen.message.contains("do not carry the discovery messages"))
    #expect(screen.message.contains("IP address"))
    #expect(screen.message.contains("Ethernet"))
}

/// The address the recovery screen offers has to reach the Spark, not re-filter Bonjour.
@MainActor
@Test func anAddressTypedIntoRecoveryReachesTheSparkDirectly() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let root = try String(
        contentsOf: appRoot.appending(path: "Shared/RetailOnboardingRootView.swift"),
        encoding: .utf8
    )
    let view = try String(
        contentsOf: appRoot.deletingLastPathComponent()
            .appending(
                path:
                    "Packages/SparkDesignSystem/Sources/SparkDesignSystem/RetailOnboardingView.swift"
            ),
        encoding: .utf8
    )

    #expect(view.contains("Connect by Address"))
    #expect(view.contains("Spark name or address"))
    #expect(root.contains("onConnectByAddress: { _ = model.chooseExistingSpark(host: $0) }"))
}

/// An address goes straight to a pinned host and port rather than a Bonjour service name.
@MainActor
@Test func anAddressBecomesADirectRouteRatherThanADiscoveryFilter() throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: MemoryLibraryStore()),
        identityResolver: DeferredPinnedIdentityResolver(),
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: []),
        runtime: CompositionLibraryTestActivationRuntime()
    )

    #expect(model.chooseExistingSpark(host: "192.168.1.40"))
    #expect(!model.chooseExistingSpark(host: "not a host"))
    #expect(!model.chooseExistingSpark(host: ""))
}

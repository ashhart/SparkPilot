import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func optionalServiceHooksNeverInventAnInstallerOrRemoteCatalogue() async {
    let unavailable = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await unavailable.refresh()
    #expect(unavailable.openWebUIStatus == "Unavailable")
    #expect(unavailable.remoteCatalogueStatus == "Unavailable")

    let detected = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(optionalServices: true),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await detected.refresh()
    #expect(detected.openWebUIStatus == "Not installed")
    #expect(detected.openWebUIDetail.contains("Version 0.6.32"))
}

@MainActor
@Test func unsafeProfileReenableRequiresCapabilityReviewPresenceAndDurableSuccess() async throws {
    let hiddenRuntime = DashboardTestFakeRuntimeReader()
    let hiddenModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: hiddenRuntime,
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await hiddenModel.refresh()
    #expect(!hiddenModel.profileReenableSupported)
    await hiddenModel.prepareProfileReenable(modelID: "open/model-8b", profileID: "large")
    #expect(hiddenModel.pendingProfileReenable == nil)

    let runtime = DashboardTestFakeRuntimeReader(profileReenable: true)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache(),
        operationDelay: { _ in }
    )
    await model.refresh()
    #expect(model.profileReenableSupported)
    #expect(model.models[0].profiles[0].safe == false)

    await model.prepareProfileReenable(modelID: "open/model-8b", profileID: "large")
    let confirmation = try #require(model.pendingProfileReenable)
    #expect(confirmation.preview.action == .profileReenable)
    #expect(confirmation.modelName == "Model 8B")
    #expect(confirmation.profileName == "Large context")
    #expect(confirmation.preview.evidence.profileFailureCode == "MEMORY_GUARD_EMERGENCY")

    await model.applyProfileReenable()

    let applied = try #require(await runtime.recordedProfileReenable())
    #expect(applied.modelID == confirmation.modelID)
    #expect(applied.profileID == confirmation.profileID)
    #expect(applied.key == confirmation.idempotencyKey)
    #expect(applied.request.acceptedPreviewDigest == confirmation.preview.previewDigest)
    #expect(await presence.count() == 1)
    #expect(await runtime.profilePolls() == 2)
    #expect(model.pendingProfileReenable == nil)
    #expect(model.profileReenableErrorMessage == nil)
    #expect(model.models[0].profiles[0].safe)
}

@MainActor
@Test func ambiguousProfileReenableRetryKeepsReviewAndIdempotencyKey() async throws {
    let runtime = DashboardTestFakeRuntimeReader(
        profileReenable: true,
        failFirstProfileReenable: true
    )
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareProfileReenable(modelID: "open/model-8b", profileID: "large")
    let reviewedKey = try #require(model.pendingProfileReenable?.idempotencyKey)

    await model.applyProfileReenable()

    #expect(model.pendingProfileReenable?.idempotencyKey == reviewedKey)
    #expect(model.profileReenableErrorMessage?.contains("could not confirm") == true)
    #expect(model.models[0].profiles[0].safe == false)

    await model.applyProfileReenable()

    #expect(await runtime.recordedProfileReenableKeys() == [reviewedKey, reviewedKey])
    #expect(await presence.count() == 2)
    #expect(model.pendingProfileReenable == nil)
    #expect(model.models[0].profiles[0].safe)
}

@MainActor
@Test func failedProfileReenableKeepsProfileDisabledAndRequiresFreshReview() async throws {
    let runtime = DashboardTestFakeRuntimeReader(
        profileReenable: true,
        profileReenableFails: true
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: DashboardTestDashboardPresenceAuthorizer(),
        telemetryCache: DashboardTestTestTelemetryCache(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareProfileReenable(modelID: "open/model-8b", profileID: "large")

    await model.applyProfileReenable()

    #expect(model.pendingProfileReenable == nil)
    #expect(model.profileReenableErrorMessage?.contains("remains disabled") == true)
    #expect(model.profileReenableErrorMessage?.contains("Review it again") == true)
    #expect(model.models[0].profiles[0].safe == false)
}

@MainActor
@Test func openWebUIInstallUsesFreshPresenceAndDistinctAdministratorCredentials() async {
    let runtime = DashboardTestFakeRuntimeReader(optionalServices: true)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        tlsFingerprint: String(repeating: "a", count: 64),
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await model.refresh()
    model.openWebUIAdminEmail = "owner@example.test"
    model.openWebUIAdminName = "Local Owner"
    model.openWebUIAdminPassword = "unique-password-1234"
    model.acceptOpenWebUIRecipe(true)

    await model.installOpenWebUI()

    let request = await runtime.recordedOpenWebUIInstall()
    #expect(request?.adminEmail == "owner@example.test")
    #expect(request?.adminName == "Local Owner")
    #expect(request?.adminPassword == "unique-password-1234")
    #expect(request?.acceptedRecipeRevision == "open-webui-r1")
    #expect(await presence.count() == 1)
    #expect(model.openWebUIAdminPassword.isEmpty)
    #expect(model.openWebUIStatus == "Healthy")

    await model.requestOpenWebUIAccess()
    #expect(model.openWebUIAccessPath == "/services/open-webui/")
    model.dismissOpenWebUI()

    await model.updateOpenWebUI()
    await model.removeOpenWebUI(eraseData: false)
    #expect(await presence.count() == 3)
    #expect(await runtime.recordedOpenWebUIRemoval()?.eraseData == false)
    #expect(model.openWebUIStatus == "Not installed")
}

@MainActor
@Test(arguments: [(nil, nil), (false, true), (true, false), (true, true)] as [(Bool?, Bool?)])
func openWebUIRepairRequiresOwnershipAndFreshAvailability(
    ownership: Bool?,
    available: Bool?
) async {
    let runtime = DashboardTestFakeRuntimeReader(optionalServices: true)
    await runtime.configureOpenWebUIRepair(ownership: ownership, available: available)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        tlsFingerprint: String(repeating: "a", count: 64),
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await model.refresh()
    let allowed = ownership == true && available == true
    #expect(model.canRepairOpenWebUI == allowed)
    await model.repairOpenWebUI()
    #expect(await runtime.recordedOpenWebUIRepairs() == (allowed ? 1 : 0))
    #expect(await presence.count() == (allowed ? 1 : 0))
    #expect(!model.canRepairOpenWebUI)
    await model.repairOpenWebUI()
    #expect(await runtime.recordedOpenWebUIRepairs() == (allowed ? 1 : 0))
}

@MainActor
@Test func dashboardDropsPresenceEnrollmentKeyAfterDefinitiveRejection() async {
    let runtime = DashboardTestFakeRuntimeReader(
        optionalServices: true,
        presenceEnrollmentStatusCode: 409
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: DashboardTestDashboardPresenceAuthorizer(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await model.refresh()
    model.openWebUIAdminEmail = "owner@example.test"
    model.openWebUIAdminName = "Local Owner"
    model.openWebUIAdminPassword = "unique-password-1234"
    model.acceptOpenWebUIRecipe(true)

    await model.installOpenWebUI()
    model.openWebUIAdminPassword = "unique-password-1234"
    await model.installOpenWebUI()

    let keys = await runtime.recordedPresenceEnrollmentKeys()
    #expect(keys.count == 2)
    #expect(keys[0] != keys[1])
}

@Test func openWebUIRouteUsesOnlyTheServerReturnedSameHostPath() throws {
    let base = URL(string: "https://spark.local:7443")!
    let route = try PinnedOpenWebUIRoute(
        baseRoute: base,
        accessPath: "/services/open-webui/"
    )
    #expect(route.initialURL == URL(string: "https://spark.local:7443/services/open-webui/"))
    #expect(
        PinnedOpenWebUINavigationPolicy(host: route.host).allows(
            URL(string: "https://spark.local:7444/")!
        )
    )
    #expect(
        !PinnedOpenWebUINavigationPolicy(host: route.host).allows(
            URL(string: "http://spark.local:7444/")!
        )
    )
    #expect(
        !PinnedOpenWebUINavigationPolicy(host: route.host).allows(
            URL(string: "https://other.local:7444/")!
        )
    )
    #expect(throws: PinnedOpenWebUIRoute.Error.invalidAccessPath) {
        try PinnedOpenWebUIRoute(baseRoute: base, accessPath: "https://other.local/")
    }
    #expect(throws: PinnedOpenWebUIRoute.Error.invalidAccessPath) {
        try PinnedOpenWebUIRoute(baseRoute: base, accessPath: "/untrusted/")
    }
}

@MainActor
@Test func signedCatalogueRefreshRequiresPresenceAndPollsTheDurableOperation() async {
    let runtime = DashboardTestFakeRuntimeReader(catalogueRefresh: true)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache(),
        operationDelay: { _ in }
    )
    await model.refresh()
    #expect(model.remoteCatalogueStatus == "Ready")
    #expect(model.catalogueStatus?.recipeCount == 1)

    let candidate = #"{"catalogue":"signed-candidate"}"#
    await model.prepareCatalogueRefresh(candidateJSON: candidate, fileName: "catalogue.json")
    #expect(model.pendingCatalogueRefresh?.preview.action == .catalogueRefresh)

    await model.applyCatalogueRefresh()

    let request = await runtime.recordedCatalogueRefresh()
    #expect(request?.candidateJson == candidate)
    #expect(
        request?.acceptedPreviewDigest
            == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    #expect(await presence.count() == 1)
    #expect(await runtime.cataloguePolls() == 2)
    #expect(model.pendingCatalogueRefresh == nil)
    #expect(model.catalogueStatus?.recipeCount == 2)
    #expect(model.catalogueErrorMessage == nil)
}

// MARK: - Open WebUI install readiness

/// Explain which prerequisite keeps installation disabled.
@Test func openWebUIInstallNamesWhatIsStillMissing() {
    func blocker(
        email: String = "",
        name: String = "",
        password: String = "",
        accepted: String? = nil
    ) -> String? {
        SparkDashboardOwnerPresentation.openWebUIInstallBlocker(
            offered: true,
            installed: false,
            availableRevision: "2026-08-29.1",
            email: email,
            name: name,
            password: password,
            acceptedRevision: accepted
        )
    }
    let password = String(repeating: "a", count: 20)

    // UX-11: the email is optional; only a malformed one blocks the install.
    #expect(blocker() == "Enter a name for the administrator.")
    #expect(blocker(email: "no-at-sign") == "Enter a full email address, or leave it blank.")
    #expect(SparkDashboardOwnerPresentation.openWebUIAdminEmail("  ") == "owner@spark.local")
    #expect(
        SparkDashboardOwnerPresentation.openWebUIAdminEmail("me@example.com") == "me@example.com"
    )
    #expect(blocker(email: "me@example.com") == "Enter a name for the administrator.")
    #expect(
        blocker(email: "me@example.com", name: "alex")
            == "The password must be 16 to 128 characters."
    )
    #expect(
        blocker(email: "me@example.com", name: "alex", password: password)
            == "Accept signed recipe 2026-08-29.1 to continue."
    )
    #expect(
        blocker(
            email: "me@example.com",
            name: "alex",
            password: password,
            accepted: "2026-08-29.1"
        ) == nil
    )
    #expect(
        SparkDashboardOwnerPresentation.openWebUIInstallBlocker(
            offered: false,
            installed: false,
            availableRevision: nil,
            email: "me@example.com",
            name: "alex",
            password: password,
            acceptedRevision: nil
        ) == "This Spark has not offered the Open WebUI recipe yet."
    )
}

@MainActor
@Test func bundledPresetUpdateUsesTheReviewedPresenceAuthorizedFlow() async throws {
    let runtime = DashboardTestFakeRuntimeReader(catalogueRefresh: true)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareBundledPresetUpdate()
    let confirmation = try #require(model.pendingCatalogueRefresh)
    #expect(confirmation.fileName == "SparkPilot model presets")
    let json = try #require(
        try JSONSerialization.jsonObject(with: Data(confirmation.candidateJSON.utf8))
            as? [String: Any]
    )
    #expect(json["signature"] != nil)
    #expect(await runtime.recordedCatalogueRefresh() == nil)
    #expect(await presence.count() == 0)
    await model.applyCatalogueRefresh()
    #expect(await presence.count() == 1)
    #expect(await runtime.recordedCatalogueRefresh()?.candidateJson == confirmation.candidateJSON)
}

@MainActor
@Test func existingOpenWebUIConnectsOnItsPortWithoutChangingCredentials() async {
    let runtime = DashboardTestFakeRuntimeReader(optionalServices: true)
    let presence = DashboardTestDashboardPresenceAuthorizer()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        tlsFingerprint: String(repeating: "a", count: 64),
        operationStore: DashboardTestTestOperationStore(),
        userPresenceAuthorizer: presence,
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await model.refresh()
    #expect(model.openWebUIPort == "18080")
    model.adoptExistingOpenWebUI = true
    model.openWebUIPort = "9090"
    model.acceptOpenWebUIRecipe(true)
    #expect(model.canInstallOpenWebUI)
    await model.installOpenWebUI()
    let request = await runtime.recordedOpenWebUIInstall()
    #expect(request?.port == 9090)
    #expect(request?.adoptExisting == true)
    #expect(request?.adminEmail == nil)
    #expect(request?.adminPassword == nil)
    #expect(await presence.count() == 1)
}

@MainActor
@Test(arguments: ["0", "65536", "7443", "7444", "18081", "18142", "9090; id"])
func openWebUIPortRejectsReservedAndInvalidValues(port: String) async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(optionalServices: true),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )
    await model.refresh()
    model.adoptExistingOpenWebUI = true
    model.openWebUIPort = port
    model.acceptOpenWebUIRecipe(true)
    #expect(!model.canInstallOpenWebUI)
}

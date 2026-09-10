import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@MainActor
@Test func reopeningAReusedSettingsModelRechecksForARequiredRuntimeUpdate() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: true,
        telemetryMode: .available
    )
    let settings = SparkSettingsModel(
        route: URL(string: "https://spark-workshop.local:7443")!,
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        administratorUsername: "example-spark",
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    await settings.loadIfNeeded()
    #expect(!settings.runtimeUpgradeRequired)

    await runtime.setSettingsRoutesAvailable(false)
    await settings.loadIfNeeded()

    #expect(settings.runtimeUpgradeRequired)
    #expect(settings.canInstallBundledRuntime)
}

@MainActor
@Test func pairedAdministratorRepairsAnOldRuntimeWithoutAnSshPassword() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available,
        runtimeUpdateMode: .succeeds
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()

    await settings.repairRequiredRuntime()

    let requests = await runtime.recordedRuntimeUpdateRequests()
    let request = try #require(requests.first)
    #expect(request.runtimeReleaseId == "dev-0.1.0")
    #expect(!settings.runtimePasswordFallbackRequired)
}

@MainActor
@Test func runtimeRepairOnlyRequestsSshPasswordWhenTheSignedRouteIsMissing() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available,
        runtimeUpdateMode: .missing
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()

    await settings.repairRequiredRuntime()

    #expect(settings.runtimePasswordFallbackRequired)
    #expect(settings.errorMessage?.contains("one-time") == true)
}

@MainActor
@Test func legacyRuntimeSchedulingFailureOffersTheOneTimeRepairPath() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available,
        runtimeUpdateMode: .schedulingBackendFailure,
        publishesSignedRuntimeUpdateCapability: false
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()

    await settings.repairRequiredRuntime()

    #expect(settings.runtimePasswordFallbackRequired)
    #expect(settings.errorMessage?.contains("one-time") == true)
    #expect(settings.errorMessage?.contains("older runtime") == true)
    #expect(settings.errorMessage?.contains("connection") != true)
}

@MainActor
@Test func aCurrentRuntimeThatCannotScheduleTheUpdateNamesItsHelperNotItsAge() async throws {
    // Report signed-update scheduling failure as a runtime fault without mislabelling the capable runtime as older.
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available,
        runtimeUpdateMode: .schedulingBackendFailure
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()
    #expect(settings.signedRuntimeUpdateSupported == true)

    await settings.repairRequiredRuntime()

    #expect(settings.runtimePasswordFallbackRequired)
    #expect(settings.errorMessage?.contains("privileged helper") == true)
    #expect(settings.errorMessage?.contains("RUNTIME_UPDATE_SCHEDULING_UNAVAILABLE") == true)
    #expect(settings.errorMessage?.contains("one-time") == true)
    #expect(settings.errorMessage?.contains("older runtime") != true)
    #expect(settings.passwordFallbackExplanation.contains("privileged helper"))
    #expect(settings.runtimeUpgradeStage == nil, "progress is cleared once the attempt ends")
}

@MainActor
@Test func aSparkRefusalNamesItsReasonInsteadOfBlamingTheConnection() async throws {
    // Present stable update refusal reasons without displaying untrusted server prose.
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available,
        runtimeUpdateMode: .refusedByTheSpark
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()

    await settings.repairRequiredRuntime()

    #expect(!settings.runtimePasswordFallbackRequired, "a 409 refusal is not a missing route")
    #expect(settings.errorMessage?.contains("INFERENCE_MUST_BE_UNLOADED") == true)
    #expect(settings.errorMessage?.contains("unload the active model") != true)
    #expect(settings.errorMessage?.contains("Check the connection") != true)
}

@MainActor
@Test func oneTimeRuntimeInstallNamesARejectedPasswordPrecisely() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .available
    )
    let settings = SparkSettingsModel(
        route: URL(string: "https://spark-workshop.local:7443")!,
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestFailingRuntimeUpgradeInstaller(
            failure: .authenticationFailed
        ),
        administratorUsername: "example-spark",
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    settings.administratorPassword = "wrong-password"

    await settings.installRequiredRuntime()

    #expect(settings.errorMessage?.contains("rejected that account password") == true)
    #expect(!settings.errorMessage!.contains("could not be installed"))
}

@MainActor
@Test func reachableOldRuntimeStillOffersUpdateWhenItsMissingRoutesCloseTheRequest() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        settingsRoutesFailAsTransport: true,
        telemetryMode: .available,
        publishesSignedRuntimeUpdateCapability: false
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.runtimeUpgradeRequired)
    #expect(settings.canInstallBundledRuntime)
    #expect(settings.errorMessage == nil)
    #expect(
        SparkDashboardOwnerPresentation.runtimeUpdateNotice(
            canInstallBundledRuntime: settings.canInstallBundledRuntime
        ) != nil
    )
}

@MainActor
@Test func aCurrentRuntimeWhoseSettingsRequestDropsIsNotToldToUpdate() async throws {
    // Treat status-less failure on a known signed-update endpoint as a dropped connection rather than forcing password installation.
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        settingsRoutesFailAsTransport: true,
        telemetryMode: .available
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.signedRuntimeUpdateSupported == true)
    #expect(!settings.runtimeUpgradeRequired)
    #expect(!settings.canInstallBundledRuntime)
    #expect(settings.errorMessage?.contains("Check the connection") == true)
}

@Test func runtimeUpgradeStagesCountUpwardsThroughTheInstallerSequence() {
    // Present step counts and elapsed time throughout runtime upgrade progress.
    let start = Date(timeIntervalSince1970: 0)
    let preparing = RuntimeUpgradeStage.sshPreparing(startedAt: start)
    let package = RuntimeUpgradeStage.ssh(.installPackage, startedAt: start)
    let waiting = RuntimeUpgradeStage.sshWaitingForRuntime(startedAt: start)

    #expect(preparing.step == 1)
    #expect(RuntimeUpgradeStage.ssh(.receiveFile(.package), startedAt: start).step < package.step)
    #expect(package.step < RuntimeUpgradeStage.ssh(.enableRuntime, startedAt: start).step)
    #expect(package.label == "Step 11 of 16")
    #expect(waiting.step == waiting.total)
    #expect(waiting.fraction == 1)
    #expect(
        RuntimeUpgradeStage.signed(operationStage: "runtime_update_restarting", startedAt: start)?
            .step == 5
    )
    #expect(RuntimeUpgradeStage.signed(operationStage: "something_else", startedAt: start) == nil)
}

@MainActor
@Test func oldRuntimeNetworkFailureNamesTheRequiredUpdate() async {
    let model = SparkNetworkStatusModel(
        route: URL(string: "https://spark-workshop.local:7443")!,
        runtime: SettingsCompositionTestMissingNetworkStatusRuntime()
    )

    await model.refresh()

    #expect(
        model.errorMessage
            == "Update SparkPilot features in Spark settings before opening Network status."
    )
}

@Test func runtimeUpgradeUsesOneVisibleProgressLabel() {
    let global = SparkSettingsProgressPresentation.globalMutationLabel(
        activeMutation: "Installing the required Spark Runtime",
        runtimeUpgradeProgress: "Removing temporary files"
    )

    #expect(global == nil)
}

@MainActor
@Test func matchingBundledRuntimeIsNotReportedAsAnUpdate() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.bundledRuntimeReleaseID == "dev-0.1.0")
    #expect(!settings.runtimeUpdateAvailable)
    #expect(!settings.canInstallBundledRuntime)
}

@MainActor
@Test func matchingLegacyRuntimeWithoutSignedUpdateCapabilityOffersBundledRepair() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available,
        publishesSignedRuntimeUpdateCapability: false
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.runtimeUpgradeRequired)
    #expect(settings.canInstallBundledRuntime)
}

@MainActor
@Test func newerBundledRuntimeIsReportedAsAnUpdate() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.2.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.bundledRuntimeReleaseID == "dev-0.2.0")
    #expect(settings.runtimeUpdateAvailable)
    #expect(settings.canInstallBundledRuntime)
}

@MainActor
@Test func olderBundledRuntimeIsNeverOfferedAsAnUpdate() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.0.9")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(!settings.runtimeUpdateAvailable)
    #expect(!settings.canInstallBundledRuntime)
}

@MainActor
@Test func definitivePresenceEnrollmentRejectionRequiresANewIdempotencyKey() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .presenceEnrollmentRejected
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: []
    )

    await settings.connectSelectedWifi()
    await settings.connectSelectedWifi()

    let keys = await runtime.enrollmentKeys()
    #expect(keys.count == 2)
    #expect(keys[0] != keys[1])
}

@MainActor
@Test func ambiguousPresenceEnrollmentFailureRetainsTheIdempotencyKey() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .presenceEnrollmentUnavailable
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: []
    )

    await settings.connectSelectedWifi()
    await settings.connectSelectedWifi()

    let keys = await runtime.enrollmentKeys()
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
}

@MainActor
@Test(arguments: [
    ("0.1.13", true),
    ("0.1.13-0qa20260907.2", true),
    ("0.1.13-0qa20260907.3", false),
    ("0.1.13-0qa20260907.10", false),
    ("0.1.14", false),
])
func newerBundledPackageRevisionIsOfferedToAnExistingSpark(
    installed: String,
    updateAvailable: Bool
) async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        runtimeVersion: installed,
        telemetryMode: .available
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(
            releaseID: "dev-0.1.13-0qa20260907.3"
        )
    )
    try await settingsCompositionTestOpenComposedDashboard(model)
    let settings = try #require(model.settingsModel)
    await settings.refresh()
    #expect(settings.runtimeUpdateAvailable == updateAvailable)
    #expect(settings.canInstallBundledRuntime == updateAvailable)
}

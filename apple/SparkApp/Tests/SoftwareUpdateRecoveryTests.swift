import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func softwareUpdateRecoveryDoesNotReinstallTheCurrentStagedRuntime() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available,
        runtimeUpdateMode: .succeeds,
        softwareUpdates: .init(
            checkedAt: "2026-09-04T23:20:00Z",
            systemPackagesAvailable: 0,
            firmwareUpdatesAvailable: 0,
            runtimeReleaseId: "dev-0.1.0",
            rebootRequired: true
        )
    )
    let model = SparkSettingsModel(
        route: URL(string: "https://update-recovery.test:7443")!,
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    await model.refresh()
    await model.installAvailableUpdates()
    #expect(await runtime.recordedRuntimeUpdateRequests().isEmpty)
}

@MainActor
@Test func softwareUpdateRecoveryKeepsAnUnconfirmedInstallVisibleAfterRefreshAndCheck() async throws
{
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available,
        runtimeUpdateMode: .leaseExpired,
        softwareUpdates: .init(
            checkedAt: "2026-09-04T23:19:00Z",
            systemPackagesAvailable: 3,
            firmwareUpdatesAvailable: 0,
            runtimeReleaseId: nil,
            rebootRequired: false
        )
    )
    let model = SparkSettingsModel(
        route: URL(string: "https://expired-update.test:7443")!,
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0"),
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    await model.refresh()
    await model.installAvailableUpdates()
    #expect(model.errorMessage?.contains("could not confirm") == true)
    #expect(model.errorMessage?.contains("Nothing changed") != true)
    #expect(model.settings?.softwareUpdates.rebootRequired == true)
    await model.refresh()
    #expect(model.errorMessage?.contains("could not confirm") == true)
    await model.checkForUpdates()
    #expect(model.errorMessage?.contains("could not confirm") == true)
    #expect(model.successMessage == nil)
    #expect(await runtime.recordedRuntimeUpdateRequests().count == 1)
}

@MainActor
@Test func softwareUpdateRecoveryRefreshClearsAnOldCheckCompletion() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available
    )
    let model = SparkSettingsModel(
        route: URL(string: "https://update-check.test:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    await model.checkForUpdates()
    await model.refresh()
    #expect(model.successMessage == nil)
}

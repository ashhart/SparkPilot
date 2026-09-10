import Testing

@testable import SparkAppComposition

/// After updates install, the card's primary action is the restart that finishes them, never a dead install button.
struct SparkSettingsUpdatesPresentationTests {
    @Test func aPendingRestartWithNothingToInstallOffersTheRestart() {
        let action = SparkSettingsUpdatesPresentation.primaryAction(
            systemPackages: 0,
            firmware: 0,
            runtimeUpdateAvailable: false,
            rebootRequired: true,
            canRestart: true
        )
        #expect(action == .restart)
    }

    @Test func availableUpdatesStillInstallFirst() {
        let action = SparkSettingsUpdatesPresentation.primaryAction(
            systemPackages: 2,
            firmware: 0,
            runtimeUpdateAvailable: false,
            rebootRequired: true,
            canRestart: true
        )
        #expect(action == .install)
        #expect(
            SparkSettingsUpdatesPresentation.primaryAction(
                systemPackages: 0,
                firmware: 0,
                runtimeUpdateAvailable: true,
                rebootRequired: false,
                canRestart: false
            ) == .install
        )
    }

    @Test func aReportedReleaseIdAloneIsNotAnUpdate() {
        let action = SparkSettingsUpdatesPresentation.primaryAction(
            systemPackages: 0,
            firmware: nil,
            runtimeUpdateAvailable: false,
            rebootRequired: false,
            canRestart: true
        )
        #expect(action == .nothing)
    }

    @Test func restartDetailNamesWhatTheRestartFinishes() {
        #expect(
            SparkSettingsUpdatesPresentation.restartDetail(primary: .restart)
                == "The installed updates finish when the Spark restarts."
        )
        #expect(
            SparkSettingsUpdatesPresentation.restartDetail(primary: .nothing)
                == "Restart the Spark from its Power controls to finish the update."
        )
    }
}

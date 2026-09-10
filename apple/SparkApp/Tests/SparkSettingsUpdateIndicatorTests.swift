import SparkAPI
import Testing
@testable import SparkAppComposition

@Suite("Software update navigation")
struct SparkSettingsUpdateIndicatorTests {
    private func status(
        os: Int? = 0,
        firmware: Int? = 0,
        stagedRuntime: String? = nil
    ) -> GeneratedAPI.SoftwareUpdateStatus {
        .init(
            checkedAt: "2026-09-04T12:00:00Z",
            systemPackagesAvailable: os,
            firmwareUpdatesAvailable: firmware,
            runtimeReleaseId: stagedRuntime,
            rebootRequired: false
        )
    }

    @Test func allReportedUpdateKindsAppearWithoutLosingTheirCounts() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: status(os: 3, firmware: 1),
            runtimeUpdateAvailable: true,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == "Available")
        #expect(indicator.detail.contains("OS packages: 3 available"))
        #expect(indicator.detail.contains("Firmware: 1 available"))
        #expect(indicator.detail.contains("Spark Runtime"))
        #expect(!indicator.detail.contains("unknown"))
    }

    @Test func missingReadingsNeverBecomeZeroOrUpToDate() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: nil,
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == nil)
        #expect(indicator.detail.contains("OS update status unknown"))
        #expect(indicator.detail.contains("Firmware update status unknown"))
        #expect(!indicator.detail.contains("No updates"))
    }

    @Test func knownUpdatesRemainVisibleWhenAnotherCheckIsUnavailable() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: status(os: 1, firmware: nil),
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == "Available")
        #expect(indicator.detail.contains("OS packages: 1 available"))
        #expect(indicator.detail.contains("Firmware update status unknown"))
    }

    @Test func reportedZeroCountsDoNotShowAnUpdateBadge() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: status(),
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == nil)
        #expect(indicator.detail == "No updates reported")
    }

    @Test func requiredRuntimeSurvivesUnavailableSystemChecks() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: nil,
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: true
        )
        #expect(indicator.badge == "Required")
        #expect(indicator.detail.contains("Spark Runtime"))
        #expect(indicator.detail.contains("OS update status unknown"))
        #expect(indicator.accessibilityValue.hasPrefix("Required,"))
    }

    @Test func aStagedPackageAloneDoesNotClaimARuntimeUpgrade() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: status(stagedRuntime: "0.1.10"),
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == nil)
        #expect(!indicator.detail.contains("Spark Runtime"))
    }

    @Test func invalidNegativeCountsRemainUnknown() {
        let indicator = SparkSettingsUpdateIndicator(
            updates: status(os: -1, firmware: -2),
            runtimeUpdateAvailable: false,
            runtimeUpgradeRequired: false
        )
        #expect(indicator.badge == nil)
        #expect(indicator.detail.contains("OS update status unknown"))
        #expect(indicator.detail.contains("Firmware update status unknown"))
    }
}

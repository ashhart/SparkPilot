import Foundation
import SparkSecurity
import Testing
@testable import SparkAppComposition

struct StartupAndPairingLinkTests {
    /// Only the invitation forms the pairing validator understands become a pending payload (L-6).
    @MainActor
    @Test func pairingLinksAreRecognisedAndOtherSparkURLsIgnored() {
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "sparkpilot://pair/abc")!)
                == "sparkpilot://pair/abc"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "sparkpilot://pair-batch/xyz")!)
                == "sparkpilot://pair-batch/xyz"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "spark://pair/abc")!)
                == "spark://pair/abc"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "spark://pair-batch/xyz")!)
                == "spark://pair-batch/xyz"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "spark://other/abc")!) == nil
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(
                from: URL(string: "sparkpilot://widget?target=all")!
            )
                == nil
        )
        let navigation = SparkWidgetNavigation()
        navigation.open(URL(string: "sparkpilot://pair/abc")!)
        #expect(navigation.takePendingPairingPayload() == "sparkpilot://pair/abc")
        #expect(navigation.takePendingPairingPayload() == nil, "a payload is handed over once")
    }

    /// QA-04: an invitation minted before the qualified scheme existed, and one a keyboard capitalised, still reach the pairing screen.
    @MainActor
    @Test func olderAndCapitalisedPairingLinksAreStillRecognised() {
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "SparkPilot://Pair/abc")!)
                == "SparkPilot://Pair/abc"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "Spark://pair-batch/xyz")!)
                == "Spark://pair-batch/xyz"
        )
        #expect(
            SparkWidgetNavigation.pairingPayload(from: URL(string: "sparkpilotx://pair/abc")!)
                == nil
        )
    }

    /// errSecMissingEntitlement gets retry advice; other Keychain failures keep the do-not-reset advice (L-3).
    @Test func missingEntitlementIsClassifiedAsTransient() {
        #expect(
            BootstrapComposition.isMissingEntitlement(DeviceKeyError.keychainLookupFailed(-34018))
        )
        #expect(BootstrapComposition.isMissingEntitlement(KeychainError.unexpectedStatus(-34018)))
        #expect(
            !BootstrapComposition.isMissingEntitlement(DeviceKeyError.keychainLookupFailed(-25300))
        )
        #expect(!BootstrapComposition.isMissingEntitlement(KeychainError.alreadyExists))
        let transient = BootstrapComposition.failureDescription(
            for: DeviceKeyError.keychainLookupFailed(-34018)
        )
        #expect(transient.contains("retry"))
        #expect(!transient.contains("Unlock this device"))
    }
}

import Foundation
import SparkSecurity
import Testing

@testable import SparkAppComposition

@Test func startupTrustFailureNamesTheTrustRoot() {
    let message = BootstrapComposition.failureDescription(
        for: BootstrapComposition.CompositionError.trustRootMissing
    )
    #expect(message.contains("release trust root"))
}

@Test func startupKeychainFailureNamesDeviceIdentityNotReleaseTrust() {
    for error: any Error in [
        DeviceKeyError.keychainLookupFailed(-34018),
        KeychainError.unexpectedStatus(-34018),
    ] {
        let message = BootstrapComposition.failureDescription(for: error)
        #expect(message.contains("device identity"))
        #expect(!message.contains("release trust root"))
    }
}

@Test func startupUnknownFailureDoesNotInventATrustRootCause() {
    let message = BootstrapComposition.failureDescription(for: CocoaError(.fileReadUnknown))
    #expect(message.contains("could not finish starting"))
    #expect(!message.contains("release trust root"))
}

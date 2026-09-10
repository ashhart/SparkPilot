import Foundation
import Testing

@testable import SparkBootstrap

@Test func joinCodeMustContainExactlySixDigits() async {
    let redeemer = HTTPSPairingJoinCodeRedeemer()
    await #expect(throws: PairingJoinCodeError.invalidCode) {
        _ = try await redeemer.redeem(
            code: "12345",
            route: URL(string: "https://spark.local:7443")!,
            trustedFingerprint: String(repeating: "a", count: 64)
        )
    }
}

@Test func joinCodeIsNeverSentOverPlainHTTP() async {
    let redeemer = HTTPSPairingJoinCodeRedeemer()
    await #expect(throws: PairingJoinCodeError.insecureRoute) {
        _ = try await redeemer.redeem(
            code: "123456",
            route: URL(string: "http://spark.local:7443")!,
            trustedFingerprint: String(repeating: "a", count: 64)
        )
    }
}

@Test func joinCodeRejectsMissingOrTruncatedTrustBeforeConnecting() async {
    for pin in ["", "0123abcd", String(repeating: "g", count: 64)] {
        await #expect(throws: PairingJoinCodeError.invalidFingerprint) {
            _ = try await HTTPSPairingJoinCodeRedeemer().redeem(
                code: "123456",
                route: URL(string: "https://spark.invalid:7443")!,
                trustedFingerprint: pin
            )
        }
    }
    #expect(
        HTTPSPairingJoinCodeRedeemer.normalizedFingerprint(
            String(repeating: "AA:", count: 31) + "AA"
        ) == String(repeating: "a", count: 64)
    )
}

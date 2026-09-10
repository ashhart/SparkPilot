import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

private func pairingPackage() -> AdditionalDevicePairingPackage {
    AdditionalDevicePairingPackage(
        nodeName: "spark-a1b2",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: String(repeating: "c", count: 64),
        invitation: PairingInvitation(
            version: 1,
            nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
            authorityFingerprint:
                "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2",
            invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            nonce: "bm9uY2U",
            role: "administrator",
            expiresAt: "2099-01-01T00:00:00Z",
            signature: "c2lnbmF0dXJl",
            localEndpoint: "https://spark-a1b2.local:7443"
        )
    )
}

/// QA-04: a fresh invitation carries the scheme only this app registers, so another installed build cannot claim the link.
@Test func aFreshInvitationIsMintedUnderTheAppsOwnScheme() throws {
    let payload = try pairingPackage().qrPayload()

    #expect(payload.hasPrefix("sparkpilot://pair/"))
    #expect(!payload.hasPrefix("spark://pair/"))
}

/// QA-04: invitations already in the wild under the unqualified scheme keep working.
@Test func anInvitationMintedUnderTheOldSchemeIsStillAccepted() throws {
    let package = pairingPackage()
    let minted = try package.qrPayload()
    let body = String(minted.dropFirst("sparkpilot://pair/".count))

    let legacy = try AdditionalDevicePairingPackage(qrPayload: "spark://pair/" + body)

    #expect(legacy == package)
}

/// QA-05: a keyboard that capitalises the first letter of a typed invitation must not make it unreadable.
@Test func aCapitalisedInvitationIsReadUnderEitherScheme() throws {
    let package = pairingPackage()
    let minted = try package.qrPayload()
    let body = String(minted.dropFirst("sparkpilot://pair/".count))

    #expect(try AdditionalDevicePairingPackage(qrPayload: "SparkPilot://pair/" + body) == package)
    #expect(try AdditionalDevicePairingPackage(qrPayload: "Spark://pair/" + body) == package)
    #expect(try AdditionalDevicePairingPackage(qrPayload: "SPARK://PAIR/" + body) == package)
}

/// QA-04: an invitation for a different route, or no route at all, is still refused.
@Test func anUnrelatedLinkIsNotReadAsAnInvitation() {
    #expect(!PairingLinkScheme.carries("sparkpilot://widget?target=all", route: "pair/"))
    #expect(!PairingLinkScheme.carries("spark://other/abc", route: "pair/"))
    #expect(!PairingLinkScheme.carries("sparkpilot://pair-batch/abc", route: "pair/"))
    #expect(PairingLinkScheme.carries("sparkpilot://pair-batch/abc", route: "pair-batch/"))
    #expect(PairingLinkScheme.body(of: "Spark://Pair/xyz", route: "pair/") == "xyz")
}

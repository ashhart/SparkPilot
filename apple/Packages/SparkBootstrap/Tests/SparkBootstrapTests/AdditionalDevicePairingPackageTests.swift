import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

@Test func additionalDevicePairingPackageRoundTripsWithoutASecret() throws {
    let package = AdditionalDevicePairingPackage(
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

    let payload = try package.qrPayload()
    let decoded = try AdditionalDevicePairingPackage(qrPayload: payload)

    #expect(decoded == package)
    #expect(payload.hasPrefix("sparkpilot://pair/"))
    #expect(!payload.lowercased().contains("password"))
    #expect(!payload.lowercased().contains("private_key"))
}

@Test func additionalDevicePackageRejectsUnsafeTrustMaterial() throws {
    let invitation = PairingInvitation(
        version: 1,
        nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
        authorityFingerprint: String(repeating: "b", count: 64),
        invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nonce: "bm9uY2U",
        role: "administrator",
        expiresAt: "2099-01-01T00:00:00Z",
        signature: "c2lnbmF0dXJl"
    )
    let malformed = AdditionalDevicePairingPackage(
        nodeName: "spark-a1b2",
        tlsFingerprint: "short",
        authorityPublicKey: String(repeating: "c", count: 64),
        invitation: invitation
    )

    #expect(throws: AdditionalDevicePairingPackageError.self) {
        _ = try malformed.qrPayload()
    }
}

private func pairingInvitationFixture() -> PairingInvitation {
    PairingInvitation(
        version: 1,
        nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
        authorityFingerprint:
            "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2",
        invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nonce: "bm9uY2U",
        role: "developer",
        expiresAt: "2099-01-01T00:00:00Z",
        signature: "c2lnbmF0dXJl"
    )
}

@Test func theOwnerDeviceCanCarryTheAddressItReachedTheSparkOn() throws {
    // Supply an endpoint hint when runtime invitations contain no local endpoint and Bonjour is unresolved.
    let package = AdditionalDevicePairingPackage(
        nodeName: "spark-a1b2",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: String(repeating: "c", count: 64),
        invitation: pairingInvitationFixture(),
        localHint: "https://spark-a1b2.local:7443"
    )

    let decoded = try AdditionalDevicePairingPackage(qrPayload: try package.qrPayload())

    #expect(decoded.localHintURL == URL(string: "https://spark-a1b2.local:7443"))
    #expect(decoded == package)
}

@Test func anAddressHintMustBeAPlainHTTPSAddress() {
    for hint in [
        "http://spark-a1b2.local:7443",
        "https://user:secret@spark-a1b2.local:7443",
        "not a url at all",
        "https:///nohost",
    ] {
        let package = AdditionalDevicePairingPackage(
            nodeName: "spark-a1b2",
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityPublicKey: String(repeating: "c", count: 64),
            invitation: pairingInvitationFixture(),
            localHint: hint
        )
        #expect(throws: AdditionalDevicePairingPackageError.invalidLocalHint) {
            _ = try package.qrPayload()
        }
    }
}

@Test func aPackageWithoutAnAddressHintStillDecodes() throws {
    // Older payloads carry no hint; they must keep working.
    let package = AdditionalDevicePairingPackage(
        nodeName: "spark-a1b2",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: String(repeating: "c", count: 64),
        invitation: pairingInvitationFixture()
    )

    let decoded = try AdditionalDevicePairingPackage(qrPayload: try package.qrPayload())
    #expect(decoded.localHint == nil)
    #expect(decoded.localHintURL == nil)
}

/// Accept nanosecond-precision invitation expiry while retaining fail-closed parsing.
@Test func aFreshInvitationWithFractionalSecondsIsStillPlausible() {
    let package = pairingPackage(expiresAt: "2026-08-29T23:45:12.123456789Z")
    let justBefore = Date(timeIntervalSince1970: 1_787_010_312)

    #expect(package.isLocallyPlausible(now: justBefore))
}

@Test func anExpiredInvitationWithFractionalSecondsIsRefused() {
    let package = pairingPackage(expiresAt: "2026-08-29T23:45:12.123456789Z")
    let wellAfter = Date(timeIntervalSince1970: 1_790_000_000)

    #expect(!package.isLocallyPlausible(now: wellAfter))
}

/// Continue accepting whole-second RFC 3339 timestamps alongside fractional ones.
@Test func wholeSecondExpiriesRemainPlausible() {
    let package = pairingPackage(expiresAt: "2099-01-01T00:00:00Z")

    #expect(package.isLocallyPlausible(now: Date(timeIntervalSince1970: 1_787_010_312)))
}

/// Reject invitations whose lifetime cannot be established.
@Test func anUnreadableExpiryIsNotPlausible() {
    let package = pairingPackage(expiresAt: "whenever")

    #expect(!package.isLocallyPlausible(now: Date(timeIntervalSince1970: 0)))
}

private func pairingPackage(expiresAt: String) -> AdditionalDevicePairingPackage {
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
            expiresAt: expiresAt,
            signature: "c2lnbmF0dXJl",
            localEndpoint: "https://spark-a1b2.local:7443"
        )
    )
}

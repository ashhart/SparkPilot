import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

private let authorityKey = String(repeating: "c", count: 64)

/// The SHA-256 of the authority key bytes, which the package validator insists the fingerprint matches.
private let authorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"

private func sharedAccessSummary() -> SharedAccessSummary {
    SharedAccessSummary(
        displayName: "Sam",
        allowedModels: ["qwen3-8b"],
        allowedHours: (0..<7).map {
            GuestDaySchedule(
                weekday: $0,
                windows: [GuestHourWindow(startMinute: 1080, endMinute: 1320)]
            )
        },
        timeZone: "Europe/London",
        maxConcurrentRequests: 1,
        dailyTokenBudget: 20_000
    )
}

private func sharedAccessInvitation(version: Int = 2) -> PairingInvitation {
    PairingInvitation(
        version: version,
        nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
        authorityFingerprint: authorityFingerprint,
        invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nonce: "bm9uY2U",
        role: "guest",
        expiresAt: "2099-01-01T00:00:00Z",
        signature: "c2lnbmF0dXJl",
        localEndpoint: "https://alex-s-Spark-8cd8b1ab.local:7443",
        remoteEndpoint: "https://spark-example.tail1234.ts.net:7443",
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        remoteHostname: "spark-example.tail1234.ts.net",
        sharedAccess: sharedAccessSummary()
    )
}

private func sharedAccessPackage(version: Int = 2) -> AdditionalDevicePairingPackage {
    AdditionalDevicePairingPackage(
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: authorityKey,
        invitation: sharedAccessInvitation(version: version),
        localHint: "https://alex-s-Spark-8cd8b1ab.local:7443"
    )
}

@Test func aSharedAccessLinkRoundTripsWithItsRoutesAndLimits() throws {
    let payload = try sharedAccessPackage().qrPayload()
    #expect(payload.hasPrefix("sparkpilot://pair/"))

    let decoded = try AdditionalDevicePairingPackage(qrPayload: payload)
    #expect(decoded == sharedAccessPackage())
    #expect(decoded.invitation.version == 2)
    #expect(decoded.invitation.isSharedAccess)
    #expect(decoded.invitation.nodeName == "Alex's Spark")
    #expect(decoded.invitation.tlsFingerprint == String(repeating: "a", count: 64))
    #expect(decoded.invitation.remoteHostname == "spark-example.tail1234.ts.net")

    let limits = try #require(decoded.invitation.sharedAccess)
    #expect(limits.displayName == "Sam")
    #expect(limits.allowedModels == ["qwen3-8b"])
    #expect(limits.dailyTokenBudget == 20_000)
    #expect(limits.timeZone == "Europe/London")
    #expect(limits.allowedHours.count == 7)
    #expect(limits.hasOpenHours)
}

@Test func anOlderVersionOnePairingLinkIsStillAccepted() throws {
    let package = AdditionalDevicePairingPackage(
        nodeName: "spark-a1b2",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: authorityKey,
        invitation: PairingInvitation(
            version: 1,
            nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
            authorityFingerprint: authorityFingerprint,
            invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            nonce: "bm9uY2U",
            role: "user",
            expiresAt: "2099-01-01T00:00:00Z",
            signature: "c2lnbmF0dXJl"
        )
    )
    let decoded = try AdditionalDevicePairingPackage(qrPayload: try package.qrPayload())
    #expect(decoded.invitation.version == 1)
    #expect(decoded.invitation.sharedAccess == nil)
    #expect(!decoded.invitation.isSharedAccess)
}

@Test func anUnknownInvitationVersionIsRefused() throws {
    #expect(throws: AdditionalDevicePairingPackageError.self) {
        _ = try sharedAccessPackage(version: 3).qrPayload()
    }
}

@Test func theSignedLimitsAreWhatTheCanonicalFormCovers() throws {
    let bootstrap = try sharedAccessPackage().bootstrapResult()
    let payload = try PairingInvitationPayload(json: bootstrap.invitation)
    let canonical = String(decoding: payload.canonicalBytes, as: UTF8.self)

    #expect(canonical.contains("\"node_name\":\"Alex's Spark\""))
    #expect(canonical.contains("\"remote_hostname\":\"spark-example.tail1234.ts.net\""))
    #expect(canonical.contains("\"shared_access\":{\"display_name\":\"Sam\""))
    #expect(canonical.contains("\"daily_token_budget\":20000"))
    #expect(
        canonical.hasSuffix(",\"signature\":null}"),
        "the signature member stays last, so version 1 bytes are unchanged"
    )
}

@Test func aSharedAccessSummaryWithNoOpenHoursSaysSo() {
    var limits = sharedAccessSummary()
    limits.allowedHours = (0..<7).map { GuestDaySchedule(weekday: $0, windows: []) }
    #expect(!limits.hasOpenHours)
    #expect(SharedAccessSummary.allHours().allSatisfy { $0.windows.count == 1 })
}

import Foundation
import Testing

@testable import SparkSecurity

private let tlsFingerprint = String(repeating: "a", count: 64)
// Use a corresponding authority key and SHA-256 fingerprint in trust-store fixtures.
private let authorityPublicKey = String(repeating: "c", count: 64)
private let authorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"
/// A different authority, and the fingerprint that actually belongs to it.
let otherAuthorityPublicKey = String(repeating: "d", count: 64)
let otherAuthorityFingerprint =
    "2b26816b927877095c29b14358af3c137109084ba54aa6aa6e19734940d7ae98"
private let nodeID = "6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f"
private let moment = Date(timeIntervalSince1970: 1_787_000_000)

private func trust(
    nodeID: String = nodeID,
    tls: String = tlsFingerprint,
    authority: String = authorityFingerprint,
    authorityKey: String = authorityPublicKey
) -> NodeTrust {
    NodeTrust(
        nodeID: nodeID,
        nodeName: "Spark",
        tlsFingerprint: tls,
        authorityFingerprint: authority,
        authorityPublicKey: authorityKey,
        pairedAt: moment
    )
}

@Test func whatPairingLearnedSurvivesRelaunch() throws {
    let store = InMemoryStore()
    try NodeTrustStore(store: store).remember(trust())

    // A fresh store over the same backing, as the next launch would build.
    let reloaded = try #require(try NodeTrustStore(store: store).trust(forNode: nodeID))
    #expect(reloaded.tlsFingerprint == tlsFingerprint)
    #expect(reloaded.authorityFingerprint == authorityFingerprint)
    #expect(reloaded.authorityPublicKey == authorityPublicKey)
    #expect(reloaded.nodeName == "Spark")
    #expect(reloaded.pairedAt == moment)
}

@Test func theStoredPinIsWhatASessionWouldUse() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(try store.pin(forNode: nodeID) == nil)
    try store.remember(trust())
    #expect(try store.pin(forNode: nodeID) == tlsFingerprint)
}

@Test func recordsAreKeyedByFullNodeIdentifier() throws {
    // Retain full-UUID trust identities despite colliding short Bonjour hints.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust(nodeID: "6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f"))
    try store.remember(
        trust(
            nodeID: "6b0f2f4a-0000-0000-0000-000000000000",
            tls: String(repeating: "d", count: 64)
        )
    )
    #expect(try store.pin(forNode: "6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f") == tlsFingerprint)
    #expect(
        try store.pin(forNode: "6b0f2f4a-0000-0000-0000-000000000000")
            == String(repeating: "d", count: 64)
    )
}

@Test func aChangedCertificateIsRefusedRatherThanQuietlyAccepted() throws {
    // Refuse changed certificates for an existing pin instead of silently overwriting trust.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())

    let impostor = String(repeating: "e", count: 64)
    #expect(
        throws: NodeTrustError.fingerprintChanged(
            nodeID: nodeID,
            expected: tlsFingerprint,
            presented: impostor
        )
    ) {
        try store.remember(trust(tls: impostor))
    }
    #expect(try store.pin(forNode: nodeID) == tlsFingerprint, "the original pin is untouched")
}

@Test func forgettingANodeIsTheDeliberateWayBack() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())
    try store.forget(nodeID: nodeID)
    #expect(try store.trust(forNode: nodeID) == nil)

    // Only after that may a different certificate be recorded.
    let rebuilt = String(repeating: "f", count: 64)
    try store.remember(trust(tls: rebuilt))
    #expect(try store.pin(forNode: nodeID) == rebuilt)
}

@Test func rememberingTheSamePinAgainIsHarmless() throws {
    // Re-pairing the same device to the same node must not look like an attack.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())
    try store.remember(trust())
    #expect(try store.pin(forNode: nodeID) == tlsFingerprint)
}

@Test func aFingerprintThatIsNotADigestIsRefused() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    for bad in ["", "abc", String(repeating: "a", count: 63), String(repeating: "A", count: 64)] {
        #expect(throws: NodeTrustError.malformedFingerprint(bad)) {
            try store.remember(trust(tls: bad))
        }
    }
}

@Test func theTwoFingerprintsMayNotBeTheSameValue() throws {
    // Reject a pairing-authority fingerprint supplied as a certificate pin.
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(throws: NodeTrustError.self) {
        try store.remember(trust(tls: tlsFingerprint, authority: tlsFingerprint))
    }
}

@Test func nodeTrustDoesNotShareStorageWithTheDeviceKey() {
    #expect(NodeTrustStore.service != SoftwareSigner.service)
}

// MARK: - Identity changes, in either half

@Test func aChangedAuthorityIsRefusedEvenWhenTheCertificateMatches() throws {
    // Reject a changed authority even when the TLS certificate remains the same.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())

    // Use internally consistent replacement authority material so the test reaches the changed-authority check.
    #expect(
        throws: NodeTrustError.authorityChanged(
            nodeID: nodeID,
            expected: authorityFingerprint,
            presented: otherAuthorityFingerprint
        )
    ) {
        try store.remember(
            trust(authority: otherAuthorityFingerprint, authorityKey: otherAuthorityPublicKey)
        )
    }
    let held = try #require(try store.trust(forNode: nodeID))
    #expect(held.authorityFingerprint == authorityFingerprint, "the original authority is kept")
}

@Test func aChangedAuthorityKeyIsRefusedEvenWhenBothFingerprintsMatch() throws {
    // Reject trust records whose authority key and fingerprint disagree.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())

    let substituted = NodeTrust(
        nodeID: nodeID,
        nodeName: "Spark",
        tlsFingerprint: tlsFingerprint,
        authorityFingerprint: authorityFingerprint,
        authorityPublicKey: String(repeating: "7", count: 64),
        pairedAt: moment
    )
    #expect(throws: NodeTrustError.self) { try store.remember(substituted) }
    #expect(try store.trust(forNode: nodeID)?.authorityPublicKey == authorityPublicKey)
}

@Test func anAuthorityPublicKeyThatIsNotAKeyIsRefused() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    let malformed = NodeTrust(
        nodeID: nodeID,
        nodeName: "Spark",
        tlsFingerprint: tlsFingerprint,
        authorityFingerprint: authorityFingerprint,
        authorityPublicKey: "not-a-key",
        pairedAt: moment
    )
    #expect(throws: NodeTrustError.malformedFingerprint("not-a-key")) {
        try store.remember(malformed)
    }
}

// MARK: - Staging, so a successful claim cannot be stranded

@Test func stagedTrustIsNotYetTrust() throws {
    // Persist staged trust before the single-use claim without treating staging as completed pairing.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.stage(trust())

    #expect(try store.trust(forNode: nodeID) == nil, "staged is not paired")
    #expect(try store.pin(forNode: nodeID) == nil, "nothing to pin to yet")
    #expect(try store.staged(forNode: nodeID)?.tlsFingerprint == tlsFingerprint)
}

@Test func committingAStagedRecordMakesItTrust() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.stage(trust())
    let committed = try store.commitStaged(nodeID: nodeID)

    #expect(committed.tlsFingerprint == tlsFingerprint)
    #expect(try store.pin(forNode: nodeID) == tlsFingerprint)
    #expect(try store.staged(forNode: nodeID) == nil, "the staging entry is cleared")
}

@Test func aClaimThatNeverHappenedLeavesNoTrustBehind() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.stage(trust())
    try store.discardStaged(nodeID: nodeID)

    #expect(try store.staged(forNode: nodeID) == nil)
    #expect(try store.trust(forNode: nodeID) == nil)
}

@Test func committingWithoutStagingIsAnError() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(throws: NodeTrustError.self) { _ = try store.commitStaged(nodeID: nodeID) }
}

@Test func stagingMayNotOverwriteAConfirmedRecord() throws {
    // Prevent re-pairing from introducing changed identity material through staging.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())

    #expect(throws: NodeTrustError.self) {
        try store.stage(trust(tls: String(repeating: "e", count: 64)))
    }
    #expect(throws: NodeTrustError.self) {
        try store.stage(trust(authority: String(repeating: "9", count: 64)))
    }
    // Staging the same material again is a harmless no-op.
    try store.stage(trust())
    #expect(try store.pin(forNode: nodeID) == tlsFingerprint)
}

@Test func forgettingANodeClearsStagedTrustToo() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.stage(trust())
    try store.forget(nodeID: nodeID)
    #expect(try store.staged(forNode: nodeID) == nil)
}

// MARK: - Resolving a Bonjour advertisement

@Test func aDiscoveryHintResolvesToTheOneNodeThatMatches() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())
    try store.remember(
        trust(
            nodeID: "11112222-3333-4444-5555-666677778888",
            tls: String(repeating: "d", count: 64)
        )
    )

    // The TXT record carries the first eight hex characters of the node UUID.
    let resolved = try #require(try store.trust(matchingDiscoveryHint: "6b0f2f4a"))
    #expect(resolved.nodeID == nodeID)
    #expect(resolved.tlsFingerprint == tlsFingerprint)
}

@Test func aDiscoveryHintForANodeThisDeviceHasNotPairedWithResolvesToNothing() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())
    #expect(try store.trust(matchingDiscoveryHint: "deadbeef") == nil)
    #expect(
        try store.trust(matchingDiscoveryHint: "") == nil,
        "an absent TXT record is not a match"
    )
}

@Test func aHintTwoPairedNodesShareIsReportedRatherThanGuessedAt() throws {
    // Reject colliding unauthenticated discovery hints rather than choosing an arbitrary paired node.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust(nodeID: "6b0f2f4a-1111-4a5b-9d0b-0f0b0a0d0e0f"))
    try store.remember(
        trust(
            nodeID: "6b0f2f4a-2222-4a5b-9d0b-0f0b0a0d0e0f",
            tls: String(repeating: "d", count: 64)
        )
    )

    #expect(throws: NodeTrustError.self) { _ = try store.trust(matchingDiscoveryHint: "6b0f2f4a") }
}

@Test func aStagedRecordIsNotDiscoverableAsAPairedNode() throws {
    // Keep staged trust non-authoritative until the node accepts the claim.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.stage(trust())
    #expect(try store.pairedNodes().isEmpty)
    #expect(try store.trust(matchingDiscoveryHint: "6b0f2f4a") == nil)
}

// MARK: - The two authority fields have to describe the same key

@Test func anAuthorityKeyThatDoesNotHashToItsFingerprintIsRefused() throws {
    // Reject mismatched authority keys and fingerprints before persistence.
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(throws: NodeTrustError.self) {
        try store.remember(trust(authorityKey: otherAuthorityPublicKey))
    }
    #expect(try store.trust(forNode: nodeID) == nil, "nothing was written")
}

@Test func aMismatchedAuthorityPairCannotBeStagedEither() throws {
    // Apply the same identity validation before staging writes to Keychain.
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(throws: NodeTrustError.self) {
        try store.stage(trust(authorityKey: otherAuthorityPublicKey))
    }
    #expect(try store.staged(forNode: nodeID) == nil)
}

@Test func anAuthorityKeyThatIsNotHexIsRefused() throws {
    let store = NodeTrustStore(store: InMemoryStore())
    #expect(throws: NodeTrustError.self) {
        try store.remember(trust(authorityKey: String(repeating: "z", count: 64)))
    }
}

@Test func aCorrespondingPairIsAccepted() throws {
    // Accept a matching key and fingerprint to exclude unconditional rejection.
    let store = NodeTrustStore(store: InMemoryStore())
    try store.remember(trust())
    #expect(try store.trust(forNode: nodeID)?.authorityPublicKey == authorityPublicKey)
    try store.remember(
        trust(
            nodeID: "11112222-3333-4444-5555-666677778888",
            tls: String(repeating: "e", count: 64),
            authority: otherAuthorityFingerprint,
            authorityKey: otherAuthorityPublicKey
        )
    )
    #expect(try store.pairedNodes().count == 2)
}

// MARK: - Records are checked on the way out, not only on the way in

/// Inject backing-store records directly to exercise read-time validation independently of write-time checks.
private func plant(_ json: String, service: String, account: String, into store: InMemoryStore)
    throws
{
    try store.set(Data(json.utf8), service: service, account: account)
}

private func legacyRecord(fingerprint: String, key: String) -> String {
    """
    {"nodeID":"\(nodeID)","nodeName":"Spark","tlsFingerprint":"\(tlsFingerprint)",\
    "authorityFingerprint":"\(fingerprint)","authorityPublicKey":"\(key)",\
    "pairedAt":768276000}
    """
}

@Test func aLegacyRowWhoseAuthorityPairDoesNotCorrespondIsRefusedOnRead() throws {
    // Reject inconsistent pre-existing records even if current writers would never create them.
    let backing = InMemoryStore()
    try plant(
        legacyRecord(fingerprint: authorityFingerprint, key: otherAuthorityPublicKey),
        service: NodeTrustStore.service,
        account: nodeID,
        into: backing
    )
    let store = NodeTrustStore(store: backing)
    // Assert the specific identity error so decoding failures cannot satisfy the test accidentally.
    #expect(
        throws: NodeTrustError.authorityKeyDoesNotMatchFingerprint(
            nodeID: nodeID,
            fingerprint: authorityFingerprint,
            computed: otherAuthorityFingerprint
        )
    ) { _ = try store.trust(forNode: nodeID) }
    #expect(throws: NodeTrustError.self) { _ = try store.pin(forNode: nodeID) }
}

@Test func thePlantedFixtureDecodesWhenItsAuthorityPairIsConsistent() throws {
    // Read a valid paired-key control fixture so malformed JSON cannot make rejection tests pass trivially.
    let backing = InMemoryStore()
    try plant(
        legacyRecord(fingerprint: authorityFingerprint, key: authorityPublicKey),
        service: NodeTrustStore.service,
        account: nodeID,
        into: backing
    )
    let read = try #require(try NodeTrustStore(store: backing).trust(forNode: nodeID))
    #expect(read.authorityPublicKey == authorityPublicKey)
    #expect(read.tlsFingerprint == tlsFingerprint)
}

@Test func aCorruptRowIsAnErrorRatherThanAnAbsentOne() throws {
    // Report damaged trust instead of returning nil and restarting first-pairing behavior.
    let backing = InMemoryStore()
    try plant("not json at all", service: NodeTrustStore.service, account: nodeID, into: backing)
    #expect(throws: NodeTrustError.self) {
        _ = try NodeTrustStore(store: backing).trust(forNode: nodeID)
    }
}

@Test func aStagedRowIsCheckedOnReadToo() throws {
    // Validate staged pins before they can be promoted by commitStaged.
    let backing = InMemoryStore()
    try plant(
        legacyRecord(fingerprint: authorityFingerprint, key: otherAuthorityPublicKey),
        service: NodeTrustStore.stagingService,
        account: nodeID,
        into: backing
    )
    let store = NodeTrustStore(store: backing)
    #expect(throws: NodeTrustError.self) { _ = try store.staged(forNode: nodeID) }
    #expect(throws: NodeTrustError.self) { _ = try store.commitStaged(nodeID: nodeID) }
    #expect(try store.trust(forNode: nodeID) == nil, "and it was not promoted")
}

@Test func oneBadRowFailsTheListRatherThanBeingDroppedFromIt() throws {
    // Fail paired-node enumeration rather than hiding corrupt records from discovery matching.
    let backing = InMemoryStore()
    try NodeTrustStore(store: backing).remember(trust())
    try plant(
        legacyRecord(fingerprint: authorityFingerprint, key: otherAuthorityPublicKey),
        service: NodeTrustStore.service,
        account: "99999999-0000-0000-0000-000000000000",
        into: backing
    )
    let store = NodeTrustStore(store: backing)
    #expect(throws: NodeTrustError.self) { _ = try store.pairedNodes() }
    #expect(throws: NodeTrustError.self) { _ = try store.trust(matchingDiscoveryHint: "6b0f2f4a") }
}

@Test func goodRowsStillReadBack() throws {
    // Accept valid stored records to exclude unconditional rejection.
    let backing = InMemoryStore()
    let store = NodeTrustStore(store: backing)
    try store.remember(trust())
    try store.stage(
        trust(
            nodeID: "11112222-3333-4444-5555-666677778888",
            tls: String(repeating: "e", count: 64),
            authority: otherAuthorityFingerprint,
            authorityKey: otherAuthorityPublicKey
        )
    )
    #expect(try store.trust(forNode: nodeID)?.authorityPublicKey == authorityPublicKey)
    #expect(try store.pairedNodes().count == 1)
    #expect(try store.staged(forNode: "11112222-3333-4444-5555-666677778888") != nil)
}

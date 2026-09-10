import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

private let batchIssuerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
private let batchRecipientID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
private let batchIssuer = BatchPairingParticipantIdentity(
    deviceID: batchIssuerID,
    displayName: "Owner iPhone",
    platform: "ios",
    publicKeyFingerprint: String(repeating: "a", count: 64)
)
private let batchRecipient = BatchPairingParticipantIdentity(
    deviceID: batchRecipientID,
    displayName: "Studio Mac",
    platform: "macos",
    publicKeyFingerprint: String(repeating: "b", count: 64)
)

private func batchTarget(
    number: Int,
    invitationNumber: Int? = nil,
    issuerID: UUID = batchIssuerID,
    recipient: BatchPairingParticipantIdentity = batchRecipient,
    expiresAt: String = "2099-01-01T00:00:00Z",
    bound: Bool = true
) throws -> BatchAdditionalDevicePairingTarget {
    let nodeID = String(format: "00000000-0000-4000-8000-%012d", number)
    let invitationID = String(
        format: "10000000-0000-4000-8000-%012d",
        invitationNumber ?? number
    )
    let signingKey = Curve25519.Signing.PrivateKey()
    let publicKey = signingKey.publicKey.rawRepresentation
    let authorityPublicKey = publicKey.map { String(format: "%02x", $0) }.joined()
    let authorityFingerprint = SHA256.hash(data: publicKey)
        .map { String(format: "%02x", $0) }.joined()
    var invitation = PairingInvitation(
        version: 1,
        nodeID: nodeID,
        authorityFingerprint: authorityFingerprint,
        invitationID: invitationID,
        nonce: "bm9uY2U",
        issuedByDeviceID: bound ? issuerID.uuidString.lowercased() : nil,
        recipientDeviceID: bound ? recipient.deviceID.uuidString.lowercased() : nil,
        recipientPublicKeyFingerprint: bound ? recipient.publicKeyFingerprint : nil,
        role: "administrator",
        expiresAt: expiresAt,
        signature: "cGxhY2Vob2xkZXI"
    )
    let unsigned = try PairingInvitationPayload(
        json: JSONValue.parse(JSONEncoder().encode(invitation))
    )
    invitation.signature = try signingKey.signature(for: unsigned.canonicalBytes)
        .base64URLEncodedString()
    return BatchAdditionalDevicePairingTarget(
        nodeID: nodeID,
        issuerDeviceID: issuerID,
        package: AdditionalDevicePairingPackage(
            nodeName: "spark-\(number)",
            tlsFingerprint: String(repeating: "c", count: 64),
            authorityPublicKey: authorityPublicKey,
            invitation: invitation,
            localHint: "https://192.168.1.\(number):7443"
        )
    )
}

private func batchPackage(
    issuer: BatchPairingParticipantIdentity = batchIssuer,
    recipient: BatchPairingParticipantIdentity = batchRecipient,
    targets: [BatchAdditionalDevicePairingTarget]? = nil
) throws -> BatchAdditionalDevicePairingPackage {
    try BatchAdditionalDevicePairingPackage(
        issuer: issuer,
        recipient: recipient,
        role: "administrator",
        targets: targets ?? [batchTarget(number: 1), batchTarget(number: 2)]
    )
}

@Test func boundBatchRoundTripsWithoutSecrets() throws {
    let original = try batchPackage()
    let payload = try original.payload()
    let decoded = try BatchAdditionalDevicePairingPackage(payload: payload)

    #expect(decoded == original)
    #expect(!payload.lowercased().contains("password"))
    #expect(!payload.lowercased().contains("private_key"))
}

@Test func batchRejectsDuplicateNodesAndInvitations() throws {
    let first = try batchTarget(number: 1)
    #expect(throws: BatchAdditionalDevicePairingPackageError.duplicateNode(first.id)) {
        try batchPackage(targets: [first, first]).validate()
    }

    let second = try batchTarget(number: 2, invitationNumber: 1)
    #expect(
        throws: BatchAdditionalDevicePairingPackageError.duplicateInvitation(
            first.package.invitation.invitationID
        )
    ) {
        try batchPackage(targets: [first, second]).validate()
    }
}

@Test func batchRejectsExpiredAndLegacyUnboundInvitations() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(throws: BatchAdditionalDevicePairingPackageError.self) {
        try batchPackage(
            targets: [
                batchTarget(number: 1, expiresAt: "2020-01-01T00:00:00Z"),
                batchTarget(number: 2),
            ]
        ).validate(now: now)
    }
    #expect(throws: BatchAdditionalDevicePairingPackageError.self) {
        try batchPackage(
            targets: [batchTarget(number: 1, bound: false), batchTarget(number: 2)]
        ).validate()
    }
}

@Test func tamperedOuterRecipientAndMixedBoundRecipientsAreRejected() throws {
    let attacker = BatchPairingParticipantIdentity(
        deviceID: UUID(),
        displayName: "Other Mac",
        platform: "macos",
        publicKeyFingerprint: String(repeating: "d", count: 64)
    )
    #expect(throws: BatchAdditionalDevicePairingPackageError.mixedRecipients) {
        try batchPackage(recipient: attacker).validate()
    }
    #expect(throws: BatchAdditionalDevicePairingPackageError.mixedRecipients) {
        try batchPackage(
            targets: [
                batchTarget(number: 1),
                batchTarget(number: 2, recipient: attacker),
            ]
        ).validate()
    }
}

@Test func crossOwnerTargetIsRejectedByItsSignedIssuer() throws {
    let otherOwnerID = UUID()
    #expect(throws: BatchAdditionalDevicePairingPackageError.mixedIssuers) {
        try batchPackage(
            targets: [
                batchTarget(number: 1),
                batchTarget(number: 2, issuerID: otherOwnerID),
            ]
        ).validate()
    }
}

@Test func malformedAndOversizedPayloadsFailClosed() throws {
    #expect(throws: BatchAdditionalDevicePairingPackageError.self) {
        _ = try BatchAdditionalDevicePairingPackage(payload: "spark://pair-batch/not-base64")
    }
    let oversized =
        BatchAdditionalDevicePairingPackage.schemePrefix
        + String(repeating: "a", count: 600_000)
    #expect(throws: BatchAdditionalDevicePairingPackageError.self) {
        _ = try BatchAdditionalDevicePairingPackage(payload: oversized)
    }
}

@Test func progressPersistsEveryTargetIndependently() throws {
    let backing = InMemoryStore()
    let store = SecureBatchPairingProgressStore(store: backing, service: "test.batch")
    var progress = BatchPairingProgress(package: try batchPackage())
    progress.targets[0].phase = .paired
    progress.targets[1].phase = .failed
    progress.targets[1].lastError = "Pairing failed."
    try store.save(progress)

    let loaded = try store.load(batchID: progress.batchID)
    let restored = try #require(loaded)
    #expect(restored.pairedCount == 1)
    #expect(restored.failedCount == 1)
    #expect(restored.targets[0].phase == .paired)
    #expect(restored.targets[1].phase == .failed)
}

private actor BatchClaimRecorder {
    private var attempts: [String: Int] = [:]

    func claim(_ package: AdditionalDevicePairingPackage, route _: URL) throws -> NodeTrust {
        let nodeID = package.invitation.nodeID.lowercased()
        attempts[nodeID, default: 0] += 1
        if nodeID.hasSuffix("000000000002"), attempts[nodeID] == 1 {
            throw CocoaError(.fileReadUnknown)
        }
        return NodeTrust(
            nodeID: nodeID,
            nodeName: package.nodeName,
            tlsFingerprint: package.tlsFingerprint,
            authorityFingerprint: package.invitation.authorityFingerprint,
            authorityPublicKey: package.authorityPublicKey,
            pairedAt: Date(),
            localDeviceRole: package.invitation.role
        )
    }

    func count(for nodeID: String) -> Int { attempts[nodeID.lowercased(), default: 0] }
}

@Test func partialClaimIsTruthfulAndRetryDoesNotDuplicateSuccessfulGrant() async throws {
    let package = try batchPackage()
    let payload = try package.payload()
    let recorder = BatchClaimRecorder()
    let store = SecureBatchPairingProgressStore(
        store: InMemoryStore(),
        service: "test.batch.coordinator"
    )
    let coordinator = BatchAdditionalDevicePairingCoordinator(
        identity: batchRecipient,
        store: store
    ) { package, route in
        try await recorder.claim(package, route: route)
    }

    let first = try await coordinator.accept(payload: payload)
    #expect(first.pairedCount == 1)
    #expect(first.failedCount == 1)
    #expect(!first.isFullyPaired)
    let failed = try #require(first.progress.targets.first(where: { $0.phase == .failed }))

    let retried = try await coordinator.retry(
        batchID: first.progress.batchID,
        nodeID: failed.id
    )
    #expect(retried.pairedCount == 2)
    #expect(retried.failedCount == 0)
    #expect(await recorder.count(for: package.targets[0].id) == 1)
    #expect(await recorder.count(for: package.targets[1].id) == 2)
}

@Test func recipientIdentityIsCheckedBeforeAnyClaim() async throws {
    let recorder = BatchClaimRecorder()
    let attacker = BatchPairingParticipantIdentity(
        deviceID: UUID(),
        displayName: "Other Device",
        platform: "ios",
        publicKeyFingerprint: String(repeating: "e", count: 64)
    )
    let coordinator = BatchAdditionalDevicePairingCoordinator(identity: attacker) {
        package,
        route in
        try await recorder.claim(package, route: route)
    }

    await #expect(throws: BatchPairingCoordinatorError.recipientIdentityChanged) {
        _ = try await coordinator.accept(payload: batchPackage().payload())
    }
    #expect(await recorder.count(for: try batchTarget(number: 1).id) == 0)
}

@Test func everySignedTargetIsValidatedBeforeTheFirstClaim() async throws {
    let package = try batchPackage()
    let validPayload = try package.payload()
    let encoded = String(
        validPayload.dropFirst(BatchAdditionalDevicePairingPackage.schemePrefix.count)
    )
    var base64 =
        encoded
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let data = try #require(Data(base64Encoded: base64))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var targets = try #require(object["targets"] as? [[String: Any]])
    var secondPackage = try #require(targets[1]["package"] as? [String: Any])
    var invitation = try #require(secondPackage["invitation"] as? [String: Any])
    invitation["signature"] = "dGFtcGVyZWQ"
    secondPackage["invitation"] = invitation
    targets[1]["package"] = secondPackage
    object["targets"] = targets
    let tampered = try JSONSerialization.data(withJSONObject: object)
        .base64URLEncodedString()
    let payload = BatchAdditionalDevicePairingPackage.schemePrefix + tampered

    let recorder = BatchClaimRecorder()
    let coordinator = BatchAdditionalDevicePairingCoordinator(identity: batchRecipient) {
        target,
        route in
        try await recorder.claim(target, route: route)
    }
    await #expect(throws: Error.self) {
        _ = try await coordinator.accept(payload: payload)
    }
    #expect(await recorder.count(for: package.targets[0].id) == 0)
    #expect(await recorder.count(for: package.targets[1].id) == 0)
}

private actor BatchIssueAndRevokeRecorder {
    private let invitations: [String: PairingInvitation]
    private var issueAttempts: [String: Int] = [:]
    private var revokeAttempts: [String: Int] = [:]

    init(targets: [BatchAdditionalDevicePairingTarget]) {
        self.invitations = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, $0.package.invitation) }
        )
    }

    func issue(source: BatchInvitationSource) throws -> PairingInvitation {
        issueAttempts[source.id, default: 0] += 1
        if source.id.hasSuffix("000000000002"), issueAttempts[source.id] == 1 {
            throw URLError(.networkConnectionLost)
        }
        return try #require(invitations[source.id])
    }

    func revoke(source: BatchInvitationSource) throws {
        revokeAttempts[source.id, default: 0] += 1
        if source.id.hasSuffix("000000000002"), revokeAttempts[source.id] == 1 {
            throw URLError(.networkConnectionLost)
        }
    }

    func issues(for nodeID: String) -> Int { issueAttempts[nodeID, default: 0] }
    func revokes(for nodeID: String) -> Int { revokeAttempts[nodeID, default: 0] }
}

@Test func ownerIssueRetryAndCompensatingRevokeStayPerSparkAndHonest() async throws {
    let package = try batchPackage()
    let sources = package.targets.map {
        BatchInvitationSource(
            nodeID: $0.nodeID,
            nodeName: $0.package.nodeName,
            route: $0.package.localHintURL!,
            tlsFingerprint: $0.package.tlsFingerprint,
            authorityPublicKey: $0.package.authorityPublicKey
        )
    }
    let recorder = BatchIssueAndRevokeRecorder(targets: package.targets)
    let store = SecureBatchInvitationProgressStore(
        store: InMemoryStore(),
        service: "test.batch.issue"
    )
    let coordinator = BatchDeviceInvitationCoordinator(
        issuer: batchIssuer,
        store: store,
        issue: { source, _, _, _ in try await recorder.issue(source: source) },
        revoke: { source, _, _ in try await recorder.revoke(source: source) }
    )
    let request = try BatchPairingRecipientRequest(recipient: batchRecipient).payload()

    let first = try await coordinator.create(
        recipientRequestPayload: request,
        role: "administrator",
        sources: sources
    )
    #expect(first.payload == nil)
    #expect(first.progress.issuedCount == 1)
    #expect(first.progress.failedCount == 1)

    let failed = try #require(first.progress.targets.first(where: { $0.phase == .failed }))
    let retried = try await coordinator.retry(
        batchID: first.progress.batchID,
        nodeID: failed.id
    )
    #expect(retried.payload != nil)
    #expect(retried.progress.issuedCount == 2)
    #expect(await recorder.issues(for: sources[0].id) == 1)
    #expect(await recorder.issues(for: sources[1].id) == 2)

    let partialUndo = try await coordinator.compensate(batchID: first.progress.batchID)
    #expect(partialUndo.targets.count(where: { $0.phase == .revoked }) == 1)
    #expect(partialUndo.targets.count(where: { $0.phase == .revocationFailed }) == 1)

    let completeUndo = try await coordinator.compensate(batchID: first.progress.batchID)
    #expect(completeUndo.targets.allSatisfy { $0.phase == .revoked })
    #expect(await recorder.revokes(for: sources[0].id) == 1)
    #expect(await recorder.revokes(for: sources[1].id) == 2)
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

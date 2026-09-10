import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Verifies that an owner device can create an invitation for another Apple device to pair with the same Spark.

private let invitedNodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
private let invitedTLSFingerprint = String(repeating: "a", count: 64)
private let invitedAuthorityKey = String(repeating: "c", count: 64)
private let invitedAuthorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"

private func invitedNodeTrust() -> NodeTrust {
    NodeTrust(
        nodeID: invitedNodeID,
        nodeName: "spark-ca890ed7",
        tlsFingerprint: invitedTLSFingerprint,
        authorityFingerprint: invitedAuthorityFingerprint,
        authorityPublicKey: invitedAuthorityKey,
        pairedAt: Date(timeIntervalSince1970: 1_787_000_000),
        localDeviceRole: "owner"
    )
}

private func issuedInvitation(
    nodeID: String = invitedNodeID,
    role: String = "administrator",
    expiresAt: String = "2099-01-01T00:00:00Z",
    joinCode: String? = nil
) -> PairingInvitation {
    PairingInvitation(
        version: 1,
        nodeID: nodeID,
        authorityFingerprint: invitedAuthorityFingerprint,
        invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nonce: "bm9uY2U",
        role: role,
        expiresAt: expiresAt,
        signature: "c2lnbmF0dXJl",
        joinCode: joinCode
    )
}

@MainActor
@Test func aModernSparkProducesATypeableSixDigitJoinCode() async {
    let runtime = InvitingRuntime(invitation: issuedInvitation(joinCode: "381204"))
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    #expect(model.joinCode == "381204")
    #expect(model.payload != nil, "the QR fallback remains available")
}

private actor InvitingRuntime: SparkRuntimeReading, DeviceManagementProviding {
    private(set) var requestedRole: String?
    private(set) var requestedExpiry: Int?
    private(set) var idempotencyKeys: [UUID] = []
    private(set) var presenceRequestCount = 0
    private(set) var enrollmentCount = 0
    private let invitation: PairingInvitation?
    private let failure: (any Error)?
    private var transientFailures: [APIError]

    init(
        invitation: PairingInvitation? = nil,
        failure: (any Error)? = nil,
        transientFailures: [APIError] = []
    ) {
        self.invitation = invitation
        self.failure = failure
        self.transientFailures = transientFailures
    }

    func health(route: URL) async throws -> Health { throw PendingRuntimeError.unconfigured }
    func status(route: URL) async throws -> SparkStatus { throw PendingRuntimeError.unconfigured }
    func models(route: URL) async throws -> ModelCatalogue {
        throw PendingRuntimeError.unconfigured
    }
    func activeInference(route: URL) async throws -> ActiveInference {
        throw PendingRuntimeError.unconfigured
    }

    func devices(route: URL) async throws -> [GeneratedAPI.Device] {
        throw PendingRuntimeError.unconfigured
    }

    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        throw PendingRuntimeError.unconfigured
    }

    func createPairingInvitation(
        route: URL,
        role: String,
        expiresInSeconds: Int,
        deviceNameHint: String?,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> PairingInvitation {
        requestedRole = role
        requestedExpiry = expiresInSeconds
        idempotencyKeys.append(idempotencyKey)
        if userPresence != nil { presenceRequestCount += 1 }
        if !transientFailures.isEmpty { throw transientFailures.removeFirst() }
        if let failure { throw failure }
        guard let invitation else { throw PendingRuntimeError.unconfigured }
        return invitation
    }

    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        enrollmentCount += 1
        return try userPresence.keyInfo.pairingFingerprint()
    }
}

private final class InvitationPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let keyInfo: UserPresenceKeyInfo
    private let signer: SoftwareSigner

    init(signer: SoftwareSigner) {
        self.signer = signer
        self.keyInfo = UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}

private actor InvitationPresenceAuthorizer: UserPresenceAuthorizing {
    private let signer = SoftwareSigner()
    private(set) var authorizationCount = 0

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        authorizationCount += 1
        return InvitationPresenceSession(signer: signer)
    }
}

@MainActor
private func invitationModel(
    runtime: any SparkRuntimeReading,
    route: String = "https://spark-ca890ed7.local:7443",
    userPresenceAuthorizer: any UserPresenceAuthorizing = InvitationPresenceAuthorizer()
) -> DeviceInvitationModel {
    DeviceInvitationModel(
        route: URL(string: route)!,
        trust: invitedNodeTrust(),
        runtime: runtime,
        userPresenceAuthorizer: userPresenceAuthorizer,
        now: { Date(timeIntervalSince1970: 1_787_000_000) }
    )
}

@MainActor
private func completeInvitation(_ model: DeviceInvitationModel) async {
    await model.requestInvitation()
    if model.isConfirmingAdministrator {
        await model.confirmAdministratorInvitation()
    }
}

// MARK: - Creating an invitation

@MainActor
@Test func administratorInvitationWaitsForConfirmationBeforeAuthenticationOrNetwork() async {
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let authorizer = InvitationPresenceAuthorizer()
    let model = invitationModel(runtime: runtime, userPresenceAuthorizer: authorizer)

    await model.requestInvitation()

    #expect(model.isConfirmingAdministrator)
    #expect(await authorizer.authorizationCount == 0)
    #expect(await runtime.requestedRole == nil)

    model.cancelAdministratorConfirmation()
    #expect(!model.isConfirmingAdministrator)
    #expect(await runtime.requestedRole == nil)

    await model.requestInvitation()
    await model.confirmAdministratorInvitation()

    #expect(await authorizer.authorizationCount == 1)
    #expect(await runtime.presenceRequestCount == 1)
    #expect(await runtime.requestedRole == "administrator")
}

@MainActor
@Test func ordinaryUserInvitationNeverRequestsLocalAuthentication() async {
    let runtime = InvitingRuntime(invitation: issuedInvitation(role: "user"))
    let authorizer = InvitationPresenceAuthorizer()
    let model = invitationModel(runtime: runtime, userPresenceAuthorizer: authorizer)
    model.role = .user

    await model.requestInvitation()

    #expect(await authorizer.authorizationCount == 0)
    #expect(await runtime.presenceRequestCount == 0)
    #expect(await runtime.requestedRole == "user")
}

@MainActor
@Test func legacyAdministratorEnrollmentUsesFreshSessionsAndRetainsInvitationIdentity() async {
    let runtime = InvitingRuntime(
        invitation: issuedInvitation(),
        transientFailures: [
            APIError(
                .local(message: "presence key not registered"),
                statusCode: 403,
                code: "USER_PRESENCE_NOT_REGISTERED"
            )
        ]
    )
    let authorizer = InvitationPresenceAuthorizer()
    let model = invitationModel(runtime: runtime, userPresenceAuthorizer: authorizer)

    await model.requestInvitation()
    await model.confirmAdministratorInvitation()

    #expect(model.errorMessage == nil)
    #expect(await authorizer.authorizationCount == 3)
    #expect(await runtime.presenceRequestCount == 2)
    #expect(await runtime.enrollmentCount == 1)
    let keys = await runtime.idempotencyKeys
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
}

@MainActor
@Test func anOwnerDeviceMintsAScannableInvitationCarryingItsOwnTrustMaterial() async throws {
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    #expect(model.errorMessage == nil)
    let payload = try #require(model.payload)
    let package = try AdditionalDevicePairingPackage(qrPayload: payload)

    // Build invitations from locally recorded pairing trust rather than trust asserted by the response.
    #expect(package.tlsFingerprint == invitedTLSFingerprint)
    #expect(package.authorityPublicKey == invitedAuthorityKey)
    #expect(package.invitation.nodeID == invitedNodeID)
    #expect(package.localHintURL?.absoluteString == "https://spark-ca890ed7.local:7443")
    #expect(await runtime.requestedRole == "administrator")
    #expect(await runtime.requestedExpiry == 300, "five minutes, per §15.3")
    #expect(!payload.lowercased().contains("password"))
}

@MainActor
@Test func theRoleTheOwnerPicksIsTheRoleTheSparkIsAskedFor() async {
    let runtime = InvitingRuntime(invitation: issuedInvitation(role: "user"))
    let model = invitationModel(runtime: runtime)
    model.role = .user

    await completeInvitation(model)

    #expect(await runtime.requestedRole == "user")
}

@MainActor
@Test func eachInvitationIsANewRequestRatherThanAReplayOfTheLastOne() async {
    // Use a fresh idempotency key for each new single-use device invitation.
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)
    await completeInvitation(model)

    let keys = await runtime.idempotencyKeys
    #expect(keys.count == 2)
    #expect(Set(keys).count == 2)
}

@MainActor
@Test func anInvitationForADifferentSparkIsNeverPassedOn() async {
    let runtime = InvitingRuntime(
        invitation: issuedInvitation(nodeID: "00000000-0000-4000-8000-000000000007")
    )
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    #expect(model.payload == nil, "nothing is handed to the device being added")
    #expect(model.errorMessage?.contains("different Spark") == true)
}

@MainActor
@Test func aDeviceWithoutTheRightToInviteIsToldWhoDoesHaveIt() async {
    let runtime = InvitingRuntime(
        failure: APIError(
            .local(message: "ROLE_FORBIDDEN"),
            statusCode: 403,
            code: "ROLE_FORBIDDEN"
        )
    )
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    #expect(model.payload == nil)
    let message = model.errorMessage ?? ""
    #expect(message.localizedCaseInsensitiveContains("administrator"))
}

@MainActor
@Test func anExpiredCodeIsMarkedRatherThanLeftLookingUsable() async {
    let runtime = InvitingRuntime(invitation: issuedInvitation(expiresAt: "2000-01-01T00:00:00Z"))
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    #expect(model.payload != nil)
    #expect(model.isExpired)
}

// MARK: - One Spark, one card, on every Apple device

private actor SecondDevicePairingService: AdditionalDevicePairingServicing {
    func claim(_ package: AdditionalDevicePairingPackage, route: URL) async throws -> NodeTrust {
        NodeTrust(
            nodeID: package.invitation.nodeID,
            nodeName: package.nodeName,
            tlsFingerprint: package.tlsFingerprint,
            authorityFingerprint: package.invitation.authorityFingerprint,
            authorityPublicKey: package.authorityPublicKey,
            pairedAt: Date(timeIntervalSince1970: 1_787_000_100),
            localDeviceRole: package.invitation.role
        )
    }
}

@MainActor
@Test func aSecondAppleDeviceLandsOnTheSameNodeIdentityAsTheFirst() async throws {
    // Use the same full node ID on both owner and recipient devices.
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let ownerDevice = invitationModel(runtime: runtime)
    await completeInvitation(ownerDevice)
    let payload = try #require(ownerDevice.payload)

    let secondDevice = RetailOnboardingModel(
        additionalDevicePairingService: SecondDevicePairingService(),
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        signerProvider: { nodeID in
            SparkRequestSigner(
                deviceID: "second-device",
                nodeID: nodeID,
                signingKey: SoftwareSigner()
            )
        }
    )
    _ = secondDevice.handleDiscovered(
        DiscoveredSpark(
            id: "spark-ca890ed7",
            displayName: "spark-ca890ed7",
            endpoint: .service(
                name: "spark-ca890ed7",
                type: "_spark-runtime._tcp",
                domain: "local.",
                interface: nil
            ),
            interface: nil,
            shortNodeID: "ca890ed7"
        )
    )

    await secondDevice.pairThisDevice(payload: payload)

    #expect(secondDevice.pairingDeviceError == nil)
    let entry = try #require(secondDevice.library.entries.first)
    #expect(entry.id == "node:\(invitedNodeID)", "keyed by node identity, not by name")
    #expect(entry.preferredRoute?.peerFingerprint == invitedTLSFingerprint)
    #expect(secondDevice.dashboardModel != nil)

    // Newly recorded trust must let the second device invite a third without the original owner device present.
    #expect(secondDevice.canInviteDevice)
    secondDevice.beginInvitingDevice()
    let nextInvitation = try #require(secondDevice.invitation)
    #expect(nextInvitation.allowedRoles == [.user])
    #expect(nextInvitation.role == .user)
}

@MainActor
@Test func anUnresolvedBonjourAdvertisementStillHasAnAddressToPairOver() async throws {
    // Carry an owner-provided endpoint hint when Bonjour supplies a service name without a usable invitation address.
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let ownerDevice = invitationModel(runtime: runtime)
    await completeInvitation(ownerDevice)
    let package = try AdditionalDevicePairingPackage(qrPayload: try #require(ownerDevice.payload))

    #expect(package.invitation.localEndpoint == nil, "the runtime supplies none")
    #expect(package.localHintURL != nil, "the owner device supplies the one it used")
}

@MainActor
@Test func openingAnotherCardDoesNotCarryTheLastSparksTrustWithIt() async throws {
    // Keep each dashboard's invitation pin bound to the Spark that was probed.
    let secondDevice = RetailOnboardingModel(
        additionalDevicePairingService: SecondDevicePairingService(),
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        signerProvider: { nodeID in
            SparkRequestSigner(
                deviceID: "second-device",
                nodeID: nodeID,
                signingKey: SoftwareSigner()
            )
        }
    )
    let runtime = InvitingRuntime(invitation: issuedInvitation())
    let ownerDevice = invitationModel(runtime: runtime)
    await completeInvitation(ownerDevice)
    _ = secondDevice.handleDiscovered(
        DiscoveredSpark(
            id: "spark-ca890ed7",
            displayName: "spark-ca890ed7",
            endpoint: .hostPort(host: "spark-ca890ed7.local", port: 7443),
            interface: nil,
            shortNodeID: "ca890ed7"
        )
    )
    await secondDevice.pairThisDevice(payload: try #require(ownerDevice.payload))
    #expect(secondDevice.canInviteDevice)

    // Failed authentication of another saved Spark must clear previous trust and publish no dashboard.
    let otherNodeID = SparkNodeID(
        rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
    )
    let outcome = secondDevice.library.reconcile(
        AuthenticatedTarget(
            nodeID: otherNodeID,
            clusterID: nil,
            name: "spark-other",
            role: .standalone,
            authorityFingerprint: invitedAuthorityFingerprint,
            displayName: "spark-other",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-other.local:7443")!,
                    kind: .localWiFi,
                    lastSuccess: Date(timeIntervalSince1970: 1_787_000_000)
                )
            ],
            reachedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    )

    await secondDevice.openLibraryEntry(outcome.entry.id)?.value

    #expect(secondDevice.dashboardTrust == nil)
    #expect(!secondDevice.canInviteDevice)
}

@MainActor
@Test func aSparkThatWillNotIssueASecondOwnerInvitationSaysWhatToDoInstead() async {
    // Present second-owner refusal as a role conflict rather than a network fault.
    let runtime = InvitingRuntime(
        failure: APIError(
            .local(message: "ROLE_FORBIDDEN"),
            statusCode: 409,
            code: "ROLE_FORBIDDEN"
        )
    )
    let model = invitationModel(runtime: runtime)

    await completeInvitation(model)

    let message = model.errorMessage ?? ""
    #expect(message.localizedCaseInsensitiveContains("already has an owner"))
    #expect(!message.localizedCaseInsensitiveContains("connection"))
}

@Test func theInvitedRolesNeverIncludeOwnership() {
    // Keep ownership transfer separate from add-device invitations (§15.5).
    #expect(!InvitedDeviceRole.allCases.map(\.rawValue).contains("owner"))
    for role in InvitedDeviceRole.allCases {
        #expect(!role.title.isEmpty)
        #expect(!role.detail.isEmpty)
    }
}

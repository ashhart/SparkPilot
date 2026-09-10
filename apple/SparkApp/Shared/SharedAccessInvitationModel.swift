import Foundation
import Observation
import SparkAPI
import SparkBootstrap
import SparkSecurity

public protocol SharedAccessProviding: Sendable {
    func sharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessOverview
    func createSharedAccessInvitation(
        route: URL,
        limits: GeneratedAPI.CreateSharedAccessInvitation,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessInvitation
    func updateSharedAccess(
        route: URL,
        deviceID: String,
        change: GeneratedAPI.UpdateSharedAccess,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessGuest
    func revokeSharedAccess(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessRevocation
}

extension SparkAPIClient: SharedAccessProviding {}

/// What the owner hands to the share sheet once the Spark has signed the invitation.
public struct SharedAccessShare: Equatable, Sendable, Identifiable {
    public let link: String
    public let nodeName: String
    public let guestName: String
    public let expiresAt: Date?
    /// True when the Spark published a tailnet name, so the friend can reach it from anywhere.
    public let reachableRemotely: Bool

    public var id: String { link }

    public init(
        link: String,
        nodeName: String,
        guestName: String,
        expiresAt: Date?,
        reachableRemotely: Bool
    ) {
        self.link = link
        self.nodeName = nodeName
        self.guestName = guestName
        self.expiresAt = expiresAt
        self.reachableRemotely = reachableRemotely
    }

    /// The plain-language message the friend receives beside the link.
    public var message: String {
        String(localized: .sharedAccessInviteMessage(nodeName, link))
    }

    public var subject: String {
        String(localized: .sharedAccessInviteSubject(nodeName))
    }
}

@MainActor
@Observable
public final class SharedAccessInvitationModel {
    public var draft: SharedAccessLimitsDraft
    public private(set) var share: SharedAccessShare?
    public private(set) var isCreating = false
    public private(set) var errorMessage: String?
    public let availableModels: [String]
    public let nodeName: String

    private let route: URL
    private let trust: NodeTrust
    private let runtime: any SharedAccessProviding
    private let userPresenceAuthorizer: any UserPresenceAuthorizing
    private var invitationKey: UUID?

    public init(
        route: URL,
        trust: NodeTrust,
        runtime: any SharedAccessProviding,
        availableModels: [String],
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        draft: SharedAccessLimitsDraft = SharedAccessLimitsDraft()
    ) {
        self.route = route
        self.trust = trust
        self.runtime = runtime
        self.availableModels = availableModels
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.draft = draft
        self.nodeName = trust.nodeName
    }

    public func toggle(model: String) {
        if let index = draft.allowedModels.firstIndex(of: model) {
            draft.allowedModels.remove(at: index)
        } else {
            draft.allowedModels.append(model)
        }
        share = nil
    }

    public func createInvitation() async {
        guard !isCreating, draft.isReady else {
            errorMessage = draft.problem
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let key = invitationKey ?? UUID()
        invitationKey = key
        do {
            let session = try await userPresenceAuthorizer.authorize(
                localizedReason: String(
                    localized: "Confirm sharing this Spark with someone else."
                )
            )
            let issued = try await runtime.createSharedAccessInvitation(
                route: route,
                limits: draft.request(),
                idempotencyKey: key,
                userPresence: session
            )
            share = try Self.share(from: issued, trust: trust, guestName: draft.guestName)
            invitationKey = nil
        } catch {
            share = nil
            errorMessage = Self.describe(error)
        }
    }

    /// Wrap the signed invitation in the pairing package the friend's app already understands.
    static func share(
        from issued: GeneratedAPI.SharedAccessInvitation,
        trust: NodeTrust,
        guestName: String
    ) throws -> SharedAccessShare {
        let invitation = try invitation(from: issued)
        guard invitation.nodeID.lowercased() == trust.nodeID.lowercased() else {
            throw SharedAccessInvitationError.differentSpark
        }
        let package = AdditionalDevicePairingPackage(
            nodeName: issued.nodeName,
            tlsFingerprint: issued.tlsFingerprint ?? trust.tlsFingerprint,
            authorityPublicKey: issued.authorityPublicKey,
            invitation: invitation,
            localHint: issued.localEndpoint
        )
        return SharedAccessShare(
            link: try package.qrPayload(),
            nodeName: issued.nodeName,
            guestName: guestName,
            expiresAt: RFC3339.date(from: invitation.expiresAt),
            reachableRemotely: invitation.remoteHostname?.isEmpty == false
        )
    }

    /// Re-decode the generated invitation into the signed wire type, so nothing is rebuilt by hand.
    static func invitation(
        from issued: GeneratedAPI.SharedAccessInvitation
    ) throws -> PairingInvitation {
        let encoder = JSONEncoder()
        let data = try encoder.encode(issued.invitation)
        return try JSONDecoder().decode(PairingInvitation.self, from: data)
    }

    static func describe(_ error: any Error) -> String {
        if let api = error as? APIError, let code = api.code {
            switch code {
            case "SHARED_ACCESS_POLICY_INVALID":
                return String(
                    localized: "The Spark refused those limits. Check them and try again."
                )
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_EXPIRED":
                return String(localized: "Confirm with Face ID or Touch ID to share this Spark.")
            case "ROLE_FORBIDDEN":
                return String(localized: "Only the owner of this Spark can share it.")
            default:
                return String(localized: "The invitation could not be created. Try again.")
            }
        }
        if error is SharedAccessInvitationError {
            return String(
                localized:
                    "This Spark returned an invitation for a different Spark. Nothing was shared."
            )
        }
        return String(localized: "The invitation could not be created. Try again.")
    }
}

public enum SharedAccessInvitationError: Error, Equatable, Sendable {
    case differentSpark
}

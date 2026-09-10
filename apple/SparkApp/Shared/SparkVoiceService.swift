import Foundation
import SparkAPI
import SparkCore
import SparkSecurity

/// A paired voice host exists independently of a loaded chat model.
public struct SparkVoiceTarget: Identifiable, Equatable, Sendable {
    public let id: String
    let displayName: String
    let nodeID: SparkNodeID
    let clusterID: SparkClusterID?
    let route: URL
    let tlsFingerprint: String
    let authorityFingerprint: String

    init(_ chat: SparkChatTarget) {
        self.init(
            id: chat.id,
            displayName: chat.displayName,
            nodeID: chat.nodeID,
            clusterID: chat.clusterID,
            route: chat.route,
            tlsFingerprint: chat.tlsFingerprint,
            authorityFingerprint: chat.authorityFingerprint
        )
    }

    init(
        id: String,
        displayName: String,
        nodeID: SparkNodeID,
        clusterID: SparkClusterID?,
        route: URL,
        tlsFingerprint: String,
        authorityFingerprint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.nodeID = nodeID
        self.clusterID = clusterID
        self.route = route
        self.tlsFingerprint = tlsFingerprint
        self.authorityFingerprint = authorityFingerprint
    }
}

struct SparkVoiceService {
    func client(for target: SparkVoiceTarget) async throws -> SparkAPIClient {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.route)
        guard identity.nodeID == target.nodeID, identity.clusterID == target.clusterID,
            identity.authorityFingerprint == target.authorityFingerprint
        else { throw SparkChatConnectionError.identityMismatch }
        return api
    }

    func status(_ target: SparkVoiceTarget) async throws -> KokoroServiceStatus {
        try await client(for: target).kokoroStatus(route: target.route)
    }

    func change(_ action: KokoroServiceAction, target: SparkVoiceTarget, key: UUID) async throws
        -> SparkAPI.Operation
    {
        let api = try await client(for: target)
        let authorizer = SystemUserPresenceAuthorizer()
        let reason = String(localized: "Confirm changing Kokoro voice on your Spark.")
        let presence = try await authorizer.authorize(localizedReason: reason)
        do {
            return try await api.changeKokoro(
                route: target.route,
                action: action,
                idempotencyKey: key,
                userPresence: presence
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else { throw error }
            let enrollment = try await authorizer.authorize(localizedReason: reason)
            _ = try await api.enrollPresenceKey(
                route: target.route,
                idempotencyKey: UUID(),
                userPresence: enrollment
            )
            let retry = try await authorizer.authorize(localizedReason: reason)
            return try await api.changeKokoro(
                route: target.route,
                action: action,
                idempotencyKey: key,
                userPresence: retry
            )
        }
    }

    func operation(_ id: UUID, target: SparkVoiceTarget) async throws -> SparkAPI.Operation {
        try await client(for: target).operation(route: target.route, id: id)
    }

    func speech(_ text: String, voice: SparkKokoroVoice, target: SparkVoiceTarget) async throws
        -> Data
    {
        try await client(for: target).speech(route: target.route, text: text, voice: voice.rawValue)
    }
}

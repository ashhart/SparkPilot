import Foundation
import SparkSecurity

public struct BatchInvitationSource: Codable, Equatable, Sendable, Identifiable {
    public let nodeID: String
    public let nodeName: String
    public let route: URL
    public let tlsFingerprint: String
    public let authorityPublicKey: String

    public var id: String { nodeID.lowercased() }

    public init(
        nodeID: String,
        nodeName: String,
        route: URL,
        tlsFingerprint: String,
        authorityPublicKey: String
    ) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.route = route
        self.tlsFingerprint = tlsFingerprint
        self.authorityPublicKey = authorityPublicKey
    }
}

public enum BatchInvitationTargetPhase: String, Codable, Equatable, Sendable {
    case pending
    case issuing
    case issued
    case failed
    case revoking
    case revoked
    case revocationFailed = "revocation_failed"
}

public struct BatchInvitationTargetProgress: Codable, Equatable, Sendable, Identifiable {
    public let source: BatchInvitationSource
    public let issueIdempotencyKey: UUID
    public let revokeIdempotencyKey: UUID
    public var package: AdditionalDevicePairingPackage?
    public var phase: BatchInvitationTargetPhase
    public var lastError: String?
    public var updatedAt: Date

    public var id: String { source.id }
}

public struct BatchInvitationProgress: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let batchID: UUID
    public let issuer: BatchPairingParticipantIdentity
    public let recipientRequest: BatchPairingRecipientRequest
    public let role: String
    public var targets: [BatchInvitationTargetProgress]
    public let createdAt: Date
    public var updatedAt: Date

    public var id: UUID { batchID }
    public var issuedCount: Int { targets.count { $0.phase == .issued } }
    public var failedCount: Int {
        targets.count { $0.phase == .failed || $0.phase == .revocationFailed }
    }
}

public protocol BatchInvitationProgressStoring: Sendable {
    func load(batchID: UUID) throws -> BatchInvitationProgress?
    func save(_ progress: BatchInvitationProgress) throws
}

public struct SecureBatchInvitationProgressStore: BatchInvitationProgressStoring {
    public static let service = "com.sparkpilot.batch-invitation-progress"

    private let store: any SecureStore
    private let service: String

    public init(store: any SecureStore = KeychainStore(), service: String = Self.service) {
        self.store = store
        self.service = service
    }

    public func load(batchID: UUID) throws -> BatchInvitationProgress? {
        guard let data = try store.data(service: service, account: account(batchID)) else {
            return nil
        }
        let value = try JSONDecoder().decode(BatchInvitationProgress.self, from: data)
        guard value.version == BatchInvitationProgress.currentVersion,
            value.batchID == batchID
        else {
            throw BatchInvitationCoordinatorError.corruptProgress
        }
        return value
    }

    public func save(_ progress: BatchInvitationProgress) throws {
        try store.set(
            JSONEncoder().encode(progress),
            service: service,
            account: account(progress.batchID)
        )
    }

    private func account(_ batchID: UUID) -> String { batchID.uuidString.lowercased() }
}

public struct BatchInvitationRunResult: Sendable {
    public let progress: BatchInvitationProgress
    public let payload: String?

    public var isReadyToShare: Bool { payload != nil }
}

public enum BatchInvitationCoordinatorError: Error, Equatable, Sendable {
    case corruptProgress
    case invalidSource(nodeID: String)
    case duplicateSource(nodeID: String)
    case issuerIdentityChanged
    case targetNotRetryable(nodeID: String)
}

/// Persist independent invitation results and retry keys, sharing only a complete batch and reporting explicit per-Spark revocation failures.
public actor BatchDeviceInvitationCoordinator {
    public typealias Issue =
        @Sendable (
            BatchInvitationSource,
            BatchPairingParticipantIdentity,
            String,
            UUID
        ) async throws -> PairingInvitation
    public typealias Revoke = @Sendable (BatchInvitationSource, UUID, UUID) async throws -> Void

    private let issuer: BatchPairingParticipantIdentity
    private let store: any BatchInvitationProgressStoring
    private let now: @Sendable () -> Date
    private let issue: Issue
    private let revoke: Revoke

    public init(
        issuer: BatchPairingParticipantIdentity,
        store: any BatchInvitationProgressStoring = SecureBatchInvitationProgressStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        issue: @escaping Issue,
        revoke: @escaping Revoke
    ) {
        self.issuer = issuer
        self.store = store
        self.now = now
        self.issue = issue
        self.revoke = revoke
    }

    public func create(
        recipientRequestPayload: String,
        role: String,
        sources: [BatchInvitationSource]
    ) async throws -> BatchInvitationRunResult {
        let request = try BatchPairingRecipientRequest(payload: recipientRequestPayload, now: now())
        guard role == "administrator" || role == "user" else {
            throw BatchAdditionalDevicePairingPackageError.invalidRole
        }
        try validate(sources)
        let timestamp = now()
        var progress = BatchInvitationProgress(
            version: BatchInvitationProgress.currentVersion,
            batchID: UUID(),
            issuer: issuer,
            recipientRequest: request,
            role: role,
            targets: sources.map {
                BatchInvitationTargetProgress(
                    source: $0,
                    issueIdempotencyKey: UUID(),
                    revokeIdempotencyKey: UUID(),
                    package: nil,
                    phase: .pending,
                    lastError: nil,
                    updatedAt: timestamp
                )
            },
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try store.save(progress)
        return try await issueTargets(&progress, selected: nil)
    }

    public func retry(batchID: UUID, nodeID: String) async throws -> BatchInvitationRunResult {
        guard var progress = try store.load(batchID: batchID) else {
            throw BatchInvitationCoordinatorError.corruptProgress
        }
        guard progress.issuer == issuer else {
            throw BatchInvitationCoordinatorError.issuerIdentityChanged
        }
        let targetID = nodeID.lowercased()
        guard progress.targets.contains(where: { $0.id == targetID && $0.phase == .failed }) else {
            throw BatchInvitationCoordinatorError.targetNotRetryable(nodeID: nodeID)
        }
        return try await issueTargets(&progress, selected: [targetID])
    }

    public func compensate(batchID: UUID) async throws -> BatchInvitationProgress {
        guard var progress = try store.load(batchID: batchID) else {
            throw BatchInvitationCoordinatorError.corruptProgress
        }
        guard progress.issuer == issuer else {
            throw BatchInvitationCoordinatorError.issuerIdentityChanged
        }
        for index in progress.targets.indices where progress.targets[index].package != nil {
            guard progress.targets[index].phase != .revoked else { continue }
            progress.targets[index].phase = .revoking
            progress.targets[index].lastError = nil
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
            do {
                try await revoke(
                    progress.targets[index].source,
                    progress.recipientRequest.recipient.deviceID,
                    progress.targets[index].revokeIdempotencyKey
                )
                progress.targets[index].phase = .revoked
            } catch {
                progress.targets[index].phase = .revocationFailed
                progress.targets[index].lastError = String(
                    localized: "This Spark could not revoke the added device."
                )
            }
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
        }
        return progress
    }

    private func issueTargets(
        _ progress: inout BatchInvitationProgress,
        selected: Set<String>?
    ) async throws -> BatchInvitationRunResult {
        for index in progress.targets.indices {
            let targetID = progress.targets[index].id
            let phase = progress.targets[index].phase
            let shouldIssue =
                selected?.contains(targetID) ?? (phase == .pending || phase == .failed)
            guard shouldIssue else { continue }
            progress.targets[index].phase = .issuing
            progress.targets[index].lastError = nil
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
            do {
                let source = progress.targets[index].source
                let invitation = try await issue(
                    source,
                    progress.recipientRequest.recipient,
                    progress.role,
                    progress.targets[index].issueIdempotencyKey
                )
                let package = AdditionalDevicePairingPackage(
                    nodeName: source.nodeName,
                    tlsFingerprint: source.tlsFingerprint,
                    authorityPublicKey: source.authorityPublicKey,
                    invitation: invitation,
                    localHint: source.route.absoluteString
                )
                try validateIssuedPackage(
                    package,
                    source: source,
                    recipient: progress.recipientRequest.recipient,
                    role: progress.role
                )
                progress.targets[index].package = package
                progress.targets[index].phase = .issued
            } catch {
                progress.targets[index].package = nil
                progress.targets[index].phase = .failed
                progress.targets[index].lastError = String(
                    localized: "This Spark could not create its invitation. Retry only this Spark."
                )
            }
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
        }

        let complete = try? completePackage(progress: progress)
        return BatchInvitationRunResult(
            progress: progress,
            payload: try? complete?.payload(now: now())
        )
    }

    private func completePackage(
        progress: BatchInvitationProgress
    ) throws -> BatchAdditionalDevicePairingPackage {
        let targets = try progress.targets.map { target -> BatchAdditionalDevicePairingTarget in
            guard let package = target.package else {
                throw BatchAdditionalDevicePairingPackageError.invalidTargetCount
            }
            return BatchAdditionalDevicePairingTarget(
                nodeID: target.source.nodeID,
                issuerDeviceID: issuer.deviceID,
                package: package
            )
        }
        let package = BatchAdditionalDevicePairingPackage(
            batchID: progress.batchID,
            issuer: issuer,
            recipient: progress.recipientRequest.recipient,
            role: progress.role,
            targets: targets
        )
        try package.validate(now: now(), requireLiveInvitations: true)
        return package
    }

    private func validateIssuedPackage(
        _ package: AdditionalDevicePairingPackage,
        source: BatchInvitationSource,
        recipient: BatchPairingParticipantIdentity,
        role: String
    ) throws {
        let invitation = package.invitation
        guard invitation.nodeID.lowercased() == source.nodeID.lowercased(),
            invitation.issuedByDeviceID?.lowercased()
                == issuer.deviceID.uuidString.lowercased(),
            invitation.recipientDeviceID?.lowercased()
                == recipient.deviceID.uuidString.lowercased(),
            invitation.recipientPublicKeyFingerprint == recipient.publicKeyFingerprint,
            invitation.role == role
        else {
            throw BatchAdditionalDevicePairingPackageError.targetIdentityMismatch
        }
        try package.verifyInvitationSignature()
        guard package.isLocallyPlausible(now: now()) else {
            throw BatchAdditionalDevicePairingPackageError.expiredInvitation(
                nodeID: source.nodeID
            )
        }
    }

    private func validate(_ sources: [BatchInvitationSource]) throws {
        let allowedTargets = ClosedRange(
            uncheckedBounds: (
                lower: BatchAdditionalDevicePairingPackage.minimumTargets,
                upper: BatchAdditionalDevicePairingPackage.maximumTargets
            )
        )
        guard allowedTargets.contains(sources.count)
        else {
            throw BatchAdditionalDevicePairingPackageError.invalidTargetCount
        }
        var seen = Set<String>()
        for source in sources {
            let nodeID = source.nodeID.lowercased()
            guard UUID(uuidString: nodeID) != nil,
                source.route.scheme?.lowercased() == "https",
                source.route.user == nil,
                source.route.password == nil,
                source.route.host != nil
            else {
                throw BatchInvitationCoordinatorError.invalidSource(nodeID: source.nodeID)
            }
            guard seen.insert(nodeID).inserted else {
                throw BatchInvitationCoordinatorError.duplicateSource(nodeID: source.nodeID)
            }
        }
    }
}

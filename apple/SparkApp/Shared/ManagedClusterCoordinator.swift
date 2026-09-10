import Foundation
import SparkAPI
import SparkCore
import SparkSecurity

public struct ManagedClusterOutcome: Sendable, Equatable {
    public let clusterID: UUID
    public let memberNodeIDs: [UUID]
    public let statusByNodeID: [UUID: ClusterStatus]
}

public struct ManagedClusterReconciliation: Sendable, Equatable {
    public enum Resolution: Sendable, Equatable {
        case ready(ManagedClusterOutcome)
        case rolledBack
    }

    public let name: String
    public let targets: [ExternalClusterTarget]
    public let resolution: Resolution
}

public enum ManagedClusterError: Error, LocalizedError, Equatable {
    case memberCount
    case trustUnavailable(String)
    case descriptorMismatch(String)
    case prepareFailed(String)
    case linkProofFailed(String)
    case collectiveFailed
    case commitFailed(String)
    case finalizeFailed(String)
    case recoveryRequired
    case recoveryJournalUnavailable
    case rollbackIncomplete([String])

    public var errorDescription: String? {
        switch self {
        case .memberCount:
            String(localized: "Select exactly two paired Sparks for this CX-7 cluster.")
        case .trustUnavailable(let name):
            String(localized: .clusterTrustUnavailable(name))
        case .descriptorMismatch(let name):
            String(localized: .clusterDescriptorMismatch(name))
        case .prepareFailed(let name):
            String(localized: .clusterPrepareFailed(name))
        case .linkProofFailed(let name):
            String(localized: .clusterLinkProofFailed(name))
        case .collectiveFailed:
            String(
                localized:
                    "The two Sparks could not complete a two-rank NCCL test. SparkPilot rolled the transaction back."
            )
        case .commitFailed(let name):
            String(localized: .clusterCommitFailed(name))
        case .finalizeFailed(let name):
            String(localized: .clusterFinalizeFailed(name))
        case .recoveryRequired:
            String(localized: "Finish the interrupted cluster setup before starting another one.")
        case .recoveryJournalUnavailable:
            String(
                localized:
                    "SparkPilot could not read the interrupted cluster record. No new cluster action was started."
            )
        case .rollbackIncomplete(let names):
            String(localized: .clusterRollbackIncomplete(names.joined(separator: ", ")))
        }
    }
}

public protocol ManagedClusterAuthorizing: Sendable {
    func authorize(
        name: String,
        coordinatorNodeID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> ManagedClusterOutcome

    func reconcilePending() async throws -> ManagedClusterReconciliation?
}

extension ManagedClusterAuthorizing {
    public func reconcilePending() async throws -> ManagedClusterReconciliation? { nil }
}

struct ManagedClusterJournalTarget: Codable, Sendable, Equatable {
    let libraryEntryID: String
    let nodeID: UUID
    let displayName: String
    let route: URL

    init(_ target: ExternalClusterTarget) {
        libraryEntryID = target.libraryEntryID
        nodeID = target.nodeID.rawValue
        displayName = target.displayName
        route = target.route
    }

    var target: ExternalClusterTarget {
        ExternalClusterTarget(
            libraryEntryID: libraryEntryID,
            nodeID: SparkNodeID(rawValue: nodeID),
            displayName: displayName,
            route: route
        )
    }
}

struct ManagedClusterTransactionJournalRecord: Codable, Sendable, Equatable {
    let version: Int
    let name: String
    let targets: [ManagedClusterJournalTarget]
    let proposal: GeneratedAPI.ClusterProposal
    let receipts: [GeneratedAPI.ClusterCommitReceipt]
    var finalizedNodeIDs: [UUID]
}

protocol ManagedClusterTransactionJournaling: Sendable {
    func load() throws -> ManagedClusterTransactionJournalRecord?
    func save(_ record: ManagedClusterTransactionJournalRecord) throws
    func remove() throws
}

struct FileManagedClusterTransactionJournal: ManagedClusterTransactionJournaling {
    private static let maximumBytes = 1024 * 1024
    let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.url =
                applicationSupport
                .appendingPathComponent("SparkFabric", isDirectory: true)
                .appendingPathComponent("pending-cluster-transaction.json")
        }
    }

    func load() throws -> ManagedClusterTransactionJournalRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumBytes else {
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        return try JSONDecoder().decode(ManagedClusterTransactionJournalRecord.self, from: data)
    }

    func save(_ record: ManagedClusterTransactionJournalRecord) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumBytes else {
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum ManagedClusterMemberOrder {
    static func coordinatorFirst(
        _ targets: [ExternalClusterTarget],
        coordinatorNodeID: UUID
    ) -> [ExternalClusterTarget]? {
        guard let coordinator = targets.first(where: { $0.nodeID.rawValue == coordinatorNodeID })
        else { return nil }
        return [coordinator] + targets.filter { $0.nodeID.rawValue != coordinatorNodeID }
    }

    static func workerFirst(
        _ targets: [ExternalClusterTarget],
        coordinatorNodeID: UUID
    ) -> [ExternalClusterTarget]? {
        coordinatorFirst(targets, coordinatorNodeID: coordinatorNodeID)?.reversed()
    }
}

public actor SignedManagedClusterCoordinator: ManagedClusterAuthorizing {
    public typealias RuntimeResolver =
        @Sendable (ExternalClusterTarget) throws -> (SparkAPIClient, NodeTrust)

    private let runtimeResolver: RuntimeResolver
    private let presenceAuthorizer: any UserPresenceAuthorizing
    private let deviceID: UUID
    private let now: @Sendable () -> Date
    private let journal: any ManagedClusterTransactionJournaling

    public init(
        runtimeResolver: RuntimeResolver? = nil,
        presenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        deviceID: UUID = DeviceIdentityStore.loadOrCreateDeviceID(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runtimeResolver = runtimeResolver ?? Self.productionRuntime
        self.presenceAuthorizer = presenceAuthorizer
        self.deviceID = deviceID
        self.now = now
        journal = FileManagedClusterTransactionJournal()
    }

    init(
        runtimeResolver: RuntimeResolver? = nil,
        presenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        deviceID: UUID = DeviceIdentityStore.loadOrCreateDeviceID(),
        now: @escaping @Sendable () -> Date = Date.init,
        journal: any ManagedClusterTransactionJournaling
    ) {
        self.runtimeResolver = runtimeResolver ?? Self.productionRuntime
        self.presenceAuthorizer = presenceAuthorizer
        self.deviceID = deviceID
        self.now = now
        self.journal = journal
    }

    public func authorize(
        name: String,
        coordinatorNodeID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> ManagedClusterOutcome {
        guard try journal.load() == nil else { throw ManagedClusterError.recoveryRequired }
        guard targets.count == 2,
            let targets = ManagedClusterMemberOrder.coordinatorFirst(
                targets,
                coordinatorNodeID: coordinatorNodeID
            )
        else { throw ManagedClusterError.memberCount }
        let runtimes = try targets.map { target in
            let runtime = try runtimeResolver(target)
            return (target, runtime.0, runtime.1)
        }
        var descriptors: [GeneratedAPI.ClusterMemberDescriptor] = []
        for (target, api, trust) in runtimes {
            let descriptor: GeneratedAPI.ClusterMemberDescriptor
            do {
                descriptor = try await api.clusterDescriptor(route: target.route)
            } catch {
                throw ManagedClusterError.prepareFailed(target.displayName)
            }
            guard descriptor.nodeId.lowercased() == target.nodeID.rawValue.uuidString.lowercased(),
                descriptor.authorityPublicKey.lowercased() == trust.authorityPublicKey.lowercased(),
                descriptor.authorityFingerprint.lowercased()
                    == trust.authorityFingerprint.lowercased()
            else { throw ManagedClusterError.descriptorMismatch(target.displayName) }
            descriptors.append(descriptor)
        }
        guard Set(descriptors.map(\.runtimeVersion)).count == 1,
            Set(descriptors.map(\.engineImage)).count == 1
        else { throw ManagedClusterError.descriptorMismatch(targets[1].displayName) }

        let transactionID = UUID()
        let clusterID = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let proposal = GeneratedAPI.ClusterProposal(
            version: 1,
            transactionId: transactionID.uuidString.lowercased(),
            clusterId: clusterID.uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            coordinatorNodeId: targets[0].nodeID.rawValue.uuidString.lowercased(),
            ownerDeviceId: deviceID.uuidString.lowercased(),
            expiresAt: formatter.string(from: now().addingTimeInterval(5 * 60)),
            members: descriptors
        )
        let presence = try await presenceAuthorizer.authorize(
            localizedReason: String(localized: "Set up this two-Spark cluster")
        )
        var prepared: [(ExternalClusterTarget, SparkAPIClient)] = []
        var grants: [GeneratedAPI.ClusterDeviceGrant] = []
        do {
            for (target, api, _) in runtimes {
                let grant = try await api.prepareClusterTransaction(
                    route: target.route,
                    proposal: proposal,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                prepared.append((target, api))
                grants.append(grant)
            }
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            let failedName =
                runtimes.first { candidate in
                    !prepared.contains(where: { $0.0.id == candidate.0.id })
                }?.0.displayName ?? targets.last!.displayName
            throw ManagedClusterError.prepareFailed(failedName)
        }

        var proofs: [GeneratedAPI.ClusterLinkProof] = []
        do {
            for (target, api) in prepared {
                _ = try await api.activateClusterTransaction(
                    route: target.route,
                    proposal: proposal,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
            }
            for (target, api) in prepared {
                let proof = try await api.proveClusterTransaction(
                    route: target.route,
                    proposal: proposal,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                proofs.append(proof)
            }
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            let name =
                prepared.indices.contains(proofs.count)
                ? prepared[proofs.count].0.displayName : targets.last!.displayName
            throw ManagedClusterError.linkProofFailed(name)
        }

        let collectives: [GeneratedAPI.ClusterCollectiveProof]
        do {
            let firstTarget = prepared[0].0
            let firstAPI = prepared[0].1
            let secondTarget = prepared[1].0
            let secondAPI = prepared[1].1
            async let first = firstAPI.runClusterCollective(
                route: firstTarget.route,
                proposal: proposal,
                idempotencyKey: UUID(),
                userPresence: presence
            )
            async let second = secondAPI.runClusterCollective(
                route: secondTarget.route,
                proposal: proposal,
                idempotencyKey: UUID(),
                userPresence: presence
            )
            let results = try await (first, second)
            collectives = [results.0, results.1]
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            throw ManagedClusterError.collectiveFailed
        }

        let request = GeneratedAPI.CommitClusterTransaction(
            proposal: proposal,
            grants: grants,
            proofs: proofs,
            collectives: collectives
        )
        var committed: [(ExternalClusterTarget, SparkAPIClient)] = []
        var receipts: [GeneratedAPI.ClusterCommitReceipt] = []
        do {
            for (target, api) in prepared {
                let receipt = try await api.commitClusterTransaction(
                    route: target.route,
                    request: request,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                committed.append((target, api))
                receipts.append(receipt)
            }
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            let failedName =
                prepared.first { candidate in
                    !committed.contains(where: { $0.0.id == candidate.0.id })
                }?.0.displayName ?? targets.last!.displayName
            throw ManagedClusterError.commitFailed(failedName)
        }
        let finalizeRequest = GeneratedAPI.FinalizeClusterTransaction(
            proposal: proposal,
            receipts: receipts
        )
        var journalRecord = ManagedClusterTransactionJournalRecord(
            version: 1,
            name: proposal.name,
            targets: targets.map(ManagedClusterJournalTarget.init),
            proposal: proposal,
            receipts: receipts,
            finalizedNodeIDs: []
        )
        do {
            try journal.save(journalRecord)
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        var finalized: [(ExternalClusterTarget, SparkAPIClient)] = []
        var statuses: [UUID: ClusterStatus] = [:]
        do {
            for (target, api) in prepared {
                let status = try await api.finalizeClusterTransaction(
                    route: target.route,
                    request: finalizeRequest,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                finalized.append((target, api))
                statuses[target.nodeID.rawValue] = status
                journalRecord.finalizedNodeIDs.append(target.nodeID.rawValue)
                try journal.save(journalRecord)
            }
        } catch {
            let failures = await rollback(prepared, proposal: proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            try? journal.remove()
            let failedName =
                prepared.first { candidate in
                    !finalized.contains(where: { $0.0.id == candidate.0.id })
                }?.0.displayName ?? targets.last!.displayName
            throw ManagedClusterError.finalizeFailed(failedName)
        }
        do {
            try journal.remove()
        } catch {
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        return ManagedClusterOutcome(
            clusterID: clusterID,
            memberNodeIDs: targets.map(\.nodeID.rawValue),
            statusByNodeID: statuses
        )
    }

    public func reconcilePending() async throws -> ManagedClusterReconciliation? {
        let record: ManagedClusterTransactionJournalRecord
        do {
            guard let pending = try journal.load() else { return nil }
            record = pending
        } catch {
            throw ManagedClusterError.recoveryJournalUnavailable
        }
        guard record.version == 1,
            record.targets.count == 2,
            record.receipts.count == 2,
            Set(record.targets.map(\.nodeID))
                == Set(
                    record.proposal.members.compactMap {
                        UUID(uuidString: $0.nodeId)
                    }
                ),
            record.proposal.coordinatorNodeId
                == record.targets[0].nodeID.uuidString.lowercased(),
            UUID(uuidString: record.proposal.clusterId) != nil
        else { throw ManagedClusterError.recoveryJournalUnavailable }
        let targets = record.targets.map(\.target)
        let runtimes = try targets.map { target in
            let runtime = try runtimeResolver(target)
            return (target, runtime.0)
        }
        let presence = try await presenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Finish or safely undo the interrupted cluster setup"
            )
        )
        let request = GeneratedAPI.FinalizeClusterTransaction(
            proposal: record.proposal,
            receipts: record.receipts
        )
        var current = record
        var statuses: [UUID: ClusterStatus] = [:]
        do {
            for (target, api) in runtimes {
                let status = try await api.finalizeClusterTransaction(
                    route: target.route,
                    request: request,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                statuses[target.nodeID.rawValue] = status
                if !current.finalizedNodeIDs.contains(target.nodeID.rawValue) {
                    current.finalizedNodeIDs.append(target.nodeID.rawValue)
                }
                try journal.save(current)
            }
            try journal.remove()
            let clusterID = UUID(uuidString: record.proposal.clusterId)!
            return ManagedClusterReconciliation(
                name: record.name,
                targets: targets,
                resolution: .ready(
                    ManagedClusterOutcome(
                        clusterID: clusterID,
                        memberNodeIDs: targets.map(\.nodeID.rawValue),
                        statusByNodeID: statuses
                    )
                )
            )
        } catch {
            let failures = await rollback(runtimes, proposal: record.proposal, presence: presence)
            if !failures.isEmpty { throw ManagedClusterError.rollbackIncomplete(failures) }
            try journal.remove()
            return ManagedClusterReconciliation(
                name: record.name,
                targets: targets,
                resolution: .rolledBack
            )
        }
    }

    private func rollback(
        _ prepared: [(ExternalClusterTarget, SparkAPIClient)],
        proposal: GeneratedAPI.ClusterProposal,
        presence: any UserPresenceProofSigning
    ) async -> [String] {
        var failed: [String] = []
        for (target, api) in prepared.reversed() {
            do {
                _ = try await api.rollbackClusterTransaction(
                    route: target.route,
                    proposal: proposal,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
            } catch {
                failed.append(target.displayName)
            }
        }
        return failed
    }

    static func productionRuntime(
        target: ExternalClusterTarget
    ) throws -> (SparkAPIClient, NodeTrust) {
        guard
            let trust = StoredNodeTrust.reader(
                target.nodeID.rawValue.uuidString.lowercased()
            ), trust.localDeviceRole == SparkDeviceRole.owner.rawValue
        else { throw ManagedClusterError.trustUnavailable(target.displayName) }
        return (
            try SparkAPIClient.pinned(
                to: trust.tlsFingerprint,
                signer: DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
            ),
            trust
        )
    }
}

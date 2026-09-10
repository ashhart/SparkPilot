import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public actor SignedExternalClusterPreviewProvider: ExternalClusterPreviewProviding {
    public typealias RuntimeResolver =
        @Sendable (ExternalClusterTarget) throws
        -> ExternalClusterRuntimeConnection

    private let runtimeResolver: RuntimeResolver
    private let now: @Sendable () -> Date

    public init(
        runtimeResolver: RuntimeResolver? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runtimeResolver = runtimeResolver ?? Self.productionRuntime
        self.now = now
    }

    public func review(
        name: String,
        targets: [ExternalClusterTarget]
    ) async throws -> ExternalClusterEvidence {
        let ordered = targets.sorted { $0.id < $1.id }
        guard let coordinator = ordered.first else {
            throw ExternalClusterPreviewError.pairedRouteUnavailable(
                String(localized: "this Spark")
            )
        }
        let connections = try ordered.map { target in
            (target, try runtimeResolver(target))
        }
        let authority = connections[0].1.expectedAuthorityFingerprint
        guard
            connections.allSatisfy({ pair in
                pair.1.expectedAuthorityFingerprint.caseInsensitiveCompare(authority)
                    == .orderedSame
            })
        else {
            let mismatched = connections.first { pair in
                pair.1.expectedAuthorityFingerprint.caseInsensitiveCompare(authority)
                    != .orderedSame
            }
            throw ExternalClusterPreviewError.authorityMismatch(
                mismatched?.0.displayName ?? String(localized: "A selected Spark")
            )
        }
        let fabricByNodeID = try await withThrowingTaskGroup(
            of: (SparkNodeID, GeneratedAPI.FabricStatus).self,
            returning: [SparkNodeID: GeneratedAPI.FabricStatus].self
        ) { group in
            for (target, connection) in connections {
                group.addTask {
                    do {
                        let identity = try await connection.api.identity(route: target.route)
                        guard identity.nodeID == target.nodeID,
                            identity.authorityFingerprint.lowercased()
                                == connection.expectedAuthorityFingerprint.lowercased()
                        else {
                            throw ExternalClusterPreviewError.identityMismatch(target.displayName)
                        }
                        guard identity.clusterID == nil else {
                            throw ExternalClusterPreviewError.targetAlreadyClustered(
                                target.displayName
                            )
                        }
                        return (
                            target.nodeID,
                            try await connection.api.fabric(route: target.route)
                        )
                    } catch let error as ExternalClusterPreviewError {
                        throw error
                    } catch {
                        throw ExternalClusterPreviewError.pairedRouteUnavailable(
                            target.displayName
                        )
                    }
                }
            }
            var result: [SparkNodeID: GeneratedAPI.FabricStatus] = [:]
            for try await (nodeID, status) in group {
                result[nodeID] = status
            }
            return result
        }
        try Task.checkCancellation()
        let coordinatorConnection = connections[0].1
        let preview = try await coordinatorConnection.api.previewExternalClusterImport(
            route: coordinator.route,
            request: .init(
                name: name,
                memberNodeIds: ordered.map {
                    $0.nodeID.rawValue.uuidString.lowercased()
                }
            )
        )
        let verifiedAt = now()
        let eligible = try Self.validateSignedEvidence(
            preview: preview,
            fabricByNodeID: fabricByNodeID,
            selected: Set(ordered.map(\.nodeID)),
            at: verifiedAt
        )
        return ExternalClusterEvidence(
            preview: preview,
            fabricByNodeID: fabricByNodeID,
            authorityFingerprint: authority,
            verifiedAt: verifiedAt,
            localRegistrationEligible: eligible
        )
    }

    private static func validateSignedEvidence(
        preview: GeneratedAPI.ExternalClusterImportPreview,
        fabricByNodeID: [SparkNodeID: GeneratedAPI.FabricStatus],
        selected: Set<SparkNodeID>,
        at date: Date
    ) throws -> Bool {
        let previewMembers = Set(
            preview.members.compactMap { member in
                UUID(uuidString: member.nodeId).map(SparkNodeID.init(rawValue:))
            }
        )
        guard previewMembers == selected,
            preview.members.count == selected.count,
            fabricByNodeID.count == selected.count,
            fabricByNodeID.keys.allSatisfy(selected.contains)
        else { throw ExternalClusterPreviewError.signedEvidenceMismatch }
        guard preview.evidenceComplete,
            preview.members.allSatisfy(\.identityAuthenticated)
        else { return false }

        let formatter = ISO8601DateFormatter()
        var adjacency: [SparkNodeID: Set<SparkNodeID>] = [:]
        for link in preview.authenticatedLinks {
            guard let first = UUID(uuidString: link.memberANodeId).map(SparkNodeID.init(rawValue:)),
                let second = UUID(uuidString: link.memberBNodeId).map(SparkNodeID.init(rawValue:)),
                selected.contains(first),
                selected.contains(second),
                first != second,
                formatter.date(from: link.expiresAt).isSomeAnd({ $0 > date }),
                Self.fabric(
                    fabricByNodeID[first],
                    portID: link.memberAPortId,
                    authenticates: second,
                    at: date,
                    formatter: formatter
                ),
                Self.fabric(
                    fabricByNodeID[second],
                    portID: link.memberBPortId,
                    authenticates: first,
                    at: date,
                    formatter: formatter
                )
            else { throw ExternalClusterPreviewError.signedEvidenceMismatch }
            adjacency[first, default: []].insert(second)
            adjacency[second, default: []].insert(first)
        }
        guard let first = selected.first else {
            throw ExternalClusterPreviewError.signedEvidenceMismatch
        }
        var connected = Set([first])
        var pending = [first]
        while let node = pending.popLast() {
            for peer in adjacency[node, default: []] where connected.insert(peer).inserted {
                pending.append(peer)
            }
        }
        guard connected == selected else {
            throw ExternalClusterPreviewError.signedEvidenceMismatch
        }
        return true
    }

    private static func fabric(
        _ status: GeneratedAPI.FabricStatus?,
        portID: String,
        authenticates peer: SparkNodeID,
        at date: Date,
        formatter: ISO8601DateFormatter
    ) -> Bool {
        status?.ports.contains { port in
            port.portId == portID
                && port.peerProof == .authenticatedNode
                && port.authenticatedPeerNodeId?.lowercased()
                    == peer.rawValue.uuidString.lowercased()
                && port.peerProofExpiresAt
                    .flatMap(formatter.date(from:))
                    .isSomeAnd { $0 > date }
        } == true
    }

    private static func productionRuntime(
        target: ExternalClusterTarget
    ) throws -> ExternalClusterRuntimeConnection {
        guard
            let trust = StoredNodeTrust.reader(target.nodeID.rawValue.uuidString.lowercased()),
            trust.localDeviceRole == SparkDeviceRole.owner.rawValue
        else {
            throw ExternalClusterPreviewError.pairedRouteUnavailable(target.displayName)
        }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        return ExternalClusterRuntimeConnection(
            api: try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer),
            expectedAuthorityFingerprint: trust.authorityFingerprint
        )
    }
}

extension Optional {
    fileprivate func isSomeAnd(_ predicate: (Wrapped) -> Bool) -> Bool {
        map(predicate) ?? false
    }
}

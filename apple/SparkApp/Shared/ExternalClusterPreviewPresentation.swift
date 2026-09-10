import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public enum ExternalClusterControl: String, Sendable, Equatable {
    case registration
    case automaticTopology
    case takeover
}

public struct ExternalClusterMemberRow: Identifiable, Sendable, Equatable {
    public let nodeID: SparkNodeID
    public let name: String
    public let identityAuthenticated: Bool
    public let identityLabel: String

    public var id: SparkNodeID { nodeID }
}

public struct ExternalClusterLinkRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let firstName: String
    public let secondName: String
    public let proofLabel: String
    public let topologyLabel: String
}

public struct ExternalClusterFabricRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let targetName: String
    public let interfacesLabel: String
    public let physicalLinkLabel: String
    public let speedLabel: String?
    public let peerLabel: String
    /// Whether Spark Runtime or another tool owns this fabric (§41.5.3).
    public let ownershipLabel: String
}

public struct ExternalClusterBlockerRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let recovery: String
}

public struct ExternalClusterPreviewPresentation: Sendable, Equatable {
    public let name: String
    public let configurationLabel: String
    public let evidenceComplete: Bool
    public let availableControls: [ExternalClusterControl]
    public let memberRows: [ExternalClusterMemberRow]
    public let linkRows: [ExternalClusterLinkRow]
    public let fabricRows: [ExternalClusterFabricRow]
    public let blockerRows: [ExternalClusterBlockerRow]
    public let preservedItems: [String]

    public init(
        evidence: ExternalClusterEvidence,
        targets: [ExternalClusterTarget]
    ) {
        let names = Dictionary(uniqueKeysWithValues: targets.map { ($0.nodeID, $0.displayName) })
        let preview = evidence.preview
        name = preview.name
        configurationLabel = String(localized: "Externally Configured")
        evidenceComplete = preview.evidenceComplete
        availableControls = [
            evidence.localRegistrationEligible ? .registration : nil,
            preview.automaticTopologyAvailable ? .automaticTopology : nil,
            preview.takeoverAvailable ? .takeover : nil,
        ].compactMap { $0 }
        memberRows = preview.members.compactMap { member in
            guard let nodeID = UUID(uuidString: member.nodeId).map(SparkNodeID.init(rawValue:))
            else {
                return nil
            }
            return ExternalClusterMemberRow(
                nodeID: nodeID,
                name: names[nodeID] ?? member.name ?? String(localized: "Unknown Spark"),
                identityAuthenticated: member.identityAuthenticated,
                identityLabel: member.identityAuthenticated
                    ? String(localized: "Paired identity authenticated")
                    : String(localized: "Identity not authenticated")
            )
        }
        linkRows = preview.authenticatedLinks.map { link in
            let firstID = UUID(uuidString: link.memberANodeId).map(SparkNodeID.init(rawValue:))
            let secondID = UUID(uuidString: link.memberBNodeId).map(SparkNodeID.init(rawValue:))
            return ExternalClusterLinkRow(
                id: "\(link.memberANodeId):\(link.memberAPortId):\(link.memberBNodeId)",
                firstName: firstID.flatMap { names[$0] } ?? String(localized: "Unknown Spark"),
                secondName: secondID.flatMap { names[$0] } ?? String(localized: "Unknown Spark"),
                proofLabel: String(localized: "Mutual TLS proof"),
                topologyLabel: Self.topologyLabel(link)
            )
        }
        fabricRows = targets.flatMap { target -> [ExternalClusterFabricRow] in
            guard let fabric = evidence.fabricByNodeID[target.nodeID] else { return [] }
            let ownership = Self.ownershipLabel(fabric.configurationOwner)
            return fabric.ports.map { port in
                ExternalClusterFabricRow(
                    id: "\(target.id):\(port.portId)",
                    targetName: target.displayName,
                    interfacesLabel: port.interfaces.isEmpty
                        ? String(localized: "Interface unavailable")
                        : port.interfaces.joined(separator: ", "),
                    physicalLinkLabel: Self.physicalLinkLabel(port.physicalLink),
                    speedLabel: port.negotiatedSpeedMbps.map(Self.speedLabel),
                    peerLabel: Self.peerLabel(port.peerProof, names: names, port: port),
                    ownershipLabel: ownership
                )
            }
        }
        blockerRows = preview.blockers.enumerated().map { index, blocker in
            let nodeID = blocker.memberNodeId
                .flatMap(UUID.init(uuidString:))
                .map(SparkNodeID.init(rawValue:))
            let memberName = nodeID.flatMap { names[$0] } ?? String(localized: "A selected Spark")
            return ExternalClusterBlockerRow(
                id: "\(blocker.code.rawValue):\(blocker.memberNodeId ?? String(index))",
                title: Self.blockerTitle(blocker.code, memberName: memberName),
                recovery: Self.blockerRecovery(blocker.code)
            )
        }
        preservedItems = preview.preservationGuarantees.map(Self.preservationLabel)
    }

    private static func topologyLabel(_ link: GeneratedAPI.AuthenticatedFabricLink) -> String {
        guard link.directConnectionProven else {
            return String(localized: "Connection path not proven direct")
        }
        return switch link.pathTopology {
        case .direct: String(localized: "Direct connection proven")
        case .switched: String(localized: "Switched connection")
        case .unknown: String(localized: "Connection path unknown")
        }
    }

    private static func physicalLinkLabel(
        _ link: GeneratedAPI.FabricPortStatusPhysicalLink
    ) -> String {
        switch link {
        case .down: String(localized: "Cable disconnected")
        case .carrier: String(localized: "Cable connected")
        case .speedMismatch: String(localized: "Connected below 200 GbE")
        case .negotiated200Gbe: String(localized: "Connected at 200 GbE")
        }
    }

    private static func speedLabel(_ speed: Int) -> String {
        speed >= 1_000
            ? String(localized: .gigabitEthernet(speed / 1_000))
            : String(localized: .megabitEthernet(speed))
    }

    private static func peerLabel(
        _ proof: GeneratedAPI.FabricPortStatusPeerProof,
        names: [SparkNodeID: String],
        port: GeneratedAPI.FabricPortStatus
    ) -> String {
        switch proof {
        case .authenticatedNode:
            let name = port.authenticatedPeerNodeId
                .flatMap(UUID.init(uuidString:))
                .map(SparkNodeID.init(rawValue:))
                .flatMap { names[$0] }
            return name.map { String(localized: .authenticatedPeer($0)) }
                ?? String(localized: "Authenticated Spark peer")
        // §10.6.2 step 5 and §41.5.3: carrier without an authenticated peer is never a trusted line.
        case .candidate: return String(localized: "Checking the other end")
        case .switchPort: return String(localized: "Network switch port")
        case .unknown: return String(localized: "Peer not authenticated")
        }
    }

    /// §41.5.3 asks the cluster detail to say whether Spark Runtime or another tool owns the fabric.
    private static func ownershipLabel(
        _ owner: GeneratedAPI.FabricStatusConfigurationOwner
    ) -> String {
        switch owner {
        case .sparkRuntimeManaged: String(localized: "Managed by SparkPilot")
        case .externallyConfigured: String(localized: "Configured outside SparkPilot")
        case .unconfigured: String(localized: "No fabric configuration")
        }
    }

    private static func blockerTitle(
        _ code: GeneratedAPI.ExternalClusterImportBlockerCode,
        memberName: String
    ) -> String {
        switch code {
        case .unverified: String(localized: .memberNotAuthenticated(memberName))
        case .mismatch: String(localized: .memberAnotherAuthority(memberName))
        case .reciprocal: String(localized: .memberNoReciprocalProof(memberName))
        }
    }

    private static func blockerRecovery(
        _ code: GeneratedAPI.ExternalClusterImportBlockerCode
    ) -> String {
        switch code {
        case .unverified:
            String(localized: "Pair this Spark independently, then review the connection again.")
        case .mismatch:
            String(localized: "Pair every member under the same Spark owner authority.")
        case .reciprocal:
            String(
                localized:
                    "Check the ConnectX cable and wait for both Sparks to authenticate each other."
            )
        }
    }

    private static func preservationLabel(
        _ item: GeneratedAPI.ExternalClusterImportPreviewPreservationGuaranteesItem
    ) -> String {
        switch item {
        case .netplan: String(localized: "Netplan")
        case .ssh: "SSH"
        case .ray: String(localized: "Ray")
        case .vllm: "vLLM"
        case .models: String(localized: "Models")
        case .containers: String(localized: "Containers")
        case .services: String(localized: "Services")
        }
    }
}

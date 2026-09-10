import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

func externalClusterTestExternalNode(_ value: Int) -> SparkNodeID {
    SparkNodeID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    )
}

func externalClusterTestExternalTarget(_ value: Int, name: String) -> ExternalClusterTarget {
    ExternalClusterTarget(
        libraryEntryID:
            "node:\(externalClusterTestExternalNode(value).rawValue.uuidString.lowercased())",
        nodeID: externalClusterTestExternalNode(value),
        displayName: name,
        route: URL(string: "https://spark-\(value).local:7443")!
    )
}

func externalClusterTestExternalLibraryTarget(_ value: Int, name: String) -> AuthenticatedTarget {
    AuthenticatedTarget(
        nodeID: externalClusterTestExternalNode(value),
        clusterID: nil,
        name: name,
        role: .standalone,
        authorityFingerprint: "authority",
        displayName: name,
        routes: [
            CachedRoute(
                baseURL: URL(string: "https://spark-\(value).local:7443")!,
                kind: .localWiFi
            )
        ]
    )
}

func externalClusterTestManagedLaunchStatus(
    _ index: Int,
    targets: [ExternalClusterTarget],
    state: GeneratedAPI.ClusterLaunchStatusState = .running,
    failureCode: String? = nil
) -> GeneratedAPI.ClusterLaunchStatus {
    GeneratedAPI.ClusterLaunchStatus(
        launchId: "00000000-0000-4000-8000-000000000098",
        clusterId: "00000000-0000-4000-8000-000000000099",
        recipeId: "verified-recipe",
        profileId: "safe-profile",
        state: state,
        coordinatorNodeId: targets[0].nodeID.rawValue.uuidString.lowercased(),
        workerNodeId: targets[1].nodeID.rawValue.uuidString.lowercased(),
        failureCode: failureCode,
        updatedAt: "2026-08-31T09:00:0\(index)Z"
    )
}

func externalClusterTestManagedMemberStatus(
    _ index: Int,
    targets: [ExternalClusterTarget],
    state: GeneratedAPI.ClusterLaunchStatusState = .running,
    failureCode: String? = nil
) -> ManagedClusterMemberLaunchStatus {
    ManagedClusterMemberLaunchStatus(
        targetID: targets[index].id,
        targetName: targets[index].displayName,
        status: externalClusterTestManagedLaunchStatus(
            index,
            targets: targets,
            state: state,
            failureCode: failureCode
        )
    )
}

func externalClusterTestExternalTrust(_ nodeID: String, role: SparkDeviceRole) -> NodeTrust {
    NodeTrust(
        nodeID: nodeID,
        nodeName: "Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: "authority",
        authorityPublicKey: "public-key",
        pairedAt: Date(timeIntervalSince1970: 0),
        localDeviceRole: role.rawValue
    )
}

func externalClusterTestExternalFabric(
    peer: SparkNodeID,
    link: GeneratedAPI.FabricPortStatusPhysicalLink = .negotiated200Gbe,
    proof: GeneratedAPI.FabricPortStatusPeerProof = .authenticatedNode,
    owner: GeneratedAPI.FabricStatusConfigurationOwner = .externallyConfigured
) -> GeneratedAPI.FabricStatus {
    GeneratedAPI.FabricStatus(
        observedAt: "2026-08-31T09:00:00Z",
        available: true,
        configurationOwner: owner,
        automaticTopologyAvailable: false,
        takeoverAvailable: false,
        addressEvidenceAvailable: true,
        routeEvidenceAvailable: true,
        netplanEvidenceAvailable: true,
        netplanSources: ["/etc/netplan/90-cluster.yaml"],
        ports: [
            GeneratedAPI.FabricPortStatus(
                portId: "0000:01:00.0:p0",
                interfaces: ["enp1s0f0np0"],
                physicalLink: link,
                negotiatedSpeedMbps: 200_000,
                mtu: 9_000,
                addresses: ["10.20.0.1/30"],
                routes: ["10.20.0.0/30"],
                peerProof: proof,
                authenticatedPeerNodeId: proof == .authenticatedNode
                    ? peer.rawValue.uuidString.lowercased() : nil,
                peerProofExpiresAt: "2026-08-31T09:10:00Z"
            )
        ]
    )
}

func externalClusterTestExternalPreview(
    first: ExternalClusterTarget,
    second: ExternalClusterTarget,
    complete: Bool = true
) -> GeneratedAPI.ExternalClusterImportPreview {
    GeneratedAPI.ExternalClusterImportPreview(
        name: "Studio cluster",
        configurationOwner: .externallyConfigured,
        members: [
            .init(
                nodeId: first.nodeID.rawValue.uuidString.lowercased(),
                name: first.displayName,
                identityAuthenticated: true,
                identitySource: "pinned_tls_identity"
            ),
            .init(
                nodeId: second.nodeID.rawValue.uuidString.lowercased(),
                name: second.displayName,
                identityAuthenticated: complete,
                identitySource: complete ? "pinned_tls_identity" : nil
            ),
        ],
        authenticatedLinks: complete
            ? [
                .init(
                    memberANodeId: first.nodeID.rawValue.uuidString.lowercased(),
                    memberAPortId: "0000:01:00.0:p0",
                    memberBNodeId: second.nodeID.rawValue.uuidString.lowercased(),
                    memberBPortId: "0000:01:00.0:p0",
                    proofSource: .mutualTlsChallenge,
                    pathTopology: .unknown,
                    directConnectionProven: false,
                    verifiedAt: "2026-08-31T09:00:00Z",
                    expiresAt: "2026-08-31T09:10:00Z"
                )
            ] : [],
        evidenceComplete: complete,
        registrationAvailable: false,
        automaticTopologyAvailable: false,
        takeoverAvailable: false,
        blockers: complete
            ? []
            : [
                .init(
                    code: .unverified,
                    memberNodeId: second.nodeID.rawValue.uuidString.lowercased()
                ),
                .init(
                    code: .reciprocal,
                    memberNodeId: second.nodeID.rawValue.uuidString.lowercased()
                ),
            ],
        preservationGuarantees: [.netplan, .ssh, .ray, .vllm, .models, .containers, .services]
    )
}

import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// Cluster phases run under the runtime's typed deadlines, well past the three-second presence probe.
    static let clusterTransactionTimeout: TimeInterval = 120

    /// `GET /api/v1/cluster` returns cluster topology and state.
    public func cluster(route base: URL) async throws -> ClusterStatus {
        try await get(base.appendingPathComponent("api/v1/cluster"))
    }

    public func clusterDescriptor(
        route base: URL
    ) async throws -> GeneratedAPI.ClusterMemberDescriptor {
        try await get(endpoint(base, "api", "v1", "cluster", "descriptor"))
    }

    public func clusterDeviceGrants(
        route base: URL
    ) async throws -> [GeneratedAPI.ClusterDeviceGrant] {
        try await get(endpoint(base, "api", "v1", "cluster", "grants"))
    }

    /// Read-only ConnectX, address, route, Netplan provenance, and peer proof.
    public func fabric(route base: URL) async throws -> GeneratedAPI.FabricStatus {
        try await get(endpoint(base, "api", "v1", "fabric"))
    }

    /// Check independently paired members and reciprocal fabric proofs without registering membership or mutating workloads.
    public func previewExternalClusterImport(
        route base: URL,
        request: GeneratedAPI.ExternalClusterImportPreviewRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ExternalClusterImportPreview {
        try await post(
            endpoint(base, "api", "v1", "cluster", "import", "preview"),
            body: request,
            idempotencyKey: idempotencyKey,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// `POST /api/v1/cluster/create` using the generated contract body.
    public func createCluster(
        route base: URL,
        request: GeneratedAPI.CreateClusterRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "cluster", "create"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// `POST /api/v1/cluster/validate`. Validation has an empty request body.
    public func validateCluster(
        route base: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "cluster", "validate"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// Prepare one member of an app-orchestrated cluster transaction.
    public func prepareClusterTransaction(
        route base: URL,
        proposal: GeneratedAPI.ClusterProposal,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterDeviceGrant {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "prepare"),
            body: proposal,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    public func activateClusterTransaction(
        route base: URL,
        proposal: GeneratedAPI.ClusterProposal,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ActivateClusterTransactionResponse200 {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "activate"),
            body: proposal,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    public func proveClusterTransaction(
        route base: URL,
        proposal: GeneratedAPI.ClusterProposal,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterLinkProof {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "prove"),
            body: proposal,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    public func runClusterCollective(
        route base: URL,
        proposal: GeneratedAPI.ClusterProposal,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterCollectiveProof {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "collective"),
            body: proposal,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// Commit the exact grant set returned by every proposed member.
    public func commitClusterTransaction(
        route base: URL,
        request: GeneratedAPI.CommitClusterTransaction,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterCommitReceipt {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "commit"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    public func finalizeClusterTransaction(
        route base: URL,
        request: GeneratedAPI.FinalizeClusterTransaction,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> ClusterStatus {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "finalize"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// Roll back only the profile and membership owned by this transaction.
    public func rollbackClusterTransaction(
        route base: URL,
        proposal: GeneratedAPI.ClusterProposal,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RollbackClusterTransactionResponse200 {
        try await post(
            endpoint(base, "api", "v1", "cluster", "transactions", "rollback"),
            body: GeneratedAPI.RollbackClusterTransactionRequest(proposal: proposal),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// Read durable launch records to restore monitoring after app relaunch without Apple-side cloud state.
    public func clusterLaunches(
        route base: URL
    ) async throws -> [GeneratedAPI.ClusterLaunchStatus] {
        try await get(endpoint(base, "api", "v1", "cluster", "launches"))
    }

    public func startClusterLaunch(
        route base: URL,
        request: GeneratedAPI.StartClusterLaunchRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterLaunchStatus {
        try await post(
            endpoint(base, "api", "v1", "cluster", "launches"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }

    /// Monitor the durable launch record on one cluster member.
    public func clusterLaunch(
        route base: URL,
        launchID: UUID
    ) async throws -> GeneratedAPI.ClusterLaunchStatus {
        try await get(
            endpoint(base, "api", "v1", "cluster", "launches", launchID.uuidString.lowercased())
        )
    }

    public func stopClusterLaunch(
        route base: URL,
        launchID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ClusterLaunchStatus {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "cluster",
                "launches",
                launchID.uuidString.lowercased(),
                "stop"
            ),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: Self.clusterTransactionTimeout
        )
    }
}

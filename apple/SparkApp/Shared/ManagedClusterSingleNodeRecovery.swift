import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public struct ManagedClusterSingleNodeCandidate: Sendable, Equatable {
    public let targetID: String
    public let targetName: String
    public let nodeID: SparkNodeID
    public let route: URL
    public let tlsFingerprint: String
    public let authorityFingerprint: String
    public let clusterID: SparkClusterID
    public let recipeRevision: String

    public init(
        targetID: String,
        targetName: String,
        nodeID: SparkNodeID,
        route: URL,
        tlsFingerprint: String,
        authorityFingerprint: String,
        clusterID: SparkClusterID,
        recipeRevision: String
    ) {
        self.targetID = targetID
        self.targetName = targetName
        self.nodeID = nodeID
        self.route = route
        self.tlsFingerprint = tlsFingerprint
        self.authorityFingerprint = authorityFingerprint
        self.clusterID = clusterID
        self.recipeRevision = recipeRevision
    }
}

public struct ManagedClusterRecoverySpec: Sendable, Equatable {
    public let launchID: UUID
    public let clusterID: UUID
    public let recipeID: String
    public let profileID: String
}

public typealias ManagedClusterRecoveryCandidateResolver =
    @Sendable (
        _ spec: ManagedClusterRecoverySpec,
        _ targets: [ExternalClusterTarget]
    ) async throws -> ManagedClusterSingleNodeCandidate?

@MainActor
public protocol VerifiedSingleNodeModelLoading: AnyObject {
    var pendingConfirmation: ModelActionConfirmation? { get }
    func prepareVerifiedLoad(
        modelID: String,
        profileID: String,
        expectedRecipeRevision: String,
        targetNodeID: String,
        targetClusterID: String?
    ) async -> Bool
    func applyPreparedLoad() async -> Bool
    func cancelPreparedLoad()
}

extension SparkDashboardModel: VerifiedSingleNodeModelLoading {
    public func applyPreparedLoad() async -> Bool {
        guard let confirmation = pendingConfirmation else { return false }
        await applyConfirmation()
        guard let state = lifecycle[confirmation.modelID] else { return false }
        return state.operation?.state == .succeeded && state.errorMessage == nil
    }

    public func cancelPreparedLoad() {
        cancelConfirmation()
    }
}

public typealias ManagedClusterRecoveryLoaderFactory =
    @MainActor @Sendable (
        _ candidate: ManagedClusterSingleNodeCandidate
    ) throws -> any VerifiedSingleNodeModelLoading

public actor SignedManagedClusterRecoveryCandidateResolver {
    public typealias RuntimeResolver =
        @Sendable (ExternalClusterTarget) throws -> (SparkAPIClient, NodeTrust)

    private let runtimeResolver: RuntimeResolver

    public init(runtimeResolver: RuntimeResolver? = nil) {
        self.runtimeResolver = runtimeResolver ?? Self.productionRuntime
    }

    public func resolve(
        spec: ManagedClusterRecoverySpec,
        targets: [ExternalClusterTarget]
    ) async throws -> ManagedClusterSingleNodeCandidate? {
        for target in targets.sorted(by: { $0.id < $1.id }) {
            do {
                let (api, trust) = try runtimeResolver(target)
                guard trust.localDeviceRole == SparkDeviceRole.owner.rawValue else { continue }
                async let loadedHealth = api.health(route: target.route)
                async let loadedStatus = api.status(route: target.route)
                async let loadedModels = api.models(route: target.route)
                async let loadedCapabilities = api.capabilities(route: target.route)
                let evidence = try await (
                    health: loadedHealth,
                    status: loadedStatus,
                    models: loadedModels,
                    capabilities: loadedCapabilities
                )
                let expectedClusterID = SparkClusterID(rawValue: spec.clusterID)
                guard evidence.health.nodeID == target.nodeID,
                    evidence.status.identity.nodeID == target.nodeID,
                    evidence.status.identity.clusterID == expectedClusterID,
                    evidence.status.identity.authorityFingerprint.caseInsensitiveCompare(
                        trust.authorityFingerprint
                    ) == .orderedSame,
                    evidence.capabilities.isEnabled("container_runtime"),
                    evidence.capabilities.isEnabled("signed_catalogue"),
                    let recipe = evidence.models.items.first(where: { $0.id == spec.recipeID }),
                    recipe.installState == .installed,
                    let revision = recipe.recipeRevision,
                    recipe.profiles.contains(where: { $0.id == spec.profileID && $0.safe })
                else { continue }
                return ManagedClusterSingleNodeCandidate(
                    targetID: target.id,
                    targetName: target.displayName,
                    nodeID: target.nodeID,
                    route: target.route,
                    tlsFingerprint: trust.tlsFingerprint,
                    authorityFingerprint: trust.authorityFingerprint,
                    clusterID: expectedClusterID,
                    recipeRevision: revision
                )
            } catch {
                continue
            }
        }
        return nil
    }

    private static func productionRuntime(
        target: ExternalClusterTarget
    ) throws -> (SparkAPIClient, NodeTrust) {
        let nodeID = target.nodeID.rawValue.uuidString.lowercased()
        guard let trust = StoredNodeTrust.reader(nodeID) else {
            throw ManagedClusterLaunchError.unavailable
        }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        return (try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer), trust)
    }
}

public enum ManagedClusterSingleNodeRecovery {
    public static let productionCandidateResolver: ManagedClusterRecoveryCandidateResolver = {
        spec,
        targets in
        try await SignedManagedClusterRecoveryCandidateResolver().resolve(
            spec: spec,
            targets: targets
        )
    }

    @MainActor
    public static func productionLoader(
        candidate: ManagedClusterSingleNodeCandidate
    ) throws -> any VerifiedSingleNodeModelLoading {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: candidate.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: candidate.tlsFingerprint, signer: signer)
        return SparkDashboardModel(
            route: candidate.route,
            runtime: api,
            targetID: candidate.targetID,
            tlsFingerprint: candidate.tlsFingerprint,
            expectedIdentity: SparkDashboardIdentityExpectation(
                coordinatorNodeID: candidate.nodeID,
                authorityFingerprint: candidate.authorityFingerprint,
                clusterID: candidate.clusterID
            ),
            targetIdentity: .node(candidate.nodeID)
        )
    }
}

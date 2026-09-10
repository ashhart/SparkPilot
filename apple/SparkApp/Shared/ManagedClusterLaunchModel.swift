import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public struct ManagedClusterLaunchFailurePresentation: Sendable, Equatable {
    public let title: String
    public let detail: String
}

public enum ManagedClusterLaunchFailureCopy {
    public static func presentation(
        for status: GeneratedAPI.ClusterLaunchStatus
    ) -> ManagedClusterLaunchFailurePresentation? {
        guard let code = status.failureCode else {
            return switch status.state {
            case .degraded, .failed:
                ManagedClusterLaunchFailurePresentation(
                    title: String(localized: "Distributed runtime needs attention"),
                    detail: String(
                        localized:
                            "Check both Sparks. You can stop the distributed runtime and review a safe single-Spark start when one member remains available."
                    )
                )
            case .preparing, .running, .stopping, .stopped: nil
            }
        }
        if code.contains("COORDINATOR_LOST") {
            return ManagedClusterLaunchFailurePresentation(
                title: String(localized: "Coordinator unavailable"),
                detail: String(
                    localized:
                        "Automatic promotion is disabled. Keep the remaining Spark online, then review a signed single-Spark start."
                )
            )
        }
        if code.contains("WORKER_LOST") {
            return ManagedClusterLaunchFailurePresentation(
                title: String(localized: "Worker unavailable"),
                detail: String(
                    localized:
                        "The distributed runtime must stop before the remaining Spark can start the same signed model safely."
                )
            )
        }
        if code.contains("STOP_UNPROVEN") || code.contains("ROLLBACK_UNPROVEN") {
            return ManagedClusterLaunchFailurePresentation(
                title: String(localized: "Cleanup needs confirmation"),
                detail: String(
                    localized:
                        "SparkPilot could not prove every distributed process stopped. Retry cleanup before starting another model."
                )
            )
        }
        if code == "WAITING_FOR_PEER_HEALTH" || code == "HEALTH_PROBE_RETRY" {
            return ManagedClusterLaunchFailurePresentation(
                title: String(localized: "Waiting for both Sparks"),
                detail: String(
                    localized:
                        "Leave both Sparks powered on while SparkPilot checks the distributed runtime."
                )
            )
        }
        if code == "OWNER_STOPPED" { return nil }
        return ManagedClusterLaunchFailurePresentation(
            title: String(localized: "Distributed start did not complete"),
            detail: String(
                localized:
                    "Check both Sparks, then review a signed single-Spark start if one member is still available."
            )
        )
    }
}

public enum ManagedClusterLaunchAvailability: Equatable {
    case checking
    case unavailable
    case available
}

@MainActor
@Observable
public final class ManagedClusterLaunchModel {
    public private(set) var availability: ManagedClusterLaunchAvailability = .checking
    public private(set) var statuses: [ManagedClusterMemberLaunchStatus] = []
    public private(set) var launchID: UUID?
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    public private(set) var recoveryMessage: String?
    public private(set) var pendingRecoveryConfirmation: ModelActionConfirmation?

    public let clusterID: UUID
    public let name: String
    private let targets: [ExternalClusterTarget]
    private let coordinator: any ManagedClusterRuntimeLaunching
    private let recoveryCandidateResolver: ManagedClusterRecoveryCandidateResolver
    private let recoveryLoaderFactory: ManagedClusterRecoveryLoaderFactory
    @ObservationIgnored private var recoveryLoader: (any VerifiedSingleNodeModelLoading)?
    @ObservationIgnored private var recoveryCandidate: ManagedClusterSingleNodeCandidate?
    @ObservationIgnored private var unresolvedStopTargetIDs: Set<String> = []

    public init(
        clusterID: UUID,
        name: String = String(localized: "Two-Spark cluster"),
        targets: [ExternalClusterTarget],
        coordinator: any ManagedClusterRuntimeLaunching = SignedManagedClusterRuntimeCoordinator(),
        recoveryCandidateResolver: @escaping ManagedClusterRecoveryCandidateResolver =
            ManagedClusterSingleNodeRecovery.productionCandidateResolver,
        recoveryLoaderFactory: @escaping ManagedClusterRecoveryLoaderFactory =
            ManagedClusterSingleNodeRecovery.productionLoader
    ) {
        self.clusterID = clusterID
        self.name = name
        self.targets = targets
        self.coordinator = coordinator
        self.recoveryCandidateResolver = recoveryCandidateResolver
        self.recoveryLoaderFactory = recoveryLoaderFactory
    }

    public var isVisible: Bool {
        availability == .available || launchID != nil
    }

    public var canStop: Bool {
        launchID != nil
            && (!unresolvedStopTargetIDs.isEmpty
                || statuses.contains { $0.status.state != .stopped })
            && !isWorking
    }

    public var missingMemberNames: [String] {
        let observed = Set(statuses.map(\.targetID))
        return targets.filter { !observed.contains($0.id) }.map(\.displayName)
    }

    public var canPrepareSingleNodeRecovery: Bool {
        !isWorking && pendingRecoveryConfirmation == nil && recoverySpec != nil
    }

    public func refresh() async {
        availability = await coordinator.available(targets: targets) ? .available : .unavailable
        do {
            let discovered = try await coordinator.launches(targets: targets)
            let matching = Dictionary(grouping: discovered) { $0.status.launchId }
                .values
                .filter { rows in
                    rows.allSatisfy {
                        $0.status.clusterId == clusterID.uuidString.lowercased()
                    }
                }
                .sorted { left, right in
                    let leftNeedsAttention = left.contains { $0.status.state != .stopped }
                    let rightNeedsAttention = right.contains { $0.status.state != .stopped }
                    if leftNeedsAttention != rightNeedsAttention { return leftNeedsAttention }
                    return (left.map(\.status.updatedAt).max() ?? "")
                        > (right.map(\.status.updatedAt).max() ?? "")
                }
                .first
            statuses = matching ?? []
            launchID = matching.flatMap { UUID(uuidString: $0[0].status.launchId) }
            reconcileStopReceipts(statuses)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "The distributed runtime state could not be read.")
        }
    }

    public func start(recipeID: String, profileID: String) async {
        guard !isWorking else { return }
        availability = await coordinator.available(targets: targets) ? .available : .unavailable
        guard availability == .available else {
            errorMessage = String(
                localized: "Distributed inference is not qualified on both Sparks."
            )
            return
        }
        isWorking = true
        defer { isWorking = false }
        let newLaunchID = UUID()
        do {
            statuses = try await coordinator.start(
                clusterID: clusterID,
                launchID: newLaunchID,
                recipeID: recipeID,
                profileID: profileID,
                targets: targets
            )
            launchID = newLaunchID
            errorMessage = nil
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The signed model could not be started on both Sparks.")
        }
    }

    public func refreshStatus() async {
        guard let launchID, !isWorking else { return }
        do {
            statuses = try await coordinator.status(launchID: launchID, targets: targets)
            reconcileStopReceipts(statuses)
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "The distributed runtime state could not be refreshed."
            )
        }
    }

    public func stop() async {
        guard let launchID, canStop else { return }
        isWorking = true
        defer { isWorking = false }
        unresolvedStopTargetIDs.formUnion(targets.map(\.id))
        do {
            let receipts = try await coordinator.stop(launchID: launchID, targets: targets)
            let receiptByTarget = Dictionary(
                uniqueKeysWithValues: receipts.map {
                    ($0.targetID, $0)
                }
            )
            statuses = statuses.map { receiptByTarget[$0.targetID] ?? $0 }
            for receipt in receipts
            where !statuses.contains(where: {
                $0.targetID == receipt.targetID
            }) {
                statuses.append(receipt)
            }
            reconcileStopReceipts(receipts)
            errorMessage =
                unresolvedStopTargetIDs.isEmpty
                ? nil
                : String(
                    localized:
                        "One Spark has not proved that its distributed runtime stopped. SparkPilot will keep retrying while it is reachable."
                )
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The two-Spark runtime could not be stopped safely.")
        }
    }

    private func reconcileStopReceipts(_ receipts: [ManagedClusterMemberLaunchStatus]) {
        for receipt in receipts where receipt.status.state == .stopped {
            unresolvedStopTargetIDs.remove(receipt.targetID)
        }
    }

    public func prepareSingleNodeRecovery() async {
        guard !isWorking, let spec = recoverySpec else { return }
        isWorking = true
        errorMessage = nil
        recoveryMessage = nil
        defer { isWorking = false }
        do {
            guard
                let candidate = try await recoveryCandidateResolver(spec, recoveryTargets)
            else {
                errorMessage = String(
                    localized:
                        "No remaining Spark has the same installed signed recipe and safe profile. Restore the missing member or install a compatible recipe before retrying."
                )
                return
            }

            let stopped = try await coordinator.stop(
                launchID: spec.launchID,
                targets: targets
            )
            guard
                stopped.contains(where: { member in
                    member.targetID == candidate.targetID
                        && member.status.state == .stopped
                        && member.status.launchId == spec.launchID.uuidString.lowercased()
                        && member.status.clusterId == spec.clusterID.uuidString.lowercased()
                        && member.status.recipeId == spec.recipeID
                        && member.status.profileId == spec.profileID
                })
            else {
                errorMessage = String(
                    localized:
                        "The distributed runtime could not prove it stopped on the remaining Spark. Retry cleanup before starting another model."
                )
                return
            }
            statuses = stopped

            let loader = try recoveryLoaderFactory(candidate)
            let prepared = await loader.prepareVerifiedLoad(
                modelID: spec.recipeID,
                profileID: spec.profileID,
                expectedRecipeRevision: candidate.recipeRevision,
                targetNodeID: candidate.nodeID.rawValue.uuidString.lowercased(),
                targetClusterID: candidate.clusterID.rawValue.uuidString.lowercased()
            )
            guard prepared, let confirmation = loader.pendingConfirmation else {
                errorMessage = String(
                    localized:
                        "The remaining Spark could not prepare a current signed start review. Nothing new was started."
                )
                return
            }
            recoveryLoader = loader
            recoveryCandidate = candidate
            pendingRecoveryConfirmation = confirmation
            recoveryMessage = String(
                localized:
                    "The distributed runtime is stopped. Review the signed single-Spark start before anything else runs."
            )
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(
                    localized:
                        "Single-Spark recovery could not be prepared. Nothing new was started."
                )
        }
    }

    public func cancelSingleNodeRecovery() {
        recoveryLoader?.cancelPreparedLoad()
        recoveryLoader = nil
        recoveryCandidate = nil
        pendingRecoveryConfirmation = nil
        recoveryMessage = nil
    }

    public func confirmSingleNodeRecovery() async {
        guard !isWorking, let loader = recoveryLoader, recoveryCandidate != nil else {
            return
        }
        isWorking = true
        pendingRecoveryConfirmation = nil
        defer { isWorking = false }
        if await loader.applyPreparedLoad() {
            recoveryMessage = String(
                localized: "The signed model is now running on the remaining Spark."
            )
            errorMessage = nil
            recoveryLoader = nil
            recoveryCandidate = nil
        } else {
            pendingRecoveryConfirmation = loader.pendingConfirmation
            errorMessage = String(
                localized:
                    "The remaining Spark did not confirm the model start. Check its current model state before retrying."
            )
        }
    }

    private var recoverySpec: ManagedClusterRecoverySpec? {
        guard let launchID,
            statuses.contains(where: { status in
                status.status.state == .degraded || status.status.state == .failed
                    || status.status.failureCode?.contains("_LOST") == true
            }),
            let first = statuses.first
        else { return nil }
        let cluster = clusterID.uuidString.lowercased()
        let launch = launchID.uuidString.lowercased()
        guard !first.status.recipeId.isEmpty, !first.status.profileId.isEmpty,
            statuses.allSatisfy({ member in
                member.status.clusterId == cluster
                    && member.status.launchId == launch
                    && member.status.recipeId == first.status.recipeId
                    && member.status.profileId == first.status.profileId
                    && member.status.coordinatorNodeId == first.status.coordinatorNodeId
                    && member.status.workerNodeId == first.status.workerNodeId
            })
        else { return nil }
        return ManagedClusterRecoverySpec(
            launchID: launchID,
            clusterID: clusterID,
            recipeID: first.status.recipeId,
            profileID: first.status.profileId
        )
    }

    private var recoveryTargets: [ExternalClusterTarget] {
        let unavailableNodeIDs = Set(
            statuses.compactMap { member -> UUID? in
                guard let code = member.status.failureCode else { return nil }
                if code.contains("WORKER_LOST") {
                    return UUID(uuidString: member.status.workerNodeId)
                }
                if code.contains("COORDINATOR_LOST") {
                    return UUID(uuidString: member.status.coordinatorNodeId)
                }
                return nil
            }
        )
        return targets.filter { !unavailableNodeIDs.contains($0.nodeID.rawValue) }
    }
}

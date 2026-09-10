import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

@MainActor
@Observable
public final class ExternalClusterPreviewModel {
    public private(set) var targets: [ExternalClusterTarget]
    public private(set) var selectedTargetIDs: Set<String> = []
    public var coordinatorTargetID: String? {
        didSet { clearReview() }
    }
    public var name: String {
        didSet { clearReview() }
    }
    public private(set) var presentation: ExternalClusterPreviewPresentation?
    public private(set) var isReviewing = false
    public private(set) var isAuthorizing = false
    public private(set) var errorMessage: String?
    public private(set) var actionMessage: String?
    public private(set) var refreshingRegistrationID: String?
    public private(set) var launchModels: [ManagedClusterLaunchModel] = []

    /// QA-25: how many standalone Sparks are saved at all, so the empty state can tell "none paired" from "none usable here".
    public var accessGate: SparkAccessGate {
        .resolve(
            savedSparks: library?.entries.filter { $0.kind == .standalone }.count ?? 0,
            usableTargets: targets.count
        )
    }

    private let provider: any ExternalClusterPreviewProviding
    private let clusterAuthorizer: any ManagedClusterAuthorizing
    private let clusterRuntime: any ManagedClusterRuntimeLaunching
    private let library: SparkLibrary?
    private let trustLookup: ExternalClusterTargetList.TrustLookup
    private var reviewedEvidence: ExternalClusterEvidence?
    private var reviewedTargets: [ExternalClusterTarget] = []

    public init(
        targets: [ExternalClusterTarget],
        name: String = String(localized: "External cluster"),
        library: SparkLibrary? = nil,
        trustLookup: @escaping ExternalClusterTargetList.TrustLookup = StoredNodeTrust.reader,
        provider: any ExternalClusterPreviewProviding = SignedExternalClusterPreviewProvider(),
        clusterAuthorizer: any ManagedClusterAuthorizing = SignedManagedClusterCoordinator(),
        clusterRuntime: any ManagedClusterRuntimeLaunching =
            SignedManagedClusterRuntimeCoordinator()
    ) {
        self.targets = targets
        self.name = name
        self.library = library
        self.trustLookup = trustLookup
        self.provider = provider
        self.clusterAuthorizer = clusterAuthorizer
        self.clusterRuntime = clusterRuntime
        refreshManagedLaunchModels()
    }

    public var launchModel: ManagedClusterLaunchModel? { launchModels.first }

    public var selectedTargets: [ExternalClusterTarget] {
        targets.filter { selectedTargetIDs.contains($0.id) }
    }

    public var canReview: Bool {
        selectedTargetIDs.count >= 2
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isReviewing && !isAuthorizing
    }

    public var canAuthorize: Bool {
        selectedTargetIDs.count == 2
            && coordinatorTargetID.map(selectedTargetIDs.contains) == true
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isReviewing && !isAuthorizing
    }

    public var canRegister: Bool {
        library != nil
            && reviewedEvidence?.localRegistrationEligible == true
            && presentation?.availableControls.contains(.registration) == true
    }

    public func registeredClusters(at date: Date = Date()) -> [ExternalClusterRegisteredRow] {
        library?.externalClusterEntries.compactMap { entry in
            guard let registration = entry.externalClusterRegistration else { return nil }
            return ExternalClusterRegisteredRow(
                id: entry.id,
                name: entry.displayName,
                memberCount: entry.members.count,
                topologyIsStale: registration.topologyIsStale(at: date),
                lastVerifiedAt: registration.lastVerifiedAt
            )
        } ?? []
    }

    public func replaceTargets(_ targets: [ExternalClusterTarget]) {
        self.targets = targets
        selectedTargetIDs.formIntersection(targets.map(\.id))
        if coordinatorTargetID.map(selectedTargetIDs.contains) != true {
            coordinatorTargetID = selectedTargets.first?.id
        }
        clearReview()
        refreshManagedLaunchModels()
    }

    public func toggle(_ targetID: String) {
        guard targets.contains(where: { $0.id == targetID }) else { return }
        if selectedTargetIDs.contains(targetID) {
            selectedTargetIDs.remove(targetID)
        } else {
            selectedTargetIDs.insert(targetID)
        }
        if coordinatorTargetID.map(selectedTargetIDs.contains) != true {
            coordinatorTargetID = selectedTargets.first?.id
        }
        clearReview()
    }

    public func review() async {
        guard canReview else { return }
        isReviewing = true
        defer { isReviewing = false }
        errorMessage = nil
        presentation = nil
        let targets = selectedTargets
        do {
            let evidence = try await provider.review(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                targets: targets
            )
            try Task.checkCancellation()
            presentation = ExternalClusterPreviewPresentation(
                evidence: evidence,
                targets: targets
            )
            reviewedEvidence = evidence
            reviewedTargets = targets
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The cluster evidence could not be read.")
        }
    }

    public func authorizeNewCluster() async {
        guard canAuthorize else { return }
        isAuthorizing = true
        defer { isAuthorizing = false }
        errorMessage = nil
        actionMessage = nil
        do {
            guard
                let coordinatorTarget = selectedTargets.first(where: {
                    $0.id == coordinatorTargetID
                }),
                let orderedTargets = ManagedClusterMemberOrder.coordinatorFirst(
                    selectedTargets,
                    coordinatorNodeID: coordinatorTarget.nodeID.rawValue
                )
            else { throw ManagedClusterError.memberCount }
            let outcome = try await clusterAuthorizer.authorize(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                coordinatorNodeID: coordinatorTarget.nodeID.rawValue,
                targets: orderedTargets
            )
            try Task.checkCancellation()
            try acceptReadyCluster(outcome, name: name, targets: orderedTargets)
            actionMessage = String(
                localized: "The two Sparks are linked, trusted and ready as one cluster."
            )
            selectedTargetIDs = []
            clearReview()
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The cluster could not be set up.")
        }
    }

    public func reconcilePendingAuthorization() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        defer { isAuthorizing = false }
        errorMessage = nil
        do {
            guard let reconciliation = try await clusterAuthorizer.reconcilePending() else {
                return
            }
            switch reconciliation.resolution {
            case .ready(let outcome):
                try acceptReadyCluster(
                    outcome,
                    name: reconciliation.name,
                    targets: reconciliation.targets
                )
                actionMessage = String(
                    localized: "The interrupted cluster setup finished safely on both Sparks."
                )
            case .rolledBack:
                actionMessage = String(
                    localized:
                        "The interrupted cluster setup was safely rolled back on both Sparks."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "The interrupted cluster setup still needs attention.")
        }
    }

    private func acceptReadyCluster(
        _ outcome: ManagedClusterOutcome,
        name: String,
        targets: [ExternalClusterTarget]
    ) throws {
        let targets = targets
        guard outcome.memberNodeIDs.count == 2,
            outcome.memberNodeIDs == targets.map(\.nodeID.rawValue),
            outcome.statusByNodeID.count == 2,
            outcome.statusByNodeID.values.allSatisfy({ $0.state == "ready" })
        else { throw ManagedClusterError.commitFailed(String(localized: "A selected Spark")) }
        if let library {
            for (index, target) in targets.enumerated() {
                let rawNodeID = target.nodeID.rawValue.uuidString.lowercased()
                let trust = trustLookup(rawNodeID)
                library.reconcile(
                    AuthenticatedTarget(
                        nodeID: target.nodeID,
                        clusterID: SparkClusterID(rawValue: outcome.clusterID),
                        name: target.displayName,
                        role: index == 0 ? .leader : .worker,
                        authorityFingerprint: trust?.authorityFingerprint,
                        displayName: target.displayName,
                        routes: [CachedRoute(baseURL: target.route, kind: .localWiFi)]
                    )
                )
            }
        }
        launchModels.removeAll { $0.clusterID == outcome.clusterID }
        launchModels.append(
            ManagedClusterLaunchModel(
                clusterID: outcome.clusterID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                targets: targets,
                coordinator: clusterRuntime
            )
        )
    }

    public func register() {
        guard canRegister,
            let library,
            let evidence = reviewedEvidence
        else { return }
        do {
            let links = try Self.registrationLinks(from: evidence.preview)
            let entry = try library.registerExternalCluster(
                name: evidence.preview.name,
                authorityFingerprint: evidence.authorityFingerprint,
                memberNodeIDs: reviewedTargets.map(\.nodeID),
                authenticatedLinks: links,
                verifiedAt: evidence.verifiedAt
            )
            actionMessage = String(localized: .clusterAddedWithoutChange(entry.displayName))
            reviewedEvidence = nil
            reviewedTargets = []
            presentation = nil
            selectedTargetIDs = []
        } catch {
            errorMessage =
                String(
                    localized:
                        "The cluster could not be saved on this device. Review the evidence again."
                )
        }
    }

    public func removeRegistration(_ entryID: String) {
        guard library?.removeExternalClusterRegistration(entryID: entryID) != nil else { return }
        actionMessage = String(
            localized: "The cluster grouping was removed. Each Spark is available separately."
        )
    }

    public func startVerifiedModel(
        clusterTargetID: String,
        recipeID: String,
        profileID: String
    ) async {
        guard case .cluster(let clusterID) = SparkTargetIdentity(rawValue: clusterTargetID),
            let launch = launchModels.first(where: { $0.clusterID == clusterID.rawValue })
        else {
            errorMessage = String(localized: "The selected two-Spark cluster is unavailable.")
            return
        }
        await launch.start(recipeID: recipeID, profileID: profileID)
        if let launchError = launch.errorMessage {
            errorMessage = launchError
        } else {
            errorMessage = nil
            actionMessage = String(localized: "The signed model is starting on both Sparks.")
        }
    }

    public func refreshLaunchMonitoring() async {
        refreshManagedLaunchModels()
        for launch in launchModels {
            await launch.refresh()
        }
    }

    public func refreshRegistration(_ entryID: String) async {
        guard refreshingRegistrationID == nil,
            let library,
            let entry = library.entry(id: entryID),
            let registration = entry.externalClusterRegistration
        else { return }
        refreshingRegistrationID = entryID
        defer { refreshingRegistrationID = nil }
        errorMessage = nil
        do {
            let targets = try ExternalClusterTargetList.registeredTargets(
                for: entry,
                trustLookup: trustLookup
            )
            guard targets.count == registration.memberNodeIDs.count else {
                throw ExternalClusterPreviewError.signedEvidenceMismatch
            }
            let evidence = try await provider.review(name: entry.displayName, targets: targets)
            guard evidence.localRegistrationEligible else {
                throw ExternalClusterPreviewError.signedEvidenceMismatch
            }
            _ = try library.refreshExternalClusterRegistration(
                entryID: entryID,
                authorityFingerprint: evidence.authorityFingerprint,
                authenticatedLinks: Self.registrationLinks(from: evidence.preview),
                verifiedAt: evidence.verifiedAt
            )
            actionMessage = String(localized: .clusterTopologyReverified(entry.displayName))
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? String(
                    localized:
                        "The saved topology could not be refreshed. The last verified copy is still available."
                )
        }
    }

    private static func registrationLinks(
        from preview: GeneratedAPI.ExternalClusterImportPreview
    ) throws -> [ExternalClusterAuthenticatedLink] {
        try preview.authenticatedLinks.map { link in
            guard let first = UUID(uuidString: link.memberANodeId),
                let second = UUID(uuidString: link.memberBNodeId),
                let verifiedAt = ISO8601DateFormatter().date(from: link.verifiedAt),
                let expiresAt = ISO8601DateFormatter().date(from: link.expiresAt)
            else { throw ExternalClusterPreviewError.signedEvidenceMismatch }
            return ExternalClusterAuthenticatedLink(
                memberANodeID: SparkNodeID(rawValue: first),
                memberAPortID: link.memberAPortId,
                memberBNodeID: SparkNodeID(rawValue: second),
                memberBPortID: link.memberBPortId,
                verifiedAt: verifiedAt,
                expiresAt: expiresAt
            )
        }
    }

    private func clearReview() {
        presentation = nil
        errorMessage = nil
        reviewedEvidence = nil
        reviewedTargets = []
    }

    public func refreshManagedLaunchModels() {
        guard let library else { return }
        let groups = ExternalClusterTargetList.managedClusters(
            in: library,
            trustLookup: trustLookup
        )
        let current = Dictionary(
            uniqueKeysWithValues: launchModels.map { ($0.clusterID, $0) }
        )
        launchModels = groups.map { group in
            current[group.clusterID.rawValue]
                ?? ManagedClusterLaunchModel(
                    clusterID: group.clusterID.rawValue,
                    name: group.name,
                    targets: group.targets,
                    coordinator: clusterRuntime
                )
        }
    }
}

public struct ExternalClusterRegisteredRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let memberCount: Int
    public let topologyIsStale: Bool
    public let lastVerifiedAt: Date
}

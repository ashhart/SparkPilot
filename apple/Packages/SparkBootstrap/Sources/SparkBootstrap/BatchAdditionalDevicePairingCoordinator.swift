import Foundation
import SparkSecurity

public struct BatchPairingRunResult: Sendable {
    public let progress: BatchPairingProgress
    public let grants: [String: NodeTrust]

    public var pairedCount: Int { progress.pairedCount }
    public var failedCount: Int { progress.failedCount }
    public var isFullyPaired: Bool { pairedCount == progress.targets.count }
}

public enum BatchPairingCoordinatorError: Error, Equatable, Sendable {
    case recipientIdentityChanged
    case unsafeRoute(nodeID: String)
    case grantForAnotherSpark(nodeID: String)
    case targetNotRetryable(nodeID: String)
}

/// Validate the whole batch before requests and persist each independent claim transition in Keychain across relaunch.
public actor BatchAdditionalDevicePairingCoordinator {
    public typealias Claim =
        @Sendable (
            AdditionalDevicePairingPackage,
            URL
        ) async throws -> NodeTrust

    private let identity: BatchPairingParticipantIdentity
    private let store: any BatchPairingProgressStoring
    private let claim: Claim
    private let now: @Sendable () -> Date

    public init(
        identity: BatchPairingParticipantIdentity,
        store: any BatchPairingProgressStoring = SecureBatchPairingProgressStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        claim: @escaping Claim
    ) {
        self.identity = identity
        self.store = store
        self.now = now
        self.claim = claim
    }

    public func accept(payload: String) async throws -> BatchPairingRunResult {
        let package = try BatchAdditionalDevicePairingPackage(payload: payload, now: now())
        guard package.recipient == identity else {
            throw BatchPairingCoordinatorError.recipientIdentityChanged
        }
        var progress = BatchPairingProgress(package: package, now: now())
        try store.save(progress)
        return try await run(&progress, targetIDs: nil)
    }

    public func retry(batchID: UUID, nodeID: String) async throws -> BatchPairingRunResult {
        guard var progress = try store.load(batchID: batchID) else {
            throw BatchAdditionalDevicePairingPackageError.corruptProgress
        }
        guard progress.recipient == identity else {
            throw BatchPairingCoordinatorError.recipientIdentityChanged
        }
        guard let target = progress.targets.first(where: { $0.id == nodeID.lowercased() }),
            target.phase == .failed
        else {
            throw BatchPairingCoordinatorError.targetNotRetryable(nodeID: nodeID)
        }
        return try await run(&progress, targetIDs: [nodeID.lowercased()])
    }

    public func resume(batchID: UUID) async throws -> BatchPairingRunResult {
        guard var progress = try store.load(batchID: batchID) else {
            throw BatchAdditionalDevicePairingPackageError.corruptProgress
        }
        guard progress.recipient == identity else {
            throw BatchPairingCoordinatorError.recipientIdentityChanged
        }
        let interrupted = Set(
            progress.targets
                .filter { $0.phase == .pending || $0.phase == .pairing }
                .map(\.id)
        )
        return try await run(&progress, targetIDs: interrupted)
    }

    private func run(
        _ progress: inout BatchPairingProgress,
        targetIDs: Set<String>?
    ) async throws -> BatchPairingRunResult {
        var grants: [String: NodeTrust] = [:]
        for index in progress.targets.indices {
            let nodeID = progress.targets[index].id
            let phase = progress.targets[index].phase
            let selected = targetIDs?.contains(nodeID) ?? (phase == .pending || phase == .failed)
            guard selected else { continue }

            progress.targets[index].phase = .pairing
            progress.targets[index].lastError = nil
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
            do {
                let target = progress.targets[index].target
                guard let route = target.package.localHintURL,
                    route.scheme?.lowercased() == "https",
                    route.user == nil,
                    route.password == nil,
                    route.host != nil
                else {
                    throw BatchPairingCoordinatorError.unsafeRoute(nodeID: nodeID)
                }
                let trust = try await claim(target.package, route)
                guard trust.nodeID.lowercased() == nodeID else {
                    throw BatchPairingCoordinatorError.grantForAnotherSpark(nodeID: nodeID)
                }
                progress.targets[index].phase = .paired
                progress.targets[index].lastError = nil
                grants[nodeID] = trust
            } catch {
                progress.targets[index].phase = .failed
                progress.targets[index].lastError = Self.safeMessage(error)
            }
            progress.targets[index].updatedAt = now()
            progress.updatedAt = now()
            try store.save(progress)
        }
        return BatchPairingRunResult(progress: progress, grants: grants)
    }

    private static func safeMessage(_ error: Error) -> String {
        switch error {
        case BatchPairingCoordinatorError.unsafeRoute:
            return String(localized: "This Spark did not provide a safe local address.")
        case BatchPairingCoordinatorError.grantForAnotherSpark:
            return String(localized: "This Spark returned a grant for a different node.")
        default:
            return String(
                localized:
                    "Pairing failed. Keep both devices on the same network and retry this Spark."
            )
        }
    }
}

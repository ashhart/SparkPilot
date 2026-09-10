import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public struct ManagedClusterMemberLaunchStatus: Sendable, Equatable {
    public let targetID: String
    public let targetName: String
    public let status: GeneratedAPI.ClusterLaunchStatus

    public init(
        targetID: String,
        targetName: String,
        status: GeneratedAPI.ClusterLaunchStatus
    ) {
        self.targetID = targetID
        self.targetName = targetName
        self.status = status
    }
}

public protocol ManagedClusterRuntimeLaunching: Sendable {
    func available(targets: [ExternalClusterTarget]) async -> Bool
    func start(
        clusterID: UUID,
        launchID: UUID,
        recipeID: String,
        profileID: String,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus]
    func launches(
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus]
    func status(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus]
    func stop(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus]
}

public enum ManagedClusterLaunchError: Error, LocalizedError {
    case memberCount
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .memberCount:
            String(localized: "A distributed launch requires exactly two paired Sparks.")
        case .unavailable:
            String(localized: "Distributed inference is not qualified on both Sparks.")
        }
    }
}

public actor SignedManagedClusterRuntimeCoordinator: ManagedClusterRuntimeLaunching {
    public typealias RuntimeResolver = SignedManagedClusterCoordinator.RuntimeResolver

    private let runtimeResolver: RuntimeResolver
    private let presenceAuthorizer: any UserPresenceAuthorizing

    public init(
        runtimeResolver: RuntimeResolver? = nil,
        presenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.runtimeResolver = runtimeResolver ?? SignedManagedClusterCoordinator.productionRuntime
        self.presenceAuthorizer = presenceAuthorizer
    }

    public func available(targets: [ExternalClusterTarget]) async -> Bool {
        guard targets.count == 2 else { return false }
        do {
            for target in targets {
                let (api, _) = try runtimeResolver(target)
                let capabilities = try await api.capabilities(route: target.route)
                guard capabilities.isEnabled("cluster_inference") else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    public func start(
        clusterID: UUID,
        launchID: UUID,
        recipeID: String,
        profileID: String,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        guard targets.count == 2 else { throw ManagedClusterLaunchError.memberCount }
        guard await available(targets: targets) else {
            throw ManagedClusterLaunchError.unavailable
        }
        let coordinatorNodeID = try await authoritativeCoordinator(
            clusterID: clusterID,
            targets: targets
        )
        guard
            let launchOrder = ManagedClusterMemberOrder.workerFirst(
                targets,
                coordinatorNodeID: coordinatorNodeID
            )
        else { throw ManagedClusterLaunchError.memberCount }
        let presence = try await presenceAuthorizer.authorize(
            localizedReason: String(localized: "Start this signed model on both Sparks")
        )
        let request = GeneratedAPI.StartClusterLaunchRequest(
            clusterId: clusterID.uuidString.lowercased(),
            launchId: launchID.uuidString.lowercased(),
            recipeId: recipeID,
            profileId: profileID
        )
        var started: [ManagedClusterMemberLaunchStatus] = []
        do {
            for target in launchOrder {
                let (api, _) = try runtimeResolver(target)
                let status = try await api.startClusterLaunch(
                    route: target.route,
                    request: request,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                started.append(
                    ManagedClusterMemberLaunchStatus(
                        targetID: target.id,
                        targetName: target.displayName,
                        status: status
                    )
                )
            }
        } catch {
            for member in started {
                guard let target = targets.first(where: { $0.id == member.targetID }),
                    let (api, _) = try? runtimeResolver(target)
                else { continue }
                _ = try? await api.stopClusterLaunch(
                    route: target.route,
                    launchID: launchID,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
            }
            throw error
        }
        return started
    }

    private func authoritativeCoordinator(
        clusterID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> UUID {
        var reported: [UUID] = []
        for target in targets {
            let (api, _) = try runtimeResolver(target)
            let cluster = try await api.cluster(route: target.route)
            guard cluster.id?.rawValue == clusterID,
                Set(cluster.members.map(\.nodeID)) == Set(targets.map(\.nodeID)),
                let coordinator = cluster.members.first(where: { $0.role == "leader" })?.nodeID,
                cluster.members.filter({ $0.role == "leader" }).count == 1
            else { throw ManagedClusterLaunchError.unavailable }
            reported.append(coordinator.rawValue)
        }
        guard Set(reported).count == 1, let coordinator = reported.first else {
            throw ManagedClusterLaunchError.unavailable
        }
        return coordinator
    }

    public func launches(
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        guard targets.count == 2 else { throw ManagedClusterLaunchError.memberCount }
        var statuses: [ManagedClusterMemberLaunchStatus] = []
        var successfulMembers = 0
        for target in targets {
            do {
                let (api, _) = try runtimeResolver(target)
                let rows = try await api.clusterLaunches(route: target.route)
                successfulMembers += 1
                statuses.append(
                    contentsOf: rows.map {
                        ManagedClusterMemberLaunchStatus(
                            targetID: target.id,
                            targetName: target.displayName,
                            status: $0
                        )
                    }
                )
            } catch {
                continue
            }
        }
        guard successfulMembers > 0 else { throw ManagedClusterLaunchError.memberCount }
        return statuses
    }

    public func status(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        guard targets.count == 2 else { throw ManagedClusterLaunchError.memberCount }
        var statuses: [ManagedClusterMemberLaunchStatus] = []
        for target in targets {
            do {
                let (api, _) = try runtimeResolver(target)
                let status = try await api.clusterLaunch(route: target.route, launchID: launchID)
                statuses.append(
                    ManagedClusterMemberLaunchStatus(
                        targetID: target.id,
                        targetName: target.displayName,
                        status: status
                    )
                )
            } catch {
                continue
            }
        }
        guard !statuses.isEmpty else { throw ManagedClusterLaunchError.memberCount }
        return statuses
    }

    public func stop(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        guard targets.count == 2 else { throw ManagedClusterLaunchError.memberCount }
        let presence = try await presenceAuthorizer.authorize(
            localizedReason: String(localized: "Stop this two-Spark runtime")
        )
        var statuses: [ManagedClusterMemberLaunchStatus] = []
        for target in targets {
            do {
                let (api, _) = try runtimeResolver(target)
                let status = try await api.stopClusterLaunch(
                    route: target.route,
                    launchID: launchID,
                    idempotencyKey: UUID(),
                    userPresence: presence
                )
                statuses.append(
                    ManagedClusterMemberLaunchStatus(
                        targetID: target.id,
                        targetName: target.displayName,
                        status: status
                    )
                )
            } catch {
                continue
            }
        }
        guard !statuses.isEmpty else { throw ManagedClusterLaunchError.memberCount }
        return statuses
    }
}

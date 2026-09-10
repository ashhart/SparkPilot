import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

actor ExternalClusterTestExternalPreviewProvider: ExternalClusterPreviewProviding {
    let result: Result<ExternalClusterEvidence, any Error>
    private(set) var requests: [(String, [String])] = []

    init(result: Result<ExternalClusterEvidence, any Error>) {
        self.result = result
    }

    func review(
        name: String,
        targets: [ExternalClusterTarget]
    ) async throws -> ExternalClusterEvidence {
        requests.append((name, targets.map(\.id)))
        return try result.get()
    }

    func recordedRequests() -> [(String, [String])] { requests }
}

actor ExternalClusterTestManagedClusterAuthorizerFixture: ManagedClusterAuthorizing {
    private(set) var requests: [(String, UUID, [String])] = []

    func authorize(
        name: String,
        coordinatorNodeID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> ManagedClusterOutcome {
        requests.append((name, coordinatorNodeID, targets.map(\.id)))
        let clusterID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        let status = try JSONDecoder().decode(
            ClusterStatus.self,
            from: Data(
                """
                {"id":"\(clusterID.uuidString.lowercased())","name":"\(name)","state":"ready","members":[]}
                """.utf8
            )
        )
        return ManagedClusterOutcome(
            clusterID: clusterID,
            memberNodeIDs: targets.map(\.nodeID.rawValue),
            statusByNodeID: Dictionary(
                uniqueKeysWithValues: targets.map { ($0.nodeID.rawValue, status) }
            )
        )
    }

    func recordedRequests() -> [(String, UUID, [String])] { requests }
}

actor ExternalClusterTestManagedClusterRuntimeFixture: ManagedClusterRuntimeLaunching {
    let isAvailable: Bool
    let listedStatuses: [ManagedClusterMemberLaunchStatus]
    private(set) var stopRequests = 0
    private(set) var startRequests = 0
    private(set) var listRequests = 0
    private(set) var statusRequests = 0
    private let stopObserver: (@Sendable () async -> Void)?
    private let stopStatuses: [ManagedClusterMemberLaunchStatus]?

    init(
        isAvailable: Bool,
        listedStatuses: [ManagedClusterMemberLaunchStatus] = [],
        stopStatuses: [ManagedClusterMemberLaunchStatus]? = nil,
        stopObserver: (@Sendable () async -> Void)? = nil
    ) {
        self.isAvailable = isAvailable
        self.listedStatuses = listedStatuses
        self.stopStatuses = stopStatuses
        self.stopObserver = stopObserver
    }

    func available(targets: [ExternalClusterTarget]) async -> Bool {
        isAvailable && targets.count == 2
    }

    func start(
        clusterID: UUID,
        launchID: UUID,
        recipeID: String,
        profileID: String,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        startRequests += 1
        return targets.indices.map {
            ManagedClusterMemberLaunchStatus(
                targetID: targets[$0].id,
                targetName: targets[$0].displayName,
                status: GeneratedAPI.ClusterLaunchStatus(
                    launchId: launchID.uuidString.lowercased(),
                    clusterId: clusterID.uuidString.lowercased(),
                    recipeId: recipeID,
                    profileId: profileID,
                    state: .preparing,
                    coordinatorNodeId: targets[0].nodeID.rawValue.uuidString.lowercased(),
                    workerNodeId: targets[1].nodeID.rawValue.uuidString.lowercased(),
                    failureCode: nil,
                    updatedAt: "2026-09-01T12:00:00Z"
                )
            )
        }
    }

    func launches(
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        listRequests += 1
        return listedStatuses
    }

    func status(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        statusRequests += 1
        return listedStatuses.filter {
            $0.status.launchId == launchID.uuidString.lowercased()
        }
    }

    func stop(
        launchID: UUID,
        targets: [ExternalClusterTarget]
    ) async throws -> [ManagedClusterMemberLaunchStatus] {
        stopRequests += 1
        await stopObserver?()
        if let stopStatuses { return stopStatuses }
        return targets.indices.map {
            ManagedClusterMemberLaunchStatus(
                targetID: targets[$0].id,
                targetName: targets[$0].displayName,
                status: externalClusterTestManagedLaunchStatus(
                    $0,
                    targets: targets,
                    state: .stopped
                )
            )
        }
    }

    func recordedStopRequests() -> Int { stopRequests }
    func recordedStartRequests() -> Int { startRequests }
    func recordedListRequests() -> Int { listRequests }
    func recordedStatusRequests() -> Int { statusRequests }
}

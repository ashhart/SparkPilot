import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

public struct ExternalClusterTarget: Identifiable, Sendable, Equatable {
    public let libraryEntryID: String
    public let nodeID: SparkNodeID
    public let displayName: String
    public let route: URL

    public init(
        libraryEntryID: String,
        nodeID: SparkNodeID,
        displayName: String,
        route: URL
    ) {
        self.libraryEntryID = libraryEntryID
        self.nodeID = nodeID
        self.displayName = displayName
        self.route = route
    }

    public var id: String { libraryEntryID }
}

public struct ManagedClusterTargetGroup: Sendable, Equatable {
    public let clusterID: SparkClusterID
    public let name: String
    public let targets: [ExternalClusterTarget]
}

public struct ExternalClusterEvidence: Sendable, Equatable {
    public let preview: GeneratedAPI.ExternalClusterImportPreview
    public let fabricByNodeID: [SparkNodeID: GeneratedAPI.FabricStatus]
    public let authorityFingerprint: String
    public let verifiedAt: Date
    public let localRegistrationEligible: Bool

    public init(
        preview: GeneratedAPI.ExternalClusterImportPreview,
        fabricByNodeID: [SparkNodeID: GeneratedAPI.FabricStatus],
        authorityFingerprint: String = "authority",
        verifiedAt: Date = Date(timeIntervalSince1970: 0),
        localRegistrationEligible: Bool = false
    ) {
        self.preview = preview
        self.fabricByNodeID = fabricByNodeID
        self.authorityFingerprint = authorityFingerprint
        self.verifiedAt = verifiedAt
        self.localRegistrationEligible = localRegistrationEligible
    }
}

public protocol ExternalClusterPreviewProviding: Sendable {
    func review(
        name: String,
        targets: [ExternalClusterTarget]
    ) async throws -> ExternalClusterEvidence
}

public enum ExternalClusterTargetList {
    public typealias TrustLookup = @Sendable (String) -> NodeTrust?

    @MainActor
    public static func pairedStandaloneTargets(
        in library: SparkLibrary,
        trustLookup: @escaping TrustLookup = StoredNodeTrust.reader
    ) -> [ExternalClusterTarget] {
        library.entries.compactMap { entry in
            guard entry.kind == .standalone,
                entry.issue == nil,
                let nodeID = entry.standaloneNodeID,
                let route = entry.preferredRoute?.baseURL,
                let trust = trustLookup(nodeID.rawValue.uuidString.lowercased()),
                trust.localDeviceRole == SparkDeviceRole.owner.rawValue
            else { return nil }
            return ExternalClusterTarget(
                libraryEntryID: entry.id,
                nodeID: nodeID,
                displayName: entry.displayName,
                route: route
            )
        }
        .sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    @MainActor
    public static func registeredTargets(
        for entry: LibraryEntry,
        trustLookup: @escaping TrustLookup = StoredNodeTrust.reader
    ) throws -> [ExternalClusterTarget] {
        guard let registration = entry.externalClusterRegistration else { return [] }
        return try registration.memberNodeIDs.map { nodeID in
            guard let member = entry.member(nodeID: nodeID),
                let route = member.routes.first?.baseURL,
                let trust = trustLookup(nodeID.rawValue.uuidString.lowercased()),
                trust.localDeviceRole == SparkDeviceRole.owner.rawValue,
                trust.authorityFingerprint.caseInsensitiveCompare(
                    registration.authorityFingerprint
                ) == .orderedSame
            else {
                throw ExternalClusterPreviewError.pairedRouteUnavailable(
                    entry.member(nodeID: nodeID)?.name ?? String(localized: "A registered Spark")
                )
            }
            return ExternalClusterTarget(
                libraryEntryID: "\(entry.id):\(nodeID.rawValue.uuidString.lowercased())",
                nodeID: nodeID,
                displayName: member.name,
                route: route
            )
        }
    }

    @MainActor
    public static func managedClusters(
        in library: SparkLibrary,
        trustLookup: @escaping TrustLookup = StoredNodeTrust.reader
    ) -> [ManagedClusterTargetGroup] {
        library.entries.compactMap { entry in
            guard entry.externalClusterRegistration == nil,
                let clusterID = entry.clusterID,
                entry.members.count == 2
            else { return nil }
            let targets = entry.members.compactMap { member -> ExternalClusterTarget? in
                let rawNodeID = member.nodeID.rawValue.uuidString.lowercased()
                guard let route = member.routes.first?.baseURL,
                    let trust = trustLookup(rawNodeID),
                    trust.localDeviceRole == SparkDeviceRole.owner.rawValue
                else { return nil }
                return ExternalClusterTarget(
                    libraryEntryID: "\(entry.id):\(rawNodeID)",
                    nodeID: member.nodeID,
                    displayName: member.name,
                    route: route
                )
            }
            guard targets.count == 2 else { return nil }
            let coordinatorNodeID = entry.members.first(where: { $0.role == .leader })?.nodeID
                .rawValue
            guard let coordinatorNodeID,
                let orderedTargets = ManagedClusterMemberOrder.coordinatorFirst(
                    targets,
                    coordinatorNodeID: coordinatorNodeID
                )
            else { return nil }
            return ManagedClusterTargetGroup(
                clusterID: clusterID,
                name: entry.displayName,
                targets: orderedTargets
            )
        }
    }
}

public enum ExternalClusterPreviewError: Error, LocalizedError, Equatable {
    case pairedRouteUnavailable(String)
    case identityMismatch(String)
    case authorityMismatch(String)
    case targetAlreadyClustered(String)
    case signedEvidenceMismatch

    public var errorDescription: String? {
        switch self {
        case .pairedRouteUnavailable(let name):
            String(localized: .pairedRouteUnavailable(name))
        case .identityMismatch(let name):
            String(localized: .memberIdentityMismatch(name))
        case .authorityMismatch(let name):
            String(localized: .memberDifferentAuthority(name))
        case .targetAlreadyClustered(let name):
            String(localized: .memberAlreadyClustered(name))
        case .signedEvidenceMismatch:
            String(
                localized: "The Sparks did not return matching signed member and fabric evidence."
            )
        }
    }
}

public struct ExternalClusterRuntimeConnection: Sendable {
    public let api: SparkAPIClient
    public let expectedAuthorityFingerprint: String

    public init(api: SparkAPIClient, expectedAuthorityFingerprint: String) {
        self.api = api
        self.expectedAuthorityFingerprint = expectedAuthorityFingerprint
    }
}

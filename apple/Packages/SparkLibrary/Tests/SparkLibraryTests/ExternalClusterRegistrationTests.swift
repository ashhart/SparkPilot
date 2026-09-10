import Foundation
import SparkCore
import Testing
@testable import SparkLibrary

private func externalRegistrationNode(_ value: UInt64) -> SparkNodeID {
    SparkNodeID(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0, 0, 0x10, 0x40, 0x00,
                0x80, 0, 0, 0,
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
                0
            )
        )
    )
}

private func externalRegistrationTarget(
    _ value: UInt64,
    authority: String = "shared-authority"
) -> AuthenticatedTarget {
    let nodeID = externalRegistrationNode(value)
    return AuthenticatedTarget(
        nodeID: nodeID,
        clusterID: nil,
        name: "Spark \(value)",
        role: .standalone,
        authorityFingerprint: authority,
        displayName: "spark-\(value).local",
        routes: [
            CachedRoute(
                baseURL: URL(string: "https://spark-\(value).local:7443")!,
                kind: .localWiFi,
                lastSuccess: Date(timeIntervalSince1970: 100)
            )
        ],
        reachedAt: Date(timeIntervalSince1970: 100)
    )
}

private func externalRegistrationLinks(
    _ nodes: [SparkNodeID],
    verifiedAt: Date = Date(timeIntervalSince1970: 200),
    expiresAt: Date = Date(timeIntervalSince1970: 800)
) -> [ExternalClusterAuthenticatedLink] {
    zip(nodes, nodes.dropFirst()).enumerated().map { index, pair in
        ExternalClusterAuthenticatedLink(
            memberANodeID: pair.0,
            memberAPortID: "left-\(index)",
            memberBNodeID: pair.1,
            memberBPortID: "right-\(index)",
            verifiedAt: verifiedAt,
            expiresAt: expiresAt
        )
    }
}

@MainActor
@Test(arguments: [2, 3, 4])
func externalClusterRegistrationPersistsOneTargetAndRestoresEveryStandalone(memberCount: Int)
    throws
{
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store)
    for value in 1...memberCount {
        library.reconcile(externalRegistrationTarget(UInt64(value)))
    }
    let members = (1...memberCount).map { externalRegistrationNode(UInt64($0)) }
    let clusterID = SparkClusterID(
        rawValue: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    )

    let cluster = try library.registerExternalCluster(
        name: "Existing lab",
        authorityFingerprint: "shared-authority",
        memberNodeIDs: members,
        authenticatedLinks: externalRegistrationLinks(members),
        verifiedAt: Date(timeIntervalSince1970: 200),
        clusterID: clusterID
    )

    #expect(library.entries.count == 1)
    #expect(cluster.externalClusterRegistration?.memberNodeIDs == members)
    #expect(cluster.members.count == memberCount)
    #expect(cluster.members.allSatisfy { !$0.routes.isEmpty })
    #expect(!cluster.canOpen)

    library.load()
    let reloaded = try #require(library.entry(clusterID: clusterID))
    #expect(reloaded.externalClusterRegistration?.memberNodeIDs == members)
    #expect(
        reloaded.externalClusterRegistration?.topologyIsStale(at: Date(timeIntervalSince1970: 500))
            == false
    )

    _ = library.remove(entryID: reloaded.id)
    #expect(library.entries.count == memberCount)
    #expect(Set(library.entries.compactMap(\.standaloneNodeID)) == Set(members))
    #expect(library.entries.allSatisfy { $0.preferredRoute != nil })
}

@MainActor
@Test func duplicateExternalImportIsIdempotentAndOverlappingImportIsRejected() throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    for value in 1...3 {
        library.reconcile(externalRegistrationTarget(UInt64(value)))
    }
    let firstPair = [externalRegistrationNode(1), externalRegistrationNode(2)]
    let initial = try library.registerExternalCluster(
        name: "Pair",
        authorityFingerprint: "shared-authority",
        memberNodeIDs: firstPair,
        authenticatedLinks: externalRegistrationLinks(firstPair),
        verifiedAt: Date(timeIntervalSince1970: 200)
    )
    let duplicate = try library.registerExternalCluster(
        name: "Renamed duplicate",
        authorityFingerprint: "shared-authority",
        memberNodeIDs: firstPair.reversed(),
        authenticatedLinks: externalRegistrationLinks(firstPair),
        verifiedAt: Date(timeIntervalSince1970: 200)
    )

    #expect(duplicate.id == initial.id)
    #expect(library.externalClusterEntries.count == 1)
    #expect(throws: ExternalClusterRegistrationError.memberAlreadyGrouped) {
        try library.registerExternalCluster(
            name: "Overlap",
            authorityFingerprint: "shared-authority",
            memberNodeIDs: [externalRegistrationNode(2), externalRegistrationNode(3)],
            authenticatedLinks: externalRegistrationLinks([
                externalRegistrationNode(2), externalRegistrationNode(3),
            ]),
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
    }
}

@MainActor
@Test func externalImportRejectsAuthorityMismatchAndObservationOnlyTopology() {
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(externalRegistrationTarget(1))
    library.reconcile(externalRegistrationTarget(2, authority: "other-authority"))
    let members = [externalRegistrationNode(1), externalRegistrationNode(2)]

    #expect(throws: ExternalClusterRegistrationError.authorityMismatch) {
        try library.registerExternalCluster(
            name: "Wrong authority",
            authorityFingerprint: "shared-authority",
            memberNodeIDs: members,
            authenticatedLinks: externalRegistrationLinks(members),
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
    }

    let matchingLibrary = SparkLibrary(store: MemoryLibraryStore())
    matchingLibrary.reconcile(externalRegistrationTarget(1))
    matchingLibrary.reconcile(externalRegistrationTarget(2))
    #expect(throws: ExternalClusterRegistrationError.fabricEvidenceIncomplete) {
        try matchingLibrary.registerExternalCluster(
            name: "Carrier is not identity",
            authorityFingerprint: "shared-authority",
            memberNodeIDs: members,
            authenticatedLinks: [],
            verifiedAt: Date(timeIntervalSince1970: 200)
        )
    }
}

@MainActor
@Test func memberRefreshDoesNotDissolveOrRenameExternalRegistration() throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(externalRegistrationTarget(1))
    library.reconcile(externalRegistrationTarget(2))
    let members = [externalRegistrationNode(1), externalRegistrationNode(2)]
    let cluster = try library.registerExternalCluster(
        name: "Production inference",
        authorityFingerprint: "shared-authority",
        memberNodeIDs: members,
        authenticatedLinks: externalRegistrationLinks(members),
        verifiedAt: Date(timeIntervalSince1970: 200)
    )

    let outcome = library.reconcile(externalRegistrationTarget(2))

    #expect(outcome.entry.id == cluster.id)
    #expect(outcome.entry.displayName == "Production inference")
    #expect(library.entries.count == 1)
    #expect(library.entries[0].members.count == 2)
}

@Test func cachedExternalTopologyExpiresInsteadOfPretendingToBeLive() {
    let members = [externalRegistrationNode(1), externalRegistrationNode(2)]
    let registration = ExternalClusterRegistration(
        authorityFingerprint: "shared-authority",
        memberNodeIDs: members,
        registeredAt: Date(timeIntervalSince1970: 200),
        lastVerifiedAt: Date(timeIntervalSince1970: 200),
        authenticatedLinks: externalRegistrationLinks(members)
    )

    #expect(!registration.topologyIsStale(at: Date(timeIntervalSince1970: 799)))
    #expect(registration.topologyIsStale(at: Date(timeIntervalSince1970: 800)))
}

@MainActor
@Test func failedTopologyRefreshLeavesTheLastVerifiedRegistrationUntouched() throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(externalRegistrationTarget(1))
    library.reconcile(externalRegistrationTarget(2))
    let members = [externalRegistrationNode(1), externalRegistrationNode(2)]
    let cluster = try library.registerExternalCluster(
        name: "Existing lab",
        authorityFingerprint: "shared-authority",
        memberNodeIDs: members,
        authenticatedLinks: externalRegistrationLinks(members),
        verifiedAt: Date(timeIntervalSince1970: 200)
    )
    let prior = cluster.externalClusterRegistration

    #expect(throws: ExternalClusterRegistrationError.fabricEvidenceIncomplete) {
        try library.refreshExternalClusterRegistration(
            entryID: cluster.id,
            authorityFingerprint: "shared-authority",
            authenticatedLinks: [],
            verifiedAt: Date(timeIntervalSince1970: 900)
        )
    }

    #expect(library.entry(id: cluster.id)?.externalClusterRegistration == prior)
}

@Test func removingAnExternalMemberPrunesBothMembershipAndItsDanglingLinks() {
    let nodes = (1...3).map { externalRegistrationNode(UInt64($0)) }
    let registration = ExternalClusterRegistration(
        authorityFingerprint: "shared-authority",
        memberNodeIDs: nodes,
        registeredAt: Date(timeIntervalSince1970: 100),
        lastVerifiedAt: Date(timeIntervalSince1970: 200),
        authenticatedLinks: externalRegistrationLinks(nodes)
    )

    let pruned = registration.removingMember(nodes[1])

    #expect(pruned.memberNodeIDs == [nodes[0], nodes[2]])
    // Remove every link incident to a departed cluster member.
    #expect(pruned.authenticatedLinks.isEmpty)
    #expect(pruned.authorityFingerprint == registration.authorityFingerprint)
    #expect(pruned.registeredAt == registration.registeredAt)
}

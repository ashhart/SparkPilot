import Foundation
import SparkCore
import SparkLibrary
import Testing

// MARK: - Standalone cards

@Test func addingAStandaloneSparkCreatesOneCardKeyedByNodeID() {
    let outcome = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )

    #expect(outcome.effect == .added)
    #expect(outcome.library.count == 1)
    #expect(outcome.entry.standaloneNodeID == libraryNodeID(1))
    #expect(outcome.entry.id == nodeKey(1), "card is keyed by namespaced node key")
    #expect(outcome.entry.logicalKey == .node(libraryNodeID(1)))
    #expect(outcome.entry.connectionState == .connectedWiFi)
}

@Test func routeChangeMergesInPlaceNeverDuplicates() {
    let first = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )
    // Same node, new route over a different slot: must not duplicate the card.
    let second = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "172.16.10.5", kind: .directEthernet)]
        ),
        into: first.library
    )

    #expect(second.library.count == 1)
    #expect(second.entry.standaloneNodeID == libraryNodeID(1))
    #expect(second.effect == .updated)
    #expect(
        second.entry.members[0].routes.count == 2,
        "a new slot joins the card, never a new card"
    )
}

@Test func sameRouteReseenOpensTheExistingCard() {
    let moment = Date(timeIntervalSince1970: 1_700_000_000)
    let first = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")],
            reachedAt: moment
        ),
        into: []
    )
    // Reuse the existing card for a byte-identical observation.
    let second = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")],
            reachedAt: moment
        ),
        into: first.library
    )

    #expect(second.effect == .openedExisting)
    #expect(second.library.count == 1)
    #expect(second.entry.members[0].routes.count == 1)
}

@Test func sameKindDifferentInterfaceSlotsStayDistinct() {
    // Distinguish physical route slots by interface scope even when their transport kind matches.
    let first = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local", kind: .localWiFi, interface: "en0")]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local", kind: .localWiFi, interface: "en1")]
        ),
        into: first.library
    )

    #expect(second.library.count == 1)
    #expect(second.entry.members[0].routes.count == 2, "en0 and en1 stay distinct")
    #expect(
        Set(second.entry.members[0].routes.map(\.slotID))
            == Set([
                RouteSlot(kind: .localWiFi, scope: "en0"),
                RouteSlot(kind: .localWiFi, scope: "en1"),
            ]),
        "two Wi-Fi radios are two slots"
    )
}

@Test func addressChurnWithinOneInterfaceReplacesTheSlotEndpoint() {
    // Update DHCP endpoints within the same physical route slot.
    let first = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "172.16.10.5", kind: .localWiFi, interface: "en0")]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "172.16.10.99", kind: .localWiFi, interface: "en0")]
        ),
        into: first.library
    )

    #expect(second.library.count == 1)
    #expect(second.entry.members[0].routes.count == 1)
    #expect(second.entry.members[0].routes.first?.baseURL.host == "172.16.10.99")
    #expect(
        second.entry.members[0].routes.first?.slotID == RouteSlot(kind: .localWiFi, scope: "en0")
    )
}

@Test func multipleStandaloneSparksStaySeparate() {
    let first = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )
    let second = reconcile(
        target(node: 2, displayName: "spark-c3d4", routes: [route(host: "spark-c3d4.local")]),
        into: first.library
    )

    #expect(second.library.count == 2)
    #expect(second.library.map(\.standaloneNodeID) == [libraryNodeID(1), libraryNodeID(2)])
}

@Test func twoSameNamedSparksCoexistWithoutIdentityChange() {
    // Factory-default Sparks legitimately share a name on different hosts.
    let first = reconcile(
        target(
            node: 1,
            name: "DGX Spark",
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 2,
            name: "DGX Spark",
            displayName: "spark-c3d4",
            routes: [route(host: "spark-c3d4.local")]
        ),
        into: first.library
    )

    #expect(second.library.count == 2)
    #expect(second.effect == .added)
    #expect(second.library.allSatisfy { $0.issue == nil })
}

// MARK: - Identity change (authenticated route-rebind evidence only)

@Test func routeRebindToDifferentNodeIsBlockedAfterAuthenticatedEvidence() {
    // Card bound to hostname spark-a1b2 as node 1.
    let first = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )
    // A different node authenticates at that same hostname slot.
    let rebound = reconcile(
        target(node: 2, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: first.library
    )

    #expect(rebound.effect == .identityChanged)
    #expect(rebound.library.count == 1, "the rebound node is not added")
    #expect(rebound.entry.issue == .identityMismatch)
    #expect(rebound.entry.connectionState == .identityMismatch)
    #expect(
        rebound.entry.standaloneNodeID == libraryNodeID(1),
        "the saved card is blocked, not replaced"
    )
}

@Test func matchingOnlyTheSparkNameNeverBlocksANewCard() {
    // Same identity name, different hostname slot → legitimate separate card.
    let first = reconcile(
        target(
            node: 1,
            name: "Kitchen Spark",
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 2,
            name: "Kitchen Spark",
            displayName: "spark-c3d4",
            routes: [route(host: "spark-c3d4.local")]
        ),
        into: first.library
    )

    #expect(second.effect == .added)
    #expect(second.library.count == 2)
    #expect(second.library.allSatisfy { $0.issue == nil })
}

@Test func unknownEmptyDisplayNameNeverBlocks() {
    let first = reconcile(
        target(
            node: 1,
            name: "Lab Spark",
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 2,
            name: "Lab Spark",
            displayName: "spark-c3d4",
            routes: [route(host: "spark-c3d4.local")]
        ),
        into: first.library
    )

    #expect(second.effect == .added)
    #expect(second.library.count == 2)
}

// MARK: - Clusters

@Test func nodeReportingKnownClusterOpensTheClusterCard() {
    let created = reconcile(
        target(
            node: 1,
            cluster: 1,
            name: "Cluster One",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    #expect(created.effect == .added)
    #expect(created.entry.kind == .cluster)
    #expect(created.entry.id == clusterKey(1), "cluster card is keyed by namespaced cluster key")

    // A new worker joins the known cluster: still one cluster card.
    let joined = reconcile(
        target(
            node: 2,
            cluster: 1,
            name: "Worker One",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        ),
        into: created.library
    )

    #expect(joined.effect == .clusterMemberUpdated)
    #expect(joined.library.count == 1)
    #expect(joined.entry.kind == .cluster)
    #expect(joined.entry.members.count == 2)
    #expect(joined.entry.coordinatorNodeID == libraryNodeID(1), "leader is the coordinator")
}

@Test func unknownClusterBecomesOneLogicalCardWithItsMemberListed() {
    let outcome = reconcile(
        target(
            node: 2,
            cluster: 9,
            name: "Worker Node",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        ),
        into: []
    )

    #expect(outcome.library.count == 1)
    #expect(outcome.entry.kind == .cluster)
    #expect(outcome.entry.members.count == 1)
    #expect(outcome.entry.members[0].role == .worker)
}

@Test func standaloneIsAbsorbedWhenItJoinsACluster() {
    let standalone = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )
    // Node 1 now reports it is the leader of a new cluster.
    let absorbed = reconcile(
        target(
            node: 1,
            cluster: 4,
            name: "New Cluster",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: standalone.library
    )

    #expect(absorbed.effect == .topologyChanged)
    #expect(absorbed.library.count == 1)
    #expect(absorbed.entry.kind == .cluster)
    #expect(absorbed.entry.standaloneNodeID == nil, "standalone card no longer exists at top level")
    #expect(absorbed.entry.coordinatorNodeID == libraryNodeID(1))
}

@Test func nodeMovingBetweenClustersIsATopologyChangeAndPrunesEmptyCluster() {
    let leader = reconcile(
        target(
            node: 1,
            cluster: 1,
            name: "Cluster One",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let withWorker = reconcile(
        target(
            node: 2,
            cluster: 1,
            name: "Worker One",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        ),
        into: leader.library
    )
    // The worker leaves cluster 1 and joins cluster 2 (authenticated).
    let moved = reconcile(
        target(
            node: 2,
            cluster: 2,
            name: "Worker One",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        ),
        into: withWorker.library
    )

    #expect(moved.effect == .topologyChanged)
    #expect(moved.library.count == 2, "cluster 1 keeps its leader; cluster 2 is created")
    #expect(
        moved.library.contains {
            $0.clusterID == libraryClusterID(1) && $0.members.map(\.nodeID) == [libraryNodeID(1)]
        }
    )
    let clusterTwo = moved.library.first { $0.clusterID == libraryClusterID(2) }
    #expect(clusterTwo?.members.map(\.nodeID) == [libraryNodeID(2)])
    #expect(
        moved.library.allSatisfy { $0.issue == nil },
        "topology change is not an identity issue"
    )
}

@Test func moveToANewClusterPrunesAnEmptyOldClusterCard() {
    // Remove a cluster container left empty when its only leader joins another cluster.
    let only = reconcile(
        target(
            node: 1,
            cluster: 1,
            name: "Alone",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let moved = reconcile(
        target(
            node: 1,
            cluster: 2,
            name: "Alone",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: only.library
    )

    #expect(moved.library.count == 1)
    #expect(moved.library.first?.clusterID == libraryClusterID(2))
}

@Test func workerOnlyClusterHasNoUsableCoordinatorRoute() {
    let outcome = reconcile(
        target(
            node: 2,
            cluster: 9,
            name: "Worker Node",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        ),
        into: []
    )

    #expect(outcome.entry.coordinatorNodeID == nil)
    #expect(outcome.entry.preferredRoute == nil)
    #expect(LibraryReconciler.connectionState(for: outcome.entry) == .offlineCached)
}

// MARK: - Namespaced keys and stable route slots

@Test func nodeAndClusterWithTheSameRawUUIDDoNotCollide() {
    // Namespace node and cluster keys so identical UUID bytes cannot merge unrelated cards.
    let sharedUUID = libraryNodeID(7).rawValue
    let sharedCluster = SparkClusterID(rawValue: sharedUUID)

    let standalone = reconcile(
        AuthenticatedTarget(
            nodeID: SparkNodeID(rawValue: sharedUUID),
            clusterID: nil,
            name: "Node Seven",
            role: .standalone,
            authorityFingerprint: "fp",
            displayName: "spark-7777",
            routes: [route(host: "spark-7777.local")]
        ),
        into: []
    )
    let cluster = reconcile(
        AuthenticatedTarget(
            nodeID: libraryNodeID(8),
            clusterID: sharedCluster,
            name: "Cluster Seven",
            role: .leader,
            authorityFingerprint: "fp",
            displayName: "spark-8888",
            routes: [route(host: "spark-8888.local")]
        ),
        into: standalone.library
    )

    #expect(cluster.library.count == 2)
    let clusterKeyString = "cluster:\(sharedUUID.uuidString.lowercased())"
    let nodeKeyString = "node:\(sharedUUID.uuidString.lowercased())"
    #expect(cluster.entry.id == clusterKeyString)
    #expect(cluster.entry.id != standalone.entry.id, "node and cluster keys never collide")
    #expect(standalone.entry.id == nodeKeyString)
    // Identity lookups still resolve each scope separately.
    #expect(
        cluster.library.first { $0.standaloneNodeID == SparkNodeID(rawValue: sharedUUID) } != nil
    )
    #expect(cluster.library.first { $0.clusterID == sharedCluster } != nil)
    // Same raw UUID, different scopes: no entry shares a logical key.
    #expect(Set(cluster.library.map(\.id)).count == 2)
}

@Test func nilInterfaceRoutesPreserveDirectAndWifiSlots() {
    // Direct and Wi-Fi must stay distinct even when interfaces are unseen.
    let first = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local", kind: .localWiFi, interface: nil)]
        ),
        into: []
    )
    let second = reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local", kind: .directEthernet, interface: nil)]
        ),
        into: first.library
    )

    #expect(second.library.count == 1)
    #expect(second.entry.members[0].routes.count == 2)
    #expect(
        Set(second.entry.members[0].routes.map(\.slotID))
            == Set([
                RouteSlot(kind: .directEthernet, scope: nil),
                RouteSlot(kind: .localWiFi, scope: nil),
            ]),
        "direct and Wi-Fi are distinct slots even with no interface names"
    )
}

@Test func addressChurnUpdatesTheSlotInPlace() {
    // Update a DHCP-changed endpoint within its existing route slot.
    let first = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "172.16.10.5")]),
        into: []
    )
    let second = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "172.16.10.99")]),
        into: first.library
    )

    #expect(second.library.count == 1)
    #expect(second.entry.members[0].routes.count == 1, "address churn replaces, never appends")
    #expect(second.entry.members[0].routes.first?.baseURL.host == "172.16.10.99")
    #expect(second.entry.members[0].routes.first?.slotID == RouteSlot(kind: .localWiFi, scope: nil))
}

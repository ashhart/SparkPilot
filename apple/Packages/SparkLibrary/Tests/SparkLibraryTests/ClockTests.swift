import Foundation
import SparkCore
import SparkLibrary
import Testing

@Test func legacyReconcilerInitializerRetainsItsZeroArgumentFunctionType() {
    let initializer: () -> LibraryReconciler = LibraryReconciler.init
    _ = initializer
}

@MainActor
@Test func legacyIdentityMismatchMethodRetainsItsTwoArgumentFunctionType() {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let legacy: (String, SparkNodeID) -> Void = library.markIdentityMismatch
    _ = legacy
}

@Test func reconcilerUsesInjectedTimeWhenBlockingIdentityChange() {
    let blockedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let reconciler = LibraryReconciler(now: { blockedAt })
    let first = reconciler.reconcile(
        target: target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: []
    )
    let rebound = reconciler.reconcile(
        target: target(
            node: 2,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        ),
        into: first.library
    )

    #expect(rebound.effect == .identityChanged)
    #expect(rebound.entry.cachedAt == blockedAt)
}

@MainActor
@Test func librarySharesItsInjectedTimeWithReconciliationAndMismatchPersistence() {
    let blockedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let mismatchLibrary = SparkLibrary(store: MemoryLibraryStore(), now: { blockedAt })
    let mismatchEntry = mismatchLibrary.reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    ).entry
    mismatchLibrary.markIdentityMismatch(
        entryID: mismatchEntry.id,
        presented: libraryNodeID(3)
    )
    #expect(mismatchLibrary.entry(id: mismatchEntry.id)?.cachedAt == blockedAt)

    let reconciliationLibrary = SparkLibrary(store: MemoryLibraryStore(), now: { blockedAt })
    _ = reconciliationLibrary.reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    )
    let rebound = reconciliationLibrary.reconcile(
        target(
            node: 2,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    )
    #expect(rebound.entry.cachedAt == blockedAt, "the library passes its clock to the reconciler")
}

@MainActor
@Test func namedReconcilerInitializerRemainsCompatibleAndSharesItsClock() {
    let blockedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let reconciler = LibraryReconciler(now: { blockedAt })
    let library = SparkLibrary(
        store: MemoryLibraryStore(),
        reconciler: reconciler
    )
    let entry = library.reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    ).entry

    library.markIdentityMismatch(entryID: entry.id, presented: libraryNodeID(2))

    #expect(library.entry(id: entry.id)?.cachedAt == blockedAt)
}

@MainActor
@Test func probeMutatorConveniencesUseTheLibraryClock() {
    let probedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore(), now: { probedAt })
    let entry = library.reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    ).entry

    library.markUnreachable(entryID: entry.id)
    #expect(library.entry(id: entry.id)?.cachedAt == probedAt)

    library.markReachable(
        entryID: entry.id,
        nodeID: libraryNodeID(1),
        route: route(host: "spark-a1b2.local")
    )
    let refreshed = library.entry(id: entry.id)
    #expect(refreshed?.cachedAt == probedAt)
    #expect(refreshed?.lastSeen == probedAt)
    #expect(refreshed?.members.first?.lastSeen == probedAt)
    #expect(refreshed?.members.first?.routes.first?.lastSuccess == probedAt)
}

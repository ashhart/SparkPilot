import Foundation
import Observation
import SparkCore

/// Persist non-secret library metadata on every mutation; keep credentials and authoritative pins in Keychain.
@MainActor
@Observable
public final class SparkLibrary {
    public private(set) var entries: [LibraryEntry] = []
    /// Records persisted-state read failure while preserving session use and allowing storage recovery.
    public private(set) var loadError: String?
    /// Set when the last persist failed; entries remain valid in memory.
    public private(set) var persistError: String?
    /// Reports durability from the actual store and every load or save outcome.
    public private(set) var storageStatus: LibraryStorageStatus

    private var store: any SparkLibraryStoring
    private let reconciler: LibraryReconciler
    private let now: @Sendable () -> Date
    private let operationalSnapshotComposer: TargetOperationalSnapshotComposer

    public init(
        store: any SparkLibraryStoring,
        reconciler: LibraryReconciler = LibraryReconciler(),
        storageStatusOverride: String? = nil,
        operationalSnapshotComposer: TargetOperationalSnapshotComposer = .init()
    ) {
        self.store = store
        self.reconciler = reconciler
        self.now = reconciler.now
        self.operationalSnapshotComposer = operationalSnapshotComposer
        if let reason = storageStatusOverride {
            self.storageStatus = .sessionOnly(reason: reason)
        } else {
            self.storageStatus =
                store.isDurable
                ? .persistent
                : .sessionOnly(
                    reason:
                        String(
                            localized:
                                "The library store is unavailable this session; changes will not survive relaunch."
                        )
                )
        }
    }

    public convenience init(
        store: any SparkLibraryStoring,
        now: @escaping @Sendable () -> Date,
        storageStatusOverride: String? = nil
    ) {
        self.init(
            store: store,
            reconciler: LibraryReconciler(now: now),
            storageStatusOverride: storageStatusOverride
        )
    }

    // MARK: - Lifecycle

    /// Loads saved cards with reachability downgraded until a new authenticated probe succeeds.
    public func load() {
        do {
            let saved = try store.load()
            entries = saved.map { entry in
                var downgraded = entry
                if entry.issue == .identityMismatch {
                    downgraded.connectionState = .identityMismatch
                } else {
                    downgraded.connectionState = .offlineCached
                }
                downgraded.members = entry.members.map { member in
                    var refreshed = member
                    refreshed.reachable = false
                    return refreshed
                }
                return downgraded
            }
            loadError = nil
            if store.isDurable { storageStatus = .persistent }
        } catch {
            loadError = "\(error)"
            // Replace an unreadable durable store with a seeded session store before any write could overwrite its unknown contents.
            if store.isDurable {
                let session = MemoryLibraryStore()
                try? session.save(entries)
                store = session
            }
            storageStatus = .sessionOnly(reason: "\(error)")
        }
    }

    /// Persists a batch while recording failures for the UI; individual mutators already flush their changes.
    public func persist() {
        do {
            try store.save(entries)
            persistError = nil
            if store.isDurable { storageStatus = .persistent }
        } catch {
            persistError = "\(error)"
            storageStatus = .sessionOnly(reason: "\(error)")
        }
    }

    /// Adopts a recovered durable store only after loading, unioning and saving all disk and session cards successfully.
    public func recoverDurableStorage(
        createStore: @MainActor () -> (any SparkLibraryStoring)?
    ) {
        guard let replacement = createStore(), replacement.isDurable else {
            storageStatus = .sessionOnly(
                reason:
                    String(
                        localized:
                            "The library store is still unavailable. Try again once this device has storage space."
                    )
            )
            return
        }

        // Read persisted cards before attempting recovery.
        let persisted: [LibraryEntry]
        do {
            persisted = try replacement.load()
        } catch {
            storageStatus = .sessionOnly(
                reason: "The saved library could not be read: \(error)"
            )
            return
        }

        // Union cards by namespaced key, reconciling members and routes while retaining identity mismatches.
        var merged = persisted
        for sessionEntry in entries {
            if let index = merged.firstIndex(where: { $0.id == sessionEntry.id }) {
                merged[index] = LibraryReconciler.mergedEntry(
                    disk: merged[index],
                    session: sessionEntry
                )
            } else {
                merged.append(sessionEntry)
            }
        }
        merged.sort { $0.id < $1.id }

        // Write the union before adopting the replacement store.
        do {
            try replacement.save(merged)
        } catch {
            storageStatus = .sessionOnly(
                reason: "The library store could not be written: \(error)"
            )
            return
        }

        store = replacement
        entries = merged
        storageStatus = .persistent
    }

    // MARK: - Reconciliation

    /// Reconciles authenticated identity, routes and topology atomically, then persists the updated library.
    @discardableResult
    public func reconcile(_ target: AuthenticatedTarget) -> ReconciliationOutcome {
        let outcome = reconciler.reconcile(target: target, into: entries)
        entries = outcome.library
        persist()
        return outcome
    }

    // MARK: - Lookup

    public func entry(id: String) -> LibraryEntry? {
        guard let key = LibraryLogicalKey(rawValue: id) else { return nil }
        return entry(key: key)
    }

    public func entry(key: LibraryLogicalKey) -> LibraryEntry? {
        entries.first { $0.logicalKey == key }
    }

    public func entry(containing nodeID: SparkNodeID) -> LibraryEntry? {
        LibraryReconciler.find(nodeID: nodeID, in: entries)?.entry
    }

    public func entry(clusterID: SparkClusterID) -> LibraryEntry? {
        LibraryReconciler.find(clusterID: clusterID, in: entries)
    }

    public var externalClusterEntries: [LibraryEntry] {
        entries.filter { $0.externalClusterRegistration != nil }
    }

    /// Finds saved cards by hostname as a discovery hint without claiming authenticated node identity.
    public func entry(matchingHostname: String) -> LibraryEntry? {
        let normalized = LibraryReconciler.normalizedDisplayName(matchingHostname)
        guard !normalized.isEmpty else { return nil }
        return entries.first { entry in
            entry.members.contains { member in
                guard let saved = member.hostname, !saved.isEmpty else { return false }
                return LibraryReconciler.normalizedDisplayName(saved) == normalized
            }
        }
    }

    // MARK: - Owner labels and hostnames

    /// Stores an app-local label override, with an empty value restoring the runtime-reported name.
    @discardableResult
    public func setCustomLabel(_ label: String, for entryID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { return false }
        var entry = entries[index]
        entry.customLabel = trimmed.isEmpty ? nil : trimmed
        entries[index] = entry
        persist()
        return persistError == nil
    }

    /// Updates discovery metadata after an authenticated hostname change without changing node identity or TLS trust.
    @discardableResult
    public func recordHostname(_ hostname: String, for entryID: String, nodeID: SparkNodeID) -> Bool
    {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        var entry = entries[index]
        guard let memberIndex = entry.members.firstIndex(where: { $0.nodeID == nodeID }) else {
            return false
        }
        entry.members[memberIndex].hostname = trimmed
        entries[index] = entry
        persist()
        return persistError == nil
    }

    // MARK: - Operational snapshots

    /// Persists authenticated evidence while retaining the prior snapshot and blocking entries on identity mismatch.
    @discardableResult
    public func recordOperationalEvidence(
        _ evidence: TargetOperationalEvidence,
        for entryID: String,
        at date: Date? = nil
    ) -> TargetOperationalSnapshot? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        let evaluatedAt = date ?? now()
        var entry = entries[index]
        let snapshot = operationalSnapshotComposer.compose(
            entry: entry,
            evidence: evidence,
            at: evaluatedAt
        )
        entry.cachedOperationalSnapshot = snapshot
        entry.cachedAt = evaluatedAt
        if snapshot.connectionState == .identityMismatch {
            entry.issue = .identityMismatch
            entry.connectionState = .identityMismatch
        } else {
            entry.lastSeen = snapshot.lastSuccessfulContact ?? entry.lastSeen
            entry.members = entry.members.map { member in
                guard member.nodeID == evidence.respondingNodeID else { return member }
                var reachable = member
                reachable.reachable = true
                reachable.lastSeen = snapshot.lastSuccessfulContact ?? member.lastSeen
                return reachable
            }
            entry.connectionState =
                snapshot.connectionState == .updateRequired
                ? .updateRequired
                : LibraryReconciler.connectionState(for: entry)
        }
        entries[index] = entry
        persist()
        return snapshot
    }

    /// Remembers a nonblank owner-established account after successful setup or login and reports whether persistence is needed.
    @discardableResult
    public func recordAdministratorUsername(_ username: String, for entryID: String) -> Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let index = entries.firstIndex(where: { $0.id == entryID }),
            entries[index].administratorUsername != trimmed
        else { return false }
        entries[index].administratorUsername = trimmed
        persist()
        return true
    }

    /// Evaluates cached evidence ages at the current time without mutating or refreshing the target.
    public func operationalSnapshot(for entryID: String, at date: Date? = nil)
        -> TargetOperationalSnapshot?
    {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return nil }
        return operationalSnapshotComposer.cachedSnapshot(entry: entry, at: date ?? now())
    }

    // MARK: - Connection state

    /// Marks a session-local probe in progress without persisting reachability across relaunch.
    public func markConnecting(entryID: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.issue == nil else { return }
        entry.connectionState = .connecting
        entries[index] = entry
    }

    /// Restores cached state after an inconclusive probe; definitive failures use markUnreachable.
    public func clearConnecting(entryID: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.connectionState == .connecting else { return }
        entry.connectionState = .offlineCached
        entries[index] = entry
    }

    /// Marks the selected node or whole card offline after a failed probe while preserving cached metadata.
    public func markUnreachable(entryID: String, nodeID: SparkNodeID? = nil) {
        markUnreachable(entryID: entryID, nodeID: nodeID, at: now())
    }

    public func markUnreachable(entryID: String, nodeID: SparkNodeID? = nil, at: Date) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.issue == nil else { return }
        entry.members = entry.members.map { member in
            guard nodeID == nil || member.nodeID == nodeID else { return member }
            var refreshed = member
            refreshed.reachable = false
            return refreshed
        }
        entry.lastSeen = entry.lastSeen ?? at
        entry.cachedAt = at
        entry.connectionState = LibraryReconciler.connectionState(for: entry)
        entries[index] = entry
        persist()
    }

    /// Attributes a failed authenticated attempt to its route so later selection can demote that path.
    public func markUnreachable(
        entryID: String,
        nodeID: SparkNodeID,
        route: CachedRoute,
        at: Date
    ) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        guard entry.issue == nil else { return }
        entry.members = entry.members.map { member in
            guard member.nodeID == nodeID else { return member }
            var refreshed = member
            let identity = LibraryReconciler.establishedIdentity(of: member)
            var charged = member.routes
            if let slot = charged.firstIndex(where: { $0.slotID == route.slotID }) {
                charged[slot].consecutiveFailures += 1
            }
            // Re-merge routes so the updated failure count changes selection order.
            refreshed.routes = LibraryReconciler.mergedRoutes(
                existing: charged,
                seen: [],
                establishedIdentity: identity
            )
            refreshed.reachable = false
            return refreshed
        }
        entry.lastSeen = entry.lastSeen ?? at
        entry.cachedAt = at
        entry.connectionState = LibraryReconciler.connectionState(for: entry)
        entries[index] = entry
        persist()
    }

    /// Marks a node reachable after a successful probe and advances card connectivity only for its coordinator.
    public func markReachable(entryID: String, nodeID: SparkNodeID, route: CachedRoute) {
        markReachable(entryID: entryID, nodeID: nodeID, route: route, at: now())
    }

    public func markReachable(
        entryID: String,
        nodeID: SparkNodeID,
        route: CachedRoute,
        at: Date
    ) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        entry.members = entry.members.map { member in
            guard member.nodeID == nodeID else { return member }
            var refreshed = member
            var observedRoute = route
            observedRoute.lastSuccess = at
            refreshed.routes = LibraryReconciler.mergedRoutes(
                existing: member.routes,
                seen: [observedRoute],
                establishedIdentity: LibraryReconciler.establishedIdentity(of: member)
            )
            refreshed.lastSeen = at
            refreshed.reachable = true
            return refreshed
        }
        entry.lastSeen = at
        entry.cachedAt = at
        entry.connectionState = LibraryReconciler.connectionState(for: entry)
        entries[index] = entry
        persist()
    }

    /// Retains an authenticated Spark's advertised endpoint without claiming it has answered here.
    public func rememberRouteCandidate(entryID: String, nodeID: SparkNodeID, route: CachedRoute) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
            entries[index].issue == nil,
            let memberIndex = entries[index].members.firstIndex(where: { $0.nodeID == nodeID })
        else { return }
        let member = entries[index].members[memberIndex]
        var candidate = route
        candidate.lastSuccess = nil
        candidate.consecutiveFailures = 0
        // An address change is a new unverified endpoint, not a successful check of the old slot.
        let existing = member.routes.filter {
            $0.slotID != candidate.slotID || $0.baseURL == candidate.baseURL
        }
        let merged = LibraryReconciler.mergedRoutes(
            existing: existing,
            seen: [candidate],
            establishedIdentity: LibraryReconciler.establishedIdentity(of: member)
        )
        guard merged != member.routes else { return }
        entries[index].members[memberIndex].routes = merged
        persist()
    }

    /// Removes disabled transport routes only from this device's cache without changing the Spark or underlying VPN.
    public func removeRoutes(
        entryID: String,
        nodeID: SparkNodeID,
        kind: SparkTransportKind
    ) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        var removed = false
        entry.members = entry.members.map { member in
            guard member.nodeID == nodeID else { return member }
            var refreshed = member
            let remaining = member.routes.filter { $0.kind != kind }
            removed = remaining.count != member.routes.count
            refreshed.routes = remaining
            if removed { refreshed.reachable = false }
            return refreshed
        }
        guard removed else { return }
        entry.connectionState = LibraryReconciler.connectionState(for: entry)
        entry.cachedAt = now()
        entries[index] = entry
        persist()
    }

    /// Blocks a saved card when an authenticated observation proves its route now presents another full node ID.
    public func markIdentityMismatch(entryID: String, presented: SparkNodeID) {
        markIdentityMismatch(entryID: entryID, presented: presented, at: now())
    }

    public func markIdentityMismatch(entryID: String, presented: SparkNodeID, at: Date) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var entry = entries[index]
        entry.issue = .identityMismatch
        entry.connectionState = .identityMismatch
        entry.cachedAt = at
        entries[index] = entry
        persist()
    }

    // MARK: - Deletion

    /// Group only independently paired members with current authenticated link evidence.
    @discardableResult
    public func registerExternalCluster(
        name: String,
        authorityFingerprint: String,
        memberNodeIDs: [SparkNodeID],
        authenticatedLinks: [ExternalClusterAuthenticatedLink],
        verifiedAt: Date,
        clusterID: SparkClusterID = SparkClusterID(rawValue: UUID())
    ) throws -> LibraryEntry {
        try editExternalCluster {
            try $0.registerExternalCluster(
                name: name,
                authorityFingerprint: authorityFingerprint,
                memberNodeIDs: memberNodeIDs,
                authenticatedLinks: authenticatedLinks,
                verifiedAt: verifiedAt,
                clusterID: clusterID
            )
        }
    }

    /// Remove the local grouping while retaining each member's saved connection metadata.
    @discardableResult
    public func removeExternalClusterRegistration(entryID: String) -> LibraryEntry? {
        editExternalCluster { $0.removeExternalClusterRegistration(entryID: entryID) }
    }

    /// Replace cached topology only after every registered member has authenticated evidence.
    @discardableResult
    public func refreshExternalClusterRegistration(
        entryID: String,
        authorityFingerprint: String,
        authenticatedLinks: [ExternalClusterAuthenticatedLink],
        verifiedAt: Date
    ) throws -> LibraryEntry {
        try editExternalCluster {
            try $0.refreshExternalClusterRegistration(
                entryID: entryID,
                authorityFingerprint: authorityFingerprint,
                authenticatedLinks: authenticatedLinks,
                verifiedAt: verifiedAt
            )
        }
    }

    private func editExternalCluster<Result>(
        _ edit: (inout ExternalClusterLibraryEditor) throws -> Result
    ) rethrows -> Result {
        var editor = ExternalClusterLibraryEditor(entries: entries)
        let result = try edit(&editor)
        if editor.changed {
            entries = editor.entries
            persist()
        }
        return result
    }

    @discardableResult
    public func remove(entryID: String) -> LibraryEntry? {
        if entries.contains(where: {
            $0.id == entryID && $0.externalClusterRegistration != nil
        }) {
            return removeExternalClusterRegistration(entryID: entryID)
        }
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        let removed = entries.remove(at: index)
        persist()
        return removed
    }

    @discardableResult
    public func remove(key: LibraryLogicalKey) -> LibraryEntry? {
        remove(entryID: key.description)
    }

    @discardableResult
    public func remove(nodeID: SparkNodeID) -> LibraryEntry? {
        guard let found = LibraryReconciler.find(nodeID: nodeID, in: entries) else { return nil }
        return remove(entryID: found.entry.id)
    }

    @discardableResult
    public func remove(clusterID: SparkClusterID) -> LibraryEntry? {
        remove(key: .cluster(clusterID))
    }
}

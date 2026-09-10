import Foundation
import SparkCore
import SparkTransport

extension LibraryReconciler {

    // MARK: - Member/entry construction

    /// Unions same-key members and route slots while retaining identity mismatches and rejecting conflicting authority fingerprints.
    public static func mergedEntry(disk: LibraryEntry, session: LibraryEntry) -> LibraryEntry {
        precondition(disk.logicalKey == session.logicalKey, "merge only same-key entries")
        var members: [LibraryMember] = []
        var conflict = false

        // Same-node members first, then disk-only, then session-only.
        let diskOnly = disk.members.filter { d in
            !session.members.contains { $0.nodeID == d.nodeID }
        }
        let sessionOnly = session.members.filter { s in
            !disk.members.contains { $0.nodeID == s.nodeID }
        }
        for diskMember in disk.members {
            guard
                let sessionMember = session.members.first(where: { $0.nodeID == diskMember.nodeID })
            else { continue }
            let merged = mergedMember(disk: diskMember, session: sessionMember)
            if merged.memberFingerprintConflict {
                conflict = true
            }
            members.append(merged.member)
        }
        members.append(contentsOf: diskOnly)
        members.append(contentsOf: sessionOnly)
        // Coordinator first, then other members by name (stable detail UI).
        members.sort { lhs, rhs in
            if lhs.role == rhs.role {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.role == .leader
        }

        // Reject competing cluster leaders rather than choosing a coordinator by incidental sort order.
        var entry = LibraryEntry(
            logicalKey: disk.logicalKey,
            name: session.name.isEmpty ? disk.name : session.name,
            customLabel: session.customLabel ?? disk.customLabel,
            members: members,
            connectionState: .offlineCached,
            issue: combinedIssue(
                disk: disk,
                session: session,
                fingerprintConflict: conflict || competingLeaders(in: members)
            ),
            lastSeen: newer(disk.lastSeen, session.lastSeen),
            cachedAt: newer(disk.cachedAt, session.cachedAt),
            cachedOperationalSnapshot: newer(
                disk.cachedOperationalSnapshot,
                session.cachedOperationalSnapshot
            ),
            externalClusterRegistration: newerExternalRegistration(
                disk.externalClusterRegistration,
                session.externalClusterRegistration
            ),
            // Preserve the owner-established account name because discovery cannot supply or replace it.
            administratorUsername: session.administratorUsername
                ?? disk.administratorUsername
        )
        entry.connectionState = connectionState(for: entry)
        return entry
    }

    private static func competingLeaders(in members: [LibraryMember]) -> Bool {
        members.lazy.filter { $0.role == .leader }.dropFirst().first != nil
    }

    private static func mergedMember(disk: LibraryMember, session: LibraryMember)
        -> (member: LibraryMember, memberFingerprintConflict: Bool)
    {
        var merged = session
        merged.name = session.name.isEmpty ? disk.name : session.name
        merged.hostname = session.hostname ?? disk.hostname
        merged.routes = mergedRoutes(
            existing: disk.routes,
            seen: session.routes,
            establishedIdentity: establishedIdentity(of: disk)
        )
        merged.lastSeen = newer(disk.lastSeen, session.lastSeen)
        merged.reachable = session.reachable

        let diskFingerprint = disk.authorityFingerprint.flatMap { $0.isEmpty ? nil : $0 }
        let sessionFingerprint = session.authorityFingerprint.flatMap { $0.isEmpty ? nil : $0 }
        let conflict =
            diskFingerprint != nil && sessionFingerprint != nil
            && diskFingerprint != sessionFingerprint
        if conflict {
            // Keep the session observation but block the card.
            merged.authorityFingerprint = session.authorityFingerprint
        } else {
            merged.authorityFingerprint =
                session.authorityFingerprint
                ?? disk.authorityFingerprint
        }
        return (merged, conflict)
    }

    private static func combinedIssue(
        disk: LibraryEntry,
        session: LibraryEntry,
        fingerprintConflict: Bool
    ) -> LibraryEntryIssue? {
        if fingerprintConflict { return .identityMismatch }
        if disk.issue == .identityMismatch { return .identityMismatch }
        return session.issue
    }

    private static func newer(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (let l?, let r?): return l > r ? l : r
        }
    }

    private static func newer(
        _ lhs: TargetOperationalSnapshot?,
        _ rhs: TargetOperationalSnapshot?
    ) -> TargetOperationalSnapshot? {
        switch (lhs, rhs) {
        case (nil, nil):
            nil
        case (let value?, nil), (nil, let value?):
            value
        case (let left?, let right?):
            left.evaluatedAt > right.evaluatedAt ? left : right
        }
    }

    private static func newerExternalRegistration(
        _ lhs: ExternalClusterRegistration?,
        _ rhs: ExternalClusterRegistration?
    ) -> ExternalClusterRegistration? {
        switch (lhs, rhs) {
        case (nil, nil):
            nil
        case (let value?, nil), (nil, let value?):
            value
        case (let left?, let right?):
            left.lastVerifiedAt > right.lastVerifiedAt ? left : right
        }
    }
}

import Foundation
import Observation
import SparkCore

/// Stage device-local cluster edits without publishing partial library state.
struct ExternalClusterLibraryEditor {
    var entries: [LibraryEntry]
    private(set) var changed = false

    private var externalClusterEntries: [LibraryEntry] {
        entries.filter { $0.externalClusterRegistration != nil }
    }

    /// Groups independently paired Sparks into a device-local read-only target using authenticated link records without runtime mutations.
    @discardableResult
    mutating func registerExternalCluster(
        name: String,
        authorityFingerprint: String,
        memberNodeIDs: [SparkNodeID],
        authenticatedLinks: [ExternalClusterAuthenticatedLink],
        verifiedAt: Date,
        clusterID: SparkClusterID = SparkClusterID(rawValue: UUID())
    ) throws -> LibraryEntry {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let authority = authorityFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberSet = Set(memberNodeIDs)
        guard !name.isEmpty, name.count <= 120 else {
            throw ExternalClusterRegistrationError.invalidName
        }
        guard memberNodeIDs.count >= 2, memberSet.count == memberNodeIDs.count else {
            throw ExternalClusterRegistrationError.invalidMembership
        }
        if let existing = externalClusterEntries.first(where: {
            Set($0.externalClusterRegistration?.memberNodeIDs ?? []) == memberSet
        }) {
            return existing
        }
        guard
            !externalClusterEntries.contains(where: { entry in
                !memberSet.isDisjoint(with: entry.externalClusterRegistration?.memberNodeIDs ?? [])
            })
        else {
            throw ExternalClusterRegistrationError.memberAlreadyGrouped
        }

        let standaloneEntries = try memberNodeIDs.map { nodeID in
            guard let entry = entries.first(where: { $0.standaloneNodeID == nodeID }),
                entry.kind == .standalone,
                entry.issue == nil,
                let member = entry.members.first
            else {
                throw ExternalClusterRegistrationError.memberUnavailable(nodeID)
            }
            return (entry, member)
        }
        guard !authority.isEmpty,
            standaloneEntries.allSatisfy({ pair in
                pair.1.authorityFingerprint?.caseInsensitiveCompare(authority) == .orderedSame
            })
        else {
            throw ExternalClusterRegistrationError.authorityMismatch
        }
        guard
            Self.linksAuthenticateEveryMember(
                memberSet,
                links: authenticatedLinks,
                at: verifiedAt
            )
        else {
            throw ExternalClusterRegistrationError.fabricEvidenceIncomplete
        }

        let registration = ExternalClusterRegistration(
            authorityFingerprint: authority,
            memberNodeIDs: memberNodeIDs,
            registeredAt: verifiedAt,
            lastVerifiedAt: verifiedAt,
            authenticatedLinks: authenticatedLinks
        )
        let members = standaloneEntries.map(\.1)
        let lastSeen = members.compactMap(\.lastSeen).max()
        let entry = LibraryEntry(
            logicalKey: .cluster(clusterID),
            name: name,
            members: members,
            connectionState: LibraryReconciler.connectionState(
                forRouteKind: members.first?.routes.first?.kind
            ),
            lastSeen: lastSeen,
            cachedAt: verifiedAt,
            externalClusterRegistration: registration
        )
        entries.removeAll { candidate in
            candidate.kind == .standalone
                && candidate.standaloneNodeID.map(memberSet.contains) == true
        }
        entries.append(entry)
        entries.sort { $0.id < $1.id }
        changed = true
        return entry
    }

    /// Removes only the local grouping and restores standalone member cards from saved routes.
    @discardableResult
    mutating func removeExternalClusterRegistration(entryID: String) -> LibraryEntry? {
        guard
            let index = entries.firstIndex(where: {
                $0.id == entryID && $0.externalClusterRegistration != nil
            })
        else { return nil }
        let removed = entries.remove(at: index)
        for member in removed.members
        where !entries.contains(where: {
            $0.members.contains { $0.nodeID == member.nodeID }
        }) {
            var standalone = member
            standalone.role = .standalone
            entries.append(
                LibraryEntry(
                    logicalKey: .node(member.nodeID),
                    name: member.name,
                    members: [standalone],
                    connectionState: LibraryReconciler.connectionState(
                        forRouteKind: member.reachable ? member.routes.first?.kind : nil
                    ),
                    lastSeen: member.lastSeen,
                    cachedAt: removed.cachedAt,
                    administratorUsername: removed.administratorUsername
                )
            )
        }
        entries.sort { $0.id < $1.id }
        changed = true
        return removed
    }

    /// Replaces cached signed topology only after every registered member refreshes successfully.
    @discardableResult
    mutating func refreshExternalClusterRegistration(
        entryID: String,
        authorityFingerprint: String,
        authenticatedLinks: [ExternalClusterAuthenticatedLink],
        verifiedAt: Date
    ) throws -> LibraryEntry {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
            let prior = entries[index].externalClusterRegistration
        else {
            throw ExternalClusterRegistrationError.memberAlreadyGrouped
        }
        let authority = authorityFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard authority.caseInsensitiveCompare(prior.authorityFingerprint) == .orderedSame else {
            throw ExternalClusterRegistrationError.authorityMismatch
        }
        let members = Set(prior.memberNodeIDs)
        guard Self.linksAuthenticateEveryMember(members, links: authenticatedLinks, at: verifiedAt)
        else {
            throw ExternalClusterRegistrationError.fabricEvidenceIncomplete
        }
        var entry = entries[index]
        entry.externalClusterRegistration = ExternalClusterRegistration(
            authorityFingerprint: prior.authorityFingerprint,
            memberNodeIDs: prior.memberNodeIDs,
            registeredAt: prior.registeredAt,
            lastVerifiedAt: verifiedAt,
            authenticatedLinks: authenticatedLinks
        )
        entry.cachedAt = verifiedAt
        entries[index] = entry
        changed = true
        return entry
    }

    private static func linksAuthenticateEveryMember(
        _ members: Set<SparkNodeID>,
        links: [ExternalClusterAuthenticatedLink],
        at date: Date
    ) -> Bool {
        guard let first = members.first else { return false }
        var connected = Set([first])
        for link in links {
            guard members.contains(link.memberANodeID),
                members.contains(link.memberBNodeID),
                link.memberANodeID != link.memberBNodeID,
                !link.memberAPortID.isEmpty,
                !link.memberBPortID.isEmpty,
                link.verifiedAt <= date,
                link.expiresAt > date
            else { return false }
        }
        while true {
            let before = connected.count
            for link in links {
                if connected.contains(link.memberANodeID) {
                    connected.insert(link.memberBNodeID)
                }
                if connected.contains(link.memberBNodeID) {
                    connected.insert(link.memberANodeID)
                }
            }
            if connected.count == before { return connected == members }
        }
    }

    /// Removes only this device's library card without resetting, revoking or deleting anything on the Spark.
}

public enum ExternalClusterRegistrationError: Error, Equatable, Sendable {
    case invalidName
    case invalidMembership
    case memberUnavailable(SparkNodeID)
    case memberAlreadyGrouped
    case authorityMismatch
    case fabricEvidenceIncomplete
}

import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func invitationWrongSpark(_ target: String) -> Self {
        .init(
            "pairing.invitation.wrong.spark",
            defaultValue: """
                That invitation is for a different Spark. Scan the code shown for \(target).
                """,
            comment: "The scanned invitation belongs to another Spark in the library."
        )
    }

    static func joinCodeWrongSpark(_ target: String) -> Self {
        .init(
            "pairing.code.wrong.spark",
            defaultValue: """
                That code belongs to a different Spark. Create a new code for \(target).
                """,
            comment: "The entered join code belongs to another Spark in the library."
        )
    }

    static func signedModelsAvailable(_ count: Int) -> Self {
        .init(
            "preflight.signed.models",
            defaultValue: "\(count) signed models are available",
            comment: "How many signed recipes the Spark offers after install."
        )
    }

    static func linkHealthIs(_ health: String) -> Self {
        .init(
            "workloads.link.health",
            defaultValue: "Link health is \(health)",
            comment: "The observed state of a cluster's fabric link."
        )
    }

    static func runtimeHealthIs(_ health: String) -> Self {
        .init(
            "workloads.runtime.health",
            defaultValue: "Spark Runtime health is \(health).",
            comment: "The runtime's own reported health, lowercased into a sentence."
        )
    }

    static func memberDegraded(_ member: String) -> Self {
        .init(
            "workloads.member.degraded",
            defaultValue: "\(member) is degraded. Distributed workload health is degraded.",
            comment: "One cluster member is degraded, so the whole workload is."
        )
    }

    static func memoryAvailableOfTotal(available: String, total: String) -> Self {
        .init(
            "workloads.memory.available",
            defaultValue: "\(available) available of \(total)",
            comment: "Free unified memory against the amount fitted."
        )
    }

    static func clusterMembersReadyCount(ready: Int, total: Int) -> Self {
        .init(
            "workloads.members.ready",
            defaultValue: "\(ready) of \(total) members ready",
            comment: "How many cluster members answered out of the cluster's size."
        )
    }

    // MARK: - External cluster review names the member associated with each finding

    static func pairedRouteUnavailable(_ member: String) -> Self {
        .init(
            "cluster.route.unavailable",
            defaultValue: "The paired route for \(member) is unavailable.",
            comment: "This member's saved route did not answer during the review."
        )
    }

    static func memberIdentityMismatch(_ member: String) -> Self {
        .init(
            "cluster.member.identity.mismatch",
            defaultValue: "\(member) did not match its paired identity.",
            comment: "The Spark that answered is not the one this device paired with."
        )
    }

    static func memberDifferentAuthority(_ member: String) -> Self {
        .init(
            "cluster.member.other.authority",
            defaultValue: "\(member) belongs to a different Spark owner authority.",
            comment: "The member is owned by someone else, so it cannot join this cluster."
        )
    }

    static func memberAlreadyClustered(_ member: String) -> Self {
        .init(
            "cluster.member.already.clustered",
            defaultValue: "\(member) already reports a signed cluster identity.",
            comment: "The member is already in a cluster, so importing would conflict."
        )
    }

    static func authenticatedPeer(_ member: String) -> Self {
        .init(
            "cluster.peer.authenticated",
            defaultValue: "Authenticated peer: \(member)",
            comment: "The named member returned reciprocal fabric proof."
        )
    }

    static func memberNotAuthenticated(_ member: String) -> Self {
        .init(
            "cluster.member.unauthenticated",
            defaultValue: "\(member) identity is not authenticated",
            comment: "Blocker: this member did not prove who it is."
        )
    }

    static func memberAnotherAuthority(_ member: String) -> Self {
        .init(
            "cluster.member.authority",
            defaultValue: "\(member) belongs to another owner authority",
            comment: "Blocker: this member is owned by someone else."
        )
    }

    static func memberNoReciprocalProof(_ member: String) -> Self {
        .init(
            "cluster.member.no.reciprocal",
            defaultValue: "\(member) has no reciprocal fabric proof",
            comment: "Blocker: the members did not each vouch for the other."
        )
    }

    static func clusterAddedWithoutChange(_ cluster: String) -> Self {
        .init(
            "cluster.added.unchanged",
            defaultValue: "\(cluster) was added without changing any Spark.",
            comment: "Registration is device-local; no mutation was sent to any Spark."
        )
    }

    static func clusterTopologyReverified(_ cluster: String) -> Self {
        .init(
            "cluster.topology.reverified",
            defaultValue: "\(cluster) topology was verified again.",
            comment: "The saved topology was re-checked against the live members."
        )
    }

    // MARK: - Fleet card

    static func checkResourceAgain(_ target: String) -> Self {
        .init(
            "fleet.action.check.again",
            defaultValue: "Check \(target) again",
            comment: "Re-run the reachability check for one named Spark."
        )
    }
}

import SwiftUI

/// State member reachability in words, because colour alone never carries status (§51.1).
public enum ClusterMemberCopy {
    public static func reachability(_ reachable: Bool) -> String {
        reachable ? String(localized: "Reachable") : String(localized: "Not reachable")
    }
}

/// Represent a cluster as one compute target with placement and member-health information (§35.6).
public struct ClusterCardState: Equatable, Sendable {
    public let name: String?
    public let state: ClusterStateValue
    public let members: [ClusterMemberValue]

    public init(name: String?, state: ClusterStateValue, members: [ClusterMemberValue]) {
        self.name = name
        self.state = state
        self.members = members
    }

    public var reachableMembers: Int {
        members.filter(\.reachable).count
    }
}

public enum ClusterStateValue: String, Sendable, Equatable, CaseIterable {
    case standalone, forming, validating, ready, degraded, failed
}

public struct ClusterMemberValue: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let role: String
    public let reachable: Bool

    public init(id: String, name: String, role: String, reachable: Bool) {
        self.id = id
        self.name = name
        self.role = role
        self.reachable = reachable
    }
}

/// Resolved presentation for one cluster state.
public struct ClusterPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String
}

public enum ClusterPresentationResolver {
    public static func resolve(_ state: ClusterCardState) -> ClusterPresentation {
        switch state.state {
        case .standalone:
            return ClusterPresentation(
                title: String(localized: "Two Sparks Are Better Than One"),
                detail:
                    String(
                        localized:
                            "Connect a second Spark with a QSFP cable to run larger models across both."
                    ),
                symbol: "square.stack.3d.up.slash"
            )
        case .forming, .validating:
            return ClusterPresentation(
                title: String(localized: "Setting Up Your Cluster"),
                detail: String(
                    localized: "Checking the cable, versions, and connection between your Sparks."
                ),
                symbol: "hourglass"
            )
        case .ready:
            return ClusterPresentation(
                title: state.name ?? String(localized: "Cluster Ready"),
                detail: String(
                    localized:
                        "Uses both Sparks. Models can run across the pair for extra capacity."
                ),
                symbol: "rectangle.stack.3d.up.fill"
            )
        case .degraded:
            return ClusterPresentation(
                title: String(localized: "Cluster Needs Attention"),
                detail:
                    String(
                        localized:
                            "One Spark is unreachable or validation is incomplete. Single-Spark models keep working."
                    ),
                symbol: "exclamationmark.square"
            )
        case .failed:
            return ClusterPresentation(
                title: String(localized: "Cluster Setup Failed"),
                detail:
                    String(
                        localized:
                            "The cable check or connection test failed. Check the QSFP cable and try again."
                    ),
                symbol: "xmark.square"
            )
        }
    }

    /// §35.5 placement vocabulary, verbatim.
    public static let placementVocabulary: [String] = [
        String(localized: "Runs on one Spark"),
        String(localized: "Can use either Spark"),
        String(localized: "Uses both Sparks"),
        String(localized: "Requires both Sparks"),
    ]
}

/// The cluster card: presentation + member list with health cues.
public struct ClusterCard: View {
    public let state: ClusterCardState

    public init(state: ClusterCardState) {
        self.state = state
    }

    public var body: some View {
        let presentation = ClusterPresentationResolver.resolve(state)
        VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: presentation.symbol)
                .font(.headline)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !state.members.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.members) { member in
                        HStack {
                            Image(
                                systemName: member.reachable
                                    ? "checkmark.circle.fill" : "circle.slash"
                            )
                            .foregroundStyle(member.reachable ? .green : .red)
                            .accessibilityHidden(true)
                            Text(member.name)
                            Spacer()
                            Text(verbatim: ClusterMemberCopy.reachability(member.reachable))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                member.role == "leader"
                                    ? String(localized: "Coordinator") : String(localized: "Worker")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

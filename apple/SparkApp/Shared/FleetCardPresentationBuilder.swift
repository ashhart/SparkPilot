import Foundation
import Observation
import SparkCore
import SparkLibrary

extension FleetPresentationBuilder {
    // MARK: Card

    static func card(for target: FleetTargetInput, isChecking: Bool) -> FleetCardPresentation {
        let snapshot = target.snapshot
        let connection = connectionPresentation(
            state: snapshot.connectionState,
            isChecking: isChecking,
            route: snapshot.routeInUse ?? snapshot.preferredRoute
        )
        // Only authenticated cluster identity can promote a node card to a cluster; member lists alone are insufficient (ADR-012).
        let artwork: FleetCardArtwork =
            isCluster(snapshot.identity)
            ? .cluster(memberCount: snapshot.members.count)
            : .spark
        let fields = FleetCardFields(
            name: snapshot.displayName,
            connectionLabel: connection.label,
            isChecking: connection.isChecking,
            lastContact: lastContact(snapshot),
            availableMemory: availableMemory(snapshot),
            activeModel: activeModel(snapshot),
            installedModels: installedModels(snapshot),
            membership: membership(
                snapshot,
                isExternallyConfigured: target.isExternallyConfiguredCluster
            ),
            warnings: snapshot.warnings.map(\.message),
            blockers: snapshot.blockers.map(\.message)
        )
        return FleetCardPresentation(
            id: target.id,
            name: fields.name,
            artwork: artwork,
            connection: connection,
            lastContact: fields.lastContact,
            availableMemory: fields.availableMemory,
            activeModel: fields.activeModel,
            installedModels: fields.installedModels,
            membership: fields.membership,
            members: members(
                snapshot,
                isExternallyConfigured: target.isExternallyConfiguredCluster
            ),
            warnings: fields.warnings,
            blockers: fields.blockers,
            evidenceNote: evidenceNote(snapshot),
            actions: actions(for: target),
            accessibilityLabel: accessibilityLabel(fields)
        )
    }

    /// Build accessibility labels from the same strings rendered on the card.
    struct FleetCardFields {
        let name: String
        let connectionLabel: String
        let isChecking: Bool
        let lastContact: String
        let availableMemory: String
        let activeModel: String
        let installedModels: String
        let membership: String
        let warnings: [String]
        let blockers: [String]
    }

    static func connectionPresentation(
        state: TargetConnectionState,
        isChecking: Bool
    ) -> FleetConnectionPresentation {
        switch state {
        case .connectedWiFi:
            return .init(
                label: String(localized: "Connected over Wi-Fi"),
                symbol: "wifi",
                tone: .positive,
                isChecking: isChecking
            )
        case .connectedDirect:
            return .init(
                label: String(localized: "Connected directly"),
                symbol: "cable.connector",
                tone: .positive,
                isChecking: isChecking
            )
        case .connectedRemote:
            return .init(
                label: String(localized: "Connected remotely"),
                symbol: "globe",
                tone: .positive,
                isChecking: isChecking
            )
        case .connecting:
            return .init(
                label: String(localized: "Connecting"),
                symbol: "hourglass",
                tone: .neutral,
                isChecking: true
            )
        case .discovering:
            return .init(
                label: String(localized: "Looking for this Spark"),
                symbol: "antenna.radiowaves.left.and.right",
                tone: .neutral,
                isChecking: true
            )
        case .foundUnpaired:
            return .init(
                label: String(localized: "Not paired yet"),
                symbol: "person.badge.key",
                tone: .caution,
                isChecking: isChecking
            )
        case .delayed:
            return .init(
                label: String(localized: "Answering slowly"),
                symbol: "clock.badge.exclamationmark",
                tone: .caution,
                isChecking: isChecking
            )
        case .offlineCached:
            return .init(
                label: String(localized: "Offline · showing saved state"),
                symbol: "pause.circle",
                tone: .caution,
                isChecking: isChecking
            )
        case .updateRequired:
            return .init(
                label: String(localized: "Update required"),
                symbol: "arrow.down.circle",
                tone: .caution,
                isChecking: isChecking
            )
        case .identityMismatch:
            return .init(
                label: String(localized: "Identity changed"),
                symbol: "exclamationmark.triangle.fill",
                tone: .critical,
                isChecking: false
            )
        }
    }

    static func lastContact(_ snapshot: TargetOperationalSnapshot) -> String {
        guard let age = snapshot.evidenceAge else { return FleetFormat.unknown }
        return FleetFormat.elapsed(age)
    }

    static func availableMemory(_ snapshot: TargetOperationalSnapshot) -> String {
        guard let memory = snapshot.unifiedMemory,
            snapshot.evidence.memory.state != .missing
        else { return FleetFormat.unknown }
        return String(
            localized: .memoryFreeOfTotal(
                free: FleetFormat.gigabytes(memory.availableBytes),
                total: FleetFormat.gigabytes(memory.totalBytes)
            )
        )
    }

    static func activeModel(_ snapshot: TargetOperationalSnapshot) -> String {
        guard let inference = snapshot.activeInference,
            snapshot.evidence.inference.state != .missing
        else { return FleetFormat.unknown }
        guard isModelActive(inference.state) else { return String(localized: "No model running") }
        let name =
            inference.modelIdentity.flatMap { identity in
                snapshot.placements.first { $0.identity == identity }?.displayName
            } ?? FleetFormat.unknown
        return String(localized: .joined(name, inferenceStateLabel(inference.state)))
    }

    static func inferenceStateLabel(_ state: SparkInferenceState) -> String {
        switch state {
        case .loading: String(localized: "Loading")
        case .ready: String(localized: "Running")
        case .idle: String(localized: "Loaded and idle")
        case .draining: String(localized: "Finishing requests")
        case .unloading: String(localized: "Stopping")
        case .unloaded: String(localized: "Stopped")
        case .failed: String(localized: "Failed")
        }
    }

    static func installedModels(_ snapshot: TargetOperationalSnapshot) -> String {
        guard snapshot.evidence.inventory.state != .missing else { return FleetFormat.unknown }
        let count = snapshot.installedModelCount
        if count == 0 { return String(localized: "No models installed") }
        return String(localized: .modelsInstalled(count))
    }

    static func membership(
        _ snapshot: TargetOperationalSnapshot,
        isExternallyConfigured: Bool = false
    ) -> String {
        guard isCluster(snapshot.identity) else {
            return String(localized: "Single Spark")
        }
        let total = snapshot.members.count
        let reachable = snapshot.members.count(where: \.reachable)
        let prefix =
            isExternallyConfigured
            ? String(localized: "Externally configured cluster") : String(localized: "Cluster")
        return String(
            localized: .clusterMembersReachable(
                prefix: prefix,
                total: total,
                reachable: reachable
            )
        )
    }

    static func members(
        _ snapshot: TargetOperationalSnapshot,
        isExternallyConfigured: Bool = false
    ) -> [FleetMemberPresentation] {
        guard isCluster(snapshot.identity) else { return [] }
        return snapshot.members.map { member in
            FleetMemberPresentation(
                id: member.nodeID.rawValue.uuidString.lowercased(),
                name: member.displayName,
                role: isExternallyConfigured
                    ? String(localized: "Member") : memberRoleLabel(member.role),
                reachability: member.reachable
                    ? String(localized: "Reachable") : String(localized: "Not reachable"),
                tone: member.reachable ? .positive : .caution
            )
        }
    }

    static func memberRoleLabel(_ role: SparkNodeRole) -> String {
        switch role {
        case .leader: String(localized: "Coordinator")
        case .worker: String(localized: "Worker")
        case .standalone: String(localized: "Single Spark")
        }
    }

    static func evidenceNote(_ snapshot: TargetOperationalSnapshot) -> String? {
        switch snapshot.connectionState {
        case .offlineCached:
            let contact = lastContact(snapshot)
            return contact == FleetFormat.unknown
                ? String(
                    localized:
                        "Saved from an earlier session. This device has no contact record yet."
                )
                : String(localized: .savedStateFromContact(contact.lowercased()))
        case .identityMismatch:
            return String(
                localized: "Saved state is retained, but this route now presents a different Spark."
            )
        case .delayed:
            return String(localized: .valuesFromLastAnswer(lastContact(snapshot).lowercased()))
        default:
            return snapshot.evidence.hasStaleEvidence
                ? String(localized: "Some values are older than their freshness limit.")
                : nil
        }
    }

    static func actions(for target: FleetTargetInput) -> [FleetCardAction] {
        // Keep identity-changed cards blocked until removal instead of offering an ineffective reprobe.
        if target.hasIdentityIssue { return [.remove] }
        var actions: [FleetCardAction] = []
        if target.canOpen { actions.append(.open) }
        actions.append(.checkAgain)
        actions.append(.remove)
        return actions
    }

    static func accessibilityLabel(_ fields: FleetCardFields) -> String {
        var parts: [String] = [fields.name, fields.connectionLabel]
        parts.append(String(localized: .lastContactLabel(fields.lastContact)))
        parts.append(String(localized: .unifiedMemoryLabel(fields.availableMemory)))
        parts.append(String(localized: .activeModelLabel(fields.activeModel)))
        parts.append(fields.installedModels)
        parts.append(fields.membership)
        if fields.isChecking { parts.append(String(localized: "Checking now")) }
        for blocker in fields.blockers { parts.append(String(localized: .blockedBy(blocker))) }
        for warning in fields.warnings { parts.append(String(localized: .warningOf(warning))) }
        return parts.joined(separator: ". ") + "."
    }
}

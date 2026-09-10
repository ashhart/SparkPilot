import Foundation
import Observation
import SparkCore

public enum WorkloadComparisonBuilder {
    public static func snapshot(
        from operationalSnapshots: [TargetOperationalSnapshot],
        generatedAt: Date
    ) -> WorkloadComparisonSnapshot {
        let orderedSnapshots = operationalSnapshots.sorted(by: targetComesBefore)
        let targets = orderedSnapshots.map(targetColumn)
        let identities = Set(orderedSnapshots.flatMap { $0.placements.map(\.identity) })

        let rows = identities.map { identity in
            let observations = orderedSnapshots.compactMap { target in
                target.placements.first { $0.identity == identity }
            }
            let preferred = observations.sorted(by: placementComesBefore).first
            return WorkloadRowPresentation(
                id: identity,
                name: preferred?.displayName ?? identity.modelID,
                versionLabel: identity.recipeRevision,
                cells: orderedSnapshots.map { target in
                    cell(for: identity, target: target)
                }
            )
        }
        .sorted(by: rowComesBefore)

        return WorkloadComparisonSnapshot(
            generatedAt: generatedAt,
            targets: targets,
            rows: rows
        )
    }

    private static func targetComesBefore(
        _ left: TargetOperationalSnapshot,
        _ right: TargetOperationalSnapshot
    ) -> Bool {
        let comparison = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.identity.description < right.identity.description
    }

    private static func placementComesBefore(
        _ left: ModelPlacementSnapshot,
        _ right: ModelPlacementSnapshot
    ) -> Bool {
        let comparison = left.displayName.localizedCaseInsensitiveCompare(right.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.identity.description < right.identity.description
    }

    private static func rowComesBefore(
        _ left: WorkloadRowPresentation,
        _ right: WorkloadRowPresentation
    ) -> Bool {
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.id.description < right.id.description
    }

    private static func targetColumn(
        _ snapshot: TargetOperationalSnapshot
    ) -> WorkloadTargetColumn {
        let members = snapshot.members.map(memberPresentation)
        let kind: WorkloadTargetKind
        let clusterHealth: WorkloadClusterHealth
        switch snapshot.identity {
        case .node:
            kind = .spark
            clusterHealth = .notApplicable
        case .cluster:
            kind = .cluster
            clusterHealth = resolvedClusterHealth(snapshot: snapshot, members: members)
        }

        return WorkloadTargetColumn(
            id: snapshot.identity,
            name: snapshot.displayName,
            kind: kind,
            connectionLabel: connectionLabel(snapshot.connectionState),
            evidenceLabel: targetEvidenceLabel(snapshot, clusterHealth: clusterHealth),
            memberSummary: memberSummary(kind: kind, members: members),
            clusterHealth: clusterHealth,
            members: members,
            runtimeVersion: snapshot.runtime.version ?? String(localized: "Not reported"),
            runtimeHealthLabel: runtimeHealthLabel(snapshot.runtime.health),
            updateLabel: updateLabel(snapshot.runtime.updateState),
            performance: performance(snapshot),
            technicalIdentity: snapshot.technicalDetails.logicalIdentity,
            warnings: snapshot.warnings.map(\.message),
            blockers: snapshot.blockers.map(\.message)
        )
    }

    private static func memberPresentation(
        _ member: TargetMemberSnapshot
    ) -> WorkloadMemberPresentation {
        let state: WorkloadMemberState
        let detail: String
        if !member.reachable {
            state = .degraded
            detail = String(localized: "Member is unreachable")
        } else if let linkHealth = member.linkHealth {
            if linkHealth.lowercased() == "healthy" {
                state = .ready
                detail = String(localized: "Member and link are healthy")
            } else {
                state = .degraded
                detail = String(localized: .linkHealthIs(linkHealth))
            }
        } else {
            state = .unknown
            detail = String(localized: "Member is reachable, but link health was not reported")
        }
        return WorkloadMemberPresentation(
            id: member.nodeID,
            name: member.displayName,
            role: roleLabel(member.role),
            state: state,
            detail: detail,
            lastContact: member.lastSuccessfulContact
        )
    }

    private static func resolvedClusterHealth(
        snapshot: TargetOperationalSnapshot,
        members: [WorkloadMemberPresentation]
    ) -> WorkloadClusterHealth {
        guard snapshot.evidence.health.state == .current, members.count > 1 else {
            return .unknown
        }
        if members.contains(where: { $0.state == .degraded }) {
            return .degraded
        }
        if members.contains(where: { $0.state == .unknown }) {
            return .unknown
        }
        return snapshot.runtime.health == .healthy ? .healthy : .degraded
    }

    private static func cell(
        for identity: ModelPlacementIdentity,
        target: TargetOperationalSnapshot
    ) -> WorkloadCellPresentation {
        let id = WorkloadCellID(model: identity, target: target.identity)
        guard let placement = target.placements.first(where: { $0.identity == identity }) else {
            if target.evidence.inventory.state == .current {
                return WorkloadCellPresentation(
                    id: id,
                    state: .notPresent,
                    evidence: .current,
                    detail: String(
                        localized: "This exact signed recipe is not present on this target."
                    )
                )
            }
            return WorkloadCellPresentation(
                id: id,
                state: .unknown,
                evidence: evidenceState(target.evidence.inventory.state),
                detail: String(
                    localized: "Inventory evidence cannot confirm whether this recipe is present."
                )
            )
        }

        let evidence = evidenceState(placement.evidence.state)
        guard evidence != .missing, target.evidence.inventory.state != .missing else {
            return WorkloadCellPresentation(
                id: id,
                state: .unknown,
                evidence: .missing,
                detail: String(localized: "Authenticated inventory evidence is missing.")
            )
        }

        if let blocker = placement.blockers.first ?? target.blockers.first {
            return WorkloadCellPresentation(
                id: id,
                state: .blocked,
                evidence: evidence,
                detail: blocker.message
            )
        }

        if placement.state == .failed || placement.state == .incompatible {
            return WorkloadCellPresentation(
                id: id,
                state: .blocked,
                evidence: evidence,
                detail: placement.state == .failed
                    ? String(localized: "The last model operation failed.")
                    : String(localized: "This signed recipe is incompatible with the target.")
            )
        }

        if placement.state == .running || placement.state == .starting
            || placement.state == .stopping
        {
            guard target.evidence.inference.state != .missing else {
                return WorkloadCellPresentation(
                    id: id,
                    state: .unknown,
                    evidence: .missing,
                    detail: String(localized: "Inference evidence is missing for this workload.")
                )
            }
        }

        if case .cluster = target.identity {
            let members = target.members.map(memberPresentation)
            let health = resolvedClusterHealth(snapshot: target, members: members)
            if health == .degraded {
                return WorkloadCellPresentation(
                    id: id,
                    state: .degraded,
                    evidence: evidence,
                    detail: clusterDegradationDetail(health: health, members: members)
                )
            }
            if health == .unknown {
                return WorkloadCellPresentation(
                    id: id,
                    state: .unknown,
                    evidence: clusterEvidenceState(snapshot: target, members: members),
                    detail: clusterUnknownDetail(snapshot: target, members: members)
                )
            }
        }

        if let warning = placement.warnings.first {
            return WorkloadCellPresentation(
                id: id,
                state: .degraded,
                evidence: evidence,
                detail: warning.message
            )
        }

        if target.runtime.health == .degraded || target.runtime.health == .unavailable {
            return WorkloadCellPresentation(
                id: id,
                state: .degraded,
                evidence: evidence,
                detail:
                    String(
                        localized: .runtimeHealthIs(
                            runtimeHealthLabel(target.runtime.health).lowercased()
                        )
                    )
            )
        }

        let state: WorkloadDisplayState
        let detail: String
        switch placement.state {
        case .running:
            state = .running
            detail = String(localized: "The runtime reports this exact recipe as active.")
        case .installed, .stopping:
            state = .installed
            detail =
                placement.state == .stopping
                ? String(localized: "The workload is stopping and remains installed.")
                : String(localized: "This exact recipe is installed.")
        case .downloading:
            state = .downloading
            detail = String(localized: "The signed recipe is downloading.")
        case .starting:
            state = .planned
            detail = String(localized: "The runtime accepted this workload and is starting it.")
        case .available:
            state = .notPresent
            detail = String(
                localized: "The recipe is available, but its model files are not installed."
            )
        case .failed, .incompatible:
            state = .blocked
            detail = String(localized: "The target cannot run this recipe.")
        case .unknown:
            state = .unknown
            detail = String(localized: "The target did not report a recognised placement state.")
        }
        return WorkloadCellPresentation(id: id, state: state, evidence: evidence, detail: detail)
    }

    private static func clusterDegradationDetail(
        health: WorkloadClusterHealth,
        members: [WorkloadMemberPresentation]
    ) -> String {
        if let member = members.first(where: { $0.state == .degraded }) {
            return String(localized: .memberDegraded(member.name))
        }
        if health == .unknown {
            return String(
                localized: "Every cluster member needs current reachability and link evidence."
            )
        }
        return String(localized: "Cluster health is degraded.")
    }

    private static func clusterUnknownDetail(
        snapshot: TargetOperationalSnapshot,
        members: [WorkloadMemberPresentation]
    ) -> String {
        if snapshot.evidence.health.state != .current {
            return String(
                localized: "Current authenticated cluster health evidence is unavailable."
            )
        }
        if members.count < 2 {
            return String(
                localized: "The coordinator did not report a complete cluster membership."
            )
        }
        return String(
            localized: "Every cluster member needs explicit reachability and link evidence."
        )
    }

    private static func clusterEvidenceState(
        snapshot: TargetOperationalSnapshot,
        members: [WorkloadMemberPresentation]
    ) -> WorkloadEvidenceState {
        let healthEvidence = evidenceState(snapshot.evidence.health.state)
        if healthEvidence != .current { return healthEvidence }
        if members.count < 2 || members.contains(where: { $0.state == .unknown }) {
            return .missing
        }
        return .current
    }

    private static func performance(
        _ snapshot: TargetOperationalSnapshot
    ) -> WorkloadPerformancePresentation {
        let memoryLabel: String
        if let memory = snapshot.unifiedMemory {
            let available = ByteCountFormatter.string(
                fromByteCount: memory.availableBytes,
                countStyle: .memory
            )
            let total = ByteCountFormatter.string(
                fromByteCount: memory.totalBytes,
                countStyle: .memory
            )
            memoryLabel = String(
                localized: .memoryAvailableOfTotal(available: available, total: total)
            )
        } else {
            memoryLabel = String(localized: "Not reported")
        }
        let diskLabel =
            snapshot.disk.map {
                String(
                    localized: .diskFree(
                        ByteCountFormatter.string(fromByteCount: $0.freeBytes, countStyle: .file)
                    )
                )
            } ?? String(localized: "Not reported")
        let inference = snapshot.activeInference
        return WorkloadPerformancePresentation(
            memoryLabel: memoryLabel,
            diskLabel: diskLabel,
            activeRequestsLabel: inference.map { String($0.activeRequests) }
                ?? String(localized: "Not reported"),
            queueDepthLabel: inference?.queueDepth.map(String.init)
                ?? String(localized: "Not reported"),
            throughputLabel: inference?.tokensPerSecond.map {
                String(
                    localized: .tokensPerSecondSpelled(
                        $0.formatted(.number.precision(.fractionLength(1)))
                    )
                )
            } ?? String(localized: "Not reported"),
            latencyLabel: inference?.timeToFirstTokenMilliseconds.map {
                String(
                    localized: .milliseconds($0.formatted(.number.precision(.fractionLength(0))))
                )
            } ?? String(localized: "Not reported")
        )
    }

    private static func targetEvidenceLabel(
        _ snapshot: TargetOperationalSnapshot,
        clusterHealth: WorkloadClusterHealth
    ) -> String {
        let states = [
            snapshot.evidence.health.state,
            snapshot.evidence.inventory.state,
            snapshot.evidence.memory.state,
            snapshot.evidence.inference.state,
        ]
        if states.contains(.missing) { return String(localized: "Evidence incomplete") }
        if states.contains(.stale) { return String(localized: "Stale evidence") }
        if clusterHealth == .unknown { return String(localized: "Cluster evidence incomplete") }
        return String(localized: "Current evidence")
    }

    private static func memberSummary(
        kind: WorkloadTargetKind,
        members: [WorkloadMemberPresentation]
    ) -> String {
        guard kind == .cluster else { return String(localized: "Single Spark") }
        guard members.count > 1 else { return String(localized: "Cluster membership incomplete") }
        let ready = members.count { $0.state == .ready }
        return String(localized: .clusterMembersReadyCount(ready: ready, total: members.count))
    }

    private static func connectionLabel(_ state: TargetConnectionState) -> String {
        switch state {
        case .discovering: String(localized: "Looking for Spark")
        case .foundUnpaired: String(localized: "Not paired")
        case .connecting: String(localized: "Connecting")
        case .connectedWiFi: String(localized: "Local Wi-Fi")
        case .connectedDirect: String(localized: "Direct connection")
        case .connectedRemote: String(localized: "Remote")
        case .delayed: String(localized: "Delayed")
        case .offlineCached: String(localized: "Offline")
        case .identityMismatch: String(localized: "Identity changed")
        case .updateRequired: String(localized: "Update required")
        }
    }

    private static func runtimeHealthLabel(_ health: SparkRuntimeHealthState) -> String {
        switch health {
        case .healthy: String(localized: "Healthy")
        case .degraded: String(localized: "Degraded")
        case .unavailable: String(localized: "Unavailable")
        case .unknown: String(localized: "Unknown")
        }
    }

    private static func updateLabel(_ state: SparkRuntimeUpdateState) -> String {
        switch state {
        case .current: String(localized: "Up to date")
        case .available: String(localized: "Update available")
        case .required: String(localized: "Update required")
        case .unknown: String(localized: "Update state unknown")
        }
    }

    private static func evidenceState(
        _ state: OperationalFreshnessState
    ) -> WorkloadEvidenceState {
        switch state {
        case .current: .current
        case .stale: .stale
        case .missing: .missing
        }
    }

    private static func roleLabel(_ role: SparkNodeRole) -> String {
        switch role {
        case .standalone: String(localized: "Standalone")
        case .leader: String(localized: "Coordinator")
        case .worker: String(localized: "Member")
        }
    }
}

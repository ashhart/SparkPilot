import Foundation
import Observation
import SparkCore
import SparkLibrary

public enum FleetPresentationBuilder {
    /// Excludes unloaded, unloading and failed states when counting targets occupied by an active model.
    static func isModelActive(_ state: SparkInferenceState) -> Bool {
        switch state {
        case .loading, .ready, .idle, .draining: true
        case .unloaded, .unloading, .failed: false
        }
    }

    /// Treat downloading placements as not yet installed.
    static func isPlacementInstalled(_ state: ModelPlacementState) -> Bool {
        switch state {
        case .installed, .starting, .running, .stopping: true
        case .available, .downloading, .failed, .incompatible, .unknown: false
        }
    }

    public static func build(
        targets: [FleetTargetInput],
        query: FleetQuery = .unfiltered,
        checking: Set<String> = [],
        storage: LibraryStorageStatus = .persistent
    ) -> FleetPresentation {
        let allCards = targets.map { card(for: $0, isChecking: checking.contains($0.id)) }
        let matching = zip(targets, allCards)
            .filter { matches(query: query, target: $0.0, card: $0.1) }
            .map(\.1)
            .sorted(by: ordersBefore)

        let content: FleetContentState
        if targets.isEmpty {
            content = .empty
        } else if matching.isEmpty {
            content = .filteredEmpty(totalCount: targets.count)
        } else {
            content = .cards(matching)
        }

        return FleetPresentation(
            summary: summary(targets: targets, cards: allCards),
            content: content,
            storageNotice: storageNotice(storage),
            installedModelOptions: installedModelOptions(targets: targets),
            visibleCount: matching.count,
            totalCount: targets.count
        )
    }

    /// Sorts by attention and then name with a total order to keep equally urgent cards stable.
    static func ordersBefore(_ lhs: FleetCardPresentation, _ rhs: FleetCardPresentation) -> Bool {
        let left = attentionRank(lhs)
        let right = attentionRank(rhs)
        if left != right { return left < right }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func attentionRank(_ card: FleetCardPresentation) -> Int {
        if !card.blockers.isEmpty { return 0 }
        if !card.warnings.isEmpty { return 1 }
        return 2
    }

    // MARK: Filtering

    static func matches(
        query: FleetQuery,
        target: FleetTargetInput,
        card: FleetCardPresentation
    ) -> Bool {
        let text = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let haystack = [card.name] + card.members.map(\.name)
            let found = haystack.contains {
                $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if !found { return false }
        }

        switch query.connection {
        case .any:
            break
        case .connected:
            guard isConnected(target.snapshot.connectionState) else { return false }
        case .delayed:
            guard target.snapshot.connectionState == .delayed else { return false }
        case .offline:
            guard target.snapshot.connectionState == .offlineCached else { return false }
        case .needsAttention:
            guard card.needsAttention else { return false }
        }

        switch query.update {
        case .any:
            break
        case .current:
            guard target.snapshot.runtime.updateState == .current else { return false }
        case .updateAvailable:
            guard target.snapshot.runtime.updateState == .available else { return false }
        case .updateRequired:
            guard target.snapshot.runtime.updateState == .required else { return false }
        case .unknown:
            guard target.snapshot.runtime.updateState == .unknown else { return false }
        }

        switch query.membership {
        case .any:
            break
        case .standalone:
            guard !isCluster(target.snapshot.identity) else { return false }
        case .cluster:
            guard isCluster(target.snapshot.identity) else { return false }
        }

        if let model = query.installedModel {
            let installed = target.snapshot.placements
                .filter { isPlacementInstalled($0.state) }
                .map(\.displayName)
            guard installed.contains(model) else { return false }
        }

        return true
    }

    static func isConnected(_ state: TargetConnectionState) -> Bool {
        switch state {
        case .connectedWiFi, .connectedDirect, .connectedRemote: true
        default: false
        }
    }

    static func isCluster(_ identity: SparkTargetIdentity) -> Bool {
        if case .cluster = identity { return true }
        return false
    }

    static func installedModelOptions(targets: [FleetTargetInput]) -> [String] {
        var names: Set<String> = []
        for target in targets {
            for placement in target.snapshot.placements where isPlacementInstalled(placement.state)
            {
                names.insert(placement.displayName)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Summary

    static func summary(
        targets: [FleetTargetInput],
        cards: [FleetCardPresentation]
    ) -> FleetSummaryPresentation {
        let connected = targets.count { isConnected($0.snapshot.connectionState) }
        let delayed = targets.count { $0.snapshot.connectionState == .delayed }
        let offline = targets.count { $0.snapshot.connectionState == .offlineCached }
        let active = targets.count { target in
            guard target.snapshot.evidence.inference.state != .missing,
                let inference = target.snapshot.activeInference
            else { return false }
            return isModelActive(inference.state)
        }
        let warnings = cards.reduce(0) { $0 + $1.warnings.count }
        let blockers = cards.reduce(0) { $0 + $1.blockers.count }

        // Aggregate memory headroom only from targets with current evidence.
        let contributing = targets.filter {
            $0.snapshot.evidence.memory.state == .current && $0.snapshot.unifiedMemory != nil
        }
        let memoryValue: String
        let memoryNote: String
        if contributing.isEmpty {
            memoryValue = FleetFormat.unknown
            memoryNote =
                targets.isEmpty
                ? String(localized: "No Sparks are paired with this device yet.")
                : String(localized: "No Spark reported current unified-memory evidence.")
        } else {
            let total = contributing.reduce(Int64(0)) {
                $0 + ($1.snapshot.unifiedMemory?.availableBytes ?? 0)
            }
            memoryValue = FleetFormat.gigabytes(total)
            memoryNote =
                String(
                    localized: .fromSparksWithEvidence(
                        contributing: contributing.count,
                        total: targets.count
                    )
                )
        }

        let items = [
            FleetSummaryItem(
                id: "connected",
                title: String(localized: "Connected"),
                value: String(
                    localized: .connectedOfTotal(connected: connected, total: targets.count)
                ),
                symbol: "checkmark.circle"
            ),
            FleetSummaryItem(
                id: "delayed",
                title: String(localized: "Delayed"),
                value: "\(delayed)",
                symbol: "clock.badge.exclamationmark"
            ),
            FleetSummaryItem(
                id: "offline",
                title: String(localized: "Offline"),
                value: "\(offline)",
                symbol: "pause.circle"
            ),
            FleetSummaryItem(
                id: "activeModels",
                title: String(localized: "Active models"),
                value: "\(active)",
                symbol: "play.circle"
            ),
            FleetSummaryItem(
                id: "memory",
                title: String(localized: "Unified memory free"),
                value: memoryValue,
                symbol: "memorychip"
            ),
            FleetSummaryItem(
                id: "warnings",
                title: String(localized: "Warnings"),
                value: blockers > 0
                    ? String(
                        localized: .warningsWithBlockers(warnings: warnings, blockers: blockers)
                    )
                    : "\(warnings)",
                symbol: "exclamationmark.triangle"
            ),
        ]

        // Combine catalogue readings with locale-aware list formatting.
        let readings =
            items
            .map { String(localized: .labelledValue(title: $0.title, value: $0.value)) }
            .formatted(.list(type: .and))
        let accessibility = String(localized: .sentencePair(readings, memoryNote))

        return FleetSummaryPresentation(
            targetCount: targets.count,
            connectedCount: connected,
            delayedCount: delayed,
            offlineCount: offline,
            activeModelCount: active,
            warningCount: warnings,
            blockerCount: blockers,
            availableUnifiedMemory: memoryValue,
            memoryEvidenceNote: memoryNote,
            items: items,
            accessibilityLabel: accessibility
        )
    }

    static func storageNotice(_ status: LibraryStorageStatus) -> FleetStorageNotice? {
        guard status.isSessionOnly else { return nil }
        return FleetStorageNotice(
            title: String(localized: "Your Sparks aren't being saved"),
            message: String(
                localized: """
                    Nothing is lost yet — this device could not open its Spark library \
                    storage, so changes won't survive relaunching the app. Try restoring \
                    storage before you add Sparks.
                    """
            ),
            actionTitle: String(localized: "Try Again")
        )
    }
}

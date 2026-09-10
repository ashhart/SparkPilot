import Foundation
import SparkAPI
import SparkCore

extension TargetOperationalSnapshotComposer {

    func evidenceFreshness(
        evidence: TargetOperationalEvidence,
        cached: TargetOperationalSnapshot?,
        at date: Date,
        forceStale: Bool
    ) -> TargetEvidenceFreshness {
        TargetEvidenceFreshness(
            health: freshness(
                observedAt: evidence.health?.observedAt ?? cached?.evidence.health.observedAt,
                at: date,
                staleAfter: freshnessPolicy.health,
                forceStale: forceStale
            ),
            inventory: freshness(
                observedAt: evidence.inventory?.observedAt ?? cached?.evidence.inventory.observedAt,
                at: date,
                staleAfter: freshnessPolicy.inventory,
                forceStale: forceStale
            ),
            memory: freshness(
                observedAt: evidence.status?.observedAt ?? cached?.evidence.memory.observedAt,
                at: date,
                staleAfter: freshnessPolicy.memory,
                forceStale: forceStale
            ),
            inference: freshness(
                observedAt: evidence.inference?.observedAt ?? evidence.status?.observedAt
                    ?? cached?.evidence.inference.observedAt,
                at: date,
                staleAfter: freshnessPolicy.inference,
                forceStale: forceStale
            ),
            operations: freshness(
                observedAt: evidence.operations?.observedAt
                    ?? cached?.evidence.operations.observedAt,
                at: date,
                staleAfter: freshnessPolicy.operations,
                forceStale: forceStale
            )
        )
    }

    func missingFreshness(at date: Date) -> TargetEvidenceFreshness {
        TargetEvidenceFreshness(
            health: freshness(observedAt: nil, at: date, staleAfter: freshnessPolicy.health),
            inventory: freshness(
                observedAt: nil,
                at: date,
                staleAfter: freshnessPolicy.inventory
            ),
            memory: freshness(observedAt: nil, at: date, staleAfter: freshnessPolicy.memory),
            inference: freshness(
                observedAt: nil,
                at: date,
                staleAfter: freshnessPolicy.inference
            ),
            operations: freshness(
                observedAt: nil,
                at: date,
                staleAfter: freshnessPolicy.operations
            )
        )
    }

    private func freshness(
        observedAt: Date?,
        at date: Date,
        staleAfter: TimeInterval,
        forceStale: Bool = false
    ) -> OperationalEvidenceFreshness {
        OperationalEvidenceFreshness(
            observedAt: observedAt,
            evaluatedAt: date,
            staleAfter: staleAfter,
            forceStale: forceStale
        )
    }

    func runtimeSnapshot(
        evidence: TargetOperationalEvidence,
        cached: TargetOperationalSnapshot?
    ) -> TargetRuntimeSnapshot {
        let version =
            evidence.health?.value.runtimeVersion
            ?? evidence.status?.value.identity.runtimeVersion
            ?? cached?.runtime.version
        let health: SparkRuntimeHealthState
        if let response = evidence.health?.value {
            health = response.isOK ? .healthy : .degraded
        } else {
            health = cached?.runtime.health ?? .unknown
        }
        let available = evidence.release?.availableVersion ?? cached?.runtime.availableVersion
        let updateState: SparkRuntimeUpdateState
        if let release = evidence.release {
            updateState =
                version.map {
                    compareVersion(
                        current: $0,
                        available: release.availableVersion,
                        minimum: release.minimumSupportedVersion
                    )
                } ?? .unknown
        } else {
            updateState = cached?.runtime.updateState ?? .unknown
        }
        return TargetRuntimeSnapshot(
            version: version,
            health: health,
            updateState: updateState,
            availableVersion: available
        )
    }

    private func compareVersion(
        current: String,
        available: String,
        minimum: String?
    ) -> SparkRuntimeUpdateState {
        guard versionParts(current) != nil, versionParts(available) != nil else {
            return current == available ? .current : .unknown
        }
        if let minimum, versionParts(minimum) == nil {
            return .unknown
        }
        if let minimum, version(current, isBefore: minimum) {
            return .required
        }
        if version(current, isBefore: available) {
            return .available
        }
        return .current
    }

    private func version(_ lhs: String, isBefore rhs: String) -> Bool {
        guard let left = versionParts(lhs), let right = versionParts(rhs) else { return false }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart }
        }
        return false
    }

    private func versionParts(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let parts = core.split(separator: ".").map(String.init)
        let numbers = parts.compactMap(Int.init)
        return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
    }
}

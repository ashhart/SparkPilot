import Foundation
import SparkAPI
import SparkCore

extension TargetOperationalSnapshotComposer {

    func operationSnapshots(_ operations: [SparkAPI.Operation])
        -> [TargetOperationSnapshot]
    {
        operations.map {
            TargetOperationSnapshot(
                id: SparkOperationID(rawValue: $0.id),
                kind: $0.kind,
                state: SparkOperationState(rawValue: $0.state.rawValue) ?? .failed,
                progress: $0.progress,
                stage: $0.stage,
                errorCode: $0.errorCode,
                cancellable: $0.cancellable,
                createdAt: $0.createdAt,
                startedAt: $0.startedAt,
                completedAt: $0.completedAt,
                actorDeviceID: $0.actorDeviceID?.uuidString.lowercased(),
                notificationRequested: $0.notificationRequested
            )
        }
    }

    func routeSummary(_ route: CachedRoute?) -> PreferredRouteSummary? {
        route.map {
            PreferredRouteSummary(
                kind: $0.kind,
                host: $0.baseURL.host,
                port: $0.baseURL.port,
                interfaceName: $0.interfaceName,
                lastSuccessfulAt: $0.lastSuccess,
                isMetered: $0.isMetered
            )
        }
    }

    func connectedState(for kind: SparkTransportKind?) -> TargetConnectionState {
        switch kind {
        case .directEthernet:
            .connectedDirect
        case .localWiFi:
            .connectedWiFi
        case .privateOverlay:
            .connectedRemote
        case nil:
            .connecting
        }
    }

    func map(_ state: SparkConnectionState) -> TargetConnectionState {
        switch state {
        case .discovering:
            .discovering
        case .foundUnpaired:
            .foundUnpaired
        case .connecting:
            .connecting
        case .connectedWiFi:
            .connectedWiFi
        case .connectedDirect:
            .connectedDirect
        case .connectedRemote:
            .connectedRemote
        case .offlineCached:
            .offlineCached
        case .identityMismatch:
            .identityMismatch
        case .updateRequired:
            .updateRequired
        }
    }

    func notices(
        connection: TargetConnectionState,
        freshness: TargetEvidenceFreshness,
        runtime: TargetRuntimeSnapshot,
        vllmHealth: VLLMHealthState,
        memory: UnifiedMemorySnapshot?,
        temperatureCelsius: Double?,
        members: [TargetMemberSnapshot],
        operations: [TargetOperationSnapshot],
        unsignedCatalogueItems: Int,
        extraBlocker: OperationalNotice?
    ) -> (warnings: [OperationalNotice], blockers: [OperationalNotice]) {
        var warnings: [OperationalNotice] = []
        var blockers: [OperationalNotice] = []
        if connection == .offlineCached {
            warnings.append(
                OperationalNotice(
                    code: "target.offline",
                    message: String(
                        localized:
                            "Showing the last authenticated state while the target is offline."
                    )
                )
            )
        } else if connection == .delayed {
            warnings.append(
                OperationalNotice(
                    code: "target.delayed",
                    message: String(localized: "The latest authenticated response is delayed.")
                )
            )
        }
        if freshness.hasStaleEvidence && connection != .offlineCached {
            warnings.append(
                OperationalNotice(
                    code: "evidence.stale",
                    message: String(
                        localized: "Some operational values are older than their freshness limit."
                    )
                )
            )
        }
        if runtime.health == .degraded {
            warnings.append(
                OperationalNotice(
                    code: "runtime.degraded",
                    message: String(localized: "Spark Runtime is degraded.")
                )
            )
        }
        if runtime.updateState == .available {
            warnings.append(
                OperationalNotice(
                    code: "runtime.update_available",
                    message: String(localized: "A newer signed Spark Runtime release is available.")
                )
            )
        } else if runtime.updateState == .required {
            blockers.append(
                OperationalNotice(
                    code: "runtime.update_required",
                    message: String(
                        localized: "Spark Runtime must be updated before normal operation."
                    )
                )
            )
        }
        if vllmHealth == .failed {
            warnings.append(
                OperationalNotice(
                    code: "inference.failed",
                    message: String(localized: "The inference engine failed.")
                )
            )
        }
        if let memory, memory.pressure == .critical || memory.pressure == .emergency {
            blockers.append(
                OperationalNotice(
                    code: "memory.pressure_blocking",
                    message: String(localized: "Unified-memory pressure blocks new model work.")
                )
            )
        } else if memory?.pressure == .warning {
            warnings.append(
                OperationalNotice(
                    code: "memory.pressure_warning",
                    message: String(localized: "Unified memory is under pressure.")
                )
            )
        }
        if let temperatureCelsius,
            SparkThermalReading.needsAttention(
                SparkThermalReading.state(reported: nil, celsius: temperatureCelsius)
            )
        {
            warnings.append(
                OperationalNotice(
                    code: "node.thermal_warning",
                    message: String(
                        localized: "This Spark is running hot and may slow down to protect itself."
                    )
                )
            )
        }
        if members.count > 1,
            members.contains(where: {
                !$0.reachable || ($0.linkHealth != nil && $0.linkHealth != "healthy")
            })
        {
            warnings.append(
                OperationalNotice(
                    code: "cluster.degraded",
                    message: String(localized: "One or more cluster members or links are degraded.")
                )
            )
        }
        if operations.contains(where: { $0.state == .failed }) {
            warnings.append(
                OperationalNotice(
                    code: "operations.failed",
                    message: String(localized: "A recent operation failed and may need recovery.")
                )
            )
        }
        if unsignedCatalogueItems > 0 {
            blockers.append(
                OperationalNotice(
                    code: "inventory.recipe_identity_missing",
                    message: String(localized: "A catalogue item has no signed recipe identity.")
                )
            )
        }
        if let extraBlocker, !blockers.contains(where: { $0.code == extraBlocker.code }) {
            blockers.append(extraBlocker)
        }
        return (warnings, blockers)
    }

    func technicalDetails(
        identity: SparkTargetIdentity,
        members: [TargetMemberSnapshot]
    ) -> TargetTechnicalDetails {
        TargetTechnicalDetails(
            logicalIdentity: identity.description,
            memberNodeIDs: members.map(\.nodeID)
        )
    }

    func newest(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

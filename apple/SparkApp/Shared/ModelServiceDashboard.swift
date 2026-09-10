import Foundation
import SparkAPI

public protocol ModelServiceSettingsReading: Sendable {
    func sparkSettings(route: URL) async throws -> GeneratedAPI.SparkSettingsSnapshot
}

extension SparkAPIClient: ModelServiceSettingsReading {}

public enum ModelServiceRunState: Sendable, Equatable {
    case running
    case installed
    case readyToInstall
    case needsAttention
    case unavailable
    case unknown
}

public enum ModelServiceOwnership: Sendable, Equatable {
    case sparkPilot
    case external
    case unknown
}

public struct ModelEngineServiceSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let state: ModelServiceRunState
    public let ownership: ModelServiceOwnership
    public let instanceCount: Int
    public let servedModels: [String]

    public init(
        id: String,
        name: String,
        state: ModelServiceRunState,
        ownership: ModelServiceOwnership,
        instanceCount: Int,
        servedModels: [String]
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.ownership = ownership
        self.instanceCount = instanceCount
        self.servedModels = servedModels
    }
}

public struct ModelOptionalServiceSnapshot: Sendable, Equatable {
    public let state: ModelServiceRunState
    public let version: String?
    public let updateAvailable: Bool
    public let gatewayHealthy: Bool?

    public init(
        state: ModelServiceRunState,
        version: String?,
        updateAvailable: Bool,
        gatewayHealthy: Bool?
    ) {
        self.state = state
        self.version = version
        self.updateAvailable = updateAvailable
        self.gatewayHealthy = gatewayHealthy
    }
}

public struct ModelSoftwareUpdateSnapshot: Sendable, Equatable {
    public let checkedAt: String
    public let systemPackagesAvailable: Int?
    public let firmwareUpdatesAvailable: Int?
    public let runtimeReleaseID: String?
    public let rebootRequired: Bool

    public init(
        checkedAt: String,
        systemPackagesAvailable: Int?,
        firmwareUpdatesAvailable: Int?,
        runtimeReleaseID: String?,
        rebootRequired: Bool
    ) {
        self.checkedAt = checkedAt
        self.systemPackagesAvailable = systemPackagesAvailable
        self.firmwareUpdatesAvailable = firmwareUpdatesAvailable
        self.runtimeReleaseID = runtimeReleaseID
        self.rebootRequired = rebootRequired
    }

    public var totalKnownUpdates: Int? {
        guard systemPackagesAvailable != nil || firmwareUpdatesAvailable != nil else {
            return nil
        }
        return (systemPackagesAvailable ?? 0) + (firmwareUpdatesAvailable ?? 0)
            + (runtimeReleaseID == nil ? 0 : 1)
    }
}

public struct ModelServiceTargetSnapshot: Sendable, Equatable {
    public let observedAt: Date
    public let runtimeVersion: String
    public let runtimeHealthy: Bool
    public let engines: [ModelEngineServiceSnapshot]
    public let openWebUI: ModelOptionalServiceSnapshot?
    public let updates: ModelSoftwareUpdateSnapshot?
    public let catalogueRecipeCount: Int
    public let catalogueRefreshAvailable: Bool?

    public init(
        observedAt: Date,
        runtimeVersion: String,
        runtimeHealthy: Bool,
        engines: [ModelEngineServiceSnapshot],
        openWebUI: ModelOptionalServiceSnapshot?,
        updates: ModelSoftwareUpdateSnapshot?,
        catalogueRecipeCount: Int,
        catalogueRefreshAvailable: Bool?
    ) {
        self.observedAt = observedAt
        self.runtimeVersion = runtimeVersion
        self.runtimeHealthy = runtimeHealthy
        self.engines = engines
        self.openWebUI = openWebUI
        self.updates = updates
        self.catalogueRecipeCount = catalogueRecipeCount
        self.catalogueRefreshAvailable = catalogueRefreshAvailable
    }
}

public enum ModelServiceDashboardAdapter {
    public static func snapshot(
        observedAt: Date,
        runtimeVersion: String,
        runtimeHealthy: Bool,
        capabilities: SparkCapabilities?,
        workloads: GeneratedAPI.WorkloadInventory?,
        openWebUI: GeneratedAPI.OptionalServiceStatus?,
        settings: GeneratedAPI.SparkSettingsSnapshot?,
        catalogueStatus: GeneratedAPI.CatalogueStatus?,
        catalogueRecipeCount: Int
    ) -> ModelServiceTargetSnapshot {
        ModelServiceTargetSnapshot(
            observedAt: observedAt,
            runtimeVersion: runtimeVersion,
            runtimeHealthy: runtimeHealthy,
            engines: engines(capabilities: capabilities, inventory: workloads),
            openWebUI: optionalService(openWebUI),
            updates: settings.map { updateSnapshot($0.softwareUpdates) },
            catalogueRecipeCount: catalogueRecipeCount,
            catalogueRefreshAvailable: catalogueStatus?.refreshAvailable
        )
    }

    private static func engines(
        capabilities: SparkCapabilities?,
        inventory: GeneratedAPI.WorkloadInventory?
    ) -> [ModelEngineServiceSnapshot] {
        let recognised = (inventory?.workloads ?? []).filter {
            $0.kind == .inferenceEngine
                && ($0.recognisedEngine == .vllm || $0.recognisedEngine == .sglang)
        }
        let groups = Dictionary(grouping: recognised, by: \.recognisedEngine)
        var snapshots = groups.map { engine, workloads in
            engineSnapshot(engine: engine, workloads: workloads)
        }
        if groups[.vllm] == nil {
            let state: ModelServiceRunState
            if capabilities?.isEnabled("container_runtime") == true {
                state = .readyToInstall
            } else if capabilities == nil || inventory?.available == false {
                state = .unknown
            } else {
                state = .unavailable
            }
            snapshots.append(
                ModelEngineServiceSnapshot(
                    id: "vllm",
                    name: "vLLM",
                    state: state,
                    ownership: .unknown,
                    instanceCount: 0,
                    servedModels: []
                )
            )
        }
        return snapshots.sorted { left, right in
            let leftRank = engineRank(left)
            let rightRank = engineRank(right)
            return leftRank == rightRank ? left.id < right.id : leftRank < rightRank
        }
    }

    private static func engineSnapshot(
        engine: GeneratedAPI.WorkloadEngine,
        workloads: [GeneratedAPI.ObservedWorkload]
    ) -> ModelEngineServiceSnapshot {
        let state: ModelServiceRunState
        if workloads.contains(where: { $0.state == .running }) {
            state = .running
        } else if workloads.contains(where: {
            $0.state == .dead || $0.state == .restarting || $0.state == .unknown
        }) {
            state = .needsAttention
        } else {
            state = .installed
        }
        let ownership: ModelServiceOwnership
        if workloads.contains(where: { $0.ownership == .sparkManaged }) {
            ownership = .sparkPilot
        } else if workloads.contains(where: {
            $0.ownership == .externalObserved || $0.ownership == .adoptionAvailable
        }) {
            ownership = .external
        } else {
            ownership = .unknown
        }
        return ModelEngineServiceSnapshot(
            id: engine == .vllm ? "vllm" : "sglang",
            name: engine == .vllm ? "vLLM" : "SGLang",
            state: state,
            ownership: ownership,
            instanceCount: workloads.count,
            servedModels: Array(Set(workloads.flatMap { $0.servedModels ?? [] })).sorted()
        )
    }

    private static func engineRank(_ engine: ModelEngineServiceSnapshot) -> Int {
        engine.id == "vllm" ? 0 : 1
    }

    private static func optionalService(
        _ service: GeneratedAPI.OptionalServiceStatus?
    ) -> ModelOptionalServiceSnapshot? {
        guard let service else { return nil }
        let state: ModelServiceRunState
        switch service.state {
        case .healthy:
            state = service.inferenceGateway.healthy ? .running : .needsAttention
        case .starting, .recovering:
            state = .installed
        case .stopped:
            state = .installed
        case .failed:
            state = .needsAttention
        case .notInstalled:
            state = .readyToInstall
        }
        return ModelOptionalServiceSnapshot(
            state: state,
            version: service.availableVersion,
            updateAvailable: service.updateAvailable,
            gatewayHealthy: service.installed ? service.inferenceGateway.healthy : nil
        )
    }

    private static func updateSnapshot(
        _ status: GeneratedAPI.SoftwareUpdateStatus
    ) -> ModelSoftwareUpdateSnapshot {
        ModelSoftwareUpdateSnapshot(
            checkedAt: status.checkedAt,
            systemPackagesAvailable: status.systemPackagesAvailable,
            firmwareUpdatesAvailable: status.firmwareUpdatesAvailable,
            runtimeReleaseID: status.runtimeReleaseId,
            rebootRequired: status.rebootRequired
        )
    }
}

import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers

public protocol SparkRuntimeReading: Sendable {
    func capabilities(route: URL) async throws -> SparkCapabilities
    func health(route: URL) async throws -> Health
    func status(route: URL) async throws -> SparkStatus
    func telemetry(route: URL) async throws -> TelemetrySnapshot
    /// Reads runtime-recorded history with a default implementation for older test doubles.
    func telemetryHistory(route: URL) async throws -> GeneratedAPI.TelemetryHistory
    func models(route: URL) async throws -> ModelCatalogue
    func activeInference(route: URL) async throws -> ActiveInference
    func openWebUIStatus(route: URL) async throws -> GeneratedAPI.OptionalServiceStatus
    func installOpenWebUI(
        route: URL,
        request: GeneratedAPI.InstallOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func updateOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func repairOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func removeOpenWebUI(
        route: URL,
        request: GeneratedAPI.RemoveOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func openWebUIAccess(
        route: URL,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.OptionalServiceAccess
    func catalogueStatus(route: URL) async throws -> GeneratedAPI.CatalogueStatus
    func previewCatalogueRefresh(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func refreshCatalogue(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func previewReenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func reenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        request: GeneratedAPI.ReenableModelProfileRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func previewInstallModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func installModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation
    func previewLoadModel(
        route: URL,
        request: GeneratedAPI.LoadModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func loadModel(
        route: URL,
        request: GeneratedAPI.LoadModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation
    func previewUnloadModel(
        route: URL,
        request: GeneratedAPI.StopModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func unloadModel(
        route: URL,
        request: GeneratedAPI.StopModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation
    func previewRemoveModel(
        route: URL,
        modelID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func removeModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.RemoveModelRequest,
        idempotencyKey: UUID,
        userPresence: String?
    ) async throws -> SparkAPI.Operation
    func workloads(route: URL) async throws -> GeneratedAPI.WorkloadInventory
    func previewWorkloadAdoption(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func adoptWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func previewWorkloadRelinquish(
        route: URL,
        workloadID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func relinquishWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadRelinquishRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RelinquishWorkloadResponse200
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation
    func operations(route: URL, limit: Int, cursor: String?) async throws -> OperationPage
    /// Mint a single-use invitation for another Apple device (§10.7, §15.3).
    func createPairingInvitation(
        route: URL,
        role: String,
        expiresInSeconds: Int,
        deviceNameHint: String?,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> PairingInvitation
    func createBoundPairingInvitation(
        route: URL,
        role: String,
        expiresInSeconds: Int,
        recipientDeviceID: UUID,
        recipientPublicKeyFingerprint: String,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> PairingInvitation
}

extension SparkRuntimeReading {
    public func capabilities(route: URL) async throws -> SparkCapabilities {
        throw PendingRuntimeError.unconfigured
    }

    public func telemetry(route: URL) async throws -> TelemetrySnapshot {
        throw PendingRuntimeError.unconfigured
    }

    public func openWebUIStatus(route: URL) async throws -> GeneratedAPI.OptionalServiceStatus {
        throw PendingRuntimeError.unconfigured
    }

    public func installOpenWebUI(
        route: URL,
        request: GeneratedAPI.InstallOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func updateOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func removeOpenWebUI(
        route: URL,
        request: GeneratedAPI.RemoveOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func repairOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func openWebUIAccess(
        route: URL,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.OptionalServiceAccess {
        throw PendingRuntimeError.unconfigured
    }

    public func catalogueStatus(route: URL) async throws -> GeneratedAPI.CatalogueStatus {
        throw PendingRuntimeError.unconfigured
    }

    public func workloads(route: URL) async throws -> GeneratedAPI.WorkloadInventory {
        throw PendingRuntimeError.unconfigured
    }

    public func previewWorkloadAdoption(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func adoptWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func previewWorkloadRelinquish(
        route: URL,
        workloadID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func relinquishWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadRelinquishRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RelinquishWorkloadResponse200 {
        throw PendingRuntimeError.unconfigured
    }

    public func previewCatalogueRefresh(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func refreshCatalogue(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func previewReenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func reenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        request: GeneratedAPI.ReenableModelProfileRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func previewInstallModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func installModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func loadModel(
        route: URL,
        request: GeneratedAPI.LoadModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func previewLoadModel(
        route: URL,
        request: GeneratedAPI.LoadModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func previewUnloadModel(
        route: URL,
        request: GeneratedAPI.StopModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func unloadModel(
        route: URL,
        request: GeneratedAPI.StopModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func previewRemoveModel(
        route: URL,
        modelID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw PendingRuntimeError.unconfigured
    }

    public func removeModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.RemoveModelRequest,
        idempotencyKey: UUID,
        userPresence: String?
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    public func operations(
        route: URL,
        limit: Int,
        cursor: String?
    ) async throws -> OperationPage {
        throw PendingRuntimeError.unconfigured
    }

    public func createPairingInvitation(
        route: URL,
        role: String,
        expiresInSeconds: Int,
        deviceNameHint: String?,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> PairingInvitation {
        throw PendingRuntimeError.unconfigured
    }

    public func createBoundPairingInvitation(
        route: URL,
        role: String,
        expiresInSeconds: Int,
        recipientDeviceID: UUID,
        recipientPublicKeyFingerprint: String,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> PairingInvitation {
        throw PendingRuntimeError.unconfigured
    }

}

/// Reports not recording when an older runtime lacks the history route.
extension SparkRuntimeReading {
    public func telemetryHistory(route: URL) async throws -> GeneratedAPI.TelemetryHistory {
        GeneratedAPI.TelemetryHistory(
            apiVersion: 1,
            nodeId: "",
            recording: false,
            retention: GeneratedAPI.TelemetryHistoryRetention(
                rawSeconds: 0,
                aggregateSeconds: 0,
                rawBucketSeconds: 10,
                aggregateBucketSeconds: 60
            ),
            rows: []
        )
    }
}

extension SparkAPIClient: SparkRuntimeReading {
    public func telemetryHistory(route: URL) async throws -> GeneratedAPI.TelemetryHistory {
        try await telemetryHistory(route: route, from: nil, to: nil, limit: nil)
    }
}

public enum SparkDashboardRefreshPolicy {
    /// Sample visible dashboard telemetry once per second.
    public static let liveTelemetryInterval: Duration = .seconds(1)
}

/// Fails closed for previews and compatibility initialisers; shipping composition supplies a pinned client.
public struct PendingSparkRuntimeReader: SparkRuntimeReading {
    public init() {}

    public func health(route: URL) async throws -> Health { throw PendingRuntimeError.unconfigured }
    public func status(route: URL) async throws -> SparkStatus {
        throw PendingRuntimeError.unconfigured
    }
    public func telemetry(route: URL) async throws -> TelemetrySnapshot {
        throw PendingRuntimeError.unconfigured
    }
    public func models(route: URL) async throws -> ModelCatalogue {
        throw PendingRuntimeError.unconfigured
    }
    public func activeInference(route: URL) async throws -> ActiveInference {
        throw PendingRuntimeError.unconfigured
    }
}

public enum PendingRuntimeError: Error, Sendable {
    case unconfigured
}

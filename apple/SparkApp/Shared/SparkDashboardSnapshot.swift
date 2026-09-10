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
@MainActor
@Observable
final class SparkDashboardSnapshot {
    var capabilities: SparkCapabilities?
    var capabilitiesChecked = false
    var workloadInventory: GeneratedAPI.WorkloadInventory?
    var workloadErrorMessage: String?
    var health: Health?
    var status: SparkStatus?
    var models: [SparkModel] = []
    var inference: ActiveInference?
    var isRefreshing = false
    var errorMessage: String?
    var identityIssue: SparkDashboardIdentityIssue?
    var freshness: SparkDashboardFreshness
    var cachedSnapshot: TargetOperationalSnapshot?
    let expectedIdentity: SparkDashboardIdentityExpectation?
    init(
        expectedIdentity: SparkDashboardIdentityExpectation?,
        cachedSnapshot: TargetOperationalSnapshot?
    ) {
        self.expectedIdentity = expectedIdentity
        self.cachedSnapshot = cachedSnapshot
        let cachedAt = cachedSnapshot?.lastSuccessfulContact ?? cachedSnapshot?.evaluatedAt
        self.freshness = cachedAt.map(SparkDashboardFreshness.cached) ?? .notLoaded
    }

    /// Validate identity-bearing responses before publishing any response from the refresh batch.
    func identityIssue(
        in health: Health,
        status: SparkStatus
    ) -> SparkDashboardIdentityIssue? {
        guard health.nodeID == status.identity.nodeID else {
            return .coordinatorMismatch
        }
        guard let expectedIdentity else { return nil }
        guard health.nodeID == expectedIdentity.coordinatorNodeID else {
            return .coordinatorMismatch
        }
        if let expectedAuthority = expectedIdentity.authorityFingerprint,
            status.identity.authorityFingerprint.lowercased() != expectedAuthority.lowercased()
        {
            return .authorityMismatch
        }
        guard status.identity.clusterID == expectedIdentity.clusterID else {
            return .clusterMismatch
        }
        if let reportedClusterID = status.cluster?.id,
            reportedClusterID != expectedIdentity.clusterID
        {
            return .clusterMismatch
        }
        return nil
    }

    var nodeName: String {
        status?.identity.name ?? cachedSnapshot?.displayName ?? String(localized: "Your Spark")
    }

    var runtimeStatus: String { runtimeStatusValue.text }

    var runtimeStatusValue: SparkStatusValue {
        if let health {
            return health.isOK
                ? SparkStatusValue(String(localized: "Healthy"))
                : SparkStatusValue(String(localized: "Needs attention"), tone: .attention)
        }
        switch cachedSnapshot?.runtime.health {
        case .healthy: return SparkStatusValue(String(localized: "Healthy"))
        case .degraded:
            return SparkStatusValue(String(localized: "Degraded"), tone: .attention)
        case .unavailable:
            return SparkStatusValue(String(localized: "Unavailable"), tone: .attention)
        case .unknown, nil: return SparkStatusValue(String(localized: "Checking"))
        }
    }

    var vllmStatus: String { vllmStatusValue.text }

    var vllmStatusValue: SparkStatusValue {
        guard capabilitiesChecked else { return SparkStatusValue(String(localized: "Checking")) }
        guard containerRuntimeAvailable else {
            return SparkStatusValue(String(localized: "Setup required"), tone: .attention)
        }
        if let inference {
            return SparkDashboardFailurePresentation.vllmStatus(for: inference.state)
        }
        switch cachedSnapshot?.vllmHealth {
        case .stopped: return SparkStatusValue(String(localized: "Ready · No model loaded"))
        case .starting: return SparkStatusValue(String(localized: "Starting"))
        case .ready: return SparkStatusValue(String(localized: "Healthy"))
        case .stopping: return SparkStatusValue(String(localized: "Stopping"))
        case .failed:
            return SparkStatusValue(String(localized: "Needs attention"), tone: .attention)
        case .unknown, nil: return SparkStatusValue(String(localized: "Checking"))
        }
    }

    var containerRuntimeAvailable: Bool {
        capabilities?.isEnabled("container_runtime") == true
    }

    var signedCatalogueAvailable: Bool {
        capabilities?.isEnabled("signed_catalogue") == true
    }

    var modelServiceDetail: String {
        guard capabilitiesChecked else { return String(localized: "Checking runtime capabilities") }
        guard containerRuntimeAvailable else {
            return String(localized: "Install a Spark Runtime with container support")
        }
        return SparkDashboardOwnerPresentation.activeModelDetail(
            activeModelID: activeModelID,
            models: models
        )
    }

    var modelCatalogueStatus: String { modelCatalogueStatusValue.text }

    var modelCatalogueStatusValue: SparkStatusValue {
        guard capabilitiesChecked else { return SparkStatusValue(String(localized: "Checking")) }
        guard signedCatalogueAvailable else {
            return SparkStatusValue(String(localized: "Unavailable"), tone: .attention)
        }
        return SparkStatusValue(String(localized: .modelsInstalledCount(installedModelCount)))
    }

    var modelCatalogueDetail: String {
        guard capabilitiesChecked else {
            return String(localized: "Checking signed catalogue support")
        }
        guard signedCatalogueAvailable else {
            return String(localized: "This runtime does not expose a verified model catalogue")
        }
        return String(localized: .modelsAvailableOnThisSpark(availableModelCount))
    }

    var installedModelCount: Int {
        guard !models.isEmpty else { return cachedSnapshot?.installedModelCount ?? 0 }
        return models.count(where: { $0.installState == .installed })
    }

    var availableModelCount: Int {
        models.isEmpty ? (cachedSnapshot?.placements.count ?? 0) : models.count
    }

    var runtimeVersion: String? {
        health?.runtimeVersion ?? cachedSnapshot?.runtime.version
    }

    var activeModelID: String? {
        inference?.modelID ?? cachedSnapshot?.activeInference?.modelIdentity?.modelID
    }

    var cachedPlacements: [ModelPlacementSnapshot] {
        models.isEmpty ? (cachedSnapshot?.placements ?? []) : []
    }

    var hasRenderableData: Bool {
        health != nil || status != nil || !models.isEmpty || inference != nil
            || cachedSnapshot != nil
    }

    var isShowingCachedData: Bool {
        if case .cached = freshness { return true }
        return false
    }

    var cachedAt: Date? {
        if case .cached(let refreshedAt) = freshness { return refreshedAt }
        return nil
    }

    /// Unified-memory summary for the health grid.
    var memorySummary: String? {
        let total: Int64
        let available: Int64
        if let system = status?.system {
            total = system.unifiedMemoryTotalBytes
            available = system.unifiedMemoryAvailableBytes
        } else if let memory = cachedSnapshot?.unifiedMemory {
            total = memory.totalBytes
            available = memory.availableBytes
        } else {
            return nil
        }
        let installed = SparkMemoryCapacity.installedBytes(reportedBytes: total)
        let used = max(0, total - available)
        return String(
            localized: .memoryUsedOfTotal(
                used: FleetFormat.gigabytes(used),
                total: FleetFormat.gigabytes(installed)
            )
        )
    }

}

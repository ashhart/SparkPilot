import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary

// MARK: - Read model

public enum ModelLibraryEvidenceFreshness: Sendable, Equatable {
    case current(observedAt: Date)
    case stale(observedAt: Date)
    case unavailable

    public var observedAt: Date? {
        switch self {
        case .current(let observedAt), .stale(let observedAt): observedAt
        case .unavailable: nil
        }
    }

    public var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}

public struct ModelLibraryTargetTopology: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case standalone
        case cluster
    }

    public let kind: Kind
    public let memberCount: Int
    public let reachableMemberCount: Int
    public let state: String?

    public init(
        kind: Kind,
        memberCount: Int = 1,
        reachableMemberCount: Int = 1,
        state: String? = nil
    ) {
        self.kind = kind
        self.memberCount = memberCount
        self.reachableMemberCount = reachableMemberCount
        self.state = state
    }

    public static let standalone = ModelLibraryTargetTopology(kind: .standalone)

    public var isCompleteCluster: Bool {
        kind == .cluster && memberCount > 1 && reachableMemberCount == memberCount
            && state?.lowercased() == "ready"
    }

    public var label: String {
        switch kind {
        case .standalone:
            return String(localized: "Single Spark")
        case .cluster where isCompleteCluster:
            return String(localized: .completeSparkCluster(memberCount))
        case .cluster:
            return String(
                localized: .clusterMembersReady(reachable: reachableMemberCount, total: memberCount)
            )
        }
    }
}

public struct ModelLibraryProfileEvidence: Sendable, Equatable {
    public let id: String
    public let name: String
    public let expectedPeakBytes: Int64
    public let isSafe: Bool
    public let maxModelLength: Int?
    public let maxSequences: Int?

    public init(
        id: String,
        name: String,
        expectedPeakBytes: Int64,
        isSafe: Bool,
        maxModelLength: Int? = nil,
        maxSequences: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.expectedPeakBytes = expectedPeakBytes
        self.isSafe = isSafe
        self.maxModelLength = maxModelLength
        self.maxSequences = maxSequences
    }
}

public struct ModelLibraryRecipeEvidence: Sendable, Equatable {
    public let modelID: String
    public let displayName: String
    public let summary: String?
    public let recipeRevision: String?
    public let sourceRevision: String?
    public let installState: SparkModelInstallState?
    public let downloadBytes: Int64?
    public let capabilities: Set<String>
    public let rawFit: String?
    public let profiles: [ModelLibraryProfileEvidence]
    public let operationalState: ModelPlacementState?

    public init(
        modelID: String,
        displayName: String,
        summary: String? = nil,
        recipeRevision: String? = nil,
        sourceRevision: String? = nil,
        installState: SparkModelInstallState?,
        downloadBytes: Int64? = nil,
        capabilities: Set<String> = [],
        rawFit: String? = nil,
        profiles: [ModelLibraryProfileEvidence] = [],
        operationalState: ModelPlacementState? = nil
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.summary = summary
        self.recipeRevision = recipeRevision
        self.sourceRevision = sourceRevision
        self.installState = installState
        self.downloadBytes = downloadBytes
        self.capabilities = capabilities
        self.rawFit = rawFit
        self.profiles = profiles
        self.operationalState = operationalState
    }
}

public struct ModelLibraryTargetEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let connectionLabel: String
    public let topology: ModelLibraryTargetTopology
    public let freshness: ModelLibraryEvidenceFreshness
    public let availableMemoryBytes: Int64?
    public let runtimeVersion: String?
    public let activeModelID: String?
    public let activeModelIdentity: ModelPlacementIdentity?
    public let activeInferenceState: SparkInferenceState?
    public let recipes: [ModelLibraryRecipeEvidence]
    public let services: ModelServiceTargetSnapshot?

    public init(
        id: String,
        name: String,
        connectionLabel: String,
        topology: ModelLibraryTargetTopology,
        freshness: ModelLibraryEvidenceFreshness,
        availableMemoryBytes: Int64? = nil,
        runtimeVersion: String? = nil,
        activeModelID: String? = nil,
        activeModelIdentity: ModelPlacementIdentity? = nil,
        activeInferenceState: SparkInferenceState? = nil,
        recipes: [ModelLibraryRecipeEvidence] = [],
        services: ModelServiceTargetSnapshot? = nil
    ) {
        self.id = id
        self.name = name
        self.connectionLabel = connectionLabel
        self.topology = topology
        self.freshness = freshness
        self.availableMemoryBytes = availableMemoryBytes
        self.runtimeVersion = runtimeVersion
        self.activeModelID = activeModelID
        self.activeModelIdentity = activeModelIdentity
        self.activeInferenceState = activeInferenceState
        self.recipes = recipes
        self.services = services
    }

    static func unavailable(for entry: LibraryEntry) -> ModelLibraryTargetEvidence {
        ModelLibraryTargetEvidence(
            id: entry.id,
            name: entry.displayName,
            connectionLabel: connectionLabel(for: entry.connectionState),
            topology: ModelLibraryTargetTopology(
                kind: entry.kind == .cluster ? .cluster : .standalone,
                memberCount: max(entry.members.count, 1),
                reachableMemberCount: entry.reachableMemberCount,
                state: nil
            ),
            freshness: .unavailable
        )
    }

    func isActive(_ recipe: ModelLibraryRecipeEvidence) -> Bool {
        if let activeModelIdentity, let recipeRevision = recipe.recipeRevision {
            return activeModelIdentity
                == ModelPlacementIdentity(
                    modelID: recipe.modelID,
                    recipeRevision: recipeRevision
                )
        }
        return activeModelID == recipe.modelID
    }

    static func connectionLabel(for state: SparkConnectionState) -> String {
        switch state {
        case .connectedDirect: String(localized: "Direct connection")
        case .connectedWiFi: String(localized: "Local Wi-Fi")
        case .connectedRemote: String(localized: "Remote")
        case .connecting: String(localized: "Connecting")
        case .discovering: String(localized: "Looking for Spark")
        case .foundUnpaired: String(localized: "Not paired")
        case .offlineCached: String(localized: "Offline")
        case .identityMismatch: String(localized: "Identity changed")
        case .updateRequired: String(localized: "Update required")
        }
    }

    static func connectionLabel(for state: TargetConnectionState) -> String {
        switch state {
        case .connectedDirect: String(localized: "Direct connection")
        case .connectedWiFi: String(localized: "Local Wi-Fi")
        case .connectedRemote: String(localized: "Remote")
        case .connecting: String(localized: "Connecting")
        case .discovering: String(localized: "Looking for Spark")
        case .foundUnpaired: String(localized: "Not paired")
        case .delayed: String(localized: "Delayed")
        case .offlineCached: String(localized: "Offline")
        case .identityMismatch: String(localized: "Identity changed")
        case .updateRequired: String(localized: "Update required")
        }
    }
}

public enum ModelTargetFit: String, CaseIterable, Sendable, Equatable {
    case fitsNow
    case fitsAfterStop
    case smallerProfile
    case clusterRequired
    case incompatible
    case evidenceUnavailable

    public var label: String {
        switch self {
        case .fitsNow: String(localized: "Fits now")
        case .fitsAfterStop: String(localized: "Fits after stop")
        case .smallerProfile: String(localized: "Smaller profile")
        case .clusterRequired: String(localized: "Cluster required")
        case .incompatible: String(localized: "Incompatible")
        case .evidenceUnavailable: String(localized: "Evidence unavailable")
        }
    }

    public var isEligible: Bool {
        self == .fitsNow || self == .fitsAfterStop
    }

    /// Map the runtime's fit token onto the localised vocabulary, never rendering the token itself.
    public static func label(forWireValue value: String) -> String? {
        switch value {
        case "ready", "fits", "fits_now": ModelTargetFit.fitsNow.label
        case "fits_after_unload", "fits_after_stop": ModelTargetFit.fitsAfterStop.label
        case "smaller_profile_required": ModelTargetFit.smallerProfile.label
        case "cluster_required": ModelTargetFit.clusterRequired.label
        case "incompatible": ModelTargetFit.incompatible.label
        case "unknown", "": ModelTargetFit.evidenceUnavailable.label
        default: nil
        }
    }

    public static func resolve(
        rawValue: String?,
        installState: SparkModelInstallState?,
        freshness: ModelLibraryEvidenceFreshness,
        topology: ModelLibraryTargetTopology
    ) -> ModelTargetFit {
        guard freshness.isCurrent else { return .evidenceUnavailable }
        if installState == .incompatible || installState == .unverified {
            return .incompatible
        }
        if topology.kind == .cluster, !topology.isCompleteCluster {
            return .clusterRequired
        }
        return switch rawValue {
        case "ready", "fits": .fitsNow
        case "fits_after_unload": .fitsAfterStop
        case "smaller_profile_required": .smallerProfile
        case "cluster_required": .clusterRequired
        case "incompatible": .incompatible
        case "unknown", .none: .evidenceUnavailable
        default: .evidenceUnavailable
        }
    }
}

public enum ModelLibraryPlacementState: String, Sendable, Equatable {
    case running
    case installed
    case downloading
    case verifying
    case available
    case failed
    case incompatible
    case unverified
    case notPresent
    case unknown

    public var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .installed: String(localized: "Installed")
        case .downloading: String(localized: "Downloading")
        case .verifying: String(localized: "Verifying")
        case .available: String(localized: "Not installed")
        case .failed: String(localized: "Install failed")
        case .incompatible: String(localized: "Not compatible")
        case .unverified: String(localized: "Not verified")
        case .notPresent: String(localized: "Not in catalogue")
        case .unknown: String(localized: "State unavailable")
        }
    }
}

/// Routes library actions through the target dashboard's signed preview and confirmation, or opens recovery for unfinished work.
public enum ModelLibraryManagementAction: String, Sendable, Equatable {
    case install
    case load
    case unload
    case review

    public static func resolve(
        state: ModelLibraryPlacementState,
        fit: ModelTargetFit,
        freshness: ModelLibraryEvidenceFreshness
    ) -> ModelLibraryManagementAction? {
        guard freshness.isCurrent else { return nil }
        switch state {
        case .running:
            return .unload
        case .installed:
            return fit.isEligible ? .load : nil
        case .available:
            return fit.isEligible ? .install : nil
        case .downloading, .verifying, .failed:
            return .review
        case .unknown:
            return fit.isEligible ? .review : nil
        case .incompatible, .unverified, .notPresent:
            return nil
        }
    }

    public func label(targetName: String) -> String {
        switch self {
        case .install: String(localized: .downloadOnTarget(targetName))
        case .load: String(localized: .startOnTarget(targetName))
        case .unload: String(localized: .stopOnTarget(targetName))
        case .review: String(localized: .reviewOnTarget(targetName))
        }
    }
}

public struct ModelLibraryTargetPlacement: Sendable, Equatable, Identifiable {
    public let id: String
    public let targetName: String
    public let connectionLabel: String
    public let topology: ModelLibraryTargetTopology
    public let freshness: ModelLibraryEvidenceFreshness
    public let availableMemoryBytes: Int64?
    public let runtimeVersion: String?
    public let fit: ModelTargetFit
    public let state: ModelLibraryPlacementState
    public let explanation: String

    public var isInstalled: Bool { state == .installed || state == .running }
    public var isRunning: Bool { state == .running }
    public var isEligible: Bool { freshness.isCurrent && fit.isEligible }
    public var managementAction: ModelLibraryManagementAction? {
        ModelLibraryManagementAction.resolve(
            state: state,
            fit: fit,
            freshness: freshness
        )
    }

    public var accessibilitySummary: String {
        var parts = [targetName, topology.label, state.label, fit.label]
        switch freshness {
        case .current:
            parts.append(String(localized: "Current evidence"))
        case .stale:
            parts.append(String(localized: "Stale evidence"))
        case .unavailable:
            parts.append(String(localized: "Evidence unavailable"))
        }
        parts.append(explanation)
        return parts.joined(separator: ", ")
    }
}

public enum ModelLibraryRecipeVerification: Sendable, Equatable {
    case verified
    case unverified
    case unavailable

    public var label: String {
        switch self {
        case .verified: String(localized: "Signed recipe verified")
        case .unverified: String(localized: "Recipe not verified")
        case .unavailable: String(localized: "Verification unavailable")
        }
    }
}

public struct ModelLibraryCoverage: Sendable, Equatable {
    public let runningTargets: [String]
    public let installedTargets: [String]
    public let cachedRunningTargets: [String]
    public let cachedInstalledTargets: [String]

    public init(
        runningTargets: [String],
        installedTargets: [String],
        cachedRunningTargets: [String] = [],
        cachedInstalledTargets: [String] = []
    ) {
        self.runningTargets = runningTargets
        self.installedTargets = installedTargets
        self.cachedRunningTargets = cachedRunningTargets
        self.cachedInstalledTargets = cachedInstalledTargets
    }

    public var label: String {
        if runningTargets.isEmpty, installedTargets.isEmpty,
            cachedRunningTargets.isEmpty, cachedInstalledTargets.isEmpty
        {
            return String(localized: "Not installed on any target")
        }
        var parts: [String] = []
        if !runningTargets.isEmpty {
            parts.append(
                String(localized: .runningOnTargets(runningTargets.formatted(.list(type: .and))))
            )
        }
        let installedOnly = installedTargets.filter { !runningTargets.contains($0) }
        if !installedOnly.isEmpty {
            parts.append(
                String(localized: .installedOnTargets(installedOnly.formatted(.list(type: .and))))
            )
        }
        if !cachedRunningTargets.isEmpty {
            parts.append(
                String(
                    localized: .lastKnownRunningOn(
                        cachedRunningTargets.formatted(.list(type: .and))
                    )
                )
            )
        }
        let cachedInstalledOnly = cachedInstalledTargets.filter {
            !cachedRunningTargets.contains($0)
        }
        if !cachedInstalledOnly.isEmpty {
            parts.append(
                String(
                    localized: .lastKnownInstalledOn(
                        cachedInstalledOnly.formatted(.list(type: .and))
                    )
                )
            )
        }
        return parts.joined(separator: ". ")
    }
}

public struct ModelLibraryRecommendation: Sendable, Equatable {
    public let targetID: String
    public let targetName: String
    public let fit: ModelTargetFit
    public let evidenceAt: Date
    public let explanation: String
}

public struct ModelLibraryTechnicalDetails: Sendable, Equatable {
    public let modelID: String
    public let recipeRevision: String?
    public let sourceRevision: String?
}

public struct CrossTargetModelLibraryItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let summary: String?
    public let versionLabel: String
    public let taskLabel: String
    public let capabilityLabels: [String]
    public let downloadBytes: Int64?
    public let verification: ModelLibraryRecipeVerification
    public let topologyLabel: String
    public let coverage: ModelLibraryCoverage
    public let placements: [ModelLibraryTargetPlacement]
    public let recommendation: ModelLibraryRecommendation?
    public let technicalDetails: ModelLibraryTechnicalDetails
    public let profiles: [ModelLibraryProfileEvidence]

    public var eligibleAlternatives: [ModelLibraryTargetPlacement] {
        placements.filter { placement in
            placement.isEligible && placement.id != recommendation?.targetID
        }
    }

    public var otherTargets: [ModelLibraryTargetPlacement] {
        placements.filter { placement in
            !placement.isEligible && placement.id != recommendation?.targetID
        }
    }

    public var accessibilitySummary: String {
        [
            displayName,
            String(localized: .versionLabelled(versionLabel)),
            String(localized: .taskLabelled(taskLabel)),
            verification.label,
            topologyLabel,
            coverage.label,
        ].joined(separator: ", ")
    }
}

public struct CrossTargetModelLibrarySnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let targets: [ModelLibraryTargetEvidence]
    public let models: [CrossTargetModelLibraryItem]

    public init(
        generatedAt: Date,
        targets: [ModelLibraryTargetEvidence],
        models: [CrossTargetModelLibraryItem]
    ) {
        self.generatedAt = generatedAt
        self.targets = targets
        self.models = models
    }

    public static let empty = CrossTargetModelLibrarySnapshot(
        generatedAt: .distantPast,
        targets: [],
        models: []
    )
}

public enum ModelLibraryVisibilityPolicy: Sendable, Equatable {
    /// Exclude unverifiable or universally incompatible recipes from the actionable owner catalogue.
    case standard
    /// Keep role-gated inspection of unverified recipes read-only.
    case technicalInspection
}

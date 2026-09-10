import Foundation
import SparkCore
import Testing
@testable import SparkIntelligence

private let node = SparkNodeID(rawValue: UUID())
private let cluster = SparkClusterID(rawValue: UUID())

private var catalog: SparkCatalogSnapshot {
    SparkCatalogSnapshot(
        largeContextModelIDs: ["llama-70b"],
        generalModelIDs: ["llama-8b"],
        clusterModelID: "llama-405b"
    )
}

/// Apply on-device, Spark and cluster defaults according to task capacity (§39.2).
@Test func defaultRoutingTable() throws {
    let router = ModelRouter(preferredNodeID: node)

    let quick = try router.select(
        task: .shortRewrite,
        context: IntelligenceContext(),
        catalog: catalog
    )
    #expect(quick.target == .appleSystem)
    #expect(quick.modelID == nil)

    let big = try router.select(
        task: .analyseLargeDocument,
        context: IntelligenceContext(approximateInputBytes: 5_000_000),
        catalog: catalog
    )
    #expect(big.target == .spark(nodeID: node, modelID: ""))
    #expect(big.modelID == "llama-70b", "capacity tasks prefer large-context models")

    let huge = try router.select(
        task: .hugeModelReasoning,
        context: IntelligenceContext(preferredClusterID: cluster),
        catalog: catalog
    )
    #expect(huge.target == .sparkCluster(clusterID: cluster, modelID: "llama-405b"))

    // Small text with a big payload outgrows the system model.
    let grown = try router.select(
        task: .summariseSmallText,
        context: IntelligenceContext(approximateInputBytes: 900_000),
        catalog: catalog
    )
    #expect(grown.target == .spark(nodeID: node, modelID: ""))
}

/// User constraints bind: on-device only, Sparks only.
@Test func policyConstraintsAreEnforced() throws {
    let onDevice = ModelRouter(
        policy: RoutingPolicy(constraint: RoutingPolicy.Constraint.onDeviceOnly),
        preferredNodeID: node
    )
    #expect(throws: RoutingError.self) {
        _ = try onDevice.select(
            task: .codingAgent,
            context: IntelligenceContext(),
            catalog: catalog
        )
    }
    let ok = try onDevice.select(
        task: .classify,
        context: IntelligenceContext(),
        catalog: catalog
    )
    #expect(ok.target == .appleSystem)

    let sparkOnly = ModelRouter(
        policy: RoutingPolicy(constraint: .sparkOnly),
        preferredNodeID: node
    )
    let routed = try sparkOnly.select(
        task: .classify,
        context: IntelligenceContext(),
        catalog: catalog
    )
    #expect(routed.target == .spark(nodeID: node, modelID: ""))

    // A Sparks-only policy without a known Spark must fail routing.
    let noSpark = ModelRouter(policy: RoutingPolicy(constraint: .sparkOnly))
    #expect(throws: RoutingError.self) {
        _ = try noSpark.select(
            task: .classify,
            context: IntelligenceContext(),
            catalog: catalog
        )
    }
}

/// `askBeforeRemoteExecution` never blocks; it requires consent.
@Test func remoteConsentFlagIsCarriedNotEnforced() throws {
    let router = ModelRouter(
        policy: RoutingPolicy(askBeforeRemoteExecution: true),
        preferredNodeID: node
    )
    let local = try router.select(
        task: .classify,
        context: IntelligenceContext(),
        catalog: catalog
    )
    #expect(!local.requiresConsent)

    let remote = try router.select(
        task: .codeReview,
        context: IntelligenceContext(),
        catalog: catalog
    )
    #expect(remote.requiresConsent)
}

/// Keep session availability consistent with the platform adapter limitation recorded in ADR-018.
@Test func serviceResolvesAndGatesSessions() async throws {
    let service = IntelligenceService(
        router: ModelRouter(preferredNodeID: node),
        sessionFactory: UnavailableLanguageSessionFactory(),
        catalogProvider: { catalog }
    )

    let selection = try await service.resolve(
        task: .codeReview,
        context: IntelligenceContext()
    )
    #expect(selection.target == .spark(nodeID: node, modelID: ""))
    #expect(!selection.requiresConsent)

    await #expect(throws: IntelligenceError.self) {
        _ = try await service.session(for: .codeReview, context: IntelligenceContext())
    }

    // Consent-gated selections never silently start a session.
    let asking = IntelligenceService(
        router: ModelRouter(
            policy: RoutingPolicy(askBeforeRemoteExecution: true),
            preferredNodeID: node
        ),
        sessionFactory: UnavailableLanguageSessionFactory(),
        catalogProvider: { catalog }
    )
    await #expect(throws: IntelligenceError.self) {
        _ = try await asking.session(for: .codeReview, context: IntelligenceContext())
    }
}

// MARK: - Routing policy and explanation coverage

private let auditNode = SparkNodeID(rawValue: UUID())
private let auditCluster = SparkClusterID(rawValue: UUID())

@Test func aRefusedRouteSaysWhichConstraintRefusedIt() throws {
    // Explain which privacy or availability constraint blocked routing and how the owner can resolve it (§39.11).
    let router = ModelRouter(
        policy: RoutingPolicy(constraint: RoutingPolicy.Constraint.onDeviceOnly),
        preferredNodeID: auditNode
    )
    let failure = #expect(throws: RoutingError.self) {
        _ = try router.select(
            task: .codingAgent,
            context: IntelligenceContext(),
            catalog: SparkCatalogSnapshot(generalModelIDs: ["llama-70b"])
        )
    }
    let routing = try #require(failure)
    #expect(
        routing.constraint == RoutingPolicy.Constraint.onDeviceOnly,
        "the excluding constraint is part of the error"
    )
    let description = try #require((routing as? any LocalizedError)?.errorDescription)
    #expect(!description.isEmpty, "and there is something a UI can show the owner")
}

@Test func aSuccessfulRouteExplainsWhyItChoseThatTarget() throws {
    // Explain why successful routing chose its actual execution target (§39.11).
    let router = ModelRouter(policy: .permissive, preferredNodeID: auditNode)
    let selection = try router.select(
        task: .analyseLargeDocument,
        context: IntelligenceContext(),
        catalog: SparkCatalogSnapshot(largeContextModelIDs: ["llama-70b"])
    )
    #expect(selection.explanation.reason == .needsSparkMemoryAndContext)
    #expect(selection.explanation.location == .spark(modelID: "llama-70b"))
}

@Test func aClusterTaskWithNoClusterIsRefusedNotQuietlyDowngraded() throws {
    // Refuse distributed-capacity requests when no cluster is available.
    let router = ModelRouter(policy: .permissive, preferredNodeID: auditNode)
    #expect(throws: RoutingError.self) {
        _ = try router.select(
            task: .hugeModelReasoning,
            context: IntelligenceContext(),
            catalog: SparkCatalogSnapshot(generalModelIDs: ["llama-70b"])
        )
    }

    // Allow the task when a cluster exists so missing-cluster refusal does not become a blanket rejection.
    let selection = try router.select(
        task: .hugeModelReasoning,
        context: IntelligenceContext(preferredClusterID: auditCluster),
        catalog: SparkCatalogSnapshot(clusterModelID: "llama-405b")
    )
    #expect(selection.target == .sparkCluster(clusterID: auditCluster, modelID: "llama-405b"))
}

@Test func aRouteWithNoModelToRunIsRefused() throws {
    // Reject selection when no installed model can execute the task.
    let router = ModelRouter(policy: .permissive, preferredNodeID: auditNode)
    #expect(throws: RoutingError.self) {
        _ = try router.select(
            task: .analyseLargeDocument,
            context: IntelligenceContext(),
            catalog: SparkCatalogSnapshot()
        )
    }
}

@Test func myHardwareOnlyIsEnforcedRatherThanSharedWithTheDefault() throws {
    // Apply an explicit ownership filter so future hosted targets cannot inherit hardware-only permission.
    let router = ModelRouter(
        policy: RoutingPolicy(constraint: RoutingPolicy.Constraint.myHardwareOnly),
        preferredNodeID: auditNode
    )
    let selection = try router.select(
        task: .analyseLargeDocument,
        context: IntelligenceContext(),
        catalog: SparkCatalogSnapshot(largeContextModelIDs: ["llama-70b"])
    )
    #expect(selection.target.isOwnerHardware, "a Spark the owner runs is their hardware")
    #expect(ExecutionTarget.appleSystem.isOwnerHardware)
}

@Test func theExplanationDoesNotClaimDataStayedOnDeviceWhenItDidNot() throws {
    // Describe image transfer truthfully when Spark-only routing cannot perform a separate on-device Vision stage.
    let router = ModelRouter(
        policy: RoutingPolicy(constraint: RoutingPolicy.Constraint.sparkOnly),
        preferredNodeID: auditNode
    )
    let selection = try router.select(
        task: .visionAnalysis,
        context: IntelligenceContext(approximateInputBytes: 12_000_000),
        catalog: SparkCatalogSnapshot(generalModelIDs: ["llava"])
    )
    #expect(selection.target != .appleSystem)
    #expect(selection.explanation.reason == .policySendsTheWholeImage)

    // Report when execution selects the on-device model.
    let onDevice = ModelRouter(policy: .permissive, preferredNodeID: auditNode)
    let local = try onDevice.select(
        task: .visionAnalysis,
        context: IntelligenceContext(approximateInputBytes: 12_000_000),
        catalog: SparkCatalogSnapshot(generalModelIDs: ["llava"])
    )
    #expect(local.target == .appleSystem)
    #expect(local.explanation.reason == .imagesStayOnThisDevice)
}

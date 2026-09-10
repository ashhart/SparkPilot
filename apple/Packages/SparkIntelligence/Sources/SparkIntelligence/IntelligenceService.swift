import Foundation
import SparkCore

/// Keep provider-capable Foundation Models sessions behind the ADR-018 adapter while supporting resolved direct-streaming selections.
public protocol LanguageSessionFactory: Sendable {
    func makeSession(
        selection: RoutingSelection,
        instructions: String?
    ) async throws -> any Sendable

    /// `true` once a Foundation-Models-capable toolchain is active.
    var supportsFoundationModelsSessions: Bool { get }
}

/// Session creation is unavailable on the installed SDK (ADR-018).
public struct UnavailableLanguageSessionFactory: LanguageSessionFactory {
    public init() {}

    public var supportsFoundationModelsSessions: Bool { false }

    public func makeSession(
        selection: RoutingSelection,
        instructions: String?
    ) async throws -> any Sendable {
        throw IntelligenceError.foundationModelsUnavailable(
            reason: String(
                localized:
                    "The installed Xcode SDK does not ship the custom model-provider API."
            )
        )
    }
}

public enum IntelligenceError: Error, Sendable, Equatable {
    case foundationModelsUnavailable(reason: String)
    case consentRequired(target: String)
}

/// Resolve routing, privacy and consent before selecting a supported session or direct-streaming target (§39.11).
public actor IntelligenceService {
    private let router: ModelRouter
    private let sessionFactory: any LanguageSessionFactory
    private let catalogProvider: @Sendable () async -> SparkCatalogSnapshot

    public init(
        router: ModelRouter,
        sessionFactory: any LanguageSessionFactory = UnavailableLanguageSessionFactory(),
        catalogProvider: @escaping @Sendable () async -> SparkCatalogSnapshot = {
            SparkCatalogSnapshot()
        }
    ) {
        self.router = router
        self.sessionFactory = sessionFactory
        self.catalogProvider = catalogProvider
    }

    /// The routing decision without any session side effects.
    public func resolve(
        task: AITask,
        context: IntelligenceContext
    ) async throws -> RoutingSelection {
        try router.select(task: task, context: context, catalog: await catalogProvider())
    }

    /// Let the concrete Foundation Models adapter own session isolation while callers present required consent.
    public func session(
        for task: AITask,
        context: IntelligenceContext
    ) async throws -> any Sendable {
        let selection = try await resolve(task: task, context: context)
        guard !selection.requiresConsent else {
            throw IntelligenceError.consentRequired(target: describe(selection.target))
        }
        return try await sessionFactory.makeSession(
            selection: selection,
            instructions: context.instructions
        )
    }

    private func describe(_ target: ExecutionTarget) -> String {
        switch target {
        case .appleSystem: String(localized: "the Apple system model")
        case .spark: String(localized: "your Spark")
        case .sparkCluster: String(localized: "your Spark cluster")
        }
    }
}

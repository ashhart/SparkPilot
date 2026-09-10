import AppIntents
import Foundation

/// A standalone Spark or logical cluster with a stable local-library identity.
public struct SparkTargetEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spark Target"
    public static let defaultQuery = SparkTargetQuery()

    public let id: String
    public let displayName: String
    public let kind: IntentTargetKind
    public let allowedActions: Set<IntentTargetAction>

    public init(
        id: String,
        displayName: String,
        kind: IntentTargetKind = .node,
        allowedActions: Set<IntentTargetAction> = [.readStatus]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.allowedActions = allowedActions
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: kind == .cluster ? .sparkClusterSubtitle : .dgxSparkSubtitle
        )
    }
}

public struct SparkTargetQuery: EntityStringQuery {
    public init() {}

    public func entities(
        for identifiers: [String]
    ) async throws -> [SparkTargetEntity] {
        let known = try await IntentServices.shared.knownTargets()
        return identifiers.compactMap { identifier in
            known.first(where: { $0.id == identifier })
                .map(Self.entity)
        }
    }

    /// Resolve the words a person actually said: Siri hands over a transcript, not an identifier.
    public func entities(matching string: String) async throws -> [SparkTargetEntity] {
        let spoken = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return [] }
        return try await IntentServices.shared.knownTargets()
            .filter { $0.displayName.localizedStandardContains(spoken) }
            .map(Self.entity)
    }

    public func suggestedEntities() async throws -> [SparkTargetEntity] {
        try await IntentServices.shared.knownTargets().map(Self.entity)
    }

    private static func entity(_ snapshot: IntentTargetSnapshot) -> SparkTargetEntity {
        SparkTargetEntity(
            id: snapshot.id,
            displayName: snapshot.displayName,
            kind: snapshot.kind,
            allowedActions: snapshot.allowedActions
        )
    }
}

public typealias SparkNodeEntity = SparkTargetEntity
public typealias SparkNodeQuery = SparkTargetQuery

/// A Spark-hosted model entity (§40.6).
public struct SparkModelEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spark Model"
    public static let defaultQuery = SparkModelQuery()

    public let id: String
    public let modelID: String
    public let targetID: String
    public let displayName: String
    public let installed: Bool
    public let canLoad: Bool

    public init(
        id: String,
        modelID: String,
        targetID: String,
        displayName: String,
        installed: Bool,
        canLoad: Bool = true
    ) {
        self.id = id
        self.modelID = modelID
        self.targetID = targetID
        self.displayName = displayName
        self.installed = installed
        self.canLoad = canLoad
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

public struct SparkModelQuery: EntityStringQuery {
    public init() {}

    public func entities(
        for identifiers: [String]
    ) async throws -> [SparkModelEntity] {
        let known = try await IntentServices.shared.knownModels()
        return identifiers.compactMap { identifier in
            known.first(where: { $0.id == identifier }).map(Self.entity)
        }
    }

    /// The model name a person says carries its Spark's name too, so one match covers both.
    public func entities(matching string: String) async throws -> [SparkModelEntity] {
        let spoken = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return [] }
        return try await IntentServices.shared.knownModels()
            .filter { $0.displayName.localizedStandardContains(spoken) }
            .map(Self.entity)
    }

    public func suggestedEntities() async throws -> [SparkModelEntity] {
        try await IntentServices.shared.knownModels().map(Self.entity)
    }

    private static func entity(_ snapshot: IntentModelSnapshot) -> SparkModelEntity {
        SparkModelEntity(
            id: snapshot.id,
            modelID: snapshot.modelID,
            targetID: snapshot.targetID,
            displayName: snapshot.displayName,
            installed: snapshot.installed,
            canLoad: snapshot.canLoad
        )
    }
}

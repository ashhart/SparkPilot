import Foundation

/// Preserves mutation semantics and preview digest across idempotent retries, with legacy records requiring fresh review.
public struct ModelOperationRetryRequest: Codable, Equatable, Sendable {
    public var recipeRevision: String?
    public var providerCredentialID: String?
    public var profileID: String?
    public var replaceActive: Bool?
    public var targetNodeID: String?
    public var targetClusterID: String?
    public var force: Bool?
    public var acceptedPreviewDigest: String?

    public init(
        recipeRevision: String? = nil,
        providerCredentialID: String? = nil,
        profileID: String? = nil,
        replaceActive: Bool? = nil,
        targetNodeID: String? = nil,
        targetClusterID: String? = nil,
        force: Bool? = nil,
        acceptedPreviewDigest: String? = nil
    ) {
        self.recipeRevision = recipeRevision
        self.providerCredentialID = providerCredentialID
        self.profileID = profileID
        self.replaceActive = replaceActive
        self.targetNodeID = targetNodeID
        self.targetClusterID = targetClusterID
        self.force = force
        self.acceptedPreviewDigest = acceptedPreviewDigest
    }
}

/// Persist only the credential-free link between a local model action and its durable runtime operation.
public struct ModelOperationRecoveryRecord: Codable, Equatable, Sendable {
    public let targetID: String
    public let modelID: String
    public let action: ModelLifecycleAction
    public let idempotencyKey: UUID
    public var operationID: UUID?
    public let createdAt: Date
    public let retryRequest: ModelOperationRetryRequest?

    public init(
        targetID: String,
        modelID: String,
        action: ModelLifecycleAction,
        idempotencyKey: UUID,
        operationID: UUID? = nil,
        createdAt: Date = Date(),
        retryRequest: ModelOperationRetryRequest? = nil
    ) {
        self.targetID = targetID
        self.modelID = modelID
        self.action = action
        self.idempotencyKey = idempotencyKey
        self.operationID = operationID
        self.createdAt = createdAt
        self.retryRequest = retryRequest
    }

    var storageKey: String {
        "\(targetID)\u{1f}\(modelID)\u{1f}\(action.rawValue)"
    }
}

@MainActor
public protocol ModelOperationRecoveryStoring {
    func records(for targetID: String) throws -> [ModelOperationRecoveryRecord]
    func save(_ record: ModelOperationRecoveryRecord) throws
    func remove(_ record: ModelOperationRecoveryRecord) throws
}

/// Persists unfinished model actions in device-local defaults without iCloud synchronisation.
@MainActor
public final class UserDefaultsModelOperationRecoveryStore: ModelOperationRecoveryStoring {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "spark.model-operation-recovery.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func records(for targetID: String) throws -> [ModelOperationRecoveryRecord] {
        try allRecords().filter { $0.targetID == targetID }
    }

    public func save(_ record: ModelOperationRecoveryRecord) throws {
        var records = try allRecords()
        records.removeAll { $0.storageKey == record.storageKey }
        records.append(record)
        defaults.set(try encoder.encode(records), forKey: key)
    }

    public func remove(_ record: ModelOperationRecoveryRecord) throws {
        var records = try allRecords()
        records.removeAll { $0.storageKey == record.storageKey }
        defaults.set(try encoder.encode(records), forKey: key)
    }

    private func allRecords() throws -> [ModelOperationRecoveryRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try decoder.decode([ModelOperationRecoveryRecord].self, from: data)
    }
}

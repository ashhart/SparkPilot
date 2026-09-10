import Foundation

public struct WarmupRequest: Codable, Equatable, Sendable {
    public var modelID: String
    public var profileID: String
    public var dueAt: Int64
    public var acceptedPreviewDigest: String?

    public init(
        modelID: String,
        profileID: String,
        dueAt: Int64,
        acceptedPreviewDigest: String? = nil
    ) {
        self.modelID = modelID
        self.profileID = profileID
        self.dueAt = dueAt
        self.acceptedPreviewDigest = acceptedPreviewDigest
    }
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case profileID = "profile_id"
        case dueAt = "due_at"
        case acceptedPreviewDigest = "accepted_preview_digest"
    }
}

public struct WarmupPreview: Decodable, Equatable, Sendable {
    public let review: GeneratedAPI.ModelActionPreview
    public let dueAt: Int64
    public let expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case review
        case dueAt = "due_at"
        case expiresAt = "expires_at"
    }
}

public struct WarmupSchedule: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let nodeID: UUID
    public let modelID: String
    public let profileID: String
    public let dueAt: Int64
    public let expiresAt: Int64
    public let state: String
    public let resultCode: String
    public let operationID: UUID?
    public let createdAt: Int64
    public let updatedAt: Int64
    public var canDisable: Bool { state == "pending" }
    public var dueDate: Date { Date(timeIntervalSince1970: TimeInterval(dueAt)) }
    enum CodingKeys: String, CodingKey {
        case id, state
        case nodeID = "node_id"
        case modelID = "model_id"
        case profileID = "profile_id"
        case dueAt = "due_at"
        case expiresAt = "expires_at"
        case resultCode = "result_code"
        case operationID = "operation_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct WarmupCollection: Decodable, Equatable, Sendable {
    public let items: [WarmupSchedule]
    public let maxPending: Int
    public let observedAt: Int64
    enum CodingKeys: String, CodingKey {
        case items
        case maxPending = "max_pending"
        case observedAt = "observed_at"
    }
}

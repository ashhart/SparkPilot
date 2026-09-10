import Foundation

/// Encode node identity as a UUID string and key application state by it rather than mutable addresses.
public struct SparkNodeID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid node id: \(string)"
                )
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

/// Stable unique identifier of a Spark cluster (`cluster_id` in the API).
public struct SparkClusterID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid cluster id: \(string)"
                )
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

/// Stable unique identifier of a durable server-side operation.
public struct SparkOperationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid operation id: \(string)"
                )
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

/// Stable unique identifier of a paired Apple device grant.
public struct SparkDeviceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid device id: \(string)"
                )
            )
        }
        self.rawValue = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

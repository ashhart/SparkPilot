import Foundation

public enum SparkWatchCommand: String, Codable, Sendable {
    case overview, status, ask, load, stop, poll, cancel
    public var changesModel: Bool { self == .load || self == .stop }
}

public struct SparkWatchMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public init(role: Role, text: String) {
        id = UUID()
        self.role = role
        self.text = text
    }
}

public struct SparkWatchRequest: Codable, Equatable, Sendable {
    public var version = 1
    public var id = UUID()
    public var createdAt = Date()
    public var command: SparkWatchCommand
    public var targetID: String?
    public var modelID: String?
    public var jobID: UUID?
    public var authenticatedAt: Date?
    public var messages: [SparkWatchMessage] = []

    public init(_ command: SparkWatchCommand, targetID: String? = nil) {
        self.command = command
        self.targetID = targetID
    }

    public func validate(now: Date) throws {
        guard version == 1, abs(now.timeIntervalSince(createdAt)) <= 120 else {
            throw SparkWatchFailure("This request expired. Refresh the watch and try again.")
        }
        guard (targetID?.utf8.count ?? 0) <= 512,
            (modelID?.utf8.count ?? 0) <= 512,
            messages.count <= 16,
            messages.reduce(0, { $0 + $1.text.utf8.count }) <= 16_384
        else { throw SparkWatchFailure("This conversation is too long. Start a new chat.") }
        if [.status, .ask, .load, .stop].contains(command), targetID?.isEmpty != false {
            throw SparkWatchFailure("Choose a Spark first.")
        }
        if command == .load, modelID?.isEmpty != false {
            throw SparkWatchFailure("Choose an installed model first.")
        }
        if command == .poll || command == .cancel, jobID == nil {
            throw SparkWatchFailure("The request could not be found.")
        }
        if command == .ask {
            guard !messages.isEmpty, messages.last?.role == .user,
                messages.enumerated().allSatisfy({ index, message in
                    message.role == (index.isMultiple(of: 2) ? .user : .assistant)
                        && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            else { throw SparkWatchFailure("Enter a message to send.") }
        }
        if command.changesModel {
            guard let authenticatedAt,
                (0...30).contains(now.timeIntervalSince(authenticatedAt))
            else { throw SparkWatchFailure("Confirm this model change again on your watch.") }
        }
    }
}

public struct SparkWatchTarget: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var canAsk: Bool
    public var canManageModels: Bool
    public init(id: String, name: String, canAsk: Bool, canManageModels: Bool) {
        self.id = id
        self.name = name
        self.canAsk = canAsk
        self.canManageModels = canManageModels
    }
}

public struct SparkWatchModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targetID: String
    public var name: String
    public init(id: String, targetID: String, name: String) {
        self.id = id
        self.targetID = targetID
        self.name = name
    }
}

public struct SparkWatchTelemetry: Codable, Equatable, Sendable {
    public var targetID: String
    public var observedAt: Date
    public var modelName: String?
    public var modelState: String
    public var memoryPercent: Double?
    public var cpuPercent: Double?
    public var gpuPercent: Double?
    public var temperatureCelsius: Double?
    public var powerWatts: Double?
    public var queuedRequests: Int

    public init(
        targetID: String,
        observedAt: Date,
        modelName: String?,
        modelState: String,
        memoryPercent: Double?,
        cpuPercent: Double?,
        gpuPercent: Double?,
        temperatureCelsius: Double?,
        powerWatts: Double?,
        queuedRequests: Int
    ) {
        self.targetID = targetID
        self.observedAt = observedAt
        self.modelName = modelName
        self.modelState = modelState
        self.memoryPercent = memoryPercent
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.temperatureCelsius = temperatureCelsius
        self.powerWatts = powerWatts
        self.queuedRequests = queuedRequests
    }
    public static func percent(fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction * 100
    }

    public func isStale(at date: Date) -> Bool {
        !(0...45).contains(date.timeIntervalSince(observedAt))
    }
}

public struct SparkWatchResponse: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case pending, complete, failed, unknown }
    public var version = 1
    public var id: UUID
    public var phase: Phase
    public var message: String?
    public var targets: [SparkWatchTarget]?
    public var models: [SparkWatchModel]?
    public var telemetry: SparkWatchTelemetry?
    public var operationID: String?

    public init(id: UUID, phase: Phase, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.message = message
    }
}

public struct SparkWatchFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum SparkWatchCodec {
    public static let maximumBytes = 48_000
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else {
            throw SparkWatchFailure("The response is too large for the watch.")
        }
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else {
            throw SparkWatchFailure("The watch message is too large.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

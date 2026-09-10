import Foundation

// The guest limits a version 2 pairing invitation carries, inside the node's signature.

/// One block of allowed local time. The end minute is exclusive, and 1440 means local midnight.
public struct GuestHourWindow: Codable, Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    enum CodingKeys: String, CodingKey {
        case startMinute = "start_minute"
        case endMinute = "end_minute"
    }
}

/// One weekday's allowed blocks, read in the owner's time zone. Monday is 0.
public struct GuestDaySchedule: Codable, Sendable, Equatable {
    public var weekday: Int
    public var windows: [GuestHourWindow]

    public init(weekday: Int, windows: [GuestHourWindow]) {
        self.weekday = weekday
        self.windows = windows
    }
}

/// What the owner shared: which models, which hours, how much, and until when.
public struct SharedAccessSummary: Codable, Sendable, Equatable {
    public var displayName: String
    public var allowedModels: [String]
    public var allowedHours: [GuestDaySchedule]
    public var timeZone: String
    public var maxConcurrentRequests: Int
    public var dailyTokenBudget: Int
    public var expiresAt: Int?

    public init(
        displayName: String,
        allowedModels: [String],
        allowedHours: [GuestDaySchedule],
        timeZone: String,
        maxConcurrentRequests: Int,
        dailyTokenBudget: Int,
        expiresAt: Int? = nil
    ) {
        self.displayName = displayName
        self.allowedModels = allowedModels
        self.allowedHours = allowedHours
        self.timeZone = timeZone
        self.maxConcurrentRequests = maxConcurrentRequests
        self.dailyTokenBudget = dailyTokenBudget
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case allowedModels = "allowed_models"
        case allowedHours = "allowed_hours"
        case timeZone = "time_zone"
        case maxConcurrentRequests = "max_concurrent_requests"
        case dailyTokenBudget = "daily_token_budget"
        case expiresAt = "expires_at"
    }

    /// Whether any minute of any day is open, so the app can say when a schedule shares nothing.
    public var hasOpenHours: Bool {
        allowedHours.contains { !$0.windows.isEmpty }
    }

    /// The whole week, every hour, which is what an owner who only limits models and tokens sends.
    public static func allHours() -> [GuestDaySchedule] {
        (0..<7).map {
            GuestDaySchedule(
                weekday: $0,
                windows: [GuestHourWindow(startMinute: 0, endMinute: 1440)]
            )
        }
    }
}

import Foundation
import SparkAPI
import SparkSecurity

/// The limits form the owner fills in, kept apart from the view so the rules can be tested on their own.
public struct SharedAccessLimitsDraft: Equatable, Sendable {
    public static let maximumModels = 32
    public static let maximumConcurrentRequests = 8
    public static let maximumDailyTokenBudget = 100_000_000

    public var guestName: String
    public var allowedModels: [String]
    /// Minutes from local midnight; the end is exclusive, and 1440 means midnight.
    public var startMinute: Int
    public var endMinute: Int
    public var weekdaysOnly: Bool
    public var timeZone: String
    public var maxConcurrentRequests: Int
    public var dailyTokenBudget: Int
    public var expiresAt: Date?

    public init(
        guestName: String = "",
        allowedModels: [String] = [],
        startMinute: Int = 0,
        endMinute: Int = 1_440,
        weekdaysOnly: Bool = false,
        timeZone: String = TimeZone.current.identifier,
        maxConcurrentRequests: Int = 1,
        dailyTokenBudget: Int = 50_000,
        expiresAt: Date? = nil
    ) {
        self.guestName = guestName
        self.allowedModels = allowedModels
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdaysOnly = weekdaysOnly
        self.timeZone = timeZone
        self.maxConcurrentRequests = maxConcurrentRequests
        self.dailyTokenBudget = dailyTokenBudget
        self.expiresAt = expiresAt
    }

    /// Why this draft cannot be sent yet, in the owner's words, or nil when it is ready.
    public var problem: String? {
        let name = guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 60 {
            return String(localized: "Give your friend a name between 1 and 60 characters.")
        }
        if allowedModels.isEmpty {
            return String(localized: "Choose at least one model to share. Nothing is shared yet.")
        }
        if allowedModels.count > Self.maximumModels {
            return String(localized: "You can share at most 32 models with one person.")
        }
        if startMinute >= endMinute || endMinute > 1_440 {
            return String(localized: "The end of the allowed hours must come after the start.")
        }
        if !(1...Self.maximumConcurrentRequests).contains(maxConcurrentRequests) {
            return String(localized: "Allow between 1 and 8 requests at a time.")
        }
        if !(1...Self.maximumDailyTokenBudget).contains(dailyTokenBudget) {
            return String(localized: "Set a daily budget of at least one token.")
        }
        if TimeZone(identifier: timeZone) == nil {
            return String(localized: "That time zone is not one this device recognises.")
        }
        return nil
    }

    public var isReady: Bool { problem == nil }

    /// The seven days the runtime stores, with the weekend closed when the owner asked for weekdays.
    public var schedule: [GeneratedAPI.GuestDaySchedule] {
        (0..<7).map { weekday in
            let open = !weekdaysOnly || weekday < 5
            return GeneratedAPI.GuestDaySchedule(
                weekday: weekday,
                windows: open
                    ? [
                        GeneratedAPI.GuestHourWindow(
                            startMinute: startMinute,
                            endMinute: endMinute
                        )
                    ]
                    : []
            )
        }
    }

    public func request() -> GeneratedAPI.CreateSharedAccessInvitation {
        GeneratedAPI.CreateSharedAccessInvitation(
            displayName: guestName.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedModels: allowedModels,
            allowedHours: schedule,
            timeZone: timeZone,
            maxConcurrentRequests: maxConcurrentRequests,
            dailyTokenBudget: dailyTokenBudget,
            expiresAt: expiresAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    public func limits() -> GeneratedAPI.SharedAccessLimits {
        GeneratedAPI.SharedAccessLimits(
            displayName: guestName.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedModels: allowedModels,
            allowedHours: schedule,
            timeZone: timeZone,
            maxConcurrentRequests: maxConcurrentRequests,
            dailyTokenBudget: dailyTokenBudget,
            expiresAt: expiresAt.map { Int($0.timeIntervalSince1970) }
        )
    }

    /// Rebuild the form from limits the Spark already holds, so editing starts where the owner left off.
    public static func from(
        displayName: String,
        allowedModels: [String],
        allowedHours: [GeneratedAPI.GuestDaySchedule],
        timeZone: String,
        maxConcurrentRequests: Int,
        dailyTokenBudget: Int,
        expiresAt: Int?
    ) -> SharedAccessLimitsDraft {
        let openDays = allowedHours.filter { !$0.windows.isEmpty }
        let window = openDays.first?.windows.first
        return SharedAccessLimitsDraft(
            guestName: displayName,
            allowedModels: allowedModels,
            startMinute: window?.startMinute ?? 0,
            endMinute: window?.endMinute ?? 1_440,
            weekdaysOnly: openDays.count == 5 && openDays.allSatisfy { $0.weekday < 5 },
            timeZone: timeZone,
            maxConcurrentRequests: maxConcurrentRequests,
            dailyTokenBudget: dailyTokenBudget,
            expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

/// Turn minutes from midnight into the clock face the owner reads.
public enum SharedAccessClock {
    public static func label(_ minute: Int) -> String {
        if minute >= 1_440 { return String(localized: "midnight") }
        var components = DateComponents()
        components.hour = minute / 60
        components.minute = minute % 60
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "\(minute)" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// The whole day reads better as "any time" than as a range that starts and ends at midnight.
    public static func windowLabel(start: Int, end: Int) -> String {
        if start == 0 && end >= 1_440 { return String(localized: "Any time") }
        return String(localized: .sharedAccessHoursRange(label(start), label(end)))
    }
}

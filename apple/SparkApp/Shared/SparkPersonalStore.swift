import CryptoKit
import EventKit
import Foundation

struct SparkPersonalCalendar: Identifiable, Equatable {
    let id: String
    let title: String
}

struct SparkPersonalItem: Identifiable, Equatable {
    let id: String
    let calendarID: String
    let calendarName: String
    let revision: String
    let draft: SparkPersonalAction
    let completed: Bool
    let editable: Bool
    let allDay: Bool
}

@MainActor
protocol SparkPersonalStoring: AnyObject {
    func authorize(_ kind: SparkPersonalActionKind, reading: Bool) async throws
    func calendars(_ kind: SparkPersonalActionKind) -> [SparkPersonalCalendar]
    func items(_ kind: SparkPersonalActionKind, start: Date) async throws -> [SparkPersonalItem]
    func save(_ draft: SparkPersonalAction, calendarID: String, replacing: SparkPersonalItem?)
        throws
    func remove(_ item: SparkPersonalItem) throws
    func complete(_ item: SparkPersonalItem) throws
}

/// EventKit stays on the Apple device; none of this store is available to the model or a Shortcut URL.
@MainActor
final class SparkPersonalStore: SparkPersonalStoring {
    private let store = EKEventStore()

    func authorize(_ kind: SparkPersonalActionKind, reading: Bool) async throws {
        let granted: Bool
        switch kind {
        case .event:
            if reading {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestWriteOnlyAccessToEvents()
            }
        case .reminder: granted = try await store.requestFullAccessToReminders()
        case .reply: throw SparkPersonalError.unsupported
        }
        guard granted else { throw SparkPersonalError.denied }
        try Task.checkCancellation()
    }

    func calendars(_ kind: SparkPersonalActionKind) -> [SparkPersonalCalendar] {
        guard kind != .reply else { return [] }
        return store.calendars(for: kind == .event ? .event : .reminder)
            .filter(\.allowsContentModifications)
            .map { .init(id: $0.calendarIdentifier, title: $0.title) }
    }

    func items(_ kind: SparkPersonalActionKind, start: Date) async throws -> [SparkPersonalItem] {
        try requireAccess(kind, reading: true)
        if kind == .event {
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(
                200
            ).map(snapshot)
        }
        guard kind == .reminder else { throw SparkPersonalError.unsupported }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        // EventKit delivers its result on an arbitrary queue; convert values there, never send EK objects.
        let result: [SparkPersonalItem] = try await withCheckedThrowingContinuation {
            continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: SparkPersonalError.unavailable)
                    return
                }
                continuation.resume(returning: reminders.prefix(200).map(Self.reminderSnapshot))
            }
        }
        try Task.checkCancellation()
        return result.sorted {
            ($0.draft.start ?? .distantFuture) < ($1.draft.start ?? .distantFuture)
        }
    }

    func save(_ draft: SparkPersonalAction, calendarID: String, replacing: SparkPersonalItem?)
        throws
    {
        try draft.validate()
        try requireAccess(draft.kind, reading: replacing != nil)
        store.reset()
        guard let calendar = store.calendar(withIdentifier: calendarID),
            calendar.allowsContentModifications,
            calendar.allowedEntityTypes.contains(draft.kind == .event ? .event : .reminder)
        else { throw SparkPersonalError.noCalendar }
        if let replacing, replacing.draft.kind != draft.kind { throw SparkPersonalError.changed }
        if draft.kind == .event {
            let event: EKEvent
            if let replacing {
                event = try existingEvent(replacing)
            } else {
                event = EKEvent(eventStore: store)
            }
            event.calendar = calendar
            event.title = draft.title
            event.notes = draft.body
            event.startDate = draft.start
            event.endDate = draft.end
            try store.save(event, span: .thisEvent, commit: true)
        } else if draft.kind == .reminder {
            let reminder = try replacing.map(existingReminder) ?? EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = draft.title
            reminder.notes = draft.body
            reminder.dueDateComponents = draft.start.map {
                Calendar.current.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                    from: $0
                )
            }
            reminder.alarms = draft.start.map { [EKAlarm(absoluteDate: $0)] }
            try store.save(reminder, commit: true)
        } else {
            throw SparkPersonalError.unsupported
        }
    }

    func remove(_ item: SparkPersonalItem) throws {
        try requireAccess(item.draft.kind, reading: true)
        store.reset()
        if item.draft.kind == .event {
            try store.remove(existingEvent(item), span: .thisEvent, commit: true)
        } else {
            try store.remove(existingReminder(item), commit: true)
        }
    }

    func complete(_ item: SparkPersonalItem) throws {
        try requireAccess(.reminder, reading: true)
        store.reset()
        let reminder = try existingReminder(item)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    private func requireAccess(_ kind: SparkPersonalActionKind, reading: Bool) throws {
        let status = EKEventStore.authorizationStatus(for: kind == .event ? .event : .reminder)
        guard status == .fullAccess || (kind == .event && !reading && status == .writeOnly)
        else { throw SparkPersonalError.denied }
    }

    private func existingEvent(_ item: SparkPersonalItem) throws -> EKEvent {
        guard let event = store.event(withIdentifier: item.id) else {
            throw SparkPersonalError.unavailable
        }
        let current = snapshot(event)
        guard current.revision == item.revision else { throw SparkPersonalError.changed }
        guard current.editable else { throw SparkPersonalError.unsupported }
        return event
    }
    private func existingReminder(_ item: SparkPersonalItem) throws -> EKReminder {
        guard item.draft.kind == .reminder,
            let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
        else { throw SparkPersonalError.unavailable }
        let current = Self.reminderSnapshot(reminder)
        guard current.revision == item.revision else { throw SparkPersonalError.changed }
        guard current.editable else { throw SparkPersonalError.unsupported }
        return reminder
    }

    private func snapshot(_ event: EKEvent) -> SparkPersonalItem {
        .init(
            id: event.eventIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            calendarName: event.calendar.title,
            revision: Self.revision(
                event,
                extra: [
                    event.startDate.description, event.endDate.description, String(event.isAllDay),
                    String(event.hasRecurrenceRules), String(event.attendees?.count ?? 0),
                ]
            ),
            draft: .init(
                kind: .event,
                title: event.title ?? "",
                body: event.notes ?? "",
                start: event.startDate,
                end: event.endDate
            ),
            completed: false,
            editable: event.calendar.allowsContentModifications && event.attendees?.isEmpty != false
                && !event.isAllDay,
            allDay: event.isAllDay
        )
    }
    nonisolated private static func reminderSnapshot(_ reminder: EKReminder) -> SparkPersonalItem {
        .init(
            id: reminder.calendarItemIdentifier,
            calendarID: reminder.calendar.calendarIdentifier,
            calendarName: reminder.calendar.title,
            revision: revision(
                reminder,
                extra: [
                    reminder.dueDateComponents?.description ?? "", String(reminder.isCompleted),
                    String(reminder.hasRecurrenceRules),
                ]
            ),
            draft: .init(
                kind: .reminder,
                title: reminder.title ?? "",
                body: reminder.notes ?? "",
                start: reminder.dueDateComponents.flatMap {
                    ($0.calendar ?? .current).date(from: $0)
                }
            ),
            completed: reminder.isCompleted,
            editable: reminder.calendar.allowsContentModifications && !reminder.hasRecurrenceRules,
            allDay: false
        )
    }
    nonisolated private static func revision(_ item: EKCalendarItem, extra: [String]) -> String {
        let fields =
            [
                item.calendarItemIdentifier, item.calendar.calendarIdentifier, item.title ?? "",
                item.notes ?? "", item.lastModifiedDate?.description ?? "",
            ] + extra
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

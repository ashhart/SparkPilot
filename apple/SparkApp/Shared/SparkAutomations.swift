import Foundation
import Observation
import SparkAPI
import SparkSecurity
import SwiftUI

/// Everything the Automations screen asks of a paired Spark.
public protocol SparkAutomationManaging: Sendable {
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation
    func listAutomations(route: URL) async throws -> GeneratedAPI.AutomationList
    func createAutomation(
        route: URL,
        request: GeneratedAPI.AutomationRequest,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> GeneratedAPI.Automation
    func updateAutomation(
        route: URL,
        id: String,
        request: GeneratedAPI.AutomationUpdateRequest,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> GeneratedAPI.Automation
    func deleteAutomation(
        route: URL,
        id: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.AutomationList
    func runAutomation(route: URL, id: String, idempotencyKey: UUID) async throws
        -> SparkAPI.Operation
    func listAutomationRuns(route: URL, id: String) async throws -> GeneratedAPI.AutomationRunList
    func getWebAccessSettings(route: URL) async throws -> GeneratedAPI.WebAccessSettings
    func models(route: URL) async throws -> ModelCatalogue
    func providerCredentials(route: URL) async throws -> [GeneratedAPI.ProviderCredential]
    func addProviderCredential(
        route: URL,
        request: GeneratedAPI.AddProviderCredentialRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ProviderCredential
    func setWebAccessSettings(
        route: URL,
        request: GeneratedAPI.WebAccessSettingsRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
}

extension SparkAPIClient: SparkAutomationManaging {}

/// The form's state, kept apart from the model so validation can be tested without a Spark.
public struct SparkAutomationDraft: Equatable, Sendable {
    public enum Repeat: String, CaseIterable, Identifiable, Sendable {
        case daily
        case weekdays
        case everyNHours = "every_n_hours"
        case weekly
        case custom

        public var id: String { rawValue }
    }

    public var name: String = ""
    public var instructions: String = ""
    public var repeats: Repeat = .daily
    public var hour: Int = 7
    public var minute: Int = 0
    public var everyHours: Int = 6
    /// Sunday is zero, matching the runtime's day-of-week field.
    public var weekday: Int = 1
    public var customExpression: String = ""
    public var timezone: String = TimeZone.current.identifier
    public var modelID: String = ""
    public var profileID: String? = nil
    public var webAccess: Bool = false
    public var notify: Bool = true
    public var enabled: Bool = true

    public init() {}

    /// The five-field expression the Spark stores, composed the same way for a preset and a typed one.
    public var expression: String {
        switch repeats {
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .everyNHours: "\(minute) */\(everyHours) * * *"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .custom: customExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Why this cannot be saved yet, in the owner's words, or nothing when it can.
    public var blocker: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Give this automation a name.")
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Say what you want your Spark to do.")
        }
        if modelID.isEmpty {
            return String(localized: "Choose the model that should do the work.")
        }
        if repeats == .custom, !Self.isFiveFields(expression) {
            return String(
                localized:
                    "A custom schedule is five parts: minute, hour, day of month, month, day of week."
            )
        }
        if repeats == .everyNHours, !(1...23).contains(everyHours) {
            return String(localized: "Choose between one and twenty-three hours.")
        }
        return nil
    }

    public var canSave: Bool { blocker == nil }

    private static func isFiveFields(_ expression: String) -> Bool {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789*/,-")
        return fields.allSatisfy { field in
            !field.isEmpty
                && field.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    public var schedule: GeneratedAPI.AutomationSchedule {
        GeneratedAPI.AutomationSchedule(
            preset: GeneratedAPI.AutomationSchedulePreset(rawValue: repeats.rawValue) ?? .custom,
            expression: expression,
            timezone: timezone
        )
    }

    public var creationRequest: GeneratedAPI.AutomationRequest {
        GeneratedAPI.AutomationRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: schedule,
            modelId: modelID,
            profileId: profileID,
            webAccess: webAccess,
            delivery: GeneratedAPI.AutomationDelivery(notify: notify),
            enabled: enabled
        )
    }

    public var updateRequest: GeneratedAPI.AutomationUpdateRequest {
        GeneratedAPI.AutomationUpdateRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule: schedule,
            modelId: modelID,
            profileId: profileID,
            webAccess: webAccess,
            delivery: GeneratedAPI.AutomationDelivery(notify: notify),
            enabled: enabled
        )
    }

    public static func editing(_ automation: GeneratedAPI.Automation) -> SparkAutomationDraft {
        var draft = SparkAutomationDraft()
        draft.name = automation.name
        draft.instructions = automation.instructions
        draft.repeats = Repeat(rawValue: automation.schedule.preset.rawValue) ?? .custom
        draft.customExpression = automation.schedule.expression
        draft.timezone = automation.schedule.timezone
        draft.modelID = automation.modelId
        draft.profileID = automation.profileId
        draft.webAccess = automation.webAccess
        draft.notify = automation.delivery.notify
        draft.enabled = automation.enabled
        let fields = automation.schedule.expression.split(separator: " ").map(String.init)
        if fields.count == 5 {
            draft.minute = Int(fields[0]) ?? 0
            draft.hour = Int(fields[1]) ?? 7
            if fields[1].hasPrefix("*/") { draft.everyHours = Int(fields[1].dropFirst(2)) ?? 6 }
            draft.weekday = Int(fields[4]) ?? 1
        }
        return draft
    }
}

import Foundation
import Observation
import SparkAPI
import SparkSecurity
import SwiftUI

/// What the Spark runs on its own, what it is allowed to read, and what every run produced.
@MainActor
@Observable
public final class SparkAutomationsModel {
    public private(set) var automations: [GeneratedAPI.Automation] = []
    public private(set) var installedModels: [SparkModel] = []
    public private(set) var searchCredentials: [GeneratedAPI.ProviderCredential] = []
    public private(set) var maxAutomations: Int = 32
    public private(set) var webAccess: GeneratedAPI.WebAccessSettings?
    public private(set) var runs: [String: [GeneratedAPI.AutomationRun]] = [:]
    public private(set) var isLoading = false
    public private(set) var isChanging = false
    public private(set) var errorMessage: String?
    public private(set) var localDeviceRole: String?

    public let route: URL
    public let targetID: String

    @ObservationIgnored private let runtime: any SparkAutomationManaging
    @ObservationIgnored private let userPresenceAuthorizer: any UserPresenceAuthorizing
    @ObservationIgnored private let presenceAuthority: SparkDashboardPresenceAuthority

    public init(
        route: URL,
        targetID: String,
        runtime: any SparkAutomationManaging,
        localDeviceRole: String?,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.localDeviceRole = localDeviceRole
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.presenceAuthority = SparkDashboardPresenceAuthority(
            route: route,
            enrollmentProvider: runtime as? any DeviceManagementProviding,
            authorizer: userPresenceAuthorizer
        )
    }

    public var canManage: Bool {
        localDeviceRole == "owner" || localDeviceRole == "administrator"
    }

    public var isOwner: Bool { localDeviceRole == "owner" }

    public var canAdd: Bool { canManage && automations.count < maxAutomations }

    /// What the Spark allows its model to read, in the owner's words.
    public var webAccessSummary: String {
        switch webAccess?.policy {
        case .some(.off), .none:
            String(localized: "This Spark does not let the model read the internet.")
        case .some(.automations):
            String(localized: "Automations you switch on may read the internet. Chats may not.")
        case .some(.automationsAndChats):
            String(
                localized: "Automations and conversations you switch on may read the internet."
            )
        }
    }

    public func updateLocalDeviceRole(_ role: String?) {
        localDeviceRole = role
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let listing = try await runtime.listAutomations(route: route)
            automations = listing.items
            maxAutomations = listing.maxAutomations
        } catch {
            errorMessage = Self.message(for: error, action: .list)
        }
        await loadChoices()
        await loadWebAccess()
    }

    public func loadWebAccess() async {
        do {
            webAccess = try await runtime.getWebAccessSettings(route: route)
        } catch {
            webAccess = nil
            errorMessage = Self.message(for: error, action: .policy)
        }
        SparkChatWebAccess.shared.updatePolicy(webAccess?.policy, targetID: targetID)
    }

    public func loadChoices() async {
        if let catalogue = try? await runtime.models(route: route) {
            installedModels = catalogue.items.filter { $0.installState == .installed }
                .sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
        }
        searchCredentials =
            (try? await runtime.providerCredentials(route: route))?
            .filter { $0.provider == "brave-search" } ?? []
    }

    public func addSearchCredential(name: String, secret: String) async -> String? {
        guard isOwner, !isChanging, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var identifier: String?
        _ = await change(action: .policy) {
            let presence = try await self.userPresenceAuthorizer.authorize(
                localizedReason: String(localized: "Save your search key on this Spark")
            )
            let credential = try await self.runtime.addProviderCredential(
                route: self.route,
                request: .init(
                    provider: "brave-search",
                    displayName: name.isEmpty ? String(localized: "Brave Search") : name,
                    secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                idempotencyKey: UUID(),
                userPresence: presence
            )
            self.searchCredentials.append(credential)
            identifier = credential.id
        }
        return identifier
    }

    public func loadRuns(for id: String) async {
        do {
            runs[id] = try await runtime.listAutomationRuns(route: route, id: id).items
        } catch {
            errorMessage = Self.message(for: error, action: .list)
        }
    }

    @discardableResult
    public func create(_ draft: SparkAutomationDraft) async -> Bool {
        guard canManage, !isChanging, draft.canSave else { return false }
        return await change(action: .create) {
            let presence =
                draft.webAccess
                ? try await self.userPresenceAuthorizer.authorize(
                    localizedReason: String(
                        localized: "Let this automation read the internet on your Spark"
                    )
                ) : nil
            let created = try await self.runtime.createAutomation(
                route: self.route,
                request: draft.creationRequest,
                idempotencyKey: UUID(),
                userPresence: presence
            )
            self.automations.append(created)
        }
    }

    @discardableResult
    public func update(_ id: String, with draft: SparkAutomationDraft) async -> Bool {
        guard canManage, !isChanging, draft.canSave else { return false }
        let turningOn =
            draft.webAccess && automations.first(where: { $0.id == id })?.webAccess == false
        return await change(action: .update) {
            let presence =
                turningOn
                ? try await self.userPresenceAuthorizer.authorize(
                    localizedReason: String(
                        localized: "Let this automation read the internet on your Spark"
                    )
                ) : nil
            let updated = try await self.runtime.updateAutomation(
                route: self.route,
                id: id,
                request: draft.updateRequest,
                idempotencyKey: UUID(),
                userPresence: presence
            )
            if let index = self.automations.firstIndex(where: { $0.id == id }) {
                self.automations[index] = updated
            }
        }
    }

    @discardableResult
    public func setEnabled(_ id: String, to enabled: Bool) async -> Bool {
        guard canManage, !isChanging else { return false }
        return await change(action: .update) {
            let updated = try await self.runtime.updateAutomation(
                route: self.route,
                id: id,
                request: GeneratedAPI.AutomationUpdateRequest(enabled: enabled),
                idempotencyKey: UUID(),
                userPresence: nil
            )
            if let index = self.automations.firstIndex(where: { $0.id == id }) {
                self.automations[index] = updated
            }
        }
    }

    @discardableResult
    public func delete(_ id: String) async -> Bool {
        guard canManage, !isChanging else { return false }
        return await change(action: .delete) {
            let listing = try await self.runtime.deleteAutomation(
                route: self.route,
                id: id,
                idempotencyKey: UUID()
            )
            self.automations = listing.items
            self.runs[id] = nil
        }
    }

    @discardableResult
    public func runNow(_ id: String) async -> Bool {
        guard canManage, !isChanging else { return false }
        let started = await change(action: .run) {
            _ = try await self.runtime.runAutomation(
                route: self.route,
                id: id,
                idempotencyKey: UUID()
            )
        }
        if started { await loadRuns(for: id) }
        return started
    }

    /// Only the owner changes what the Spark itself may reach, and only with a fresh presence check.
    @discardableResult
    public func setWebAccess(
        policy: GeneratedAPI.WebAccessSettingsPolicy,
        harnessAccess: Bool,
        backend: GeneratedAPI.WebAccessSettingsSearchBackend,
        braveCredentialID: String? = nil
    ) async -> Bool {
        guard isOwner, !isChanging, let current = webAccess else { return false }
        let changed = await change(action: .policy) {
            let key = UUID()
            let operation = try await self.presenceAuthority.submitPresenceAuthorized(
                reason: String(
                    localized: "Confirm changing what your Spark may read on the internet"
                )
            ) { presence in
                try await self.runtime.setWebAccessSettings(
                    route: self.route,
                    request: GeneratedAPI.WebAccessSettingsRequest(
                        policy: GeneratedAPI.WebAccessSettingsRequestPolicy(
                            rawValue: policy.rawValue
                        )
                            ?? .off,
                        harnessAccess: harnessAccess,
                        allowDomains: current.allowDomains,
                        denyDomains: current.denyDomains,
                        searchBackend: GeneratedAPI.WebAccessSettingsRequestSearchBackend(
                            rawValue: backend.rawValue
                        ) ?? .searxng,
                        searxngUrl: current.searxngUrl ?? "http://127.0.0.1:18119",
                        braveCredentialId: braveCredentialID ?? current.braveCredentialId
                    ),
                    idempotencyKey: key,
                    userPresence: presence
                )
            }
            try await self.waitForWebSetting(operation)
        }
        if changed {
            await loadWebAccess()
        }
        return changed && webAccess != nil
    }

    private enum Action { case list, create, update, delete, run, policy }

    private func waitForWebSetting(_ accepted: SparkAPI.Operation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        var operation = accepted
        while true {
            try Task.checkCancellation()
            guard operation.id == accepted.id, operation.kind == "settings.web_access" else {
                throw APIError(.reported, code: "OPERATION_INVALID")
            }
            switch operation.state {
            case .succeeded: return
            case .failed, .cancelled:
                throw APIError(.reported, code: operation.errorCode ?? "WEB_SEARCH_UNAVAILABLE")
            default: break
            }
            guard ContinuousClock.now < deadline else {
                throw APIError(.reported, code: "OPERATION_TIMEOUT")
            }
            operation = try await runtime.operation(route: route, id: accepted.id)
            if operation.state != .succeeded && operation.state != .failed
                && operation.state != .cancelled
            {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func change(action: Action, _ work: () async throws -> Void) async -> Bool {
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            try await work()
            return true
        } catch {
            errorMessage = Self.message(for: error, action: action)
            return false
        }
    }

    /// Never echo a runtime message; say what the owner can do about it.
    private static func message(for error: any Error, action: Action) -> String {
        guard let api = error as? APIError else {
            return String(localized: "Your Spark could not be reached. Try again in a moment.")
        }
        switch api.code {
        case "ROLE_FORBIDDEN":
            return String(localized: "This device is not allowed to change automations.")
        case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_EXPIRED":
            return String(localized: "Confirm with Face ID, Touch ID or your passcode to continue.")
        case "USER_PRESENCE_NOT_REGISTERED":
            return String(localized: "This device has no confirmation key yet. Pair it again.")
        case "AUTOMATION_TIMEZONE_UNKNOWN":
            return String(localized: "Your Spark does not know that time zone.")
        case "AUTOMATION_SCHEDULE_INVALID":
            return String(localized: "Your Spark could not read that schedule.")
        case "AUTOMATION_LIMIT_REACHED":
            return String(localized: "This Spark already holds as many automations as it keeps.")
        case "AUTOMATION_RUN_IN_FLIGHT":
            return String(localized: "This automation is already running.")
        case "AUTOMATION_NOT_FOUND":
            return String(localized: "That automation is no longer on this Spark.")
        case "WEB_ACCESS_POLICY_OFF":
            return String(localized: "Model internet access is switched off on this Spark.")
        case "WEB_SEARCH_UNAVAILABLE":
            return String(
                localized:
                    "Your Spark's search service could not start. Try Repair search, or choose another search service."
            )
        case "OPERATION_TIMEOUT":
            return String(
                localized:
                    "Your Spark is still setting up search. Check Activity for progress before trying again."
            )
        default:
            return switch action {
            case .list: String(localized: "Your Spark's automations could not be read.")
            case .create: String(localized: "That automation was not saved.")
            case .update: String(localized: "That change was not saved.")
            case .delete: String(localized: "That automation was not deleted.")
            case .run: String(localized: "That run did not start.")
            case .policy: String(localized: "That internet setting was not saved.")
            }
        }
    }
}

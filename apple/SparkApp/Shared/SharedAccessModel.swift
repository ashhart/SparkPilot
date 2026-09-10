import Foundation
import Observation
import SparkAPI
import SparkSecurity

/// The owner's view of one guest, with the numbers already reduced to what the row shows.
public struct SharedAccessGuestRow: Equatable, Sendable, Identifiable {
    public let guest: GeneratedAPI.SharedAccessGuest

    public var id: String { guest.deviceId ?? guest.invitationId }
    public var hasJoined: Bool { guest.deviceId != nil }
    public var name: String { guest.displayName }
    public var state: GeneratedAPI.SharedAccessState { guest.state }
    public var usedToday: Int { guest.today.totalTokens }
    public var requestsToday: Int { guest.today.requests }
    public var usedThisWeek: Int { guest.thisWeek.totalTokens }
    public var refusalsThisWeek: Int { guest.thisWeek.refusals }
    public var budget: Int { guest.dailyTokenBudget }

    public init(guest: GeneratedAPI.SharedAccessGuest) {
        self.guest = guest
    }

    /// The refusal reasons the owner most needs to see, largest first.
    public var topRefusals: [(reason: String, count: Int)] {
        guest.refusalsThisWeek
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .prefix(3)
            .map { (reason: $0.key, count: $0.value) }
    }

    public var hoursLabel: String {
        guard let day = guest.allowedHours.days.first(where: { !$0.windows.isEmpty }),
            let window = day.windows.first
        else {
            return String(localized: "No hours set")
        }
        let openDays = guest.allowedHours.days.filter { !$0.windows.isEmpty }
        let range = SharedAccessClock.windowLabel(
            start: window.startMinute,
            end: window.endMinute
        )
        if openDays.count == 5 && openDays.allSatisfy({ $0.weekday < 5 }) {
            return String(localized: .sharedAccessWeekdayHours(range))
        }
        return range
    }

    public var draft: SharedAccessLimitsDraft {
        SharedAccessLimitsDraft.from(
            displayName: guest.displayName,
            allowedModels: guest.allowedModels,
            allowedHours: guest.allowedHours.days,
            timeZone: guest.timeZone,
            maxConcurrentRequests: guest.maxConcurrentRequests,
            dailyTokenBudget: guest.dailyTokenBudget,
            expiresAt: guest.expiresAt
        )
    }
}

@MainActor
@Observable
public final class SharedAccessModel {
    public private(set) var rows: [SharedAccessGuestRow] = []
    public private(set) var isLoading = false
    public private(set) var busyDeviceID: String?
    public private(set) var errorMessage: String?
    public private(set) var hasLoaded = false
    public var revocationConfirmation: SharedAccessGuestRow?

    public let route: URL
    private let runtime: any SharedAccessProviding
    private let userPresenceAuthorizer: any UserPresenceAuthorizing

    public init(
        route: URL,
        runtime: any SharedAccessProviding,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer()
    ) {
        self.route = route
        self.runtime = runtime
        self.userPresenceAuthorizer = userPresenceAuthorizer
    }

    public var pendingCount: Int { rows.filter { $0.state == .pending && $0.hasJoined }.count }

    /// Build the invitation form against the same Spark and the same presence prompt.
    public func invitationModel(
        trust: NodeTrust,
        availableModels: [String]
    ) -> SharedAccessInvitationModel {
        SharedAccessInvitationModel(
            route: route,
            trust: trust,
            runtime: runtime,
            availableModels: availableModels,
            userPresenceAuthorizer: userPresenceAuthorizer
        )
    }

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let overview = try await runtime.sharedAccess(route: route)
            rows = overview.guests.map(SharedAccessGuestRow.init)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    public func confirm(_ row: SharedAccessGuestRow) async {
        await change(
            row,
            to: .active,
            reason: String(localized: "Confirm this person can use your Spark.")
        )
    }

    public func pause(_ row: SharedAccessGuestRow) async {
        await change(
            row,
            to: .paused,
            reason: String(localized: "Pause this person's access to your Spark.")
        )
    }

    public func resume(_ row: SharedAccessGuestRow) async {
        await change(
            row,
            to: .active,
            reason: String(localized: "Let this person use your Spark again.")
        )
    }

    public func applyLimits(_ draft: SharedAccessLimitsDraft, to row: SharedAccessGuestRow) async {
        guard let deviceID = row.guest.deviceId else { return }
        guard draft.isReady else {
            errorMessage = draft.problem
            return
        }
        await mutate(
            deviceID: deviceID,
            reason: String(localized: "Change what this person can use.")
        ) {
            session in
            _ = try await self.runtime.updateSharedAccess(
                route: self.route,
                deviceID: deviceID,
                change: GeneratedAPI.UpdateSharedAccess(state: nil, limits: draft.limits()),
                idempotencyKey: UUID(),
                userPresence: session
            )
        }
    }

    public func revoke(_ row: SharedAccessGuestRow) async {
        revocationConfirmation = nil
        guard let deviceID = row.guest.deviceId else { return }
        await mutate(
            deviceID: deviceID,
            reason: String(localized: "Stop sharing your Spark with this person.")
        ) { session in
            _ = try await self.runtime.revokeSharedAccess(
                route: self.route,
                deviceID: deviceID,
                idempotencyKey: UUID(),
                userPresence: session
            )
        }
    }

    private func change(
        _ row: SharedAccessGuestRow,
        to state: GeneratedAPI.UpdateSharedAccessState,
        reason: String
    ) async {
        guard let deviceID = row.guest.deviceId else { return }
        await mutate(deviceID: deviceID, reason: reason) { session in
            _ = try await self.runtime.updateSharedAccess(
                route: self.route,
                deviceID: deviceID,
                change: GeneratedAPI.UpdateSharedAccess(state: state, limits: nil),
                idempotencyKey: UUID(),
                userPresence: session
            )
        }
    }

    private func mutate(
        deviceID: String,
        reason: String,
        _ work: @escaping (any UserPresenceProofSigning) async throws -> Void
    ) async {
        guard busyDeviceID == nil else { return }
        busyDeviceID = deviceID
        errorMessage = nil
        defer { busyDeviceID = nil }
        do {
            let session = try await userPresenceAuthorizer.authorize(localizedReason: reason)
            try await work(session)
            await refresh()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let api = error as? APIError else {
            return String(localized: "That change did not reach your Spark. Try again.")
        }
        switch api.code {
        case "ROLE_FORBIDDEN":
            return String(localized: "Only the owner of this Spark can change shared access.")
        case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_EXPIRED", "USER_PRESENCE_INVALID":
            return String(localized: "Confirm with Face ID or Touch ID to change shared access.")
        case "GUEST_ACCESS_REVOKED":
            return String(localized: "That person's access has already been withdrawn.")
        case "SHARED_ACCESS_POLICY_INVALID":
            return String(localized: "The Spark refused those limits. Check them and try again.")
        default:
            return String(localized: "That change did not reach your Spark. Try again.")
        }
    }
}

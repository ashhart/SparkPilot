import Foundation
import Observation
import SparkAPI

public protocol OwnSharedAccessProviding: Sendable {
    func ownSharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessSelf
}

extension SparkAPIClient: OwnSharedAccessProviding {}

/// What a guest's copy of SparkPilot may show; the Spark's own capabilities remain authoritative.
public struct GuestExperience: Equatable, Sendable {
    public let record: GeneratedAPI.SharedAccessSelf

    public init(record: GeneratedAPI.SharedAccessSelf) {
        self.record = record
    }

    public var guestName: String { record.displayName }
    public var allowedModels: [String] { record.allowedModels }
    public var dailyTokenBudget: Int { record.dailyTokenBudget }
    public var usedToday: Int { record.today.totalTokens }
    public var requestsToday: Int { record.today.requests }
    public var timeZone: String { record.timeZone }

    public var remainingToday: Int { max(0, dailyTokenBudget - usedToday) }

    public var canChat: Bool {
        record.state == .active && !allowedModels.isEmpty && remainingToday > 0 && hasOpenHours
    }

    public var hasOpenHours: Bool {
        record.allowedHours.days.contains { !$0.windows.isEmpty }
    }

    /// A guest never sees settings, other devices, dashboards, automations or web tools.
    public var showsOwnerControls: Bool { false }
    public var showsDeviceList: Bool { false }
    public var showsDashboard: Bool { false }
    public var showsAutomations: Bool { false }

    public var budgetResetsAt: Date? {
        record.budgetResetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var expiresAt: Date? {
        record.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// The one sentence a guest sees when chat is not available, saying what is limited and why.
    public var unavailableReason: String? {
        switch record.state {
        case .pending:
            return String(
                localized:
                    "The owner hasn't confirmed your access yet. They'll get a prompt on their device."
            )
        case .paused:
            return String(
                localized:
                    "The owner has paused your access. Nothing you send will reach the Spark."
            )
        case .revoked:
            return String(localized: "The owner has stopped sharing this Spark with you.")
        case .active:
            break
        }
        if allowedModels.isEmpty {
            return String(localized: "The owner hasn't shared any models with you yet.")
        }
        if !hasOpenHours {
            return String(localized: "The owner hasn't set any hours when you can use this Spark.")
        }
        if remainingToday == 0 {
            return String(
                localized:
                    "You've used today's share of this Spark. It starts again at the owner's midnight."
            )
        }
        return nil
    }

    /// The windows one weekday allows, as the guest reads them.
    public func hoursLabel(weekday: Int) -> String {
        guard let day = record.allowedHours.days.first(where: { $0.weekday == weekday }),
            !day.windows.isEmpty
        else {
            return String(localized: "Not available")
        }
        return day.windows
            .map { SharedAccessClock.windowLabel(start: $0.startMinute, end: $0.endMinute) }
            .joined(separator: ", ")
    }
}

@MainActor
@Observable
public final class GuestExperienceModel {
    public private(set) var experience: GuestExperience?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// A device that is not a guest gets the ordinary app; nothing here hides anything from an owner.
    public private(set) var isGuest = false

    private let route: URL
    private let runtime: any OwnSharedAccessProviding
    private let nodeID: String?
    private let registry: GuestAccessRegistry

    public init(
        route: URL,
        runtime: any OwnSharedAccessProviding,
        nodeID: String? = nil,
        registry: GuestAccessRegistry = .shared
    ) {
        self.route = route
        self.runtime = runtime
        self.nodeID = nodeID
        self.registry = registry
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let record = try await runtime.ownSharedAccess(route: route)
            experience = GuestExperience(record: record)
            isGuest = true
            if let nodeID { registry.record(allowedModels: record.allowedModels, forNode: nodeID) }
        } catch let error as APIError
            where error.statusCode == 404 || error.code == "ROLE_FORBIDDEN"
        {
            // Not a guest: this device holds its own grant and keeps the whole app.
            experience = nil
            isGuest = false
            if let nodeID { registry.forget(node: nodeID) }
        } catch {
            experience = nil
            errorMessage = String(
                localized: "Your access to this Spark could not be read. It may be offline."
            )
        }
    }
}

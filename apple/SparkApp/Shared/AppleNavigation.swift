import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkProjects
import SwiftUI

public enum AppleDeviceClass: Sendable, Equatable {
    case phone
    case pad
}

public enum AppleNavigationLayout: Sendable, Equatable {
    case tabs
    case splitView
}

public enum AppleNavigationSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case chats
    case projects
    case models
    case clusters
    case automations
    case activity
    case settings
    case more

    public var id: String { rawValue }

    public var title: String {
        return switch self {
        case .home: String(localized: "Home")
        case .chats: String(localized: "Chats")
        case .projects: String(localized: "Develop")
        case .models: String(localized: "Models")
        case .clusters: String(localized: "Clusters")
        case .automations: String(localized: "Automations")
        case .activity: String(localized: "Activity")
        case .settings: String(localized: "Settings")
        case .more: String(localized: "More")
        }
    }

    public var symbol: String {
        return switch self {
        case .home: "house"
        case .chats: "bubble.left.and.bubble.right"
        case .projects: "terminal"
        case .models: "square.stack.3d.up"
        case .clusters: "point.3.connected.trianglepath.dotted"
        case .automations: "clock.badge.checkmark"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        case .more: "ellipsis"
        }
    }

    /// Uses the same destination names on iPhone and iPad.
    public func title(for device: AppleDeviceClass) -> String {
        guard device == .pad else { return title }
        return switch self {
        case .home: String(localized: "Home")
        case .activity: String(localized: "Activity")
        default: title
        }
    }

    public func symbol(for device: AppleDeviceClass) -> String {
        guard device == .pad else { return symbol }
        return switch self {
        case .home: "square.grid.2x2"
        case .activity: "clock.arrow.circlepath"
        default: symbol
        }
    }
}

public enum AppleNavigationPlan {
    public static let sidebarSections: [AppleNavigationSection] = [
        .home, .chats, .projects, .models, .clusters, .automations, .activity, .settings,
    ]
    public static let phoneTabs: [AppleNavigationSection] = [
        .home, .chats, .activity, .more,
    ]
    public static let phoneMoreSections: [AppleNavigationSection] = [
        .projects, .models, .clusters, .automations, .settings,
    ]

    public static func phoneTabs(engineeringMode: Bool) -> [AppleNavigationSection] {
        [.home, .chats, engineeringMode ? .projects : .activity, .more]
    }

    public static func phoneMoreSections(engineeringMode: Bool) -> [AppleNavigationSection] {
        engineeringMode
            ? [.activity, .models, .clusters, .automations, .settings]
            : [.models, .clusters, .automations, .settings]
    }

    public static func phoneSelection(
        _ selection: AppleNavigationSection,
        engineeringMode: Bool
    ) -> AppleNavigationSection {
        guard !phoneTabs(engineeringMode: engineeringMode).contains(selection) else {
            return selection
        }
        return selection == .activity || selection == .projects
            ? (engineeringMode ? .projects : .activity) : .home
    }

    public static func visibleSections(
        _ sections: [AppleNavigationSection],
        hasSparks: Bool,
        engineeringMode: Bool
    ) -> [AppleNavigationSection] {
        sections.filter { section in
            if !hasSparks { return [.home, .chats, .settings, .more].contains(section) }
            return engineeringMode || section != .projects
        }
    }

    public static func layout(for device: AppleDeviceClass) -> AppleNavigationLayout {
        device == .pad ? .splitView : .tabs
    }

    public static func showsWorkloads(
        in section: AppleNavigationSection,
        on device: AppleDeviceClass
    ) -> Bool {
        false
    }

    public static func showsModelLibrary(
        in section: AppleNavigationSection,
        on device: AppleDeviceClass
    ) -> Bool {
        _ = device
        return section == .models
    }

    public static func usesFleetHome(on device: AppleDeviceClass) -> Bool {
        device == .pad
    }

    /// Reads the stable device identifier once to attribute Activity jobs to this device.
    public static let localDeviceID: UUID = DeviceIdentityStore.loadOrCreateDeviceID()

    public static func activityCards(
        for operations: [TargetOperationSnapshot],
        targetName: String? = nil,
        localDeviceID: UUID? = AppleNavigationPlan.localDeviceID
    ) -> [OperationCardState] {
        let local = localDeviceID?.uuidString.lowercased()
        return operations.map { operation in
            OperationCardState(
                id: operation.id,
                kind: operation.kind,
                state: operation.state,
                stage: operation.stage,
                progress: operation.progress,
                cancellable: operation.cancellable,
                errorCode: operation.errorCode,
                targetName: targetName,
                createdAt: operation.createdAt,
                startedAt: operation.startedAt,
                completedAt: operation.completedAt,
                origin: origin(of: operation.actorDeviceID, local: local)
            )
        }
    }

    /// §41.8's unified timeline: every Spark's jobs in one chronological list, newest first.
    public static func activityTimeline(for entries: [LibraryEntry]) -> [OperationCardState] {
        entries.flatMap { entry in
            activityCards(
                for: entry.cachedOperationalSnapshot?.operations ?? [],
                targetName: entry.displayName
            )
        }
        .sorted { left, right in
            let leftInstant = left.mostRecentInstant ?? .distantPast
            let rightInstant = right.mostRecentInstant ?? .distantPast
            if leftInstant != rightInstant { return leftInstant > rightInstant }
            return left.id.rawValue.uuidString < right.id.rawValue.uuidString
        }
    }

    /// Omits job origin when either the runtime actor or this device's identifier is unavailable.
    private static func origin(of actorDeviceID: String?, local: String?) -> OperationOrigin? {
        guard let actorDeviceID = actorDeviceID?.lowercased(), let local else { return nil }
        return actorDeviceID == local ? .thisDevice : .anotherDevice
    }

    public static func activityCards(
        for entries: [LibraryEntry],
        selected route: SparkNotificationOperationRoute
    ) -> [OperationCardState] {
        let entry = entries.first(where: { $0.id == route.targetID })
        let operation = entry?.cachedOperationalSnapshot?.operations.first(where: {
            $0.id == route.operationID
        })
        return activityCards(for: operation.map { [$0] } ?? [], targetName: entry?.displayName)
    }
}

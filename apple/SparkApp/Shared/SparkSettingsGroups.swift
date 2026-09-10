import SparkAPI
import SparkDesignSystem
import SwiftUI

/// Groups settings by the owner's task with one destination per concern.
public enum SparkSettingsGroup: String, CaseIterable, Identifiable, Sendable {
    case network
    case hardware
    case updates
    case models
    case storage
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .network: String(localized: "Network")
        case .hardware: String(localized: "Hardware and power")
        case .updates: String(localized: "Software updates")
        case .models: String(localized: "Models and memory")
        case .storage: String(localized: "Storage")
        case .system: String(localized: "Time and privacy")
        }
    }

    public var detail: String {
        switch self {
        case .network:
            String(localized: "Status, Wi-Fi, wired LAN, travel hotspot and remote access")
        case .hardware: String(localized: "Power profile, thermal limits and Bluetooth")
        case .updates: String(localized: "Spark Runtime and system updates")
        case .models: String(localized: "Memory guard and model idle policy")
        case .storage: String(localized: "Disk use and downloaded models")
        case .system: String(localized: "Time zone, clock and telemetry choices")
        }
    }

    public var symbol: String {
        switch self {
        case .network: "network"
        case .hardware: "cpu"
        case .updates: "arrow.triangle.2.circlepath"
        case .models: "memorychip"
        case .storage: "internaldrive"
        case .system: "clock"
        }
    }
}

/// Allow missing network and remote settings models when runtime support or open-Spark composition is unavailable.
public struct SparkSettingsContext {
    public let settings: SparkSettingsModel
    public let networkStatus: SparkNetworkStatusModel?
    public let remoteAccess: RemoteAccessModel?
    /// Lets the updates page finish an update with the same restart the Power card offers.
    public let powerControl: SparkPowerControlModel?

    public init(
        settings: SparkSettingsModel,
        networkStatus: SparkNetworkStatusModel? = nil,
        remoteAccess: RemoteAccessModel? = nil,
        powerControl: SparkPowerControlModel? = nil
    ) {
        self.settings = settings
        self.networkStatus = networkStatus
        self.remoteAccess = remoteAccess
        self.powerControl = powerControl
    }
}

/// Support dashboard cards and platform Settings list rows from the same settings groups.
public enum SparkSettingsRowStyle: Sendable {
    case card
    case list
}

/// Reports only runtime update evidence or verified bundled-release comparisons, preserving unknown counts as unknown.
struct SparkSettingsUpdateIndicator: Equatable {
    let badge: String?
    let detail: String

    var accessibilityValue: String {
        badge.map { String(localized: .pair($0, detail)) } ?? detail
    }

    init(
        updates: GeneratedAPI.SoftwareUpdateStatus?,
        runtimeUpdateAvailable: Bool,
        runtimeUpgradeRequired: Bool
    ) {
        var available: [String] = []
        var unknown: [String] = []
        if let count = updates?.systemPackagesAvailable, count >= 0 {
            if count > 0 {
                available.append(
                    String(
                        localized: .labelledValue(
                            title: String(localized: "OS packages"),
                            value: String(localized: .updatesAvailable(count))
                        )
                    )
                )
            }
        } else {
            unknown.append(String(localized: "OS update status unknown"))
        }
        if let count = updates?.firmwareUpdatesAvailable, count >= 0 {
            if count > 0 {
                available.append(
                    String(
                        localized: .labelledValue(
                            title: String(localized: "Firmware"),
                            value: String(localized: .updatesAvailable(count))
                        )
                    )
                )
            }
        } else {
            unknown.append(String(localized: "Firmware update status unknown"))
        }
        // Determine update availability from verified release comparison rather than the presence of a staged package.
        if runtimeUpdateAvailable || runtimeUpgradeRequired {
            available.append(String(localized: "Spark Runtime"))
        }
        badge =
            runtimeUpgradeRequired
            ? String(localized: "Required")
            : !available.isEmpty
                ? String(localized: "Available")
                : updates?.rebootRequired == true ? String(localized: "Restart required") : nil
        var descriptions: [String] = []
        if !available.isEmpty {
            descriptions.append(
                String(
                    localized: .labelledValue(
                        title: String(localized: "Reported"),
                        value: available.formatted(.list(type: .and))
                    )
                )
            )
        } else if unknown.isEmpty {
            descriptions.append(String(localized: "No updates reported"))
        }
        if updates?.rebootRequired == true {
            descriptions.append(String(localized: "Restart this Spark to finish applying updates."))
        }
        descriptions.append(contentsOf: unknown)
        detail = descriptions.formatted(.list(type: .and))
    }
}

/// One row per settings page.
public struct SparkSettingsGroupRows: View {
    private let context: SparkSettingsContext
    private let style: SparkSettingsRowStyle

    public init(context: SparkSettingsContext, style: SparkSettingsRowStyle = .card) {
        self.context = context
        self.style = style
    }

    public var body: some View {
        let updateIndicator = SparkSettingsUpdateIndicator(
            updates: context.settings.settings?.softwareUpdates,
            runtimeUpdateAvailable: context.settings.runtimeUpdateAvailable,
            runtimeUpgradeRequired: context.settings.runtimeUpgradeRequired
        )
        ForEach(SparkSettingsGroup.allCases) { group in
            let detail = group == .updates ? updateIndicator.detail : group.detail
            let badge = group == .updates ? updateIndicator.badge : nil
            switch style {
            case .card:
                NavigationLink {
                    page(group)
                } label: {
                    SparkSettingsCardRowLabel(
                        title: group.title,
                        detail: detail,
                        symbol: group.symbol,
                        badge: badge
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityValue(group == .updates ? updateIndicator.accessibilityValue : "")
                .accessibilityHint(group.detail)
                .accessibilityIdentifier("spark.settings.group.\(group.rawValue)")
            case .list:
                NavigationLink {
                    page(group)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(group.title)
                                if let badge {
                                    SparkSettingsUpdateBadge(text: badge)
                                }
                            }
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: group.symbol)
                    }
                }
                .accessibilityLabel(group.title)
                .accessibilityValue(group == .updates ? updateIndicator.accessibilityValue : "")
                .accessibilityHint(group.detail)
                .accessibilityIdentifier("spark.settings.group.\(group.rawValue)")
            }
        }
        .task(id: context.settings.route) { await context.settings.loadIfNeeded() }
    }

    private func page(_ group: SparkSettingsGroup) -> some View {
        SparkSettingsView(
            model: context.settings,
            group: group,
            networkStatus: context.networkStatus,
            remoteAccess: context.remoteAccess,
            powerControl: context.powerControl
        )
    }
}

/// Share the dashboard settings navigation row across Spark settings pages.
public struct SparkSettingsCardRowLabel: View {
    let title: String
    let detail: String
    let symbol: String
    let badge: String?

    public init(title: String, detail: String, symbol: String, badge: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.badge = badge
    }

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                    if let badge {
                        SparkSettingsUpdateBadge(text: badge)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SparkSettingsUpdateBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

import Observation
import SparkAPI
import SwiftUI

public protocol SparkNetworkStatusReading: Sendable {
    func networkInterfaces(route: URL) async throws -> NetworkInterfacesSnapshot
}

extension SparkAPIClient: SparkNetworkStatusReading {}

@MainActor
@Observable
public final class SparkNetworkStatusModel {
    public private(set) var snapshot: NetworkInterfacesSnapshot?
    public private(set) var isRefreshing = false
    public private(set) var errorMessage: String?

    public let route: URL

    @ObservationIgnored
    private let runtime: any SparkNetworkStatusReading

    public init(route: URL, runtime: any SparkNetworkStatusReading) {
        self.route = route
        self.runtime = runtime
    }

    public func loadIfNeeded() async {
        guard snapshot == nil else { return }
        await refresh()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            snapshot = try await runtime.networkInterfaces(route: route)
        } catch let error as APIError where error.statusCode == 404 {
            errorMessage =
                String(
                    localized:
                        "Update SparkPilot features in Spark settings before opening Network status."
                )
        } catch {
            errorMessage =
                String(
                    localized:
                        "Network status is unavailable. Check that this Spark is online and its runtime is up to date."
                )
        }
    }
}

public struct SparkNetworkStatusView: View {
    @Bindable private var model: SparkNetworkStatusModel

    public init(model: SparkNetworkStatusModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                if model.snapshot == nil, model.isRefreshing {
                    SparkSkeletonList(
                        rowCount: 3,
                        accessibilityLabel: String(localized: "Loading Spark network interfaces")
                    )
                } else if let snapshot = model.snapshot {
                    if snapshot.interfaces.isEmpty {
                        ContentUnavailableView(
                            "No Interfaces Reported",
                            systemImage: "network.slash",
                            description: Text(
                                "NetworkManager did not report an interface on this Spark."
                            )
                        )
                    } else {
                        let split = SparkNetworkInterfaces.split(snapshot.interfaces)
                        ForEach(split.ownersOwn) { interface in
                            NetworkInterfaceCard(interface: interface)
                        }
                        if !split.plumbing.isEmpty {
                            DisclosureGroup(
                                String(
                                    localized: .containerInterfacesCount(split.plumbing.count)
                                )
                            ) {
                                ForEach(split.plumbing) { interface in
                                    NetworkInterfaceCard(interface: interface)
                                }
                            }
                            .font(.headline)
                        }
                    }
                    Text(
                        .checkedAt(
                            snapshot.observedAt.formatted(date: .omitted, time: .standard)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 680)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .sparkHelp(String(localized: "Checks every network interface on this Spark now."))
            }
        }
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Network status")
                        .font(.title2.bold())
                    SparkTooltipButton(
                        title: String(localized: "Internet checks"),
                        message:
                            String(
                                localized:
                                    "SparkPilot tests each connected interface through its own gateway and DNS link."
                            )
                    )
                }
                Text(
                    "Addresses, link speed, Wi-Fi signal and internet reachability from this Spark."
                )
                .foregroundStyle(.secondary)
            }
        }
    }

}

/// Separates owner-facing network interfaces from loopback and container infrastructure while keeping both inspectable.
enum SparkNetworkInterfaces {
    static func isPlumbing(_ interface: NetworkInterfaceStatus) -> Bool {
        let name = interface.name
        if interface.type == "loopback" || name == "lo" { return true }
        return name.hasPrefix("docker") || name.hasPrefix("br-") || name.hasPrefix("veth")
            || name.hasPrefix("virbr") || name.hasPrefix("cni") || name.hasPrefix("flannel")
    }

    static func split(
        _ interfaces: [NetworkInterfaceStatus]
    ) -> (ownersOwn: [NetworkInterfaceStatus], plumbing: [NetworkInterfaceStatus]) {
        let ordered = interfaces.sorted { left, right in
            if left.state == right.state { return left.name < right.name }
            if left.state == "connected" { return true }
            if right.state == "connected" { return false }
            return left.name < right.name
        }
        return (
            ordered.filter { !isPlumbing($0) },
            ordered.filter { isPlumbing($0) }
        )
    }
}

private struct NetworkInterfaceCard: View {
    let interface: NetworkInterfaceStatus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Move the state pill below the interface name at accessibility sizes to avoid competing for width.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    interfaceIdentity
                    statePill
                }
            } else {
                HStack(spacing: 12) {
                    interfaceIdentity
                    Spacer()
                    statePill
                }
            }

            Divider()
            NetworkValueRow(title: String(localized: "Internet"), value: internetLabel)
            if let speed = interface.linkSpeedMbps {
                NetworkValueRow(title: String(localized: "Link speed"), value: linkSpeed(speed))
            }
            if let ssid = interface.wifiSSID {
                NetworkValueRow(
                    title: String(localized: "Wi-Fi"),
                    value: NetworkInterfacePresentation.wifiValue(
                        name: ssid,
                        signalPercent: interface.wifiSignalPercent
                    )
                )
            }
            if !interface.addresses.isEmpty {
                NetworkValueRow(
                    title: String(localized: "IP addresses"),
                    value: interface.addresses.map(\.address).joined(separator: "\n")
                )
            }
            if let gateway = interface.gateway {
                NetworkValueRow(title: String(localized: "Gateway"), value: gateway)
            }
            if !interface.dnsServers.isEmpty {
                NetworkValueRow(title: "DNS", value: interface.dnsServers.joined(separator: "\n"))
            }
            if let mac = interface.macAddress {
                NetworkValueRow(title: String(localized: "MAC address"), value: mac)
            }
            if let mtu = interface.mtu {
                NetworkValueRow(title: "MTU", value: mtu.formatted())
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var interfaceIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(
                    interface.state == "connected" ? Color.accentColor : .secondary
                )
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(interface.connectionName ?? interface.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(.joined(typeLabel, interface.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statePill: some View {
        Text(stateLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stateColour)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(stateColour.opacity(0.12), in: Capsule())
    }

    private var symbol: String {
        switch interface.type {
        case "ethernet": "cable.connector"
        case "wifi": "wifi"
        case "bridge": "point.3.connected.trianglepath.dotted"
        case "loopback": "arrow.trianglehead.2.clockwise.rotate.90"
        default: "network"
        }
    }

    private var typeLabel: String { NetworkInterfacePresentation.typeLabel(interface.type) }

    private var stateLabel: String { NetworkInterfacePresentation.stateLabel(interface.state) }

    private var stateColour: Color {
        switch interface.state {
        case "connected": .green
        case "disconnected": .secondary
        default: .orange
        }
    }

    private var internetLabel: String {
        NetworkInterfacePresentation.internetLabel(
            state: interface.state,
            reachable: interface.internet.reachable,
            gatewayReachable: interface.internet.gatewayReachable,
            dnsReachable: interface.internet.dnsReachable
        )
    }

    private func linkSpeed(_ megabits: Int64) -> String {
        NetworkInterfacePresentation.linkSpeed(megabits)
    }
}

private struct NetworkValueRow: View {
    let title: String
    let value: String

    var body: some View {
        // Stack labels and values when a shared line would force long addresses into narrow wrapping.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }
}

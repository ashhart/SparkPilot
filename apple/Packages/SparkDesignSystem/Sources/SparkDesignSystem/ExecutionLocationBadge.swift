import SwiftUI

/// How the answer reaches the Apple device, which §52.1 requires the owner to be able to inspect.
public enum SparkExecutionTransport: Sendable, Equatable, CaseIterable {
    /// The Apple system model. Nothing is sent anywhere.
    case onThisDevice
    case localNetwork
    case directCable
    case remote

    /// Whether the prompt leaves the Apple device at all (§52.1).
    public var leavesThisDevice: Bool { self != .onThisDevice }

    public var detail: String {
        switch self {
        case .onThisDevice: String(localized: "Nothing leaves this device")
        case .localNetwork: String(localized: "Local Wi-Fi")
        case .directCable: String(localized: "Direct 10 GbE")
        case .remote: String(localized: "Secure remote connection")
        }
    }
}

/// Show the actual execution target with both symbol and label (§39.2, §52.1).
public struct ExecutionLocationValue: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let transport: SparkExecutionTransport

    public init(label: String, symbol: String, transport: SparkExecutionTransport = .localNetwork) {
        self.label = label
        self.symbol = symbol
        self.transport = transport
    }

    /// The transport phrase behind the label, for a detail line or a spoken value.
    public var detail: String { transport.detail }

    /// The §52.1 target vocabulary.
    public static let appleSystem = ExecutionLocationValue(
        label: Self.thisDeviceLabel,
        symbol: "iphone.gen3",
        transport: .onThisDevice
    )

    public static func spark(
        nodeName: String?,
        transport: SparkExecutionTransport = .localNetwork
    ) -> ExecutionLocationValue {
        let name = nodeName ?? String(localized: "your Spark")
        return ExecutionLocationValue(
            label: transport == .remote
                ? String(localized: .remoteConnectionTo(name)) : String(localized: .onTarget(name)),
            symbol: transport == .remote ? "antenna.radiowaves.left.and.right" : "server.rack",
            transport: transport
        )
    }

    public static func sparkCluster(
        nodeCount: Int,
        name: String? = nil,
        transport: SparkExecutionTransport = .localNetwork
    ) -> ExecutionLocationValue {
        let label = name ?? String(localized: .sparkClusterOfNodes(nodeCount))
        return ExecutionLocationValue(
            label: transport == .remote
                ? String(localized: .remoteConnectionTo(label))
                : String(localized: .onTarget(label)),
            symbol: transport == .remote
                ? "antenna.radiowaves.left.and.right" : "rectangle.stack.3d.up",
            transport: transport
        )
    }

    /// Name the actual Apple device rather than a generic "this device".
    static var thisDeviceLabel: String {
        #if os(macOS)
            String(localized: "On this Mac")
        #else
            UIDevice.current.userInterfaceIdiom == .pad
                ? String(localized: "On this iPad") : String(localized: "On this iPhone")
        #endif
    }
}

/// Compact badge for toolbars/cards/chat headers.
public struct ExecutionLocationBadge: View {
    public let value: ExecutionLocationValue

    public init(value: ExecutionLocationValue) {
        self.value = value
    }

    public var body: some View {
        Label(value.label, systemImage: value.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, SparkSpacing.compact)
            .padding(.vertical, SparkSpacing.tiny)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .accessibilityElement()
            .accessibilityLabel(Text(.runningOn(value.label)))
            .accessibilityValue(Text(verbatim: value.detail))
    }
}

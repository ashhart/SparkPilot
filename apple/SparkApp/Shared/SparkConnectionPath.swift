import Foundation
import Network
import SparkCore
import SparkLibrary
import SwiftUI

/// Which way the app is reaching a Spark right now, in the owner's words: on the same network or over Tailscale.
public struct SparkConnectionPath: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case local
        case tailscale
        case unknown
    }

    public let transport: Transport
    /// The remote name shown beside the label; local paths do not repeat the local address.
    public let host: String?

    public init(transport: Transport, host: String?) {
        self.transport = transport
        self.host = transport == .local ? nil : host
    }

    public var isRemote: Bool { transport == .tailscale }

    public var label: String {
        switch transport {
        case .local: String(localized: "On your network")
        case .tailscale: String(localized: "Over Tailscale")
        case .unknown: String(localized: "Connected")
        }
    }

    public var symbol: String {
        switch transport {
        case .local: "house.fill"
        case .tailscale: "lock.shield.fill"
        case .unknown: "network"
        }
    }

    public var accessibilityLabel: String {
        guard let host else { return label }
        return String(localized: .pair(label, host))
    }

    public static func resolve(kind: SparkTransportKind, host: String?) -> SparkConnectionPath {
        switch kind {
        case .directEthernet, .localWiFi: SparkConnectionPath(transport: .local, host: host)
        case .privateOverlay: SparkConnectionPath(transport: .tailscale, host: host)
        }
    }

    /// Without a library route only the name is left: Tailscale, an address of this network, or the internet.
    public static func resolve(url: URL) -> SparkConnectionPath {
        let rawHost = url.host()?.lowercased() ?? ""
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        let transport: Transport
        if host.hasSuffix(".ts.net") || isTailscaleIPv4(host) || isTailscaleIPv6(host) {
            transport = .tailscale
        } else if isLocalHost(host) {
            transport = .local
        } else {
            transport = .unknown
        }
        return SparkConnectionPath(transport: transport, host: url.host())
    }

    /// A name or address that can only be answered from the same network as this device.
    static func isLocalHost(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if name == "127.0.0.1" || name == "::1" || name == "[::1]" { return true }
        if let bytes = ipv6Bytes(name) {
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return isPrivateIPv4(name)
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let address =
            host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        return IPv6Address(address).map { Array($0.rawValue) }
    }

    /// Tailscale's ULA prefix: https://tailscale.com/docs/concepts/ipv6.
    static func isTailscaleIPv6(_ host: String) -> Bool {
        guard let bytes = ipv6Bytes(host) else { return false }
        return bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    }

    /// The four IPv4 ranges a home or office network hands out.
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = UInt8(parts[0]), let second = UInt8(parts[1]),
            UInt8(parts[2]) != nil, UInt8(parts[3]) != nil
        else { return false }
        if first == 10 { return true }
        if first == 192 && second == 168 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        return first == 169 && second == 254
    }

    /// Prefer the library route the open session is on, then the route that answered last, then the URL alone.
    public static func resolve(entry: LibraryEntry?, activeRouteURL: URL?) -> SparkConnectionPath? {
        if let entry, let coordinator = entry.coordinatorNodeID,
            let member = entry.member(nodeID: coordinator)
        {
            let active = activeRouteURL.flatMap { url in
                member.routes.first { RetailRouteComparison.sameRoute($0.baseURL, url) }
            }
            if let route = active ?? member.routeInUse ?? entry.preferredRoute {
                return resolve(kind: route.kind, host: route.baseURL.host())
            }
        }
        return activeRouteURL.map(resolve(url:))
    }

    static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = UInt8(parts[0]), let second = UInt8(parts[1]),
            UInt8(parts[2]) != nil, UInt8(parts[3]) != nil
        else { return false }
        return first == 100 && (64...127).contains(second)
    }
}

/// One line under a Spark's name: the path in use and, when remote, the hostname it is reached by.
public struct SparkConnectionPathBadge: View {
    public let path: SparkConnectionPath

    public init(path: SparkConnectionPath) {
        self.path = path
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: path.symbol)
                .accessibilityHidden(true)
            Text(path.label)
            if let host = path.host {
                Text(host)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path.accessibilityLabel)
    }
}

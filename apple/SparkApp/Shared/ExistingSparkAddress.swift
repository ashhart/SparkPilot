import Foundation
import Network
import SparkDiscovery

/// Validate a typed endpoint without narrowing an out-of-range port or treating URL credentials as a hostname.
enum ExistingSparkAddress {
    static func bootstrap(_ raw: String) -> BootstrapSpark? {
        guard let target = discovered(raw, defaultPort: 22) else { return nil }
        return BootstrapSpark(displayName: target.displayName, endpoint: target.endpoint)
    }

    static func discovered(_ raw: String, defaultPort: UInt16 = 7443) -> DiscoveredSpark? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
            let components = URLComponents(string: "https://\(value)"),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let number = UInt16(exactly: components.port ?? Int(defaultPort)), number > 0,
            let port = NWEndpoint.Port(rawValue: number)
        else { return nil }
        return DiscoveredSpark(
            id: "manual:\(host.lowercased()):\(port.rawValue)",
            displayName: host,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
            interface: nil,
            shortNodeID: nil
        )
    }
}

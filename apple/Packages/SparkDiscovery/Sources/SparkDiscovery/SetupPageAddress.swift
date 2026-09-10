import Foundation

/// Where a first-boot page may live: on the Spark's own setup network, never on a public host.
public enum SetupPageAddress {
    /// NVIDIA's first-boot page answers on the default web ports; any other port is not that page.
    static let permittedPorts: Set<Int> = [80, 443]

    /// Accept http or https without credentials, on a default port, at a setup-network host.
    public static func isOnSetupNetwork(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.user == nil, url.password == nil,
            url.port.map(permittedPorts.contains) ?? true,
            let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        return isSetupNetworkHost(host)
    }

    /// A link-local or private IPv4, a link-local or unique-local IPv6, or a one-label .local name.
    public static func isSetupNetworkHost(_ host: String) -> Bool {
        let literal = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let octets = ipv4Octets(literal) { return isPrivateIPv4(octets) }
        if let bytes = ipv6Bytes(literal) { return isPrivateIPv6(bytes) }
        return isLocalHostname(literal)
    }

    private static func ipv4Octets(_ literal: String) -> [UInt8]? {
        let parts = literal.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// 10/8, 172.16/12 and 192.168/16 (RFC 1918) plus 169.254/16 link-local.
    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _): true
        case (172, 16...31): true
        case (192, 168): true
        case (169, 254): true
        default: false
        }
    }

    private static func ipv6Bytes(_ literal: String) -> [UInt8]? {
        guard literal.contains(":") else { return nil }
        // A zone index names this device's interface; the address itself decides the range.
        let address = literal.split(separator: "%", maxSplits: 1).first.map(String.init) ?? literal
        var parsed = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { return nil }
        return withUnsafeBytes(of: &parsed) { Array($0) }
    }

    /// fe80::/10 link-local and fc00::/7 unique-local.
    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
        return linkLocal || uniqueLocal
    }

    /// The shape SparkSetupAddress derives for a setup SSID: one DNS label under `.local`.
    private static func isLocalHostname(_ literal: String) -> Bool {
        let labels = literal.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 2, labels[1] == "local" else { return false }
        let label = labels[0]
        return !label.isEmpty && label.utf8.count <= 63
            && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy {
                $0 == 45 || (48...57).contains($0) || (97...122).contains($0)
            }
    }
}

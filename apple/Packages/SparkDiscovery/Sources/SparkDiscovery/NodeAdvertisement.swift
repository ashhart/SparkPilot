import Foundation
import Network

/// Treat Bonjour TXT as untrusted discovery metadata until the pinned identity endpoint verifies the node (§12.1).
public struct DiscoveredSpark: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let endpoint: NWEndpoint
    public let interface: NWInterface?
    /// Short node id from TXT (8 hex chars) when advertised, else nil.
    public let shortNodeID: String?
    /// The cluster this node says it belongs to, so 10.2.3 can group it as a cluster.
    public let clusterID: String?

    public init(
        id: String,
        displayName: String,
        endpoint: NWEndpoint,
        interface: NWInterface?,
        shortNodeID: String?,
        clusterID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.interface = interface
        self.shortNodeID = shortNodeID
        self.clusterID = clusterID
    }
}

/// Parsed TXT service records from a `_spark-runtime._tcp` advertisement.
public struct NodeTXT: Sendable {
    public let api: String?
    public let node: String?
    public let cluster: String?
    public let pairing: String?
    public let role: String?
    public let tls: String?
    public let runtime: String?

    public init(dictionary: [String: Data]) {
        func text(_ key: String) -> String? {
            guard let data = dictionary[key], !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }
        self.api = text("api")
        self.node = text("node")
        self.cluster = text("cluster")
        self.pairing = text("pairing")
        self.role = text("role")
        self.tls = text("tls")
        self.runtime = text("runtime")
    }

    public init(raw: String) {
        let pairs = raw.split(separator: "\n").compactMap {
            line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        self.init(
            dictionary: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, Data($0.1.utf8)) })
        )
    }

    /// Pass shipping Bonjour metadata into identity-hint parsing without treating discovery as authentication.
    public init(metadata: NWBrowser.Result.Metadata) {
        switch metadata {
        case .bonjour(let record):
            self.init(
                dictionary: record.dictionary.mapValues { Data($0.utf8) }
            )
        case .none:
            self.init(dictionary: [:])
        @unknown default:
            self.init(dictionary: [:])
        }
    }
}

/// Convert Network-framework interfaces into constructible domain values for deterministic logic tests.
public enum SparkInterfaceKind: String, Sendable, Equatable {
    case wifi
    case wiredEthernet
    case cellular
    case loopback
    case other

    public init(interface: NWInterface?) {
        guard let type = interface?.type else {
            self = .other
            return
        }
        switch type {
        case .wifi: self = .wifi
        case .wiredEthernet: self = .wiredEthernet
        case .cellular: self = .cellular
        case .loopback: self = .loopback
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}

/// Record individual network advertisements before endpoint merging.
public struct NodeAdvertisement: Hashable, Sendable {
    public let instance: String
    public let endpoint: NWEndpoint
    public let interfaceKind: SparkInterfaceKind
    public let shortNodeID: String?
    /// Untrusted TXT hint that this node is part of a cluster; grouping only, never trust.
    public let clusterID: String?
    public let discoveredAt: Date

    public init(
        instance: String,
        endpoint: NWEndpoint,
        interfaceKind: SparkInterfaceKind,
        txt: NodeTXT,
        discoveredAt: Date = Date()
    ) {
        self.instance = instance
        self.endpoint = endpoint
        self.interfaceKind = interfaceKind
        self.shortNodeID = txt.node
        self.clusterID = txt.cluster
        self.discoveredAt = discoveredAt
    }

    /// Whether this is a wired path (direct-link candidate).
    public var isWired: Bool {
        interfaceKind == .wiredEthernet
    }

    /// TXT identity is untrusted: only deduplicate observations of the same network endpoint.
    public var mergeKey: String {
        switch endpoint {
        case .service(let name, let type, let domain, _):
            return "service:\(name.utf8.count):\(name):\(type):\(domain)"
        case .hostPort(let host, let port):
            return "host:\(host):\(port.rawValue)"
        default:
            return "endpoint:\(endpoint)"
        }
    }
}

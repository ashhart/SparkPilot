#if os(macOS)
    import AppKit
    import Network
    import SparkAPI
    import SparkCore
    import SparkDesignSystem
    import SparkDiscovery
    import SparkLibrary
    import SparkProjects
    import SparkSecurity
    import SwiftUI

    public struct MacDiscoveredSparkPresentation: Equatable, Sendable {
        public let name: String
        public let connectionLabel: String
        public let connectionSymbol: String

        public init(name: String, interfaceKind: SparkInterfaceKind) {
            self.name = name
            switch interfaceKind {
            case .wiredEthernet:
                connectionLabel = String(localized: "Direct connection")
                connectionSymbol = "cable.connector"
            case .wifi:
                connectionLabel = String(localized: "Local Wi-Fi")
                connectionSymbol = "wifi"
            case .cellular:
                connectionLabel = String(localized: "Cellular network")
                connectionSymbol = "antenna.radiowaves.left.and.right"
            case .loopback, .other:
                connectionLabel = String(localized: "Local network")
                connectionSymbol = "network"
            }
        }
    }

    enum MacHomeDestination: Equatable {
        case fleet
        case dashboard
    }

    enum MacRootPresentationPlan {
        static func homeDestination(hasDashboard: Bool) -> MacHomeDestination {
            hasDashboard ? .dashboard : .fleet
        }

        static func shouldResetDetailPath(
            from previous: MacSidebarItem?,
            to next: MacSidebarItem?
        ) -> Bool {
            previous != next
        }

    }

    /// Uses the local library for Fleet and starts Bonjour only after Add Spark or Find Nearby.
    extension DiscoveredSpark {
        /// Builds a candidate HTTPS route from resolved discovery data, subject to pinned-identity validation before use.
        public var runtimeCandidateURL: URL? {
            guard case .service(let name, let type, _, _) = endpoint else { return nil }
            let host =
                name
                .replacingOccurrences(of: ".\(type)", with: "")
                .replacingOccurrences(of: " ", with: "-")
            return SparkAppRoute.localRoute(host: host)
        }

        /// Uses Bonjour's resolved host and advertised port, returning no URL for unresolved service endpoints.
        public func runtimeRoute() -> URL? {
            guard case .hostPort(let host, let port) = endpoint else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = DiscoveredSpark.literal(host)
            components.port = Int(port.rawValue)
            return components.url
        }

        /// Brackets IPv6 hosts and percent-encodes their scope zones when constructing URLs.
        static func literal(_ host: NWEndpoint.Host) -> String {
            switch host {
            case .name(let name, _):
                return name
            case .ipv4(let address):
                return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            case .ipv6(let address):
                let text = "\(address)"
                let zoned = text.replacingOccurrences(of: "%", with: "%25")
                return "[\(zoned)]"
            @unknown default:
                return "\(host)"
            }
        }
    }

    enum MacSidebarItem: String, CaseIterable, Identifiable {
        case home
        case chats
        case projects
        case launch
        case models
        case clusters
        case activity
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: String(localized: "Home")
            case .chats: String(localized: "Chats")
            case .projects: String(localized: "Develop")
            case .launch: String(localized: "Launch")
            case .models: String(localized: "Models")
            case .clusters: String(localized: "Clusters")
            case .activity: String(localized: "Workloads")
            case .settings: String(localized: "Settings")
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .chats: "bubble.left.and.bubble.right"
            case .projects: "terminal"
            case .launch: "paperplane"
            case .models: "square.stack.3d.up"
            case .clusters: "point.3.connected.trianglepath.dotted"
            case .activity: "tablecells"
            case .settings: "gearshape"
            }
        }
    }

#endif

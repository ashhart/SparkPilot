import Foundation
import SparkCore
import SparkLibrary

// Share deterministic identity and route fixtures within the SparkLibrary test module.

func libraryNodeID(_ hex: UInt64) -> SparkNodeID {
    SparkNodeID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", hex))!)
}

func libraryClusterID(_ hex: UInt64) -> SparkClusterID {
    SparkClusterID(
        rawValue: UUID(uuidString: String(format: "11111111-0000-4000-8000-%012llx", hex))!
    )
}

/// Namespaced logical-key string for a node, e.g. "node:<uuid>".
func nodeKey(_ hex: UInt64) -> String {
    "node:\(libraryNodeID(hex).rawValue.uuidString.lowercased())"
}

/// Namespaced logical-key string for a cluster, e.g. "cluster:<uuid>".
func clusterKey(_ hex: UInt64) -> String {
    "cluster:\(libraryClusterID(hex).rawValue.uuidString.lowercased())"
}

func route(
    host: String,
    kind: SparkTransportKind = .localWiFi,
    interface: String? = nil,
    port: Int = 7443
) -> CachedRoute {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = port
    return CachedRoute(baseURL: components.url!, kind: kind, interfaceName: interface)
}

func target(
    node: UInt64,
    cluster: UInt64? = nil,
    name: String = "DGX Spark",
    role: SparkNodeRole = .standalone,
    displayName: String = "spark-a1b2",
    routes: [CachedRoute] = [],
    reachedAt: Date = Date(),
    authorityFingerprint: String = "fp"
) -> AuthenticatedTarget {
    AuthenticatedTarget(
        nodeID: libraryNodeID(node),
        clusterID: cluster.map(libraryClusterID),
        name: name,
        role: role,
        authorityFingerprint: authorityFingerprint,
        displayName: displayName,
        routes: routes,
        reachedAt: reachedAt
    )
}

/// Create a fresh production-clock reconciler unless a test explicitly supplies a fixed clock.
func reconcile(
    _ target: AuthenticatedTarget,
    into entries: [LibraryEntry]
) -> ReconciliationOutcome {
    LibraryReconciler().reconcile(target: target, into: entries)
}

import Foundation
import SparkDiscovery
import SparkLibrary

/// Discovers replacement address hints without granting trust; routes must still match the paired certificate, authority and node identity.
@MainActor
public protocol SavedSparkRouteDiscovering {
    func candidateRoutes() async -> [URL]
}

/// Use bounded SSH Bonjour discovery when runtime advertising or saved hostnames are temporarily unavailable.
@MainActor
struct BonjourSavedSparkRouteDiscovery: SavedSparkRouteDiscovering {
    private let discovery: BootstrapDiscoveryService
    private let settle: @Sendable (Duration) async throws -> Void

    init(
        discovery: BootstrapDiscoveryService,
        settle: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.discovery = discovery
        self.settle = settle
    }

    func candidateRoutes() async -> [URL] {
        discovery.start()
        defer { discovery.stop() }

        // Bound the Bonjour fallback after failed saved-route probing.
        for _ in 0..<4 where discovery.candidates.isEmpty {
            guard !Task.isCancelled else { return [] }
            do {
                try await settle(.milliseconds(250))
            } catch {
                return []
            }
        }

        var seen = Set<String>()
        return discovery.candidates.compactMap { candidate in
            let host = SSHRuntimeBootstrapInstaller.hostName(for: candidate)
            guard let route = SparkAppRoute.localRoute(host: host),
                seen.insert(route.absoluteString.lowercased()).inserted
            else { return nil }
            return route
        }
    }
}

enum SavedSparkRouteRecovery {
    /// Change only the mutable route address while preserving the paired peer fingerprint.
    static func candidate(baseURL: URL, savedRoute: CachedRoute) -> CachedRoute {
        CachedRoute(
            slotID: savedRoute.slotID,
            baseURL: baseURL,
            kind: savedRoute.kind,
            interfaceName: savedRoute.interfaceName,
            peerFingerprint: savedRoute.peerFingerprint,
            lastSuccess: nil,
            isMetered: savedRoute.isMetered
        )
    }
}

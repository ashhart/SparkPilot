import Foundation
import SparkAPI

extension RemoteAccessModel {
    /// Reuse this Spark's pinned client when the previously used local address is unavailable away from home.
    func readRemoteStatus(refreshHealth: Bool) async throws -> RemoteStatus {
        try await performRemoteRequest { candidate in
            if refreshHealth { return try await runtime.refreshRemoteHealth(route: candidate) }
            return try await runtime.remoteStatus(route: candidate)
        }
    }

    var activeRemoteRoute: URL { connectedRemoteRoute ?? route }

    /// Replays only transport failures against this Spark's signed, pinned route hints.
    func performRemoteRequest<Value: Sendable>(
        _ request: (URL) async throws -> Value
    ) async throws -> Value {
        let candidates = statusReadRoutes
        for (index, candidate) in candidates.enumerated() {
            do {
                try Task.checkCancellation()
                let value = try await request(candidate)
                try Task.checkCancellation()
                connectedRemoteRoute = candidate
                return value
            } catch {
                guard index + 1 < candidates.count, Self.isRouteUnavailable(error) else {
                    throw error
                }
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private var statusReadRoutes: [URL] {
        var candidates = [activeRemoteRoute]
        if !candidates.contains(route) { candidates.append(route) }
        guard route.scheme == "https", let status, status.enabled, status.mode == .privateOverlay
        else { return candidates }
        for hostname in [status.hostname, status.privateOverlayAddress].compactMap({ $0 }) {
            guard
                LibraryRemoteAccessRouteRegistration.isTailscaleName(hostname)
                    || SparkConnectionPath.isTailscaleIPv4(hostname)
            else { continue }
            var components = URLComponents()
            components.scheme = "https"
            components.host = hostname
            components.port = route.port ?? 7_443
            if let url = components.url, !candidates.contains(url) { candidates.append(url) }
        }
        return candidates
    }

    private static func isRouteUnavailable(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

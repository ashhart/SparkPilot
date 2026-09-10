import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI
@MainActor
struct SparkSettingsNetworkPoller {
    let runtime: any SparkSettingsManaging
    let networkRouteDiscovery: any SavedSparkRouteDiscovering
    let networkPollAttempts: Int
    let networkPollDelay: @Sendable (Duration) async throws -> Void
    let observe: (SparkAPI.Operation) -> Void

    func waitForNetworkHandoff(
        _ submitted: SparkAPI.Operation,
        originalRoute: URL,
        expectedNodeID: SparkNodeID,
        preferredCandidateRoute: URL?,
        maxAttempts: Int
    ) async throws -> (operation: SparkAPI.Operation, route: URL, identity: SparkIdentity) {
        var operation = submitted
        var verifiedRoute: (route: URL, identity: SparkIdentity)?
        var sawIdentityMismatch = false
        let identityChecker = try await runtime.makeNetworkHandoffIdentityChecker()

        let attempts = max(1, min(maxAttempts, networkPollAttempts))
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            observe(operation)
            if operation.state == .failed || operation.state == .cancelled {
                throw APIError(
                    .local(message: String(localized: "The Spark rejected the network change.")),
                    code: operation.errorCode
                )
            }

            var candidates = await networkRouteDiscovery.candidateRoutes()
            if let preferredCandidateRoute,
                !candidates.contains(preferredCandidateRoute)
            {
                candidates.insert(preferredCandidateRoute, at: 0)
            }
            // Discover recovery routes only after acceptance and open fresh connections to resolve changed addresses behind stable hostnames.
            for candidate in candidates {
                do {
                    let identity = try await identityChecker.identity(route: candidate)
                    guard identity.nodeID == expectedNodeID else {
                        sawIdentityMismatch = true
                        continue
                    }
                    verifiedRoute = (candidate, identity)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }

            if operation.state == .succeeded, let verifiedRoute {
                return (operation, verifiedRoute.route, verifiedRoute.identity)
            }

            guard attempt + 1 < attempts else { break }
            try await networkPollDelay(.milliseconds(500))
            let pollingRoute = verifiedRoute?.route ?? originalRoute
            do {
                let refreshed = try await runtime.operation(route: pollingRoute, id: operation.id)
                operation = refreshed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        throw sawIdentityMismatch ? NetworkHandoffError.identityMismatch : .timedOut
    }

    func waitForNetworkResolution(
        _ submitted: SparkAPI.Operation,
        preferredRoute: URL,
        fallbackRoute: URL
    ) async throws -> SparkAPI.Operation {
        var operation = submitted
        for _ in 0..<120 {
            switch operation.state {
            case .succeeded, .failed, .cancelled:
                return operation
            default:
                try await Task.sleep(for: .milliseconds(500))
                if let refreshed = try? await runtime.operation(
                    route: preferredRoute,
                    id: operation.id
                ) {
                    operation = refreshed
                } else if let refreshed = try? await runtime.operation(
                    route: fallbackRoute,
                    id: operation.id
                ) {
                    operation = refreshed
                }
            }
        }
        throw APIError(
            .local(message: String(localized: "The network restore is still being applied."))
        )
    }
}

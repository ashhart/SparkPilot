import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

/// Presence-gated requests, bounded polling and pinned route registration shared by every remote-access flow.
extension RemoteAccessModel {
    func waitForTerminalOperation(_ accepted: SparkAPI.Operation) async throws
        -> SparkAPI.Operation
    {
        let poller = RemoteAccessOperationPoller(
            runtime: runtime,
            route: activeRemoteRoute,
            maximumPolls: maximumOperationPolls,
            delay: operationDelay
        )
        return try await poller.wait(for: accepted) { [weak self] operation in
            self?.lastOperation = operation
        }
    }

    func reconcilePrivateOverlayRoute(for loaded: RemoteStatus) async -> String? {
        let generation = privateRouteVerificationGeneration
        verifiedPrivateRouteHostname = nil
        guard loaded.enabled else {
            routeRegistration.unregisterPrivateOverlay(currentRoute: route)
            return nil
        }
        guard loaded.mode == .privateOverlay else { return nil }
        let candidates = [loaded.hostname, loaded.privateOverlayAddress]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // Save both signed hints even if this Apple device has not joined Tailscale yet.
        for candidate in candidates {
            routeRegistration.rememberPrivateOverlay(hostname: candidate, basedOn: route)
        }
        for candidate in candidates {
            guard generation == privateRouteVerificationGeneration, !Task.isCancelled else {
                return nil
            }
            do {
                try await routeRegistration.registerPrivateOverlay(
                    hostname: candidate,
                    basedOn: route
                )
                guard generation == privateRouteVerificationGeneration else { return nil }
                verifiedPrivateRouteHostname = candidate
            } catch {
                // Keep any route already authenticated; another address can be temporarily unavailable.
            }
        }
        if verifiedPrivateRouteHostname != nil { return nil }
        return String(
            localized: """
                The Spark reports a private route, but this Apple device could not \
                authenticate it. Stay on the local network and refresh after checking \
                Tailscale.
                """
        )
    }

    func enableRemote(
        previewDigest: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        do {
            return try await runtime.enableRemote(
                route: activeRemoteRoute,
                body: EnableRemoteRequest(
                    mode: .privateOverlay,
                    acceptedPreviewDigest: previewDigest
                ),
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
        }

        try await enrollPresenceKey()
        let retryPresence = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm using this Spark's existing Tailscale connection."
            )
        )
        return try await runtime.enableRemote(
            route: activeRemoteRoute,
            body: EnableRemoteRequest(
                mode: .privateOverlay,
                acceptedPreviewDigest: previewDigest
            ),
            idempotencyKey: idempotencyKey,
            userPresence: retryPresence
        )
    }

    func disableRemote(
        previewDigest: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        do {
            return try await runtime.disableRemote(
                route: activeRemoteRoute,
                acceptedPreviewDigest: previewDigest,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else {
                throw error
            }
        }

        try await enrollPresenceKey()
        let retryPresence = try await userPresenceAuthorizer.authorize(
            localizedReason: status?.mode == .privateOverlay
                ? String(
                    localized: "Confirm stopping SparkPilot from using this Spark's private route."
                )
                : String(localized: "Confirm turning off remote access to this Spark.")
        )
        return try await runtime.disableRemote(
            route: activeRemoteRoute,
            acceptedPreviewDigest: previewDigest,
            idempotencyKey: idempotencyKey,
            userPresence: retryPresence
        )
    }

    func enrollPresenceKey() async throws {
        guard let presenceEnrollmentProvider else {
            throw APIError(
                .local(message: String(localized: "Presence-key enrollment is unavailable.")),
                code: "USER_PRESENCE_ENROLLMENT_UNAVAILABLE"
            )
        }
        let presence = try await userPresenceAuthorizer.authorize(
            localizedReason: String(
                localized: "Confirm upgrading protected actions for this Apple device."
            )
        )
        let idempotencyKey = presenceEnrollmentKey ?? UUID()
        presenceEnrollmentKey = idempotencyKey
        do {
            _ = try await presenceEnrollmentProvider.enrollPresenceKey(
                route: activeRemoteRoute,
                idempotencyKey: idempotencyKey,
                userPresence: presence
            )
            presenceEnrollmentKey = nil
        } catch {
            if Self.isDefinitiveRejection(error) { presenceEnrollmentKey = nil }
            throw error
        }
    }

    static func isDefinitiveRejection(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return false }
        return (400...499).contains(status)
    }
}

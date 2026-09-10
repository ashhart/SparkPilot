import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

/// Manages signed status and owner-reviewed private-overlay routes using the owner’s Tailscale account.
public protocol RemoteAccessReading: Sendable {
    func remoteStatus(route: URL) async throws -> RemoteStatus
    func refreshRemoteHealth(route: URL) async throws -> RemoteStatus
    func remoteOverlaySetup(route: URL) async throws -> RemoteOverlaySetup
    func remoteOverlayPreferences(route: URL) async throws -> GeneratedAPI.RemoteOverlayPreferences
    func configureRemoteOverlay(
        route: URL,
        body: GeneratedAPI.ConfigureRemoteOverlayRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation
    func previewRemoteEnable(
        route: URL,
        body: RemotePreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func enableRemote(
        route: URL,
        body: EnableRemoteRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
    func previewRemoteDisable(
        route: URL,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview
    func disableRemote(
        route: URL,
        acceptedPreviewDigest: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation
}

extension SparkAPIClient: RemoteAccessReading {}

/// Remembers signed route hints separately from proof that they answer with the paired identity.
@MainActor
public protocol RemoteAccessRouteRegistering: Sendable {
    func rememberPrivateOverlay(hostname: String, basedOn currentRoute: URL)
    func registerPrivateOverlay(hostname: String, basedOn currentRoute: URL) async throws
    func unregisterPrivateOverlay(currentRoute: URL)
}

extension RemoteAccessRouteRegistering {
    public func rememberPrivateOverlay(hostname: String, basedOn currentRoute: URL) {}
}

extension RemoteAccessReading {
    public func remoteOverlayPreferences(route: URL) async throws
        -> GeneratedAPI.RemoteOverlayPreferences
    {
        throw APIError(
            .local(message: String(localized: "Tailscale settings are unavailable.")),
            code: "TAILSCALE_PREFERENCES_UNAVAILABLE"
        )
    }

    public func configureRemoteOverlay(
        route: URL,
        body: GeneratedAPI.ConfigureRemoteOverlayRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw APIError(
            .local(message: String(localized: "Tailscale settings are unavailable.")),
            code: "TAILSCALE_PREFERENCES_UNAVAILABLE"
        )
    }

    /// An older runtime has no setup endpoint; the app then treats Tailscale setup as unavailable from here.
    public func remoteOverlaySetup(route _: URL) async throws -> RemoteOverlaySetup {
        RemoteOverlaySetup(state: .unavailable)
    }

    /// A reader that cannot force a recheck degrades to a plain status read.
    public func refreshRemoteHealth(route: URL) async throws -> RemoteStatus {
        try await remoteStatus(route: route)
    }

    public func previewRemoteEnable(
        route _: URL,
        body _: RemotePreviewRequest,
        idempotencyKey _: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw APIError(
            .local(message: String(localized: "Remote access enablement is unavailable.")),
            code: "REMOTE_ENABLE_UNAVAILABLE"
        )
    }

    public func enableRemote(
        route _: URL,
        body _: EnableRemoteRequest,
        idempotencyKey _: UUID,
        userPresence _: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw APIError(
            .local(message: String(localized: "Remote access enablement is unavailable.")),
            code: "REMOTE_ENABLE_UNAVAILABLE"
        )
    }

    public func previewRemoteDisable(
        route _: URL,
        idempotencyKey _: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        throw APIError(
            .local(message: String(localized: "Remote access review is unavailable.")),
            code: "REMOTE_PREVIEW_UNAVAILABLE"
        )
    }

    public func disableRemote(
        route _: URL,
        acceptedPreviewDigest _: String,
        idempotencyKey _: UUID,
        userPresence _: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw APIError(
            .local(message: String(localized: "Remote access disablement is unavailable.")),
            code: "REMOTE_DISABLE_UNAVAILABLE"
        )
    }
}

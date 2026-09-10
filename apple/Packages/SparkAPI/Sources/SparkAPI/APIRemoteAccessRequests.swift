import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// `GET /api/v1/remote` returns remote-access status.
    public func remoteStatus(route base: URL) async throws -> RemoteStatus {
        try await get(base.appendingPathComponent("api/v1/remote"))
    }

    /// Reconcile remote health without changing mode, so refresh needs no mutation review or presence proof.
    public func refreshRemoteHealth(route base: URL) async throws -> RemoteStatus {
        try await post(
            base.appendingPathComponent("api/v1/remote/refresh"),
            body: NoBody?.none,
            idempotencyKey: UUID(),
            timeoutInterval: 60
        )
    }

    /// `GET /api/v1/remote/overlay/setup` — the Spark's Tailscale state and, while an enable waits, the owner's sign-in link.
    public func remoteOverlaySetup(route base: URL) async throws -> RemoteOverlaySetup {
        try await get(base.appendingPathComponent("api/v1/remote/overlay/setup"))
    }

    public func remoteOverlayPreferences(route base: URL) async throws
        -> GeneratedAPI.RemoteOverlayPreferences
    {
        try await get(base.appendingPathComponent("api/v1/remote/overlay/preferences"))
    }

    public func configureRemoteOverlay(
        route base: URL,
        body: GeneratedAPI.ConfigureRemoteOverlayRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        guard (body.enabled != nil) != (body.acceptDns != nil) else {
            throw APIError(
                .local(message: String(localized: "Change exactly one Tailscale preference.")),
                code: "TAILSCALE_SETTING_INVALID"
            )
        }
        return try await post(
            base.appendingPathComponent("api/v1/remote/overlay/preferences"),
            body: body,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func previewRemoteEnable(
        route base: URL,
        body: RemotePreviewRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            base.appendingPathComponent("api/v1/remote/enable/preview"),
            body: body,
            idempotencyKey: idempotencyKey
        )
    }

    /// `POST /api/v1/remote/enable` — accepted operation (202).
    public func enableRemote(
        route base: URL,
        body: EnableRemoteRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            base.appendingPathComponent("api/v1/remote/enable"),
            body: body,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func previewRemoteDisable(
        route base: URL,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            base.appendingPathComponent("api/v1/remote/disable/preview"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey
        )
    }

    /// `POST /api/v1/remote/disable` — accepted operation (202).
    public func disableRemote(
        route base: URL,
        acceptedPreviewDigest: String,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            base.appendingPathComponent("api/v1/remote/disable"),
            body: DisableRemoteRequest(acceptedPreviewDigest: acceptedPreviewDigest),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}

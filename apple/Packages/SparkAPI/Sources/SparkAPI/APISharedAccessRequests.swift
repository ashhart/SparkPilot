import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// `GET /api/v1/shared-access`. Owner only: every guest, their limits and what they have used.
    public func sharedAccess(route base: URL) async throws -> GeneratedAPI.SharedAccessOverview {
        try await get(endpoint(base, "api", "v1", "shared-access"))
    }

    /// `GET /api/v1/shared-access/self`. What this device may read about its own guest access.
    public func ownSharedAccess(route base: URL) async throws -> GeneratedAPI.SharedAccessSelf {
        try await get(endpoint(base, "api", "v1", "shared-access", "self"))
    }

    /// `POST /api/v1/shared-access/invitations`. The owner shares the Spark with one friend.
    public func createSharedAccessInvitation(
        route base: URL,
        limits: GeneratedAPI.CreateSharedAccessInvitation,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessInvitation {
        try await post(
            endpoint(base, "api", "v1", "shared-access", "invitations"),
            body: limits,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// `PATCH /api/v1/shared-access/{deviceId}`. Confirm, pause or re-limit one guest.
    public func updateSharedAccess(
        route base: URL,
        deviceID: String,
        change: GeneratedAPI.UpdateSharedAccess,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessGuest {
        try await presenceMutation(
            method: "PATCH",
            url: endpoint(base, "api", "v1", "shared-access", deviceID),
            body: change,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// `DELETE /api/v1/shared-access/{deviceId}`. Withdraw a guest's access at once.
    public func revokeSharedAccess(
        route base: URL,
        deviceID: String,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessRevocation {
        try await presenceMutation(
            method: "DELETE",
            url: endpoint(base, "api", "v1", "shared-access", deviceID),
            body: Optional<GeneratedAPI.UpdateSharedAccess>.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// Sign a mutation with a fresh presence proof for a verb the shared helpers do not cover.
    private func presenceMutation<B: Encodable, T: Decodable>(
        method: String,
        url: URL,
        body: B?,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        var encoded = Data()
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encoded
        }
        guard let signer = signer as? any UserPresenceRequestSigning else {
            throw APIError(
                .userPresenceProofUnavailable,
                code: "USER_PRESENCE_SIGNER_UNAVAILABLE"
            )
        }
        request = try await signer.authorizeWithUserPresence(
            request,
            body: encoded,
            userPresence: userPresence
        )
        let (data, http) = try await transport.perform(request)
        try validate(http: http, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(
                .malformedResponse,
                statusCode: http.statusCode,
                diagnosticDetail: "decode failed: \(error)"
            )
        }
    }
}

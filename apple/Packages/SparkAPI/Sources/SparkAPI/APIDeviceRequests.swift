import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// `GET /api/v1/devices` using the generated device schema.
    public func devices(route base: URL) async throws -> [GeneratedAPI.Device] {
        let response: GeneratedAPI.ListDevicesResponse200 = try await get(
            endpoint(base, "api", "v1", "devices")
        )
        return response.items
    }

    /// `DELETE /api/v1/devices/{deviceId}`. A successful response has no body.
    public func revokeDevice(
        route base: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        try await deleteNoContent(
            endpoint(base, "api", "v1", "devices", deviceID),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// Check the returned presence-key fingerprint against the local canonical point during compatibility enrollment.
    public func enrollPresenceKey(
        route base: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        var request = URLRequest(
            url: endpoint(base, "api", "v1", "devices", "self", "presence-key")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        guard let signer = signer as? any UserPresenceRequestSigning else {
            throw APIError(
                .userPresenceEnrollmentUnavailable,
                code: "USER_PRESENCE_SIGNER_UNAVAILABLE"
            )
        }
        let authorized = try await signer.authorizePresenceKeyEnrollment(
            request,
            userPresence: userPresence
        )
        var signedRequest = authorized.request
        signedRequest.httpBody = authorized.body
        let (data, http) = try await transport.perform(signedRequest)
        try validate(http: http, data: data)
        let result: PresenceKeyEnrollmentWireResponse
        do {
            result = try decoder.decode(PresenceKeyEnrollmentWireResponse.self, from: data)
        } catch {
            throw APIError(
                .malformedResponse,
                statusCode: http.statusCode,
                diagnosticDetail: "decode failed: \(error)"
            )
        }
        let expected = try userPresence.keyInfo.pairingFingerprint()
        guard result.presenceKeyFingerprint == expected else {
            throw APIError(
                .userPresenceFingerprintMismatch,
                statusCode: http.statusCode,
                code: "USER_PRESENCE_KEY_FINGERPRINT_MISMATCH"
            )
        }
        return result.presenceKeyFingerprint
    }

    /// An owner or administrator issues a signed, short-lived, single-use invitation with an explicit role and no embedded credentials (§15.3).
    public func createPairingInvitation(
        route base: URL,
        role: String,
        expiresInSeconds: Int = 300,
        deviceNameHint: String? = nil,
        idempotencyKey: UUID = UUID(),
        userPresence: (any UserPresenceProofSigning)? = nil
    ) async throws -> PairingInvitation {
        let url = base.appendingPathComponent("api/v1/pairing/invitations")
        let body = CreatePairingInvitationRequest(
            role: role,
            expiresInSeconds: expiresInSeconds,
            deviceNameHint: deviceNameHint
        )
        if let userPresence {
            return try await post(
                url,
                body: body,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        }
        return try await post(url, body: body, idempotencyKey: idempotencyKey)
    }

    /// Bind a multi-Spark invitation to the exact approved Apple device identity through the node-authority signature.
    public func createBoundPairingInvitation(
        route base: URL,
        role: String,
        expiresInSeconds: Int = 300,
        recipientDeviceID: UUID,
        recipientPublicKeyFingerprint: String,
        idempotencyKey: UUID = UUID(),
        userPresence: (any UserPresenceProofSigning)? = nil
    ) async throws -> PairingInvitation {
        let url = base.appendingPathComponent("api/v1/pairing/invitations")
        let body = CreatePairingInvitationRequest(
            role: role,
            expiresInSeconds: expiresInSeconds,
            deviceNameHint: nil,
            recipientDeviceID: recipientDeviceID,
            recipientPublicKeyFingerprint: recipientPublicKeyFingerprint
        )
        if let userPresence {
            return try await post(
                url,
                body: body,
                idempotencyKey: idempotencyKey,
                userPresence: userPresence
            )
        }
        return try await post(url, body: body, idempotencyKey: idempotencyKey)
    }
}

private struct PresenceKeyEnrollmentWireResponse: Decodable {
    let presenceKeyFingerprint: String

    enum CodingKeys: String, CodingKey {
        case presenceKeyFingerprint = "presence_key_fingerprint"
    }
}

/// `POST /api/v1/pairing/invitations` request body.
public struct CreatePairingInvitationRequest: Encodable, Sendable, Equatable {
    public let role: String
    public let expiresInSeconds: Int
    public let deviceNameHint: String?
    public let recipientDeviceID: UUID?
    public let recipientPublicKeyFingerprint: String?

    /// - Parameter expiresInSeconds: Clamp to the contract range of 60–3600 seconds before submission.
    public init(
        role: String,
        expiresInSeconds: Int,
        deviceNameHint: String? = nil,
        recipientDeviceID: UUID? = nil,
        recipientPublicKeyFingerprint: String? = nil
    ) {
        self.role = role
        self.expiresInSeconds = min(max(expiresInSeconds, 60), 3_600)
        self.deviceNameHint = deviceNameHint
        self.recipientDeviceID = recipientDeviceID
        self.recipientPublicKeyFingerprint = recipientPublicKeyFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case role
        case expiresInSeconds = "expires_in_seconds"
        case deviceNameHint = "device_name_hint"
        case recipientDeviceID = "recipient_device_id"
        case recipientPublicKeyFingerprint = "recipient_public_key_fingerprint"
    }
}

import Foundation
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// Pair unsigned using a short-lived, single-use authority-signed invitation and device-key proof of possession.
public struct PairingClient: Sendable {
    private let transport: any PinnedHTTPTransport
    private let decoder: JSONDecoder

    /// Restrict custom transports to SPI tests; shipping pairing constructs its own pinned transport from the node certificate.
    @_spi(SparkTestSupport)
    public init(transport: any PinnedHTTPTransport) {
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    /// - Parameter pin: The node's tls_fingerprint used to construct a non-substitutable pinned transport.
    public init(pin: String) throws {
        self.transport = try URLSessionPinnedTransport(pin: pin)
        self.decoder = JSONDecoder()
    }

    /// Record the certificate pin alongside the identity learned through the paired connection.
    public var pin: String { transport.pin }

    /// `POST /api/v1/pairing/challenge`
    public func challenge(
        route base: URL,
        invitationID: UUID,
        devicePublicKeySPKI: Data
    ) async throws -> PairingChallengeResponse {
        try await post(
            base.appendingPathComponent("api/v1/pairing/challenge"),
            body: PairingChallengeRequest(
                invitationID: invitationID,
                devicePublicKeySPKI: devicePublicKeySPKI.base64EncodedString()
            ),
            expecting: 200
        )
    }

    /// `POST /api/v1/pairing/claim` — 201 on success.
    public func claim(
        route base: URL,
        request: PairingClaimRequest
    ) async throws -> PairingClaimResponse {
        try await post(
            base.appendingPathComponent("api/v1/pairing/claim"),
            body: request,
            expecting: 201
        )
    }

    private func post<B: Encodable, T: Decodable>(
        _ url: URL,
        body: B,
        expecting status: Int
    ) async throws -> T {
        guard url.scheme?.lowercased() == "https" else {
            throw APIError(.insecureTransport, diagnosticDetail: "pairing requires https")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await transport.perform(request)
        guard http.statusCode == status else {
            // Preserve typed refusal distinctions so expired invitations and existing owners receive different recovery guidance.
            throw APIError(
                PairingClient.failure(status: http.statusCode),
                statusCode: http.statusCode,
                diagnosticDetail: PairingClient.diagnostic(body: data)
            )
        }
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

    /// Classify pairing refusal by status without displaying unauthenticated response text.
    static func failure(status: Int) -> APIFailure {
        switch status {
        case 401, 403: .invitationRefused
        case 404: .invitationUnknown
        case 409: .invitationAlreadyUsed
        case 410: .invitationExpired
        default: .unexpectedStatus
        }
    }

    /// Retain bounded response diagnostics internally without exporting or exposing them to presenters.
    static func diagnostic(body: Data) -> String {
        String(decoding: body.prefix(1000), as: UTF8.self)
    }
}

/// Encode the contract-defined pairing challenge request body.
public struct PairingChallengeRequest: Encodable, Sendable, Equatable {
    public let invitationID: UUID
    /// Standard base64 of the device's SubjectPublicKeyInfo DER.
    public let devicePublicKeySPKI: String

    public init(invitationID: UUID, devicePublicKeySPKI: String) {
        self.invitationID = invitationID
        self.devicePublicKeySPKI = devicePublicKeySPKI
    }

    enum CodingKeys: String, CodingKey {
        case invitationID = "invitation_id"
        case devicePublicKeySPKI = "device_public_key_spki"
    }
}

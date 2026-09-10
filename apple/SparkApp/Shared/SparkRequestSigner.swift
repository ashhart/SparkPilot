import Foundation
import SparkAPI
import SparkSecurity

/// Sign SPARK2 method, target, timestamp, nonce, body digest, device ID and trusted recipient node ID (§37.1/§58.3).
public struct SparkRequestSigner: UserPresenceRequestSigning {
    private let nodeID: UUID
    private let deviceID: String
    private let signingKey: any SendableDeviceSigning
    private let now: @Sendable () -> Date

    var eventCursorIdentity: String {
        "\(nodeID.uuidString.lowercased())\n\(deviceID.lowercased())"
    }

    public init(
        deviceID: String,
        nodeID: UUID,
        signingKey: any SendableDeviceSigning,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.nodeID = nodeID
        self.deviceID = deviceID
        self.signingKey = signingKey
        self.now = now
    }

    public func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
        let authorization = try canonicalRequest(for: request, body: body)
        return try applyNormalSignature(to: request, canonical: authorization.canonical)
    }

    public func authorizeWithUserPresence(
        _ request: URLRequest,
        body: Data,
        userPresence: any UserPresenceProofSigning
    ) async throws -> URLRequest {
        let authorization = try canonicalRequest(for: request, body: body)
        let canonical = authorization.canonical
        let presenceCanonical = try UserPresenceCanonicalRequest(
            method: canonical.method,
            pathAndQuery: canonical.pathAndQuery,
            timestamp: canonical.timestamp,
            nonce: canonical.nonce,
            bodyHashHex: canonical.bodyHashHex,
            deviceID: canonical.deviceID,
            expiresAt: Self.timestamp(authorization.issuedAt.addingTimeInterval(60)),
            nodeID: nodeID
        )
        let proof = try await userPresence.proof(for: presenceCanonical)
        var requestWithPresence = request
        requestWithPresence.setValue(
            try proof.headerValue(),
            forHTTPHeaderField: "X-Spark-User-Presence"
        )
        return try applyNormalSignature(to: requestWithPresence, canonical: canonical)
    }

    public func authorizePresenceKeyEnrollment(
        _ request: URLRequest,
        userPresence: any UserPresenceProofSigning
    ) async throws -> PresenceKeyEnrollmentAuthorization {
        let seed = try requestSeed(for: request)
        guard let identifier = UUID(uuidString: deviceID) else {
            throw UserPresenceProofError.invalidPairingBinding
        }
        let fingerprint = try userPresence.keyInfo.pairingFingerprint()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(
            PresenceKeyEnrollmentBody(
                presencePublicKeySPKI: userPresence.keyInfo.publicKeySPKIBase64
            )
        )
        let canonical = seed.canonical(body: body, deviceID: deviceID, nodeID: nodeID)
        let binding = try PresenceKeyEnrollmentBinding(
            method: seed.method,
            pathAndQuery: seed.pathAndQuery,
            timestamp: seed.timestamp,
            nonce: seed.nonce,
            contentSHA256: canonical.bodyHashHex,
            deviceID: identifier,
            presenceKeyFingerprint: fingerprint,
            nodeID: nodeID
        )
        let presenceSignature = try await userPresence.signPresenceKeyEnrollment(binding)
        var requestWithProof = request
        requestWithProof.setValue(
            Base64URL.encode(presenceSignature),
            forHTTPHeaderField: "X-Spark-Presence-Key-Proof"
        )
        return PresenceKeyEnrollmentAuthorization(
            request: try applyNormalSignature(to: requestWithProof, canonical: canonical),
            body: body
        )
    }

    private func canonicalRequest(
        for request: URLRequest,
        body: Data
    ) throws -> (canonical: CanonicalRequest, issuedAt: Date) {
        let seed = try requestSeed(for: request)
        return (seed.canonical(body: body, deviceID: deviceID, nodeID: nodeID), seed.issuedAt)
    }

    private func requestSeed(for request: URLRequest) throws -> RequestSeed {
        // Reject missing or unparsable request URLs as invalid input instead of crashing the signer.
        guard let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                ?? URLComponents(url: url, resolvingAgainstBaseURL: true)
        else {
            throw SparkRequestSignerError.unusableRequestURL
        }
        let pathAndQuery =
            components.percentEncodedPath
            + (components.percentEncodedQuery.map { "?\($0)" } ?? "")

        let issuedAt = now()
        return RequestSeed(
            method: request.httpMethod ?? "GET",
            pathAndQuery: pathAndQuery,
            timestamp: Self.timestamp(issuedAt),
            nonce: try Base64URL.encode(SecureRandom.nonce()),
            issuedAt: issuedAt
        )
    }

    private func applyNormalSignature(
        to request: URLRequest,
        canonical: CanonicalRequest
    ) throws -> URLRequest {
        var signed = request
        for (name, value) in try canonical.headers(signingKey: { input in
            try signingKey.sign(input)
        }) {
            signed.setValue(value, forHTTPHeaderField: name)
        }
        return signed
    }

    /// RFC3339 UTC with second precision, matching the runtime's window.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private struct RequestSeed {
        let method: String
        let pathAndQuery: String
        let timestamp: String
        let nonce: String
        let issuedAt: Date

        func canonical(body: Data, deviceID: String, nodeID: UUID) -> CanonicalRequest {
            CanonicalRequest(
                method: method,
                pathAndQuery: pathAndQuery,
                timestamp: timestamp,
                nonce: nonce,
                bodyHashHex: SHA256Digest.hex(body),
                deviceID: deviceID,
                nodeID: nodeID
            )
        }
    }

    private struct PresenceKeyEnrollmentBody: Encodable {
        let presencePublicKeySPKI: String

        enum CodingKeys: String, CodingKey {
            case presencePublicKeySPKI = "presence_public_key_spki"
        }
    }
}

/// A request this signer cannot canonicalise.
public enum SparkRequestSignerError: Error, Equatable, Sendable {
    /// Reject requests lacking a URL that can supply canonical path and query bytes.
    case unusableRequestURL
}

/// Load the stable device identity through Secure Enclave-first key creation with software fallback.
public enum DeviceIdentityStore {
    static let deviceIDKey = "spark.device.id"

    /// Persists a stable lowercase device UUID matching Rust's spelling in signed material.
    public static func loadOrCreateDeviceID(defaults: UserDefaults = .standard) -> UUID {
        if let stored = defaults.string(forKey: deviceIDKey),
            let parsed = UUID(uuidString: stored)
        {
            return parsed
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString.lowercased(), forKey: deviceIDKey)
        return fresh
    }

    public static func loadOrCreateSigner(
        nodeID: UUID,
        defaults: UserDefaults = .standard,
        store: any SecureStore = KeychainStore()
    ) throws -> SparkRequestSigner {
        let deviceID = loadOrCreateDeviceID(defaults: defaults).uuidString.lowercased()
        // Receive SendableDeviceSigning directly so both Secure Enclave and software signers satisfy the request-signing contract.
        let signer = try DeviceKeyFactory.makeSigner(store: store)
        return SparkRequestSigner(deviceID: deviceID, nodeID: nodeID, signingKey: signer)
    }
}

// Keep signer protocol conformances beside their implementations in SparkSecurity.

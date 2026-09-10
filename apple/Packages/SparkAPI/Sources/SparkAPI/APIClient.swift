import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// Validate post-mutation route candidates with a fresh request-scoped connection.
public protocol NetworkHandoffIdentityChecking: Sendable {
    func identity(route: URL) async throws -> SparkIdentity
}

public protocol NetworkHandoffIdentityCheckerMaking: NetworkHandoffIdentityChecking {
    func makeNetworkHandoffIdentityChecker() async throws
        -> any NetworkHandoffIdentityChecking
}

extension NetworkHandoffIdentityCheckerMaking {
    public func makeNetworkHandoffIdentityChecker() async throws
        -> any NetworkHandoffIdentityChecking
    {
        self
    }
}

/// Attach typed user-presence proof before the normal SPARK2 signature.
public protocol UserPresenceRequestSigning: RequestSigning {
    func authorizeWithUserPresence(
        _ request: URLRequest,
        body: Data,
        userPresence: any UserPresenceProofSigning
    ) async throws -> URLRequest

    /// Produce both signatures over the same timestamp, nonce and body digest.
    func authorizePresenceKeyEnrollment(
        _ request: URLRequest,
        userPresence: any UserPresenceProofSigning
    ) async throws -> PresenceKeyEnrollmentAuthorization
}

public struct PresenceKeyEnrollmentAuthorization: Sendable {
    public let request: URLRequest
    public let body: Data

    public init(request: URLRequest, body: Data) {
        self.request = request
        self.body = body
    }
}

/// Sign the typed control surface when a signer is attached, with only health and pairing publicly available unsigned (§58.2).
public actor SparkAPIClient: NetworkHandoffIdentityCheckerMaking {
    let transport: any PinnedHTTPTransport
    let decoder: JSONDecoder
    let signer: (any RequestSigning)?
    let retryPolicy: SparkRetryPolicy
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private let pause: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    /// Restrict custom transports to SPI tests; shipping callers use pinned(to:signer:) so a claimed protocol conformance cannot bypass TLS pinning.
    @_spi(SparkTestSupport)
    public init(
        transport: any PinnedHTTPTransport,
        signer: (any RequestSigning)? = nil,
        retryPolicy: SparkRetryPolicy = .standard,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = {
            .random(in: 0...max($0, 0))
        },
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.signer = signer
        self.retryPolicy = retryPolicy
        self.jitter = jitter
        self.pause = pause
        self.now = now
    }

    /// The certificate this client is bound to.
    public var pin: String { transport.pin }

    /// Bind to tls_fingerprint, the SHA-256 of the leaf certificate DER, never the unrelated authority-key fingerprint.
    public static func pinned(
        to pin: String,
        signer: (any RequestSigning)? = nil
    ) throws -> SparkAPIClient {
        SparkAPIClient(
            transport: try URLSessionPinnedTransport(pin: pin),
            signer: signer
        )
    }

    /// Share signed, pinned mutation execution internally without widening the shipping public API.
    func post<B: Encodable, T: Decodable>(
        _ url: URL,
        body: B?,
        idempotencyKey: UUID,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        try await mutation(
            method: "POST",
            url: url,
            body: body,
            idempotencyKey: idempotencyKey,
            userPresence: nil,
            timeoutInterval: timeoutInterval
        )
    }

    func post<B: Encodable, T: Decodable>(
        _ url: URL,
        body: B?,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let encoded = try body.map {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode($0)
        }
        request.httpBody = encoded
        guard let signer = signer as? any UserPresenceRequestSigning else {
            throw APIError(
                .userPresenceProofUnavailable,
                code: "USER_PRESENCE_SIGNER_UNAVAILABLE"
            )
        }
        request = try await signer.authorizeWithUserPresence(
            request,
            body: encoded ?? Data(),
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

    /// Any signed method with a fresh presence proof, so PUT and PATCH need no separate primitive.
    func presenceMutation<B: Encodable, T: Decodable>(
        method: String,
        url: URL,
        body: B?,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let encoded = try body.map {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode($0)
        }
        request.httpBody = encoded
        guard let signer = signer as? any UserPresenceRequestSigning else {
            throw APIError(
                .userPresenceProofUnavailable,
                code: "USER_PRESENCE_SIGNER_UNAVAILABLE"
            )
        }
        request = try await signer.authorizeWithUserPresence(
            request,
            body: encoded ?? Data(),
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

    /// A presence-proved read with a POST body creates no durable mutation or replay key.
    func postWithoutReplayKey<B: Encodable, T: Decodable>(
        _ url: URL,
        body: B,
        userPresence: any UserPresenceProofSigning,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(body)
        request.httpBody = encoded
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

    func delete<B: Encodable, T: Decodable>(
        _ url: URL,
        body: B,
        idempotencyKey: UUID,
        userPresence: String?
    ) async throws -> T {
        try await mutation(
            method: "DELETE",
            url: url,
            body: body,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    func deleteNoContent(
        _ url: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        guard let signer = signer as? any UserPresenceRequestSigning else {
            throw APIError(
                .userPresenceProofUnavailable,
                code: "USER_PRESENCE_SIGNER_UNAVAILABLE"
            )
        }
        request = try await signer.authorizeWithUserPresence(
            request,
            body: Data(),
            userPresence: userPresence
        )
        let (data, http) = try await transport.perform(request)
        try validate(http: http, data: data)
    }

    func mutation<B: Encodable, T: Decodable>(
        method: String,
        url: URL,
        body: B?,
        idempotencyKey: UUID,
        userPresence: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        if let userPresence {
            request.setValue(userPresence, forHTTPHeaderField: "X-Spark-User-Presence")
        }
        let encoded = try body.map {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode($0)
        }
        request.httpBody = encoded
        // A single-use presence proof cannot be replayed, so a presence-proved mutation gets one attempt.
        let (data, http) = try await send(
            request,
            body: encoded,
            retry: userPresence == nil ? retryPolicy : .none
        )
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

    func get<T: Decodable>(_ url: URL, timeoutInterval: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: url)
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await send(request, body: nil, retry: retryPolicy)
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

    /// Apply §38.2, signing each attempt afresh and letting `Retry-After` set the pace.
    func send(
        _ request: URLRequest,
        body: Data?,
        retry: SparkRetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            var signed = request
            try applySigning(to: &signed, body: body)
            do {
                let (data, http) = try await transport.perform(signed)
                guard attempt < retry.maximumAttempts,
                    SparkRetryPolicy.statusIsRetryable(http.statusCode)
                else { return (data, http) }
                try await pause(
                    retry.delay(
                        afterAttempt: attempt,
                        retryAfter: SparkRetryAfter.seconds(
                            from: http.value(forHTTPHeaderField: "Retry-After"),
                            now: now()
                        ),
                        jitter: jitter
                    )
                )
            } catch {
                guard attempt < retry.maximumAttempts,
                    SparkRetryPolicy.transportFailureIsRetryable(error)
                else { throw error }
                try await pause(
                    retry.delay(afterAttempt: attempt, retryAfter: nil, jitter: jitter)
                )
            }
        }
    }

    func validate(http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        if let envelope = try? decoder.decode(GeneratedAPI.ErrorEnvelope.self, from: data) {
            throw APIError(
                .reported,
                statusCode: http.statusCode,
                code: envelope.error.code,
                diagnosticDetail: envelope.error.message
            )
        }
        throw APIError(.unexpectedStatus, statusCode: http.statusCode)
    }

    /// Encode each opaque path segment independently so slashes inside model IDs remain part of that ID.
    func endpoint(_ base: URL, _ pathComponents: String...) -> URL {
        var absolute = base.absoluteString
        while absolute.hasSuffix("/") { absolute.removeLast() }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        for component in pathComponents {
            let encoded =
                component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
            absolute += "/\(encoded)"
        }
        // Return a failing request instead of trapping if a percent-encoded component still cannot form a URL.
        return URL(string: absolute) ?? base
    }

    /// Propagate signing failures before sending any request bytes.
    func applySigning(to request: inout URLRequest, body: Data?) throws {
        guard let signer else { return }
        request = try signer.authorize(request, body: body ?? Data())
    }
}

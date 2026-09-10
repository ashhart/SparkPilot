import Foundation
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// Advertise Mac build capabilities without exporting signing identities or provisioning profiles (§43.3).
public struct BuildWorkerCapabilities: Codable, Equatable, Sendable {
    public var platform: String
    public var xcodeVersion: String
    public var sdkVersions: [String]
    public var architectures: [String]
    public var simulators: [String]
    public var signingAvailable: Bool
    public var maxConcurrentJobs: Int

    public init(
        platform: String = "macOS",
        xcodeVersion: String,
        sdkVersions: [String] = [],
        architectures: [String] = ["arm64"],
        simulators: [String] = [],
        signingAvailable: Bool = false,
        maxConcurrentJobs: Int = 1
    ) {
        self.platform = platform
        self.xcodeVersion = xcodeVersion
        self.sdkVersions = sdkVersions
        self.architectures = architectures
        self.simulators = simulators
        self.signingAvailable = signingAvailable
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case xcodeVersion = "xcode_version"
        case sdkVersions = "sdk_versions"
        case architectures
        case simulators
        case signingAvailable = "signing_available"
        case maxConcurrentJobs = "max_concurrent_jobs"
    }
}

extension GeneratedAPI.BuildWorkerRegistration {
    /// Accept locally grouped worker capabilities while preserving the flat OpenAPI wire shape.
    public init(workerID: String, capabilities: BuildWorkerCapabilities) {
        self.init(
            workerId: workerID,
            platform: .macOS,
            xcodeVersion: capabilities.xcodeVersion,
            sdkVersions: capabilities.sdkVersions,
            architectures: capabilities.architectures,
            simulators: capabilities.simulators,
            signingAvailable: capabilities.signingAvailable,
            maxConcurrentJobs: capabilities.maxConcurrentJobs
        )
    }
}

/// A build job a developer submitted (§43.4).
public struct BuildJobRequest: Codable, Equatable, Sendable {
    public var projectID: String
    public var commit: String
    public var sourceSHA256: String
    public var scheme: String
    public var configuration: String
    public var destination: String
    public var actions: [String]
    public var timeoutSeconds: Int

    public init(
        projectID: String,
        commit: String,
        sourceSHA256: String,
        scheme: String = "SparkApp",
        configuration: String = "Debug",
        destination: String = "platform=macOS",
        actions: [String] = ["build"],
        timeoutSeconds: Int = 1800
    ) {
        self.projectID = projectID
        self.commit = commit
        self.sourceSHA256 = sourceSHA256
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.actions = actions
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case commit
        case sourceSHA256 = "source_sha256"
        case scheme
        case configuration
        case destination
        case actions
        case timeoutSeconds = "timeout_seconds"
    }
}

/// Worker-reported result payload (§43.5).
public struct BuildResultPayload: Codable, Equatable, Sendable {
    public var exitState: String
    public var output: String
    public var xcresult: String?
    public var testFailures: [String]
    public var screenshots: [String]
    public var diagnostics: [String]

    private enum CodingKeys: String, CodingKey {
        case exitState = "exit_state"
        case output
        case xcresult
        case testFailures = "test_failures"
        case screenshots
        case diagnostics
    }
}

/// Use caller-supplied RequestSigning for the typed Mac build-worker API (§43).
public actor BuildClient {
    private let baseURL: URL
    private let transport: URLSessionPinnedTransport
    private let signer: (any RequestSigning)?

    /// Require HTTPS and the node's tls_fingerprint for build registration, source retrieval and signed result submission.
    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil
    ) throws {
        try self.init(baseURL: baseURL, pin: pin, signer: signer, interceptingWith: [])
    }

    /// Allow SPI tests to intercept requests using protocol classes without replacing hardened session configuration.
    @_spi(SparkTestSupport)
    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil,
        interceptingWith protocolClasses: [AnyClass]
    ) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw PinnedTransportError.insecureScheme(baseURL.scheme ?? "none")
        }
        guard URLSessionPinnedTransport.isFingerprint(pin) else {
            throw PinnedTransportError.malformedPin(pin)
        }
        self.baseURL = baseURL
        self.transport = try URLSessionPinnedTransport(pin: pin, interceptingWith: protocolClasses)
        self.signer = signer
    }

    /// `POST /api/v1/builds` — returns the operation id.
    public func submit(
        _ request: BuildJobRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> String {
        let (data, response) = try await send(
            "POST",
            pathComponents: ["api", "v1", "builds"],
            body: try JSONEncoder().encode(request),
            idempotencyKey: idempotencyKey
        )
        try Self.validate(response)
        struct Operation: Decodable { let id: String }
        return try JSONDecoder().decode(Operation.self, from: data).id
    }

    public struct Submission: Sendable, Equatable {
        public let operationID: String
        public let buildID: String

        public init(operationID: String, buildID: String) {
            self.operationID = operationID
            self.buildID = buildID
        }
    }

    public func submitTracked(
        _ request: GeneratedAPI.BuildJobRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> Submission {
        let (data, response) = try await send(
            "POST",
            pathComponents: ["api", "v1", "builds"],
            body: try Self.encoder.encode(request),
            idempotencyKey: idempotencyKey
        )
        try Self.validate(response)
        let operation = try JSONDecoder().decode(GeneratedAPI.Operation.self, from: data)
        guard let buildID = operation.resourceId, UUID(uuidString: buildID) != nil else {
            throw BuildClientError.missingBuildID
        }
        return Submission(operationID: operation.id, buildID: buildID)
    }

    /// `GET /api/v1/builds/{id}` — status + result.
    public func status(buildID: String) async throws -> (
        status: String, result: BuildResultPayload?
    ) {
        let (data, response) = try await send(
            "GET",
            pathComponents: ["api", "v1", "builds", buildID],
            body: nil
        )
        try Self.validate(response)
        struct Build: Decodable {
            let status: String
            let result: BuildResultPayload?
        }
        let build = try JSONDecoder().decode(Build.self, from: data)
        return (build.status, build.result)
    }

    public func job(buildID: String) async throws -> GeneratedAPI.BuildJob {
        let (data, response) = try await send(
            "GET",
            pathComponents: ["api", "v1", "builds", buildID],
            body: nil
        )
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.BuildJob.self, from: data)
    }

    public func artifact(
        buildID: String,
        artifactID: String,
        expectedSHA256: String
    ) async throws -> Data {
        let (data, response) = try await send(
            "GET",
            pathComponents: ["api", "v1", "builds", buildID, "artifacts", artifactID],
            body: nil,
            headers: ["Accept": "application/octet-stream"]
        )
        try Self.validate(response)
        guard let http = response as? HTTPURLResponse,
            http.value(forHTTPHeaderField: "X-Spark-Artifact-SHA256") == expectedSHA256,
            SHA256Digest.hex(data) == expectedSHA256
        else { throw BuildClientError.artifactDigestMismatch }
        return data
    }

    public func projects() async throws -> [GeneratedAPI.Project] {
        let (data, response) = try await send(
            "GET",
            pathComponents: ["api", "v1", "projects"],
            body: nil
        )
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.ListProjectsResponse200.self, from: data).items
    }

    /// Generated `BuildWorkerRegistration` payload from OpenAPI (§43.3).
    public typealias RegistrationRequest = GeneratedAPI.BuildWorkerRegistration

    /// `POST /api/v1/build_workers`.
    public func register(
        _ registration: RegistrationRequest,
        idempotencyKey: UUID = UUID()
    ) async throws {
        let (_, response) = try await send(
            "POST",
            pathComponents: ["api", "v1", "build_workers"],
            body: try JSONEncoder().encode(registration),
            idempotencyKey: idempotencyKey
        )
        try Self.validate(response)
    }

    public func heartbeat(
        workerID: UUID,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.BuildWorkerHeartbeat {
        let (data, response) = try await send(
            "POST",
            pathComponents: [
                "api", "v1", "build_workers", workerID.uuidString.lowercased(), "heartbeat",
            ],
            body: nil,
            idempotencyKey: idempotencyKey
        )
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.BuildWorkerHeartbeat.self, from: data)
    }

    public func claim(
        workerID: UUID,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.BuildClaim? {
        let (data, response) = try await send(
            "POST",
            pathComponents: [
                "api", "v1", "build_workers", workerID.uuidString.lowercased(), "claims",
            ],
            body: nil,
            idempotencyKey: idempotencyKey
        )
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.BuildClaim.self, from: data)
    }

    public func renew(
        buildID: String,
        claimToken: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.BuildLeaseRenewal {
        let (data, response) = try await send(
            "POST",
            pathComponents: ["api", "v1", "builds", buildID, "lease"],
            body: nil,
            idempotencyKey: idempotencyKey,
            headers: ["X-Spark-Build-Claim": claimToken]
        )
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.BuildLeaseRenewal.self, from: data)
    }

    public func upload(
        buildID: String,
        claimToken: String,
        artifactToken: String,
        evidence: GeneratedAPI.BuildArtifactEvidence,
        bytes: Data,
        idempotencyKey: UUID = UUID()
    ) async throws {
        let (_, response) = try await send(
            "PUT",
            pathComponents: ["api", "v1", "builds", buildID, "artifacts", evidence.artifactId],
            body: bytes,
            idempotencyKey: idempotencyKey,
            headers: [
                "X-Spark-Build-Claim": claimToken,
                "X-Spark-Artifact-Token": artifactToken,
                "X-Spark-Artifact-SHA256": evidence.sha256,
                "X-Spark-Artifact-Kind": evidence.kind.rawValue,
                "X-Spark-Artifact-Path": evidence.relativePath,
            ],
            contentType: "application/octet-stream"
        )
        try Self.validate(response)
    }

    public func report(
        buildID: String,
        claimToken: String,
        result: GeneratedAPI.SignedBuildResult,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.BuildJob {
        let (data, response) = try await send(
            "POST",
            pathComponents: ["api", "v1", "builds", buildID, "result"],
            body: try Self.encoder.encode(result),
            idempotencyKey: idempotencyKey,
            headers: ["X-Spark-Build-Claim": claimToken]
        )
        try Self.validate(response)
        return try JSONDecoder().decode(GeneratedAPI.BuildJob.self, from: data)
    }

    private func send(
        _ method: String,
        pathComponents: [String],
        body: Data?,
        idempotencyKey: UUID? = nil,
        headers: [String: String] = [:],
        contentType: String = "application/json"
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath ?? ""
        let separator = basePath.hasSuffix("/") ? "" : "/"
        components?.percentEncodedPath =
            basePath + separator
            + pathComponents.map(Self.encodedPathSegment).joined(separator: "/")
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey {
            request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.httpBody = body
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Sign empty-body GET requests too, because build status and diagnostics require SPARK2 device authentication.
        if let signer {
            request = try signer.authorize(request, body: body ?? Data())
        }
        return try await transport.perform(request)
    }

    /// Encode UTF-8 bytes outside RFC 3986 unreserved characters so a supplied percent escape cannot inject a path separator.
    private nonisolated static func encodedPathSegment(_ value: String) -> String {
        value.utf8.map { byte in
            let unreserved =
                byte.isASCIIAlphaNumeric
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
            return unreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    private nonisolated static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BuildClientError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum BuildClientError: Error, Sendable, Equatable {
    case http(Int)
    case missingBuildID
    case artifactDigestMismatch
}

public protocol BuildWorkerNetworking: Sendable {
    func register(
        _ registration: GeneratedAPI.BuildWorkerRegistration,
        idempotencyKey: UUID
    ) async throws
    func heartbeat(workerID: UUID, idempotencyKey: UUID) async throws
        -> GeneratedAPI.BuildWorkerHeartbeat
    func claim(workerID: UUID, idempotencyKey: UUID) async throws
        -> GeneratedAPI.BuildClaim?
    func renew(buildID: String, claimToken: String, idempotencyKey: UUID) async throws
        -> GeneratedAPI.BuildLeaseRenewal
    func upload(
        buildID: String,
        claimToken: String,
        artifactToken: String,
        evidence: GeneratedAPI.BuildArtifactEvidence,
        bytes: Data,
        idempotencyKey: UUID
    ) async throws
    func report(
        buildID: String,
        claimToken: String,
        result: GeneratedAPI.SignedBuildResult,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.BuildJob
}

extension BuildClient: BuildWorkerNetworking {}

public protocol BuildProjectNetworking: Sendable {
    func projects() async throws -> [GeneratedAPI.Project]
    func submitTracked(
        _ request: GeneratedAPI.BuildJobRequest,
        idempotencyKey: UUID
    ) async throws -> BuildClient.Submission
    func job(buildID: String) async throws -> GeneratedAPI.BuildJob
    func artifact(buildID: String, artifactID: String, expectedSHA256: String) async throws -> Data
}

extension BuildClient: BuildProjectNetworking {}

extension UInt8 {
    fileprivate var isASCIIAlphaNumeric: Bool {
        (0x30...0x39).contains(self)
            || (0x41...0x5A).contains(self)
            || (0x61...0x7A).contains(self)
    }
}

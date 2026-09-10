import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

/// Exercise fixed build recipes, public worker capabilities and runtime result decoding.
@Suite(.serialized)
struct BuildClientTests {

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var responseHeaders: [String: String] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBody
            let path = request.url?.path() ?? ""
            let (status, data) = Self.responses[path] ?? Self.responses["*"] ?? (404, Data())
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"].merging(
                    Self.responseHeaders,
                    uniquingKeysWith: { _, override in override }
                )
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// The mock intercepts before TLS, proving construction requires a pin while SparkTransport tests verify enforcement.
    private static let testPin = String(repeating: "a", count: 64)

    private func makeClient(signer: (any RequestSigning)? = nil) throws -> BuildClient {
        return try BuildClient(
            baseURL: URL(string: "https://spark.local:7443")!,
            pin: Self.testPin,
            signer: signer,
            interceptingWith: [MockURLProtocol.self]
        )
    }

    @Test func jobSubmissionUsesTheExactHTTPWireKeysAndImmutableCommit() async throws {
        let client = try makeSignedClient()
        MockURLProtocol.responses = [
            "/api/v1/builds": (
                202,
                Data(#"{"id":"b1111111-2222-3333-4444-555555555555"}"#.utf8)
            )
        ]
        let request = BuildJobRequest(
            projectID: "2f3f6c90-7f5e-4e3a-9f4b-1d1c0b2a3c4d",
            commit: String(repeating: "a", count: 40),
            sourceSHA256: String(repeating: "c", count: 64),
            scheme: "SparkApp",
            configuration: "Debug",
            destination: "platform=iOS Simulator,name=iPad Pro",
            actions: ["build", "test"],
            timeoutSeconds: 1800
        )
        _ = try await client.submit(request)
        let data = try #require(RecordingSigner.signedBodies.first)
        let json = try #require(
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path() == "/api/v1/builds")
        #expect(
            Set(json.keys)
                == Set([
                    "projectId", "commit", "source_sha256", "scheme", "configuration",
                    "destination", "actions", "timeout_seconds",
                ])
        )
        #expect(json["projectId"] as? String == "2f3f6c90-7f5e-4e3a-9f4b-1d1c0b2a3c4d")
        #expect(json["commit"] as? String == String(repeating: "a", count: 40))
        #expect(json["source_sha256"] as? String == String(repeating: "c", count: 64))
        #expect((json["actions"] as? [String]) == ["build", "test"])
        #expect(json["timeout_seconds"] as? Int == 1800)
    }

    @Test func submitAndStatusRoundTrip() async throws {
        let client = try makeClient()
        MockURLProtocol.responses = [
            "/api/v1/builds": (
                202,
                Data(#"{"id":"b1111111-2222-3333-4444-555555555555"}"#.utf8)
            ),
            "/api/v1/builds/b1111111-2222-3333-4444-555555555555": (
                200,
                Data(
                    #"{"build_id":"b1111111-2222-3333-4444-555555555555","project_id":"p","commit":"aaaa","status":"completed","result":{"exit_state":"succeeded","output":"build ok","xcresult":"/tmp/build.xcresult","test_failures":[],"screenshots":[],"diagnostics":[]}}"#
                        .utf8
                )
            ),
        ]

        let operationID = try await client.submit(
            BuildJobRequest(
                projectID: "2f3f6c90-7f5e-4e3a-9f4b-1d1c0b2a3c4d",
                commit: String(repeating: "b", count: 40),
                sourceSHA256: String(repeating: "c", count: 64)
            )
        )
        #expect(operationID == "b1111111-2222-3333-4444-555555555555")

        let (status, result) = try await client.status(buildID: operationID)
        #expect(status == "completed")
        #expect(result?.exitState == "succeeded")
        #expect(result?.xcresult?.hasSuffix("build.xcresult") == true)
    }

    @Test func statusEncodesAnOpaqueBuildIDAsOnePathSegment() async throws {
        let client = try makeClient()
        let buildID = "folder/name ?%#"
        MockURLProtocol.responses = [
            "*": (
                200,
                Data(#"{"status":"queued","result":null}"#.utf8)
            )
        ]

        _ = try await client.status(buildID: buildID)

        let encodedPath = MockURLProtocol.lastRequest?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        #expect(
            encodedPath == "/api/v1/builds/folder%2Fname%20%3F%25%23"
        )
    }

    @Test func registrationNeverCarriesSigningIdentity() async throws {
        var capabilities = BuildWorkerCapabilities(xcodeVersion: "26.6")
        capabilities.signingAvailable = false
        let registration = BuildClient.RegistrationRequest(
            workerID: "w123",
            capabilities: capabilities
        )
        let data = try JSONEncoder().encode(registration)
        let json = try #require(
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["worker_id"] as? String == "w123")
        #expect(json["signing_available"] as? Bool == false)
        #expect(json["architectures"] as? [String] == ["arm64"])
        #expect(json["capabilities"] == nil)
        // No private identity fields are encoded at all.
        let encoded = String(data: data, encoding: .utf8) ?? ""
        #expect(!encoded.localizedCaseInsensitiveContains("identity"))
        #expect(!encoded.localizedCaseInsensitiveContains("profile"))
    }

    @Test func workerClaimsOnlyThroughItsOwnEncodedIdentityRoute() async throws {
        let client = try makeClient()
        let workerID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        MockURLProtocol.responses = ["*": (404, Data())]

        let claim = try await client.claim(workerID: workerID)

        #expect(claim == nil)
        #expect(
            MockURLProtocol.lastRequest?.url?.path()
                == "/api/v1/build_workers/11111111-2222-4333-8444-555555555555/claims"
        )
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test func trackedSubmissionUsesTheBuildResourceNotTheOperationAsIdentity() async throws {
        let client = try makeClient()
        let operationID = UUID().uuidString.lowercased()
        let buildID = UUID().uuidString.lowercased()
        MockURLProtocol.responses = [
            "/api/v1/builds": (
                202,
                Data(
                    """
                    {"id":"\(operationID)","kind":"build","state":"queued","stage":"queued","progress":0,"cancellable":true,"resource_id":"\(buildID)","created_at":"2026-09-01T12:00:00Z","updated_at":"2026-09-01T12:00:00Z"}
                    """.utf8
                )
            )
        ]
        let submission = try await client.submitTracked(
            .init(
                projectId: UUID().uuidString.lowercased(),
                commit: String(repeating: "a", count: 40),
                sourceSha256: String(repeating: "b", count: 64)
            )
        )
        #expect(submission.operationID == operationID)
        #expect(submission.buildID == buildID)
    }

    @Test func artifactDownloadRequiresTheExpectedHeaderAndBodyDigest() async throws {
        let client = try makeClient()
        let bytes = Data("verified screenshot".utf8)
        let digest = SHA256Digest.hex(bytes)
        MockURLProtocol.responses = ["*": (200, bytes)]
        MockURLProtocol.responseHeaders = ["X-Spark-Artifact-SHA256": digest]
        defer { MockURLProtocol.responseHeaders = [:] }

        let downloaded = try await client.artifact(
            buildID: "build",
            artifactID: "artifact",
            expectedSHA256: digest
        )
        #expect(downloaded == bytes)
        #expect(MockURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept")
                == "application/octet-stream"
        )

        MockURLProtocol.responses = ["*": (200, Data("tampered".utf8))]
        await #expect(throws: BuildClientError.artifactDigestMismatch) {
            try await client.artifact(
                buildID: "build",
                artifactID: "artifact",
                expectedSHA256: digest
            )
        }
    }

    // MARK: - What cannot be built

    @Test func aPlaintextBaseURLIsRefused() {
        // Protect worker registration, source retrieval and signed results on the same pinned connection.
        #expect(throws: PinnedTransportError.insecureScheme("http")) {
            _ = try BuildClient(
                baseURL: URL(string: "http://spark.local:7443")!,
                pin: Self.testPin
            )
        }
    }

    @Test func aPinThatIsNotAFingerprintIsRefused() {
        #expect(throws: PinnedTransportError.malformedPin("")) {
            _ = try BuildClient(baseURL: URL(string: "https://spark.local:7443")!, pin: "")
        }
    }

    // MARK: - Every request is signed, not only the ones with a body

    /// Records what it was asked to sign.
    private struct RecordingSigner: RequestSigning {
        nonisolated(unsafe) static var signedMethods: [String] = []
        nonisolated(unsafe) static var signedBodies: [Data] = []
        nonisolated(unsafe) static var lastIdempotencyKey: String?

        func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
            RecordingSigner.signedMethods.append(request.httpMethod ?? "?")
            RecordingSigner.signedBodies.append(body)
            RecordingSigner.lastIdempotencyKey = request.value(
                forHTTPHeaderField: "Idempotency-Key"
            )
            var signed = request
            signed.setValue("spark1", forHTTPHeaderField: "Authorization")
            return signed
        }
    }

    private func makeSignedClient() throws -> BuildClient {
        RecordingSigner.signedMethods = []
        RecordingSigner.signedBodies = []
        RecordingSigner.lastIdempotencyKey = nil
        return try BuildClient(
            baseURL: URL(string: "https://spark.local:7443")!,
            pin: Self.testPin,
            signer: RecordingSigner(),
            interceptingWith: [MockURLProtocol.self]
        )
    }

    @Test func aStatusRequestIsSigned() async throws {
        // Require authentication on bodyless GET requests that expose build status and diagnostics.
        MockURLProtocol.responses = [
            "/api/v1/builds/abc": (200, Data(#"{"status":"succeeded","result":null}"#.utf8))
        ]
        let client = try makeSignedClient()
        _ = try await client.status(buildID: "abc")

        #expect(RecordingSigner.signedMethods == ["GET"], "the GET went through the signer")
        #expect(RecordingSigner.signedBodies == [Data()], "over an empty body, as SPARK1 expects")
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "spark1",
            "and the signature reached the wire"
        )
    }

    @Test func aSubmitRequestIsStillSignedOverItsBody() async throws {
        // Also exercise the supported request to ensure validation does not reject every input.
        MockURLProtocol.responses = [
            "/api/v1/builds": (200, Data(#"{"id":"op-1"}"#.utf8))
        ]
        let client = try makeSignedClient()
        _ = try await client.submit(
            BuildJobRequest(
                projectID: "2f3f6c90-7f5e-4e3a-9f4b-1d1c0b2a3c4d",
                commit: String(repeating: "a", count: 40),
                sourceSHA256: String(repeating: "c", count: 64),
                scheme: "SparkApp",
                configuration: "Debug",
                destination: "generic/platform=iOS"
            )
        )
        #expect(RecordingSigner.signedMethods == ["POST"])
        #expect(RecordingSigner.signedBodies.first?.isEmpty == false)
    }

    @Test func anUnsignedClientStillWorks() async throws {
        // Allow unsigned registration before the Mac worker has a device grant.
        MockURLProtocol.responses = [
            "/api/v1/builds/abc": (200, Data(#"{"status":"queued","result":null}"#.utf8))
        ]
        let client = try makeClient()
        let (status, _) = try await client.status(buildID: "abc")
        #expect(status == "queued")
    }

    @Test func mutationsCarryTheCallerStableUUIDBeforeSigning() async throws {
        RecordingSigner.lastIdempotencyKey = nil
        MockURLProtocol.responses = [
            "/api/v1/builds": (
                202,
                Data(#"{"id":"b1111111-2222-3333-4444-555555555555"}"#.utf8)
            )
        ]
        let client = try makeClient(signer: RecordingSigner())
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        _ = try await client.submit(
            BuildJobRequest(
                projectID: "2f3f6c90-7f5e-4e3a-9f4b-1d1c0b2a3c4d",
                commit: String(repeating: "b", count: 40),
                sourceSHA256: String(repeating: "c", count: 64)
            ),
            idempotencyKey: key
        )

        #expect(RecordingSigner.lastIdempotencyKey == key.uuidString)
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
                == key.uuidString
        )
    }
}

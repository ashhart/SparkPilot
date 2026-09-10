import Foundation
import Testing

@_spi(SparkTestSupport) @_spi(SparkInternal) @testable import SparkTransport

/// Verifies that pinned transports reject invalid pins, plaintext requests and redirects.

@Suite(.serialized)
struct PinnedHTTPTransportTests {

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var headers: [String: String] = [:]
        nonisolated(unsafe) static var body = Data("{}".utf8)
        nonisolated(unsafe) static var requestedURLs: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestedURLs.append(request.url?.absoluteString ?? "")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: Self.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class HangingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var started = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.started = true
        }

        override func stopLoading() {}
    }

    private final class CancelledProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        override func stopLoading() {}
    }

    @Test func sessionCancellationIsNotACertificateRejection() async throws {
        let transport = try URLSessionPinnedTransport(
            pin: Self.pin,
            interceptingWith: [CancelledProtocol.self]
        )
        await #expect(throws: CancellationError.self) {
            _ = try await transport.perform(
                URLRequest(url: URL(string: "https://spark.local:7443/api/v1/health")!)
            )
        }
    }

    private static let pin = String(repeating: "a", count: 64)

    private func transport() throws -> URLSessionPinnedTransport {
        StubProtocol.requestedURLs = []
        StubProtocol.statusCode = 200
        StubProtocol.headers = [:]
        StubProtocol.body = Data("{}".utf8)
        return try URLSessionPinnedTransport(pin: Self.pin, interceptingWith: [StubProtocol.self])
    }

    // MARK: - What cannot be built

    @Test func aPinThatIsNotAFingerprintIsRefusedAtConstruction() {
        // Reject malformed certificate pins at construction so failure identifies the invalid input.
        for bad in [
            "", "abc", String(repeating: "a", count: 63), String(repeating: "z", count: 64),
        ] {
            #expect(throws: PinnedTransportError.malformedPin(bad)) {
                _ = try URLSessionPinnedTransport(pin: bad)
            }
        }
    }

    @Test func aValidFingerprintIsAccepted() throws {
        let built = try URLSessionPinnedTransport(pin: Self.pin)
        #expect(built.pin == Self.pin)
    }

    // MARK: - What it refuses to send

    @Test func aPlainHTTPRequestIsRefusedBeforeItIsSent() async throws {
        // Reject plaintext before sending because HTTP cannot trigger certificate validation.
        let transport = try transport()
        await #expect(throws: PinnedTransportError.insecureScheme("http")) {
            _ = try await transport.perform(
                URLRequest(url: URL(string: "http://spark.local:7443/api/v1/health")!)
            )
        }
        #expect(StubProtocol.requestedURLs.isEmpty, "nothing left the device")
    }

    @Test func aNonHTTPSchemeIsRefusedToo() async throws {
        let transport = try transport()
        await #expect(throws: (any Error).self) {
            _ = try await transport.perform(URLRequest(url: URL(string: "file:///etc/passwd")!))
        }
        #expect(StubProtocol.requestedURLs.isEmpty)
    }

    @Test func anHTTPSRequestGoesThrough() async throws {
        let transport = try transport()
        let (data, response) = try await transport.perform(
            URLRequest(url: URL(string: "https://spark.local:7443/api/v1/health")!)
        )
        #expect(response.statusCode == 200)
        #expect(data == Data("{}".utf8))
    }

    @Test func cooperativeTaskCancellationIsNotReportedAsACertificateRejection() async throws {
        HangingProtocol.started = false
        let transport = try URLSessionPinnedTransport(
            pin: Self.pin,
            interceptingWith: [HangingProtocol.self]
        )
        let request = URLRequest(url: URL(string: "https://spark.local:7443/api/v1/health")!)
        let task = Task { try await transport.perform(request) }
        while !HangingProtocol.started { await Task.yield() }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Redirects

    @Test func aRedirectIsReportedRatherThanFollowed() async throws {
        // Reject redirects that could change the pinned destination or downgrade to HTTP.
        StubProtocol.statusCode = 302
        StubProtocol.requestedURLs = []
        StubProtocol.headers = ["Location": "http://elsewhere.invalid/"]
        let transport = try URLSessionPinnedTransport(
            pin: Self.pin,
            interceptingWith: [StubProtocol.self]
        )

        await #expect(
            throws: PinnedTransportError.redirected(to: "http://elsewhere.invalid/")
        ) {
            _ = try await transport.perform(
                URLRequest(url: URL(string: "https://spark.local:7443/api/v1/health")!)
            )
        }
        #expect(
            StubProtocol.requestedURLs == ["https://spark.local:7443/api/v1/health"],
            "the redirect target was never requested"
        )
    }

    @Test func theDelegateRefusesToBuildARedirectRequest() {
        // Assert both delegate-level refusal and response-level redirect rejection.
        let delegate = PinnedSessionDelegate(policy: PinnedTrustPolicy(fingerprint: Self.pin))
        var handed: URLRequest? = URLRequest(url: URL(string: "https://elsewhere.invalid")!)
        delegate.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: URL(string: "https://spark.local")!),
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://spark.local")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )!,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.invalid")!),
            completionHandler: { handed = $0 }
        )
        #expect(handed == nil, "the redirect was not followed")
    }
}

/// Verifies that Spark sessions isolate caches, cookies and credentials from process-wide stores.
@Suite struct HardenedConfigurationTests {

    @Test func nothingIsCachedCookiedOrCredentialed() {
        let configuration = SparkURLSessionConfiguration.hardened()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func itDoesNotWaitIndefinitelyForALocalNetwork() {
        // Report missing connectivity promptly rather than holding a local Spark request open.
        #expect(SparkURLSessionConfiguration.hardened().waitsForConnectivity == false)
    }

    @Test func localSparkRequestsFailFastWhenTheSavedRouteDoesNotAnswer() {
        let configuration = SparkURLSessionConfiguration.hardened()

        #expect(
            configuration.timeoutIntervalForRequest <= 3,
            "a saved local route must not leave its card showing Connecting for a minute"
        )
    }

    @Test func itIsNotTheSharedConfiguration() {
        let configuration = SparkURLSessionConfiguration.hardened()
        #expect(configuration.urlCache !== URLSessionConfiguration.default.urlCache)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    }

    @Test func aTestMayInterceptButMayNotRelaxAnyOfIt() {
        // Keep the test interception seam unable to restore caches, cookies or credential stores.
        final class Nothing: URLProtocol {}
        let configuration = SparkURLSessionConfiguration.hardened(interceptingWith: [Nothing.self])
        #expect(configuration.protocolClasses?.count == 1)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func aPinnedSessionUsesIt() {
        let session = PinnedSession.pinned(to: String(repeating: "a", count: 64))
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.urlCredentialStorage == nil)
        #expect(session.delegate is PinnedSessionDelegate, "and it carries the pinning delegate")
    }
}

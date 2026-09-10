import Foundation
import Testing
@_spi(SparkTestSupport) @testable import SparkAppComposition

@Suite(.serialized)
struct SparkOOBEClientTests {
    private struct CapturedRequest {
        let path: String
        let method: String?
        let body: Data?
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
        nonisolated(unsafe) static var errors: [String: URLError.Code] = [:]
        nonisolated(unsafe) static var redirects: [String: String] = [:]
        nonisolated(unsafe) static var requests: [CapturedRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.requests.append(
                CapturedRequest(
                    path: path,
                    method: request.httpMethod,
                    body: request.httpBody ?? request.httpBodyStream?.readAllData()
                )
            )
            if let error = Self.errors[path] {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            guard let (status, body) = Self.responses[path] else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            var headers = ["Content-Type": "application/json"]
            if let location = Self.redirects[path] { headers["Location"] = location }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> SparkOOBEClient {
        StubURLProtocol.requests = []
        StubURLProtocol.errors = [:]
        StubURLProtocol.redirects = [:]
        return SparkOOBEClient(
            baseURL: URL(string: "http://spark-a1b2.local")!,
            interceptingWith: [StubURLProtocol.self]
        )
    }

    @Test func loadsRegionalOptionsUsingServerIndexes() async throws {
        StubURLProtocol.responses = [
            "/api/v1/langs": (
                200,
                #"[{"CountryCode":"GB","LanguageCode":"en","DisplayName":"English","Locale":"en_GB.utf8"}]"#
            ),
            "/api/v1/tz": (200, #"["Europe/London"]"#),
        ]

        let options = try await makeClient().regionalOptions()

        #expect(options.languages[0].index == 0)
        #expect(options.languages[0].locale == "en_GB.utf8")
        #expect(options.timeZones == ["Europe/London"])
    }

    @Test func submitsLanguageBeforeTimeZone() async throws {
        StubURLProtocol.responses = [
            "/api/v1/langs": (200, "{}"),
            "/api/v1/tz": (200, "{}"),
        ]

        try await makeClient().configureRegion(languageIndex: 4, timeZoneIndex: 2)

        #expect(StubURLProtocol.requests.map(\.path) == ["/api/v1/langs", "/api/v1/tz"])
    }

    @Test func submitsAccountUsingTheSparkOOBEContract() async throws {
        StubURLProtocol.responses = ["/api/v1/user": (200, "{}")]
        let client = makeClient()

        try await client.createAccount(username: "alex", password: "correct-horse")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.method == "POST")
        let body = try #require(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(json?["digits_fullname"] == "alex")
        #expect(json?["digits_username"] == "alex")
        #expect(json?["digits_password"] == "correct-horse")
    }

    @Test func submitsSelectedWiFiByScanIndex() async throws {
        StubURLProtocol.responses = ["/api/v1/wifi": (200, "{}")]
        let client = makeClient()

        try await client.connectWiFi(index: 3, password: "home-secret")

        let request = try #require(StubURLProtocol.requests.last)
        let body = try #require(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["wifi"] as? Int == 3)
        #expect(json?["psk"] as? String == "home-secret")
    }

    @Test func networkLossAfterWiFiSubmissionMeansHandoffStarted() async throws {
        StubURLProtocol.responses = [:]
        let client = makeClient()
        StubURLProtocol.errors = ["/api/v1/wifi": .networkConnectionLost]

        try await client.connectWiFi(index: 3, password: "home-secret")
    }

    @Test func lackOfInternetDoesNotPretendTheWiFiPasswordReachedTheSpark() async throws {
        StubURLProtocol.responses = [:]
        let client = makeClient()
        StubURLProtocol.errors = ["/api/v1/wifi": .notConnectedToInternet]

        await #expect(throws: URLError.self) {
            try await client.connectWiFi(index: 3, password: "home-secret")
        }
    }

    @Test func aTimedOutWiFiSubmissionDoesNotPretendTheSparkAcceptedIt() async throws {
        StubURLProtocol.responses = [:]
        let client = makeClient()
        StubURLProtocol.errors = ["/api/v1/wifi": .timedOut]

        await #expect(throws: URLError.self) {
            try await client.connectWiFi(index: 3, password: "home-secret")
        }
    }

    @Test func skippedWiFiMeansTheSparkConfirmedWiredInternet() async throws {
        StubURLProtocol.responses = [
            "/api/v1/wifi": (409, "Skipped Wi-Fi Selection")
        ]

        let options = try await makeClient().networkOptions()

        #expect(options.ethernetHasInternet)
        #expect(options.wifiNetworks.isEmpty)
    }

    @Test func aServerFailureThatMentionsSkippedWiFiIsNotPresentedAsEthernet() async throws {
        StubURLProtocol.responses = [
            "/api/v1/wifi": (409, "Could not skip Wi-Fi Selection")
        ]

        await #expect(throws: SparkOOBEClientError.self) {
            _ = try await makeClient().networkOptions()
        }
    }

    /// A redirect from the setup page would otherwise carry the new admin password to its target.
    @Test func aRedirectFromTheSetupPageIsRefusedRatherThanFollowed() async throws {
        StubURLProtocol.responses = [
            "/api/v1/user": (302, ""),
            "/api/v1/redirected-user": (200, "{}"),
        ]
        let client = makeClient()
        StubURLProtocol.redirects = ["/api/v1/user": "http://evil.example/api/v1/redirected-user"]

        await #expect(throws: SparkOOBEClientError.server(statusCode: 302, diagnosticDetail: "")) {
            try await client.createAccount(username: "alex", password: "correct-horse")
        }
        #expect(StubURLProtocol.requests.map(\.path) == ["/api/v1/user"])
    }

    @Test func finalizesWithoutOTAWhenPolicyAllowsIt() async throws {
        StubURLProtocol.responses = [
            "/api/v1/ota-policy": (200, #"{"enforceOta":false}"#),
            "/api/v1/complete-without-ota": (200, "{}"),
        ]

        try await makeClient().finishSetup()

        #expect(
            StubURLProtocol.requests.map(\.path) == [
                "/api/v1/ota-policy", "/api/v1/complete-without-ota",
            ]
        )
        #expect(StubURLProtocol.requests.last?.method == "POST")
    }
}

extension InputStream {
    fileprivate func readAllData() -> Data {
        open()
        defer { close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

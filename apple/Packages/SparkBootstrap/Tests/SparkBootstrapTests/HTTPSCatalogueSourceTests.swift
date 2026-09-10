import Foundation
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

/// The published catalogue is fetched with the same bounds the Spark applies, over HTTPS only.
@Suite(.serialized)
struct HTTPSCatalogueSourceTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var statusCode = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var endless = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: Self.endless ? [:] : ["Content-Length": "\(Self.body.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if Self.endless {
                let chunk = Data(repeating: 0x7b, count: 64 * 1024)
                for _ in 0..<64 { client?.urlProtocol(self, didLoad: chunk) }
                return
            }
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func plainHTTPIsRefusedBeforeAnyRequest() async {
        let source = HTTPSCatalogueSource(
            url: URL(string: "http://sparkpilot.dev/models/v1/catalogue.json")!,
            interceptingWith: [StubProtocol.self]
        )
        await #expect(throws: PublishedCatalogueError.self) { try await source.catalogue() }
    }

    @Test func thePublishedBytesAreReturnedUnchanged() async throws {
        StubProtocol.statusCode = 200
        StubProtocol.endless = false
        StubProtocol.body = Data("{\"recipes\":[],\"signature\":{}}".utf8)
        let source = HTTPSCatalogueSource(
            url: URL(string: "https://sparkpilot.dev/models/v1/catalogue.json")!,
            interceptingWith: [StubProtocol.self]
        )
        #expect(try await source.catalogue() == StubProtocol.body)
    }

    @Test func aFileLargerThanASparkAcceptsIsCutOffWhileStreaming() async {
        StubProtocol.statusCode = 200
        StubProtocol.endless = true
        let source = HTTPSCatalogueSource(
            url: URL(string: "https://sparkpilot.dev/models/v1/catalogue.json")!,
            interceptingWith: [StubProtocol.self]
        )
        await #expect(throws: PublishedCatalogueError.self) { try await source.catalogue() }
        StubProtocol.endless = false
    }

    @Test func anErrorStatusIsATransportFailure() async {
        StubProtocol.statusCode = 503
        StubProtocol.endless = false
        StubProtocol.body = Data()
        let source = HTTPSCatalogueSource(
            url: URL(string: "https://sparkpilot.dev/models/v1/catalogue.json")!,
            interceptingWith: [StubProtocol.self]
        )
        await #expect(throws: PublishedCatalogueError.self) { try await source.catalogue() }
        StubProtocol.statusCode = 200
    }
}

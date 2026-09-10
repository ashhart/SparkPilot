import Foundation
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

/// Test download bounds during streaming rather than after whole-body allocation.

/// The stub uses shared static state; these tests must run serially.
@Suite(.serialized)
struct HTTPSReleaseSourceTests {

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Reply {
            var statusCode = 200
            var body = Data()
            /// What to claim in `Content-Length`, if not the body's real size.
            var advertisedLength: Int?
            /// Send this many bytes and never finish, as an endless stream does.
            var endless = false
        }

        nonisolated(unsafe) static var reply = Reply()
        nonisolated(unsafe) static var bytesDelivered = 0
        nonisolated(unsafe) static var cancelled = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let reply = Self.reply
            var headers: [String: String] = [:]
            let advertised = reply.advertisedLength ?? reply.body.count
            if !reply.endless || reply.advertisedLength != nil {
                headers["Content-Length"] = "\(advertised)"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            if reply.endless {
                // Deliver endless 64 KiB chunks asynchronously so the reader can enforce its streaming cap.
                Self.schedule { [weak self] in self?.deliverChunk() }
                return
            }

            Self.bytesDelivered = reply.body.count
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        /// Make the endless-body fixture exceed every tested bound so reaching its cap reveals a failed stream limit.
        static let endlessCap = 64 * 1024 * 1024
        nonisolated(unsafe) static let queue = DispatchQueue(label: "stub-release-server")

        private func deliverChunk() {
            guard !Self.cancelled, Self.bytesDelivered < Self.endlessCap else {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let chunk = Data(repeating: 0x41, count: 64 * 1024)
            client?.urlProtocol(self, didLoad: chunk)
            Self.bytesDelivered += chunk.count
            Self.schedule { [weak self] in self?.deliverChunk() }
        }

        /// Pace the fixture producer so the reader can enforce its cap during streaming.
        private static func schedule(_ work: @escaping @Sendable () -> Void) {
            queue.asyncAfter(deadline: .now() + .milliseconds(1), execute: work)
        }

        override func stopLoading() {
            Self.cancelled = true
        }
    }

    private func source(manifest: String = "https://releases.example.invalid/manifest.json")
        -> HTTPSReleaseSource
    {
        StubProtocol.bytesDelivered = 0
        StubProtocol.cancelled = false
        return HTTPSReleaseSource(
            manifestURL: URL(string: manifest)!,
            interceptingWith: [StubProtocol.self]
        )
    }

    private func artifact(size: Int64) -> ReleaseArtifact {
        ReleaseArtifact(
            name: "spark-runtime_0.1.0-1_arm64.deb",
            architecture: "arm64",
            url: URL(string: "https://releases.example.invalid/spark-runtime.deb")!,
            size: size,
            sha256: String(repeating: "a", count: 64),
            signatureURL: URL(string: "https://releases.example.invalid/spark-runtime.deb.sig")!
        )
    }

    @Test func aManifestComesBackWhole() async throws {
        let body = Data(#"{"version":"0.1.0"}"#.utf8)
        StubProtocol.reply = .init(body: body)
        #expect(try await source().manifest() == body)
    }

    @Test func anOverlongContentLengthIsRefusedBeforeTheBodyIsRead() async throws {
        // Reject an excessive declared content length before reading the body.
        StubProtocol.reply = .init(
            body: Data(repeating: 0x41, count: 16),
            advertisedLength: HTTPSReleaseSource.maximumManifestBytes + 1
        )
        await #expect(throws: ReleaseSourceError.self) { _ = try await source().manifest() }
        #expect(StubProtocol.bytesDelivered == 16, "it did not read a large body to find out")
    }

    @Test func aBodyLongerThanAdvertisedIsCutOffRatherThanBuffered() async throws {
        // Enforce the running byte limit when a server understates Content-Length.
        StubProtocol.reply = .init(advertisedLength: 32, endless: true)
        await #expect(throws: ReleaseSourceError.self) { _ = try await source().manifest() }
        #expect(
            StubProtocol.bytesDelivered < StubProtocol.endlessCap,
            "the reader stopped the stream rather than draining it"
        )
    }

    @Test func anArtifactIsBoundedByItsSignedSizeNotJustTheCeiling() async throws {
        // Enforce the signed manifest size even when a server advertises a larger response.
        StubProtocol.reply = .init(body: Data(repeating: 0x41, count: 4096))
        await #expect(throws: ReleaseSourceError.self) {
            _ = try await source().artifact(artifact(size: 16))
        }
    }

    @Test func anArtifactOfTheDeclaredSizeIsAccepted() async throws {
        let body = Data(repeating: 0x41, count: 4096)
        StubProtocol.reply = .init(body: body)
        #expect(try await source().artifact(artifact(size: 4096)) == body)
    }

    @Test func aDetachedSignatureIsHeldToAFewKilobytes() async throws {
        // Bound signature responses to the expected 64-byte signature representation.
        StubProtocol.reply = .init(body: Data(repeating: 0x41, count: 8192))
        await #expect(throws: ReleaseSourceError.self) {
            _ = try await source().detachedSignature(artifact(size: 4096))
        }
    }

    @Test func plainHTTPIsRefusedWithoutAConnection() async throws {
        StubProtocol.reply = .init(body: Data("nope".utf8))
        let source = source(manifest: "http://releases.example.invalid/manifest.json")
        await #expect(throws: ReleaseSourceError.self) { _ = try await source.manifest() }
        #expect(StubProtocol.bytesDelivered == 0, "nothing was fetched")
    }

    @Test func anErrorStatusIsNotTreatedAsAManifest() async throws {
        StubProtocol.reply = .init(statusCode: 404, body: Data("not found".utf8))
        await #expect(throws: ReleaseSourceError.self) { _ = try await source().manifest() }
    }

    // MARK: - No channel

    @Test func aBuildWithNoChannelSaysSoRatherThanDoingNothing() async throws {
        let source = UnconfiguredReleaseSource()
        await #expect(throws: ReleaseSourceError.noReleaseChannelConfigured) {
            _ = try await source.manifest()
        }
    }

    @Test func aChannelThatIsPresentButBrokenIsReportedDifferently() async throws {
        // Distinguish missing configuration from malformed configuration.
        let source = UnconfiguredReleaseSource(misconfigured: "must be https")
        await #expect(throws: ReleaseSourceError.releaseChannelMisconfigured("must be https")) {
            _ = try await source.manifest()
        }
    }
}

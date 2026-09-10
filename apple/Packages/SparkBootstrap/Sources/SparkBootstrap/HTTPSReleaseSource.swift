import Foundation
import SparkTransport

/// Fetch bounded HTTPS release bytes using public CA trust while the installer independently verifies signatures and digests.
public final class HTTPSReleaseSource: ReleaseSource {
    private let manifestURL: URL
    private let session: URLSession

    deinit { session.finishTasksAndInvalidate() }

    /// Reject oversized release artifacts before allocating their complete contents.
    public static let maximumArtifactBytes = 256 * 1024 * 1024
    public static let maximumManifestBytes = 1 * 1024 * 1024

    /// Require HTTPS and construct a private hardened session without shared release caches or cookies.
    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
        self.session = URLSession(configuration: SparkURLSessionConfiguration.hardened())
    }

    /// For tests that drive a stubbed `URLProtocol`.
    @_spi(SparkTestSupport)
    public init(manifestURL: URL, interceptingWith protocolClasses: [AnyClass]) {
        self.manifestURL = manifestURL
        self.session = URLSession(
            configuration: SparkURLSessionConfiguration.hardened(
                interceptingWith: protocolClasses
            )
        )
    }

    public func manifest() async throws -> Data {
        try await fetch(manifestURL, limit: Self.maximumManifestBytes)
    }

    public func artifact(_ artifact: ReleaseArtifact) async throws -> Data {
        // The manifest's own size is the tighter bound, and it is signed.
        try await fetch(artifact.url, limit: min(Int(artifact.size), Self.maximumArtifactBytes))
    }

    public func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data {
        try await fetch(artifact.signatureURL, limit: 4096)
    }

    /// Enforce the byte cap during streaming even when Content-Length understates the response.
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw ReleaseSourceError.insecureURL(url)
        }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseSourceError.transport(url: url, detail: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReleaseSourceError.transport(url: url, detail: "HTTP \(http.statusCode)")
        }

        let advertised = http.expectedContentLength
        if advertised > 0, advertised > Int64(limit) {
            throw ReleaseSourceError.tooLarge(url: url, bytes: Int(advertised), limit: limit)
        }

        var data = Data()
        if advertised > 0 { data.reserveCapacity(min(Int(advertised), limit)) }
        for try await byte in stream {
            if data.count == limit {
                throw ReleaseSourceError.tooLarge(url: url, bytes: limit + 1, limit: limit)
            }
            data.append(byte)
        }
        return data
    }
}

public enum ReleaseSourceError: Error, Equatable, Sendable {
    case insecureURL(URL)
    case transport(url: URL, detail: String)
    case tooLarge(url: URL, bytes: Int, limit: Int)
    /// Report an unconfigured release channel as an explicit installation failure.
    case noReleaseChannelConfigured
    /// Distinguish a malformed or non-HTTPS release channel from absent configuration.
    case releaseChannelMisconfigured(String)
}

/// Fail explicitly when no release source is configured.
public struct UnconfiguredReleaseSource: ReleaseSource {
    private let reason: ReleaseSourceError

    public init() {
        self.reason = .noReleaseChannelConfigured
    }

    /// A channel that is present but unusable.
    public init(misconfigured detail: String) {
        self.reason = .releaseChannelMisconfigured(detail)
    }

    public func manifest() async throws -> Data { throw reason }

    public func artifact(_ artifact: ReleaseArtifact) async throws -> Data { throw reason }

    public func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data {
        throw reason
    }
}

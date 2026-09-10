import Foundation
import SparkTransport

/// The Spark verifies these catalogue bytes against its own trust root; publication grants no authority.
public protocol PublishedCatalogueSource: Sendable {
    func catalogue() async throws -> Data
}

public enum PublishedCatalogueError: Error, Equatable, Sendable {
    case insecureURL(URL)
    case transport(url: URL, detail: String)
    case tooLarge(url: URL, limit: Int)
    case notConfigured(String?)
}

/// Fetch the catalogue over HTTPS with public CA trust, bounded to the Spark's own catalogue size cap.
public final class HTTPSCatalogueSource: PublishedCatalogueSource {
    /// The runtime refuses larger candidates, so nothing larger is worth downloading.
    public static let maximumBytes = 2 * 1024 * 1024

    private let url: URL
    private let session: URLSession

    deinit { session.finishTasksAndInvalidate() }

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: SparkURLSessionConfiguration.hardened())
    }

    /// For tests that drive a stubbed `URLProtocol`.
    @_spi(SparkTestSupport)
    public init(url: URL, interceptingWith protocolClasses: [AnyClass]) {
        self.url = url
        self.session = URLSession(
            configuration: SparkURLSessionConfiguration.hardened(
                interceptingWith: protocolClasses
            )
        )
    }

    public func catalogue() async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw PublishedCatalogueError.insecureURL(url)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A stale edge copy would hide a recipe the owner just published.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublishedCatalogueError.transport(url: url, detail: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PublishedCatalogueError.transport(url: url, detail: "HTTP \(http.statusCode)")
        }
        let limit = Self.maximumBytes
        let advertised = http.expectedContentLength
        if advertised > 0, advertised > Int64(limit) {
            throw PublishedCatalogueError.tooLarge(url: url, limit: limit)
        }
        var data = Data()
        if advertised > 0 { data.reserveCapacity(min(Int(advertised), limit)) }
        for try await byte in stream {
            if data.count == limit {
                throw PublishedCatalogueError.tooLarge(url: url, limit: limit)
            }
            data.append(byte)
        }
        return data
    }
}

/// Fail explicitly when the build names no catalogue location.
public struct UnconfiguredCatalogueSource: PublishedCatalogueSource {
    private let reason: String?

    public init(misconfigured reason: String? = nil) {
        self.reason = reason
    }

    public func catalogue() async throws -> Data {
        throw PublishedCatalogueError.notConfigured(reason)
    }
}

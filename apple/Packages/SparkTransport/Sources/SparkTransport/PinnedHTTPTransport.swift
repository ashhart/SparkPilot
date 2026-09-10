import Foundation

/// Restrict injected transport conformances to SPI tests while shipping clients construct concrete pin enforcement.
public protocol PinnedHTTPTransport: Sendable {
    /// Expose the recorded certificate pin as metadata, never as proof that an arbitrary transport enforces it.
    var pin: String { get }

    /// Perform a request, returning the body and the response.
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum PinnedTransportError: Error, Equatable, Sendable {
    /// Distinguish certificate mismatch from an unreachable Spark.
    case certificateRejected(host: String)
    case unreachable(String)
    case nonHTTPResponse
    /// The request was not `https`. Refused before it is sent.
    case insecureScheme(String)
    /// The node answered with a redirect. Refused rather than followed.
    case redirected(to: String)
    /// Reject malformed SHA-256 pins before attempting a connection.
    case malformedPin(String)
}

/// Build hardened sessions internally without shared caches, cookies or credential stores.
public enum SparkURLSessionConfiguration {
    /// - Parameter interceptingWith: Test protocol classes may intercept requests without relaxing session hardening.
    public static func hardened(interceptingWith protocolClasses: [AnyClass] = [])
        -> URLSessionConfiguration
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        // Fail unavailable local connectivity rather than waiting indefinitely for it to return.
        configuration.waitsForConnectivity = false
        // Use a short foreground presence timeout so unavailable local routes do not leave cards connecting for a minute.
        configuration.timeoutIntervalForRequest = 3
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses
        }
        return configuration
    }
}

/// Construct the production pinned session internally, allowing SPI tests to inject only request-intercepting protocol classes.
public final class URLSessionPinnedTransport: PinnedHTTPTransport {
    public let pin: String
    private let session: URLSession
    private let trustDelegate: PinnedSessionDelegate

    /// Require a 64-hex SHA-256 leaf-certificate DER pin and fail malformed values during transport construction.
    public convenience init(pin: String) throws {
        try self.init(pin: pin, interceptingWith: [])
    }

    /// For tests that drive a stubbed `URLProtocol` through the real transport.
    @_spi(SparkTestSupport)
    public init(pin: String, interceptingWith protocolClasses: [AnyClass]) throws {
        guard URLSessionPinnedTransport.isFingerprint(pin) else {
            throw PinnedTransportError.malformedPin(pin)
        }
        self.pin = pin
        let pinned = PinnedSession.pinnedWithDelegate(to: pin, interceptingWith: protocolClasses)
        self.session = pinned.session
        self.trustDelegate = pinned.delegate
    }

    /// Validates the SHA-256 certificate-pin format shared by buffered and streaming clients.
    public static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }

    deinit { session.finishTasksAndInvalidate() }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Reject HTTP before sending because it cannot present the certificate required by the pin.
        guard request.url?.scheme?.lowercased() == "https" else {
            throw PinnedTransportError.insecureScheme(request.url?.scheme ?? "none")
        }

        let requestDelegate = trustDelegate.forRequest()
        do {
            let (data, response) = try await session.data(for: request, delegate: requestDelegate)
            guard let http = response as? HTTPURLResponse else {
                throw PinnedTransportError.nonHTTPResponse
            }
            // Surface redirects distinctly so callers neither consume another host's response nor retry the same redirect.
            guard !(300..<400).contains(http.statusCode) else {
                throw PinnedTransportError.redirected(
                    to: http.value(forHTTPHeaderField: "Location")
                        ?? String(localized: "an unnamed location")
                )
            }
            return (data, http)
        } catch let error as PinnedTransportError {
            throw error
        } catch {
            let failure = requestDelegate.transportError(
                error,
                host: request.url?.host ?? String(localized: "the Spark")
            )
            if failure is CancellationError { throw failure }
            if let failure = failure as? PinnedTransportError { throw failure }
            throw PinnedTransportError.unreachable(error.localizedDescription)
        }
    }
}

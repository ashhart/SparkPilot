import Foundation

/// Creates sessions whose server-trust challenges are evaluated against the selected Spark's certificate pin.
public enum PinnedSession {
    /// Pins the lowercase SHA-256 leaf-DER fingerprint using a hardened configuration that isolates caches, cookies and credentials.
    @_spi(SparkInternal)
    public static func pinned(
        to fingerprint: String,
        interceptingWith protocolClasses: [AnyClass] = []
    ) -> URLSession {
        pinnedWithDelegate(to: fingerprint, interceptingWith: protocolClasses).session
    }

    /// Returns the session and pinning delegate together because streaming tasks require an explicit challenge delegate.
    @_spi(SparkInternal)
    public static func pinnedWithDelegate(
        to fingerprint: String,
        interceptingWith protocolClasses: [AnyClass] = []
    ) -> (session: URLSession, delegate: PinnedSessionDelegate) {
        let delegate = PinnedSessionDelegate(policy: PinnedTrustPolicy(fingerprint: fingerprint))
        let session = URLSession(
            configuration: SparkURLSessionConfiguration.hardened(
                interceptingWith: protocolClasses
            ),
            delegate: delegate,
            delegateQueue: nil
        )
        return (session, delegate)
    }

    /// Arbitrary trust policies remain internal so callers cannot construct a supported accept-all Spark session.
    static func session(
        policy: any ServerTrustPolicy,
        interceptingWith protocolClasses: [AnyClass] = []
    ) -> URLSession {
        let delegate = PinnedSessionDelegate(policy: policy)
        // The session retains its delegate; the caller holds the session.
        return URLSession(
            configuration: SparkURLSessionConfiguration.hardened(
                interceptingWith: protocolClasses
            ),
            delegate: delegate,
            delegateQueue: nil
        )
    }
}

/// Applies the selected trust policy and refuses redirects that could change the destination or drop TLS.
public final class PinnedSessionDelegate: NSObject, URLSessionDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let policy: any ServerTrustPolicy
    private let rejectionLock = NSLock()
    private var rejected = false

    /// Each concurrent request gets independent rejection evidence.
    @_spi(SparkInternal)
    public func forRequest() -> PinnedSessionDelegate {
        PinnedSessionDelegate(policy: policy)
    }

    @_spi(SparkInternal)
    public func transportError(_ error: any Error, host: String) -> any Error {
        if rejectionLock.withLock({ rejected }) {
            return PinnedTransportError.certificateRejected(host: host)
        }
        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    /// Restrict arbitrary trust-policy injection to SPI so shipping callers cannot build accept-anything delegates.
    @_spi(SparkTestSupport)
    public init(policy: any ServerTrustPolicy) {
        self.policy = policy
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Handle only server trust here; other authentication challenges retain Foundation's default handling.
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch policy.evaluate(trust: trust, host: challenge.protectionSpace.host) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .defaultSystem:
            completionHandler(.performDefaultHandling, nil)
        case .reject:
            // Cancel rejected pin challenges without falling back to another trust rule.
            rejectionLock.withLock { rejected = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Applies pinning to task-level challenges used by streaming requests.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    /// Completing with nil exposes the redirect response without following it.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

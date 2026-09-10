import Foundation

/// For unpinned local endpoints: never follow a redirect, never answer a credential prompt.
final class SparkRedirectRefusingSessionDelegate: NSObject, URLSessionTaskDelegate {
    /// Completing with nil exposes the redirect response without following it anywhere.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(
            Self.disposition(for: challenge.protectionSpace.authenticationMethod),
            nil
        )
    }

    /// Server trust gets the system's evaluation; anything else would need implicit credentials.
    static func disposition(for authenticationMethod: String) -> URLSession.AuthChallengeDisposition
    {
        authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge
    }
}

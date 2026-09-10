import Foundation
import Testing
@testable import SparkAppComposition

/// Records what the delegate decided for a challenge it was handed.
private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private func challenge(method: String) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
        protectionSpace: URLProtectionSpace(
            host: "spark-a1b2.local",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: method
        ),
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: ChallengeSender()
    )
}

private func decide(_ method: String) async -> URLSession.AuthChallengeDisposition {
    let delegate = SparkRedirectRefusingSessionDelegate()
    let task = URLSession.shared.dataTask(with: URL(string: "https://spark-a1b2.local/")!)
    return await withCheckedContinuation { continuation in
        delegate.urlSession(URLSession.shared, task: task, didReceive: challenge(method: method)) {
            disposition,
            credential in
            #expect(credential == nil)
            continuation.resume(returning: disposition)
        }
    }
}

@Test func serverTrustChallengesUseTheSystemEvaluation() async {
    #expect(await decide(NSURLAuthenticationMethodServerTrust) == .performDefaultHandling)
}

@Test func credentialChallengesAreCancelledRatherThanAnsweredImplicitly() async {
    #expect(await decide(NSURLAuthenticationMethodHTTPBasic) == .cancelAuthenticationChallenge)
    #expect(
        await decide(NSURLAuthenticationMethodClientCertificate) == .cancelAuthenticationChallenge
    )
    #expect(await decide(NSURLAuthenticationMethodNTLM) == .cancelAuthenticationChallenge)
}

@Test func redirectsAreNeverFollowed() async {
    let delegate = SparkRedirectRefusingSessionDelegate()
    let original = URL(string: "http://spark-a1b2.local/api/v1/eula")!
    let task = URLSession.shared.dataTask(with: original)
    let response = HTTPURLResponse(
        url: original,
        statusCode: 302,
        httpVersion: nil,
        headerFields: nil
    )!
    let followed: URLRequest? = await withCheckedContinuation { continuation in
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://evil.example/api/v1/eula")!)
        ) { continuation.resume(returning: $0) }
    }
    #expect(followed == nil)
}

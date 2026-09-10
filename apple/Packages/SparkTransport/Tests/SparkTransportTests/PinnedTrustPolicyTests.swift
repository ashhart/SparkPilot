import CryptoKit
import Foundation
import Security
import Testing

@_spi(SparkInternal) @_spi(SparkTestSupport) @testable import SparkTransport

/// Exercises pin evaluation with real SecTrust objects built from two distinct self-signed P-256 certificates.

private func certificate(_ name: String) throws -> SecCertificate {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        Issue.record("missing fixture \(name)")
        throw CocoaError(.fileNoSuchFile)
    }
    let der = try Data(contentsOf: url)
    guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
        Issue.record("\(name) is not a DER certificate")
        throw CocoaError(.fileReadCorruptFile)
    }
    return certificate
}

private func serverTrust(_ certificate: SecCertificate) throws -> SecTrust {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(
        certificate as CFTypeRef,
        SecPolicyCreateBasicX509(),
        &trust
    )
    guard status == errSecSuccess, let trust else {
        Issue.record("SecTrustCreateWithCertificates failed: \(status)")
        throw CocoaError(.coderInvalidValue)
    }
    return trust
}

private func fingerprint(of name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        throw CocoaError(.fileNoSuchFile)
    }
    let der = try Data(contentsOf: url)
    return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
}

@Test func aMatchingLeafIsAccepted() throws {
    let node = try certificate("node-certificate.der")
    let policy = PinnedTrustPolicy(fingerprint: try fingerprint(of: "node-certificate.der"))
    #expect(policy.evaluate(trust: try serverTrust(node), host: "spark.local") == .accept)
}

@Test func aDifferentCertificateOnTheSameAddressIsRejected() throws {
    // Reject a certificate that differs from the expected Spark pin.
    let impostor = try certificate("impostor-certificate.der")
    let policy = PinnedTrustPolicy(fingerprint: try fingerprint(of: "node-certificate.der"))
    #expect(policy.evaluate(trust: try serverTrust(impostor), host: "spark.local") == .reject)
}

@Test func thePolicyUsesItsOwnPinAndNotACallSiteValue() throws {
    // The same connection must produce different decisions for policies constructed with different pins.
    let node = try certificate("node-certificate.der")
    let trust = try serverTrust(node)

    let correct = PinnedTrustPolicy(fingerprint: try fingerprint(of: "node-certificate.der"))
    let wrong = PinnedTrustPolicy(fingerprint: try fingerprint(of: "impostor-certificate.der"))

    #expect(correct.evaluate(trust: trust, host: "spark.local") == .accept)
    #expect(wrong.evaluate(trust: trust, host: "spark.local") == .reject)
}

@Test func theFingerprintMatchesWhatTheRuntimePublishes() throws {
    // Swift must hash the same leaf-DER bytes and emit the same lowercase hex as the runtime.
    let node = try certificate("node-certificate.der")
    let expected = try fingerprint(of: "node-certificate.der")

    #expect(node.fingerprint() == expected)
    #expect(expected.count == 64)
    #expect(expected == expected.lowercased(), "the runtime writes lowercase hex")
    #expect(expected.allSatisfy { $0.isNumber || ("a"..."f").contains($0) })
}

@Test func aPinThatIsNotADigestTrustsNothing() throws {
    let node = try certificate("node-certificate.der")
    let trust = try serverTrust(node)
    // Reject malformed pins even when a well-formed but unrelated authority fingerprint would simply mismatch.
    for pin in ["", "abc", String(repeating: "a", count: 63), String(repeating: "A", count: 64)] {
        #expect(
            PinnedTrustPolicy(fingerprint: pin).evaluate(trust: trust, host: "spark.local")
                == .reject,
            "pin \(pin) must not accept anything"
        )
    }
}

@Test func constantTimeComparisonAgreesWithEquality() {
    #expect(constantTimeEquals("abc", "abc"))
    #expect(!constantTimeEquals("abc", "abd"))
    #expect(!constantTimeEquals("abc", "ab"))
    #expect(!constantTimeEquals("", "a"))
    #expect(constantTimeEquals("", ""))

    let digest = String(repeating: "a", count: 64)
    var nearMiss = digest
    nearMiss.removeLast()
    nearMiss.append("b")
    #expect(!constantTimeEquals(digest, nearMiss))
}

@Test func theDelegateAnswersOnlyServerTrustChallenges() {
    // Do not synthesize credentials for client-certificate or HTTP authentication challenges.
    let delegate = PinnedSessionDelegate(
        policy: PinnedTrustPolicy(fingerprint: String(repeating: "a", count: 64))
    )
    let space = URLProtectionSpace(
        host: "spark.local",
        port: 7443,
        protocol: "https",
        realm: nil,
        authenticationMethod: NSURLAuthenticationMethodHTTPBasic
    )
    let challenge = URLAuthenticationChallenge(
        protectionSpace: space,
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: NoopChallengeSender()
    )

    var disposition: URLSession.AuthChallengeDisposition?
    var credential: URLCredential?
    delegate.urlSession(URLSession.shared, didReceive: challenge) {
        disposition = $0
        credential = $1
    }
    #expect(disposition == .performDefaultHandling)
    #expect(credential == nil)
}

private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class TestServerTrustSpace: URLProtectionSpace, @unchecked Sendable {
    let testTrust: SecTrust
    init(trust: SecTrust) {
        self.testTrust = trust
        super.init(
            host: "spark.local",
            port: 7443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }
    required init?(coder: NSCoder) { return nil }
    override var serverTrust: SecTrust? { testTrust }
}

@Test func pinRejectionEvidenceBelongsOnlyToTheRequestThatWasRejected() throws {
    let delegate = PinnedSessionDelegate(
        policy: PinnedTrustPolicy(
            fingerprint: try fingerprint(of: "node-certificate.der")
        )
    )
    let rejectedRequest = delegate.forRequest()
    let cancelledRequest = delegate.forRequest()
    let challenge = URLAuthenticationChallenge(
        protectionSpace: TestServerTrustSpace(
            trust: try serverTrust(certificate("impostor-certificate.der"))
        ),
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: NoopChallengeSender()
    )
    rejectedRequest.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in
        #expect(disposition == .cancelAuthenticationChallenge)
    }
    #expect(
        rejectedRequest.transportError(URLError(.cancelled), host: "spark.local")
            as? PinnedTransportError == .certificateRejected(host: "spark.local")
    )
    #expect(
        cancelledRequest.transportError(URLError(.cancelled), host: "spark.local")
            is CancellationError
    )
}

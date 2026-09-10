import CryptoKit
import Foundation
import os
import Security

/// Resolve each server-trust challenge through the configured trust policy (§37.4).
public enum TrustDecision: Sendable, Equatable {
    /// Accept the presented server trust.
    case accept
    /// Fall back to default system validation (public CA).
    case defaultSystem
    /// Refuse the connection.
    case reject
}

/// Keep pin-decision logic independently testable while the concrete evaluator handles SecTrust.
public protocol ServerTrustPolicy: Sendable {
    func evaluate(trust: SecTrust, host: String) -> TrustDecision
}

/// Pins SHA-256 of the leaf certificate's DER bytes, independently of the authority key, hostname and public-CA chain.
public struct PinnedTrustPolicy: ServerTrustPolicy, Sendable {
    public let fingerprint: String

    public init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    public func evaluate(trust: SecTrust, host: String) -> TrustDecision {
        // Treat malformed SHA-256 pins as rejecting all certificates.
        guard fingerprint.count == 64,
            fingerprint.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
        else { return .reject }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return .reject }

        // Compare all fingerprint bytes without exposing the matching-prefix length.
        let presented = leaf.fingerprint()
        if constantTimeEquals(presented, fingerprint) { return .accept }
        // Report public expected and observed fingerprints to make pin failures diagnosable.
        Logger(subsystem: "com.sparkfabric.transport", category: "trust")
            .error(
                "pinned trust rejected \(host, privacy: .public): expected \(fingerprint, privacy: .public), presented \(presented, privacy: .public)"
            )
        return .reject
    }
}

/// Compare two ASCII strings without an early exit.
func constantTimeEquals(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count {
        difference |= a[index] ^ b[index]
    }
    return difference == 0
}

extension SecCertificate {
    /// Hash certificate DER to lowercase SHA-256 hex matching runtime tls_fingerprint.
    public func fingerprint() -> String {
        let data = SecCertificateCopyData(self) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

extension AppShellTestFixedSigner: SendableDeviceSigning {}

// MARK: - SPARK2 signing (§37.1, §58.3)

/// A fixed software signer (no Keychain) for deterministic tests.
final class AppShellTestFixedSigner: DeviceSigning, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()

    var publicKeySPKI: Data { key.publicKey.derRepresentation }

    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}

final class AppShellTestAppTestPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    private let signer: SoftwareSigner
    let keyInfo: UserPresenceKeyInfo

    init() {
        let signer = SoftwareSigner()
        self.signer = signer
        self.keyInfo = UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }

    func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) async throws -> Data {
        try signer.sign(binding.signatureInput)
    }
}

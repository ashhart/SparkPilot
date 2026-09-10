import CryptoKit
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Atomically consume local approval on the first actor-isolated proof request.
actor UserPresenceSigningSession: UserPresenceProofSigning {
    nonisolated let keyInfo: UserPresenceKeyInfo

    private let signing: @Sendable (Data) throws -> Data
    private let invalidate: @Sendable () -> Void
    private var consumed = false

    init(
        keyInfo: UserPresenceKeyInfo,
        signing: @escaping @Sendable (Data) throws -> Data,
        invalidate: @escaping @Sendable () -> Void = {}
    ) {
        self.keyInfo = keyInfo
        self.signing = signing
        self.invalidate = invalidate
    }

    func proof(for request: UserPresenceCanonicalRequest) throws -> UserPresenceProof {
        let signature = try signOnce(request.signatureInput)
        return try UserPresenceProof(
            expiresAt: request.expiresAt,
            signature: Base64URL.encode(signature)
        )
    }

    func signPairingBinding(_ binding: PairingPresenceBinding) throws -> Data {
        try signOnce(binding.signatureInput)
    }

    func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) throws -> Data {
        try signOnce(binding.signatureInput)
    }

    private func signOnce(_ input: Data) throws -> Data {
        guard !consumed else { throw UserPresenceProofError.sessionConsumed }
        consumed = true
        defer { invalidate() }
        return try signing(input)
    }
}

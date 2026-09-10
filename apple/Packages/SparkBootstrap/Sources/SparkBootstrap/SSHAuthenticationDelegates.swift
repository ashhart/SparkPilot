import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Authentication

/// Offer password authentication once and fail the handshake explicitly when methods are exhausted.
final class PasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate,
    @unchecked Sendable
{
    private let username: String
    private let handshake: HandshakeGate
    private let lock = NSLock()
    private var password: String?
    private var offered = false

    init(username: String, password: String, handshake: HandshakeGate) {
        self.username = username
        self.password = password
        self.handshake = handshake
    }

    var exhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offered
    }

    /// Clear the accepted credential while the longer-lived SSH delegate remains active.
    func releaseCredential() {
        lock.lock()
        password = nil
        lock.unlock()
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        let alreadyOffered = offered
        let credential = password
        offered = true
        lock.unlock()

        guard !alreadyOffered, let credential else {
            // Fail exhausted authentication immediately instead of leaving NIOSSH waiting silently.
            handshake.fail(BootstrapSSHError.authenticationFailed)
            nextChallengePromise.succeed(nil)
            return
        }
        guard availableMethods.contains(.password) else {
            handshake.fail(
                BootstrapSSHError.connectionFailed(
                    "the Spark does not accept password authentication"
                )
            )
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: credential))
            )
        )
    }
}

// MARK: - Host key

/// Resolve asynchronous owner host-key approval without blocking the SSH event loop.
final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate,
    @unchecked Sendable
{
    private let host: String
    private let policy: HostKeyPolicy
    private let lock = NSLock()
    private var error: HostKeyError?

    init(host: String, policy: HostKeyPolicy) {
        self.host = host
        self.policy = policy
    }

    var recordedError: HostKeyError? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // Hash the OpenSSH serialized public-key blob to match ssh-keygen's displayed fingerprint.
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let blob = Data(base64Encoded: String(parts[1])) else {
            validationCompletePromise.fail(
                BootstrapSSHError.channelFailed("the host key could not be read")
            )
            return
        }
        let fingerprint = SSHHostKeyFingerprint(
            keyType: String(parts[0]),
            publicKeyBlob: blob
        )

        let host = self.host
        let policy = self.policy
        Task { [weak self] in
            do {
                _ = try await policy.decide(host: host, presented: fingerprint)
                validationCompletePromise.succeed(())
            } catch let hostKeyError as HostKeyError {
                self?.record(hostKeyError)
                validationCompletePromise.fail(hostKeyError)
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    private func record(_ error: HostKeyError) {
        lock.lock()
        self.error = error
        lock.unlock()
    }
}

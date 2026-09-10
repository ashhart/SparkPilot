import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SparkBootstrap

@Test func aRefusedHostKeyStopsBeforeThePasswordIsOffered() async throws {
    // Confirm the host key before offering administrator credentials.
    let server = try SSHSessionTestTestSSHServer()
    defer { server.shutdown() }

    let confirmer = SSHSessionTestRecordingConfirmer(accepts: false)
    let policy = HostKeyPolicy(store: InMemoryHostKeyStore(), confirmer: confirmer)
    await #expect(throws: BootstrapSSHError.self) {
        _ = try await NIOSSHBootstrapSession.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "spark",
            password: "hunter2",
            hostKeyPolicy: policy,
            handshakeTimeout: .seconds(10)
        )
    }
    #expect(confirmer.observations.count == 1, "the owner was asked")
    #expect(server.log.recordedCommands.isEmpty, "nothing ran")
}

@Test func theFingerprintTheOwnerIsShownIsTheServersOwn() async throws {
    // Match the fingerprint printed by ssh-keygen for owner comparison.
    let server = try SSHSessionTestTestSSHServer()
    defer { server.shutdown() }

    let store = InMemoryHostKeyStore()
    let (policy, confirmer) = sshSessionTestAcceptingPolicy(store: store)
    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: policy,
        handshakeTimeout: .seconds(10)
    )
    await session.close()

    let observed = try #require(confirmer.observations.first)
    #expect(observed.host == "127.0.0.1")
    #expect(observed.fingerprint == server.expectedFingerprint)
    #expect(observed.fingerprint.displayString.hasPrefix("SHA256:"))
    #expect(
        try store.fingerprint(forHost: "127.0.0.1") == server.expectedFingerprint,
        "a confirmed key is remembered, so the next launch does not ask again"
    )
}

@Test func aWrongPasswordIsReportedAsAnAuthenticationFailureAndOfferedOnlyOnce() async throws {
    // Offer a rejected password only once to avoid triggering account lockout through retries.
    let server = try SSHSessionTestTestSSHServer(password: "hunter2")
    defer { server.shutdown() }

    await #expect(throws: BootstrapSSHError.authenticationFailed) {
        _ = try await NIOSSHBootstrapSession.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "spark",
            password: "not-the-password",
            hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
            handshakeTimeout: .seconds(10)
        )
    }
}

@Test func connectDoesNotReturnUntilTheServerHasAuthenticated() async throws {
    // Reject a silent TCP listener that never completes the SSH handshake.
    let silent = try SSHSessionTestSilentTCPServer()
    defer { silent.shutdown() }

    let started = Date()
    await #expect(throws: BootstrapSSHError.self) {
        _ = try await NIOSSHBootstrapSession.connect(
            host: "127.0.0.1",
            port: silent.port,
            username: "spark",
            password: "hunter2",
            hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
            handshakeTimeout: .milliseconds(500)
        )
    }
    #expect(Date().timeIntervalSince(started) >= 0.4, "it waited rather than returning at TCP")
}

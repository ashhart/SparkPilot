import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SparkBootstrap

// MARK: - Host-key confirmation for the tests

/// Record the real host-key policy prompt before allowing the adapter to send a password.
final class SSHSessionTestRecordingConfirmer: HostKeyConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(host: String, fingerprint: SSHHostKeyFingerprint)] = []
    private let accepts: Bool

    init(accepts: Bool) { self.accepts = accepts }

    var observations: [(host: String, fingerprint: SSHHostKeyFingerprint)] {
        lock.withLock { seen }
    }

    func confirmFirstUse(host: String, fingerprint: SSHHostKeyFingerprint) async -> Bool {
        lock.withLock { seen.append((host, fingerprint)) }
        return accepts
    }
}

func sshSessionTestAcceptingPolicy(
    store: InMemoryHostKeyStore = InMemoryHostKeyStore()
) -> (HostKeyPolicy, SSHSessionTestRecordingConfirmer) {
    let confirmer = SSHSessionTestRecordingConfirmer(accepts: true)
    return (HostKeyPolicy(store: store, confirmer: confirmer), confirmer)
}

// MARK: - Tests

func sshSessionTestTestParameters() throws -> BootstrapCommand.Parameters {
    try BootstrapCommand.Parameters(
        operationID: UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!,
        artifactName: "spark-runtime_0.1.0-1_arm64.deb",
        sha256: String(repeating: "a", count: 64),
        size: 4096
    )
}

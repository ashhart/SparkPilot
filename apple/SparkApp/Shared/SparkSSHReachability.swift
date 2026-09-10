import Foundation
import Network
import SparkDiscovery

/// Whether a Spark's SSH port answers at all, so a restart can be seen begin and end before any login is tried.
public enum SparkSSHReachability {
    /// A plain TCP connect to port 22 with a short deadline; nothing is sent.
    public static func isListening(_ target: BootstrapSpark) async -> Bool {
        let host = SSHRuntimeBootstrapInstaller.hostName(for: target)
        return await isListening(host: host, port: 22, deadline: .seconds(3))
    }

    static func isListening(host: String, port: UInt16, deadline: Duration) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let outcome = ReachabilityOutcome()
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    outcome.settle(true, continuation)
                    connection.cancel()
                case .failed, .cancelled:
                    outcome.settle(false, continuation)
                case .waiting:
                    // No route yet is as good as unreachable for a restart watch; do not sit in the queue.
                    outcome.settle(false, continuation)
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .seconds(Int(deadline.components.seconds))
            ) {
                outcome.settle(false, continuation)
                connection.cancel()
            }
        }
    }
}

/// Resume a continuation exactly once across the state handler and the deadline.
private final class ReachabilityOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func settle(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        let first = !settled
        settled = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

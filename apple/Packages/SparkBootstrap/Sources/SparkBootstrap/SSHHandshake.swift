import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Handshake

/// Complete the handshake only after accepted SSH authentication rather than TCP connection establishment.
final class HandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var waiters: [EventLoopPromise<Void>] = []

    func succeed() { settle(.success(())) }

    func fail(_ error: any Error) { settle(.failure(error)) }

    /// Fail a connection that closes before authentication.
    func closed() {
        settle(
            .failure(
                BootstrapSSHError.connectionFailed("the connection closed during the SSH handshake")
            )
        )
    }

    private func settle(_ result: Result<Void, any Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let pending = waiters
        waiters = []
        lock.unlock()
        for promise in pending { promise.completeWith(result) }
    }

    /// Keep lock-held handshake updates synchronous.
    private func register(_ promise: EventLoopPromise<Void>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            promise.completeWith(outcome)
            return
        }
        waiters.append(promise)
        lock.unlock()
    }

    func waitForAuthentication(timeout: TimeAmount, on eventLoop: any EventLoop) async throws {
        let promise = eventLoop.makePromise(of: Void.self)
        register(promise)
        let timeoutTask = eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.fail(BootstrapSSHError.connectionFailed("the SSH handshake timed out"))
        }
        defer { timeoutTask.cancel() }
        try await promise.futureResult.get()
    }
}

/// Watches the parent channel for the end of the handshake.
final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let gate: HandshakeGate

    init(gate: HandshakeGate) {
        self.gate = gate
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            gate.succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        gate.closed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        gate.fail(error)
        context.fireErrorCaught(error)
    }
}

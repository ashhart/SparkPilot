import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Exec channel

/// Accumulates one command's output and exit status.
final class ExecOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()
    private var exitStatus: Int32?
    private var failure: (any Error)?
    private var noMoreData = false
    private var waiters: [EventLoopPromise<CommandResult>] = []

    /// Bound retained remote output so an endless stream cannot exhaust device memory.
    private static let outputLimit = 4 * 1024 * 1024

    func append(_ data: Data, isStandardError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardError {
            if standardError.count < Self.outputLimit { standardError.append(data) }
        } else {
            if standardOutput.count < Self.outputLimit { standardOutput.append(data) }
        }
    }

    /// Wait for output EOF or channel closure after exit status because flow-controlled data can arrive later.
    func recordExit(status: Int32) {
        lock.lock()
        exitStatus = status
        let ready = noMoreData
        lock.unlock()
        if ready { complete() }
    }

    /// Mark output complete only after the peer closes its sending side.
    func noMoreOutput() {
        lock.lock()
        noMoreData = true
        let ready = exitStatus != nil
        lock.unlock()
        if ready { complete() }
    }

    private func complete() {
        lock.lock()
        guard let exitStatus, failure == nil else {
            lock.unlock()
            return
        }
        let result = CommandResult(
            exitStatus: exitStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.succeed(result) }
    }

    func fail(_ error: any Error) {
        lock.lock()
        failure = error
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.fail(error) }
    }

    /// On channel closure, require an exit status before reporting command completion.
    func channelClosed() {
        lock.lock()
        noMoreData = true
        let haveStatus = exitStatus != nil
        let alreadyFailed = failure != nil
        lock.unlock()
        if alreadyFailed { return }
        if haveStatus {
            complete()
        } else {
            fail(BootstrapSSHError.noExitStatus)
        }
    }

    /// Register completion waiters synchronously so no lock crosses a suspension point.
    private func register(_ promise: EventLoopPromise<CommandResult>) {
        lock.lock()
        if let failure {
            lock.unlock()
            promise.fail(failure)
            return
        }
        if let exitStatus {
            let result = CommandResult(
                exitStatus: exitStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
            lock.unlock()
            promise.succeed(result)
            return
        }
        waiters.append(promise)
        lock.unlock()
    }

    func wait(timeout: TimeAmount, on eventLoop: any EventLoop) async throws -> CommandResult {
        let promise = eventLoop.makePromise(of: CommandResult.self)
        register(promise)

        let timeoutTask = eventLoop.scheduleTask(in: timeout) { [weak self] in
            self?.fail(BootstrapSSHError.channelFailed("the command timed out"))
        }
        defer { timeoutTask.cancel() }
        return try await promise.futureResult.get()
    }
}

/// Reads one exec channel.
final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let collector: ExecOutputCollector

    init(collector: ExecOutputCollector) {
        self.collector = collector
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch channelData.type {
        case .channel:
            collector.append(bytes, isStandardError: false)
        case .stdErr:
            collector.append(bytes, isStandardError: true)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            collector.recordExit(status: Int32(status.exitStatus))
        case ChannelEvent.inputClosed:
            collector.noMoreOutput()
        case let signal as SSHChannelRequestEvent.ExitSignal:
            // Treat signal termination as command failure regardless of captured output.
            collector.fail(
                BootstrapSSHError.channelFailed("the command was killed by \(signal.signalName)")
            )
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        collector.channelClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        collector.fail(error)
        context.close(promise: nil)
    }
}

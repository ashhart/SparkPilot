import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SparkBootstrap

/// Exercise host-key and authentication ordering against a loopback NIOSSH server rather than a session stub.

// MARK: - A server

final class SSHSessionTestFixedPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == username,
            case .password(let offered) = request.request,
            offered.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

/// What the server should do with an exec request.
struct SSHSessionTestExecBehaviour: Sendable {
    var standardOutput: String = ""
    var standardError: String = ""
    var exitStatus: Int32 = 0
    /// Accept an exec request without replying to exercise the client's command timeout.
    var neverExits = false
    /// Close the channel without sending an exit status.
    var closeWithoutStatus = false
    /// Send exit status before output to reproduce control-message overtaking deterministically.
    var exitStatusFirst = false
}

/// Reply to one exec request only after stdin closes, making client half-close observable.
final class SSHSessionTestServerExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let behaviour: SSHSessionTestExecBehaviour
    private let log: SSHSessionTestCommandLog
    private var executed = false
    private var inputClosed = false

    init(behaviour: SSHSessionTestExecBehaviour, log: SSHSessionTestCommandLog) {
        self.behaviour = behaviour
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        log.appendStandardInput(Data(buffer.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exec as SSHChannelRequestEvent.ExecRequest:
            log.appendCommand(exec.command)
            executed = true
            replyIfReady(context: context)
        case ChannelEvent.inputClosed:
            inputClosed = true
            replyIfReady(context: context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func replyIfReady(context: ChannelHandlerContext) {
        guard executed, inputClosed else { return }
        guard !behaviour.neverExits else { return }
        if behaviour.closeWithoutStatus {
            context.close(promise: nil)
            return
        }

        let exitStatus = {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitStatus(exitStatus: Int(self.behaviour.exitStatus))
            )
        }
        let output = {
            self.write(context: context, text: self.behaviour.standardOutput, type: .channel)
                .flatMap {
                    self.write(context: context, text: self.behaviour.standardError, type: .stdErr)
                }
        }

        // Complete queued writes before closing the fixture channel.
        let sent: EventLoopFuture<Void> =
            behaviour.exitStatusFirst
            ? exitStatus().flatMap { output() }
            : output().flatMap { exitStatus() }
        sent.whenComplete { _ in context.close(promise: nil) }
    }

    private func write(
        context: ChannelHandlerContext,
        text: String,
        type: SSHChannelData.DataType
    ) -> EventLoopFuture<Void> {
        guard !text.isEmpty else { return context.eventLoop.makeSucceededVoidFuture() }
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return context.writeAndFlush(
            wrapOutboundOut(SSHChannelData(type: type, data: .byteBuffer(buffer)))
        )
    }
}

/// What the server saw.
final class SSHSessionTestCommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var standardInput = Data()

    func appendCommand(_ line: String) {
        lock.lock()
        commands.append(line)
        lock.unlock()
    }

    func appendStandardInput(_ data: Data) {
        lock.lock()
        standardInput.append(data)
        lock.unlock()
    }

    var recordedCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    var recordedStandardInput: Data {
        lock.lock()
        defer { lock.unlock() }
        return standardInput
    }
}

/// An SSH server on a loopback port, torn down with the test.
final class SSHSessionTestTestSSHServer {
    let group: MultiThreadedEventLoopGroup
    let channel: any Channel
    let hostKey: NIOSSHPrivateKey
    let log = SSHSessionTestCommandLog()

    var port: Int { channel.localAddress?.port ?? 0 }

    /// Compute the expected owner fingerprint independently from the OpenSSH public-key blob using SHA-256.
    var expectedFingerprint: SSHHostKeyFingerprint {
        let openSSH = String(openSSHPublicKey: hostKey.publicKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1)
        return SSHHostKeyFingerprint(
            keyType: String(parts[0]),
            publicKeyBlob: Data(base64Encoded: String(parts[1]))!
        )
    }

    init(
        username: String = "spark",
        password: String = "hunter2",
        behaviour: SSHSessionTestExecBehaviour = SSHSessionTestExecBehaviour(standardOutput: "ok\n")
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let log = self.log
        self.channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(
                                .init(
                                    hostKeys: [hostKey],
                                    userAuthDelegate: SSHSessionTestFixedPasswordDelegate(
                                        username: username,
                                        password: password
                                    )
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: { child, type in
                                guard type == .session else {
                                    return child.eventLoop.makeFailedFuture(
                                        ChannelError.operationUnsupported
                                    )
                                }
                                // Enable half-close so stdin EOF does not tear down the fixture's output path.
                                return child.setOption(
                                    ChannelOptions.allowRemoteHalfClosure,
                                    value: true
                                ).flatMap {
                                    child.eventLoop.makeCompletedFuture {
                                        try child.pipeline.syncOperations.addHandler(
                                            SSHSessionTestServerExecHandler(
                                                behaviour: behaviour,
                                                log: log
                                            )
                                        )
                                    }
                                }
                            }
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        self.group = group
        self.hostKey = hostKey
    }

    func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// Accept TCP without speaking SSH to simulate a stalled service on port 22.
final class SSHSessionTestSilentTCPServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: any Channel

    var port: Int { channel.localAddress?.port ?? 0 }

    init() throws {
        self.channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

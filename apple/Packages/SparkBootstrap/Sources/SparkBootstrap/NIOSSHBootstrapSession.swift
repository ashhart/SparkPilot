import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Translate confirmed password authentication into bounded fixed exec requests without shells, PTYs, forwarding or authentication retries.
public actor NIOSSHBootstrapSession: BootstrapSSHSession {
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let commandTimeout: TimeAmount
    private var closed = false

    /// Bound each SSH command, allowing dpkg time without leaving onboarding suspended indefinitely.
    public static let defaultCommandTimeout: TimeAmount = .seconds(180)

    private init(
        channel: any Channel,
        group: MultiThreadedEventLoopGroup,
        commandTimeout: TimeAmount
    ) {
        self.channel = channel
        self.group = group
        self.commandTimeout = commandTimeout
    }

    /// Bound SSH handshakes while allowing time for owner fingerprint confirmation.
    public static let defaultHandshakeTimeout: TimeAmount = .seconds(300)

    /// Return only after host-key confirmation and accepted SSH authentication, then release the authentication password.
    public static func connect(
        host: String,
        port: Int = 22,
        username: String,
        password: String,
        hostKeyPolicy: HostKeyPolicy,
        handshakeTimeout: TimeAmount = NIOSSHBootstrapSession.defaultHandshakeTimeout,
        commandTimeout: TimeAmount = NIOSSHBootstrapSession.defaultCommandTimeout
    ) async throws -> NIOSSHBootstrapSession {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handshake = HandshakeGate()
        let authenticationDelegate = PasswordAuthenticationDelegate(
            username: username,
            password: password,
            handshake: handshake
        )
        let serverAuthenticationDelegate = HostKeyValidationDelegate(
            host: host,
            policy: hostKeyPolicy
        )

        func fail(_ error: any Error) async -> BootstrapSSHError {
            try? await group.shutdownGracefully()
            if let hostKeyError = serverAuthenticationDelegate.recordedError {
                return BootstrapSSHError.hostKey(hostKeyError)
            }
            if let bootstrapError = error as? BootstrapSSHError {
                return bootstrapError
            }
            if authenticationDelegate.exhausted {
                return BootstrapSSHError.authenticationFailed
            }
            return BootstrapSSHError.connectionFailed("\(error)")
        }

        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(20))
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        NIOSSHHandler(
                            role: .client(
                                SSHClientConfiguration(
                                    userAuthDelegate: authenticationDelegate,
                                    serverAuthDelegate: serverAuthenticationDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            // Reject inbound SSH channels from the Spark.
                            inboundChildChannelInitializer: nil
                        ),
                        HandshakeHandler(gate: handshake),
                    ])
                }
                .connect(host: host, port: port)
                .get()
        } catch {
            throw await fail(error)
        }

        do {
            try await handshake.waitForAuthentication(
                timeout: handshakeTimeout,
                on: channel.eventLoop
            )
        } catch {
            try? await channel.close().get()
            throw await fail(error)
        }

        // Discard the accepted password immediately; retries request it again from the owner.
        authenticationDelegate.releaseCredential()
        return NIOSSHBootstrapSession(
            channel: channel,
            group: group,
            commandTimeout: commandTimeout
        )
    }

    public func run(
        _ command: BootstrapCommand,
        parameters: BootstrapCommand.Parameters,
        standardInput: Data?
    ) async throws -> CommandResult {
        guard !closed else {
            throw BootstrapSSHError.channelFailed("the session is closed")
        }
        let line = command.line(parameters)
        let collector = ExecOutputCollector()

        let parent = channel
        let childChannel: any Channel
        do {
            childChannel = try await parent.pipeline
                .handler(type: NIOSSHHandler.self)
                .flatMap { handler in
                    let promise = parent.eventLoop.makePromise(of: (any Channel).self)
                    handler.createChannel(promise) { child, channelType in
                        guard channelType == .session else {
                            return child.eventLoop.makeFailedFuture(
                                BootstrapSSHError.channelFailed("unexpected channel type")
                            )
                        }
                        // Allow output half-close so the channel can still deliver the command's exit status.
                        return child.setOption(
                            ChannelOptions.allowRemoteHalfClosure,
                            value: true
                        ).flatMap {
                            child.pipeline.addHandlers([
                                ExecHandler(collector: collector)
                            ])
                        }
                    }
                    return promise.futureResult
                }
                .get()
        } catch {
            throw BootstrapSSHError.channelFailed("\(error)")
        }

        do {
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: line, wantReply: true)
            ).get()

            if let standardInput, !standardInput.isEmpty {
                // Stream artifact uploads in bounded chunks to limit transient allocations.
                var offset = standardInput.startIndex
                let chunkSize = 32 * 1024
                while offset < standardInput.endIndex {
                    let end =
                        standardInput.index(
                            offset,
                            offsetBy: chunkSize,
                            limitedBy: standardInput.endIndex
                        ) ?? standardInput.endIndex
                    var buffer = childChannel.allocator.buffer(capacity: end - offset)
                    buffer.writeBytes(standardInput[offset..<end])
                    try await childChannel.writeAndFlush(
                        SSHChannelData(
                            type: .channel,
                            data: .byteBuffer(buffer)
                        )
                    ).get()
                    offset = end
                }
            }
            // Close stdin so cat and sha256sum can finish consuming their input.
            try await childChannel.close(mode: .output).get()

            let result = try await collector.wait(
                timeout: commandTimeout,
                on: childChannel.eventLoop
            )
            try? await childChannel.close().get()
            return result
        } catch let error as BootstrapSSHError {
            try? await childChannel.close().get()
            throw error
        } catch {
            try? await childChannel.close().get()
            throw BootstrapSSHError.channelFailed("\(error)")
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

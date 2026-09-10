import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SparkBootstrap

@Test func aCommandsOutputAndExitStatusComeBackWhole() async throws {
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(
            standardOutput: "installed\n",
            standardError: "a warning\n",
            exitStatus: 0
        )
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    defer { Task { await session.close() } }

    let result = try await session.run(
        .prepareWorkDirectory,
        parameters: try sshSessionTestTestParameters(),
        standardInput: nil
    )
    #expect(result.exitStatus == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "installed\n")
    #expect(String(decoding: result.standardError, as: UTF8.self) == "a warning\n")
    #expect(
        server.log.recordedCommands == [
            BootstrapCommand.prepareWorkDirectory.line(try sshSessionTestTestParameters())
        ],
        "the server saw exactly the rendered command, with nothing added"
    )
}

@Test func outputThatArrivesAfterTheExitStatusIsStillReported() async throws {
    // Wait for flow-controlled output even when exit status arrives first.
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(
            standardOutput: "the report the installer parses\n",
            standardError: "a warning\n",
            exitStatus: 0,
            exitStatusFirst: true
        )
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    defer { Task { await session.close() } }

    let result = try await session.run(
        .prepareWorkDirectory,
        parameters: try sshSessionTestTestParameters(),
        standardInput: nil
    )
    #expect(result.exitStatus == 0)
    #expect(
        String(decoding: result.standardOutput, as: UTF8.self)
            == "the report the installer parses\n"
    )
    #expect(String(decoding: result.standardError, as: UTF8.self) == "a warning\n")
}

@Test func aNonZeroExitIsReportedRatherThanTreatedAsSuccess() async throws {
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(standardError: "dpkg: error\n", exitStatus: 1)
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    defer { Task { await session.close() } }

    let result = try await session.run(
        .prepareWorkDirectory,
        parameters: try sshSessionTestTestParameters(),
        standardInput: nil
    )
    #expect(result.exitStatus == 1)
}

@Test func aCommandThatNeverExitsTimesOutRatherThanHanging() async throws {
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(neverExits: true)
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10),
        commandTimeout: .milliseconds(500)
    )
    defer { Task { await session.close() } }

    await #expect(throws: BootstrapSSHError.self) {
        _ = try await session.run(
            .prepareWorkDirectory,
            parameters: try sshSessionTestTestParameters(),
            standardInput: nil
        )
    }
}

@Test func aChannelThatClosesWithoutAnExitStatusIsAFailure() async throws {
    // Treat premature channel closure as an unknown command result rather than success.
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(closeWithoutStatus: true)
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    defer { Task { await session.close() } }

    await #expect(throws: BootstrapSSHError.noExitStatus) {
        _ = try await session.run(
            .prepareWorkDirectory,
            parameters: try sshSessionTestTestParameters(),
            standardInput: nil
        )
    }
}

@Test func standardInputReachesTheCommandAndIsTerminated() async throws {
    // Send stdin EOF so file transfer and digest-check commands can finish.
    let server = try SSHSessionTestTestSSHServer(
        behaviour: SSHSessionTestExecBehaviour(standardOutput: "ok\n")
    )
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    defer { Task { await session.close() } }

    // Larger than the 32 KiB write chunk, so the chunking is exercised too.
    let payload = Data(repeating: 0x41, count: 70_000)
    _ = try await session.run(
        .prepareWorkDirectory,
        parameters: try sshSessionTestTestParameters(),
        standardInput: payload
    )
    #expect(server.log.recordedStandardInput == payload)
}

@Test func aClosedSessionRefusesFurtherCommands() async throws {
    let server = try SSHSessionTestTestSSHServer()
    defer { server.shutdown() }

    let session = try await NIOSSHBootstrapSession.connect(
        host: "127.0.0.1",
        port: server.port,
        username: "spark",
        password: "hunter2",
        hostKeyPolicy: sshSessionTestAcceptingPolicy().0,
        handshakeTimeout: .seconds(10)
    )
    await session.close()
    // Closing twice is a no-op, not a crash.
    await session.close()

    await #expect(throws: BootstrapSSHError.self) {
        _ = try await session.run(
            .prepareWorkDirectory,
            parameters: try sshSessionTestTestParameters(),
            standardInput: nil
        )
    }
}

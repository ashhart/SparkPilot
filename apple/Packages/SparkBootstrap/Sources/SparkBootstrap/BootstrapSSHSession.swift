import Foundation

/// One command's result on the Spark.
public struct CommandResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitStatus: Int32, standardOutput: Data, standardError: Data) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitStatus == 0 }
    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Expose only validated BootstrapCommand execution, excluding arbitrary strings, PTYs and interactive channels.
public protocol BootstrapSSHSession: Sendable {
    /// Use stdin for either transferred bytes or a sudo password, never both.
    func run(
        _ command: BootstrapCommand,
        parameters: BootstrapCommand.Parameters,
        standardInput: Data?
    ) async throws -> CommandResult

    /// Close the connection and release anything it holds.
    func close() async
}

public enum BootstrapSSHError: Error, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case channelFailed(String)
    case hostKey(HostKeyError)
    /// The remote closed without reporting an exit status.
    case noExitStatus
    case timedOut(BootstrapCommand)
}

extension BootstrapSSHError: Equatable {
    public static func == (lhs: BootstrapSSHError, rhs: BootstrapSSHError) -> Bool {
        switch (lhs, rhs) {
        case (.connectionFailed(let a), .connectionFailed(let b)): return a == b
        case (.authenticationFailed, .authenticationFailed): return true
        case (.channelFailed(let a), .channelFailed(let b)): return a == b
        case (.hostKey(let a), .hostKey(let b)): return a == b
        case (.noExitStatus, .noExitStatus): return true
        case (.timedOut(let a), .timedOut(let b)): return a == b
        default: return false
        }
    }
}

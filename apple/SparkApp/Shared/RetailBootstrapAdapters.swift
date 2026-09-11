import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport

/// The installer the app ships with, over SwiftNIO SSH.
public struct SSHRuntimeBootstrapInstaller: RuntimeBootstrapInstalling {
    private let trustRoot: ReleaseTrustRoot
    private let source: any ReleaseSource
    private let hostKeyPolicy: HostKeyPolicy
    private let username: String

    public init(
        trustRoot: ReleaseTrustRoot,
        source: any ReleaseSource,
        hostKeyPolicy: HostKeyPolicy,
        username: String
    ) {
        self.trustRoot = trustRoot
        self.source = source
        self.hostKeyPolicy = hostKeyPolicy
        self.username = username
    }

    public func prepareRuntimeUpdate() async throws -> RuntimeUpdateBundle {
        try await RuntimeBootstrapInstaller(trustRoot: trustRoot, source: source)
            .prepareUpdateBundle()
    }

    public func availableRuntimeUpdateReleaseID() async throws -> String {
        try await RuntimeBootstrapInstaller(trustRoot: trustRoot, source: source)
            .availableUpdateReleaseID()
    }

    public func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        try await install(
            on: target,
            administratorPassword: administratorPassword,
            progress: { _ in }
        )
    }

    public func install(
        on target: BootstrapSpark,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult {
        try await install(
            on: target,
            administratorUsername: nil,
            administratorPassword: administratorPassword,
            progress: progress
        )
    }

    public func install(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult {
        let host = Self.hostName(for: target)
        let submittedUsername = administratorUsername?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginUsername = submittedUsername.flatMap { $0.isEmpty ? nil : $0 } ?? username
        let session = try await NIOSSHBootstrapSession.connect(
            host: host,
            username: loginUsername,
            password: administratorPassword,
            hostKeyPolicy: hostKeyPolicy
        )
        defer { Task { await session.close() } }

        let installer = RuntimeBootstrapInstaller(
            trustRoot: trustRoot,
            source: source,
            progress: ClosureBootstrapProgress(handler: progress)
        )
        return try await installer.install(
            over: session,
            administratorPassword: administratorPassword,
            fallbackName: host
        )
    }

    public func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        let session = try await connect(
            to: target,
            administratorUsername: administratorUsername,
            administratorPassword: administratorPassword
        )
        defer { Task { await session.close() } }
        return try await RuntimeBootstrapInstaller(trustRoot: trustRoot, source: source)
            .preflight(over: session)
    }

    private func connect(
        to target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> NIOSSHBootstrapSession {
        let submitted = administratorUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await NIOSSHBootstrapSession.connect(
            host: Self.hostName(for: target),
            username: submitted.flatMap { $0.isEmpty ? nil : $0 } ?? username,
            password: administratorPassword,
            hostKeyPolicy: hostKeyPolicy
        )
    }

    public func upgrade(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws {
        let host = Self.hostName(for: target)
        let submittedUsername = administratorUsername?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginUsername = submittedUsername.flatMap { $0.isEmpty ? nil : $0 } ?? username
        let session = try await NIOSSHBootstrapSession.connect(
            host: host,
            username: loginUsername,
            password: administratorPassword,
            hostKeyPolicy: hostKeyPolicy
        )
        defer { Task { await session.close() } }

        let installer = RuntimeBootstrapInstaller(
            trustRoot: trustRoot,
            source: source,
            progress: ClosureBootstrapProgress(handler: progress)
        )
        try await installer.upgrade(
            over: session,
            administratorPassword: administratorPassword
        )
    }

    /// Uses the owner-supplied machine hostname for SSH rather than treating a Bonjour service name as a host.
    static func hostName(for target: BootstrapSpark) -> String {
        if case .hostPort(let host, _) = target.endpoint { return "\(host)" }
        var name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(" ssh") {
            name.removeLast(4)
        }
        return name.lowercased().hasSuffix(".local") ? name : "\(name).local"
    }
}

/// The pairing service the app ships with.
public struct SparkFirstOwnerPairingService: FirstOwnerPairingServicing {
    private let pairing: FirstOwnerPairing

    public init(pairing: FirstOwnerPairing) {
        self.pairing = pairing
    }

    public func claim(_ bootstrap: RuntimeBootstrapResult, route: URL) async throws -> NodeTrust {
        try await pairing.claim(bootstrap, route: route)
    }
}

public struct SparkAdditionalDevicePairingService: AdditionalDevicePairingServicing {
    private let pairing: FirstOwnerPairing
    private let identity: BatchPairingParticipantIdentity

    public init(pairing: FirstOwnerPairing, identity: BatchPairingParticipantIdentity) {
        self.pairing = pairing
        self.identity = identity
    }

    public func recipientIdentity() throws -> BatchPairingParticipantIdentity { identity }

    public func claim(
        _ package: AdditionalDevicePairingPackage,
        route: URL
    ) async throws -> NodeTrust {
        try await pairing.claim(package, route: route)
    }
}

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

/// Returns bootstrap-authenticated authority and TLS trust material with installation so pairing needs no unverified follow-up lookup.
public protocol RuntimeBootstrapInstalling: Sendable {
    /// Returns the verified bundled release identity without loading package bytes.
    func availableRuntimeUpdateReleaseID() async throws -> String

    /// Prepares a verified release for signed HTTP updates without opening SSH or requesting administrator credentials.
    func prepareRuntimeUpdate() async throws -> RuntimeUpdateBundle

    /// Read the Spark without changing it (§10.2 steps 5-6).
    func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult

    func install(
        on target: BootstrapSpark,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult

    func install(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult

    /// Repairs or upgrades a paired Spark without repeating first-owner bootstrap.
    func upgrade(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws
}

extension RuntimeBootstrapInstalling {
    /// Reports unavailable preflight explicitly instead of presenting an unchecked machine as clear for installation.
    public func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        throw RuntimeBootstrapError.notConfigured
    }

    public func availableRuntimeUpdateReleaseID() async throws -> String {
        throw RuntimeBootstrapError.notConfigured
    }

    public func prepareRuntimeUpdate() async throws -> RuntimeUpdateBundle {
        throw RuntimeBootstrapError.notConfigured
    }

    public func install(
        on target: BootstrapSpark,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult {
        try await install(on: target, administratorPassword: administratorPassword)
    }

    public func install(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult {
        try await install(
            on: target,
            administratorPassword: administratorPassword,
            progress: progress
        )
    }

    public func upgrade(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws {
        throw RuntimeBootstrapError.notConfigured
    }
}

/// Provides a test and preview fallback; shipping entry points use BootstrapComposition.
public struct PendingRuntimeBootstrapInstaller: RuntimeBootstrapInstalling {
    public init() {}

    public func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        throw RuntimeBootstrapError.notConfigured
    }
}

public enum RuntimeBootstrapError: Error, Sendable, Equatable {
    case notConfigured
}

/// Claims the first-owner invitation the install produced.
public protocol FirstOwnerPairingServicing: Sendable {
    func claim(_ bootstrap: RuntimeBootstrapResult, route: URL) async throws -> NodeTrust
}

/// Claims a short-lived invitation transferred from an owner device.
public protocol AdditionalDevicePairingServicing: Sendable {
    func recipientIdentity() throws -> BatchPairingParticipantIdentity
    func claim(
        _ package: AdditionalDevicePairingPackage,
        route: URL
    ) async throws -> NodeTrust
}

extension AdditionalDevicePairingServicing {
    public func recipientIdentity() throws -> BatchPairingParticipantIdentity {
        throw BatchDevicePairingServiceError.identityUnavailable
    }
}

public enum BatchDevicePairingServiceError: Error, Equatable, Sendable {
    case identityUnavailable
}

public typealias SparkOOBEServiceFactory = @Sendable (URL) -> any SparkOOBEServicing

/// Use a named clock: Swift 6.3.3 miscompiles inline sleep defaults, aborting with "freed pointer was not the last allocation".
public enum RetailOnboardingClock {
    public static func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

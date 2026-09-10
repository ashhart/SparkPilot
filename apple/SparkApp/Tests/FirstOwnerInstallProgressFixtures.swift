import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Emits installer progress before each command and during failure cleanup to match production ordering.
actor FirstOwnerFlowTestReportingInstaller: RuntimeBootstrapInstalling {
    /// Record commands preceding failure while expecting cleanup on either outcome.
    private let announced: [BootstrapCommand]
    private let failure: (any Error)?

    init(announced: [BootstrapCommand], failure: (any Error)? = nil) {
        self.announced = announced
        self.failure = failure
    }

    /// The Spark answers its survey at once: these flows start after the first-boot restart.
    func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        HostPreflight(survey: HostSurvey.parse("survey=1\nos=DGX OS 7.2\n"))
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        try await install(
            on: target,
            administratorPassword: administratorPassword,
            progress: { _ in }
        )
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws -> RuntimeBootstrapResult {
        for command in announced { progress(command) }
        // Cleanup runs after failed installation as well as success.
        progress(.cleanUp)
        if let failure { throw failure }
        return firstOwnerFlowTestBootstrapResult()
    }
}

/// Fails at bootstrapOwner after preceding steps complete so only the pairing row remains in flight.
let firstOwnerFlowTestCommandsUpToOwnerBootstrap: [BootstrapCommand] = [
    .prepareWorkDirectory,
    .verifyDigest,
    .verifyDetachedSignature,
    .verifyAgainstInstalledTrustRoot,
    .installPackage,
    .enablePrivilegedHelper,
    .enableRuntime,
    .bootstrapOwner,
]

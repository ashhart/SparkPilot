import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

public struct BuildExecutionArtifact: Sendable, Equatable {
    public let id: UUID
    public let kind: GeneratedAPI.BuildArtifactEvidenceKind
    public let relativePath: String
    public let bytes: Data

    public init(
        id: UUID = UUID(),
        kind: GeneratedAPI.BuildArtifactEvidenceKind,
        relativePath: String,
        bytes: Data
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.bytes = bytes
    }

    public var evidence: GeneratedAPI.BuildArtifactEvidence {
        GeneratedAPI.BuildArtifactEvidence(
            artifactId: id.uuidString.lowercased(),
            kind: kind,
            relativePath: relativePath,
            sha256: SHA256Digest.hex(bytes),
            sizeBytes: bytes.count
        )
    }
}

public struct BuildExecutionOutcome: Sendable, Equatable {
    public let exitState: GeneratedAPI.BuildResultEvidenceExitState
    public let output: String
    public let testFailures: [GeneratedAPI.BuildTestFailure]
    public let diagnostics: [GeneratedAPI.BuildDiagnostic]
    public let artifacts: [BuildExecutionArtifact]

    public init(
        exitState: GeneratedAPI.BuildResultEvidenceExitState,
        output: String,
        testFailures: [GeneratedAPI.BuildTestFailure] = [],
        diagnostics: [GeneratedAPI.BuildDiagnostic] = [],
        artifacts: [BuildExecutionArtifact] = []
    ) {
        self.exitState = exitState
        self.output = output
        self.testFailures = testFailures
        self.diagnostics = diagnostics
        self.artifacts = artifacts
    }
}

public protocol BuildSourceFetching: Sendable {
    func fetch(
        ticket: GeneratedAPI.BuildSourceTicket,
        into directory: URL
    ) async throws -> URL
}

public protocol TypedBuildExecuting: Sendable {
    func execute(
        recipe: GeneratedAPI.BuildRecipePayload,
        sourceDirectory: URL
    ) async throws -> BuildExecutionOutcome
}

public enum BuildWorkerExecutionError: Error, Equatable, Sendable {
    case repositoryMissing
    case repositoryURLRefused
    case sourceTooLarge
    case sourceDigestMismatch
    case checkoutMismatch
    case unsafeArtifact
    case invalidRecipeField(String)
    case timedOut
    case outputTooLarge
    case toolFailed(String, Int32)
    case unsupportedPlatform
}

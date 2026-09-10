import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

/// Verify install ordering, stdin-only credentials, artifact cleanup and authority rejection through the fake SSH boundary.

// MARK: - Test doubles

struct InstallerTestRecordedCommand: Sendable {
    let command: BootstrapCommand
    let standardInput: Data?
}

actor InstallerTestFakeSession: BootstrapSSHSession {
    private(set) var recorded: [InstallerTestRecordedCommand] = []
    private var responses: [String: CommandResult] = [:]
    private var failures: [BootstrapCommand: Int32] = [:]

    /// Default the host survey fixture to an empty factory-reset Spark.
    private var surveyOutput = Data("survey=1\nos=DGX OS 7.2\n".utf8)

    init(bootstrapReport: Data, installedTrustRoot: Bool = false) {
        responses["bootstrapOwner"] = CommandResult(
            exitStatus: 0,
            standardOutput: bootstrapReport,
            standardError: Data()
        )
        responses["verifyAgainstInstalledTrustRoot"] = CommandResult(
            exitStatus: 0,
            standardOutput: installedTrustRoot
                ? Data(#"{"digest_verified":true}"#.utf8)
                : Data("spark-bootstrap-no-installed-trust-root\n".utf8),
            standardError: Data()
        )
    }

    func fail(_ command: BootstrapCommand, status: Int32 = 1) {
        failures[command] = status
    }

    func reportSurvey(_ output: String) {
        surveyOutput = Data(output.utf8)
    }

    func run(
        _ command: BootstrapCommand,
        parameters: BootstrapCommand.Parameters,
        standardInput: Data?
    ) async throws -> CommandResult {
        recorded.append(
            InstallerTestRecordedCommand(command: command, standardInput: standardInput)
        )
        if let status = failures[command] {
            return CommandResult(
                exitStatus: status,
                standardOutput: Data(),
                standardError: Data("the remote command failed\n".utf8)
            )
        }
        switch command {
        case .bootstrapOwner:
            return responses["bootstrapOwner"]!
        case .verifyAgainstInstalledTrustRoot:
            return responses["verifyAgainstInstalledTrustRoot"]!
        case .surveyHost:
            return CommandResult(
                exitStatus: 0,
                standardOutput: surveyOutput,
                standardError: Data()
            )
        default:
            return CommandResult(exitStatus: 0, standardOutput: Data(), standardError: Data())
        }
    }

    func close() async {}

    var commands: [BootstrapCommand] { recorded.map(\.command) }

    func input(for command: BootstrapCommand) -> Data? {
        recorded.first { $0.command == command }?.standardInput
    }

    var allInputs: [Data] { recorded.compactMap(\.standardInput) }
}

struct InstallerTestFakeReleaseSource: ReleaseSource {
    let manifestData: Data
    let packageData: Data
    let signatureData: Data

    func manifest() async throws -> Data { manifestData }
    func artifact(_ artifact: ReleaseArtifact) async throws -> Data { packageData }
    func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data { signatureData }
}

struct InstallerTestManifestOnlyReleaseSource: ReleaseSource {
    let manifestData: Data

    func manifest() async throws -> Data { manifestData }
    func artifact(_ artifact: ReleaseArtifact) async throws -> Data {
        throw RuntimeBootstrapError.artifactUnavailable("package must not be read")
    }
    func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data {
        throw RuntimeBootstrapError.artifactUnavailable("signature must not be read")
    }
}

// MARK: - A signed release, built here so the test owns its own key

/// Use a fixed signing seed for reproducible failures.
let installerTestSigningKey: Curve25519.Signing.PrivateKey = {
    let seed = Data(repeating: 0x2A, count: 32)
    // swift-format-ignore: NeverForceUnwrap
    return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
}()

let installerTestPackageBytes = Data("a package that pretends to be a deb".utf8)

let installerTestMoment = RFC3339.date(from: "2026-08-27T00:00:00Z")!

func installerTestTestTrustRoot(
    channels: [String] = ["dev"],
    purposes: [String] = [ReleaseTrustRoot.manifestPurpose, ReleaseTrustRoot.packagePurpose]
) throws -> ReleaseTrustRoot {
    let json = JSONValue.object([
        "schema": .integer(1),
        "keys": .array([
            .object([
                "key_id": .string("test-key"),
                "algorithm": .string("ed25519"),
                "public_key": .string(
                    installerTestSigningKey.publicKey.rawRepresentation.hexString
                ),
                "channels": .array(channels.map(JSONValue.string)),
                "purposes": .array(purposes.map(JSONValue.string)),
                "not_before": .string("2026-01-01T00:00:00Z"),
                "not_after": .string("2027-01-01T00:00:00Z"),
            ])
        ]),
    ])
    return try ReleaseTrustRoot.parse(try json.canonicalBytes())
}

func installerTestSignedManifest(
    channel: String = "dev",
    name: String = "spark-runtime_0.1.0-1_arm64.deb",
    minimumDGXOS: String = "7.0",
    maximumDGXOS: String? = nil,
    package: Data = installerTestPackageBytes
) throws -> Data {
    var members: [String: JSONValue] = [
        "version": .string("0.1.0"),
        "channel": .string(channel),
        "released_at": .string("2026-08-27T00:00:00Z"),
        "minimum_dgx_os": .string(minimumDGXOS),
        "api_version": .integer(1),
        "artifacts": .array([
            .object([
                "name": .string(name),
                "architecture": .string("aarch64"),
                "url": .string("https://releases.example.invalid/dev/\(name)"),
                "size": .integer(Int64(package.count)),
                "sha256": .string(SHA256Hex.of(package)),
                "signature_url": .string("https://releases.example.invalid/dev/\(name).sig"),
            ])
        ]),
    ]
    if let maximumDGXOS { members["maximum_dgx_os"] = .string(maximumDGXOS) }

    let canonical = try JSONValue.object(members).canonicalBytes()
    let signature = try installerTestSigningKey.signature(for: canonical)
    members["signature"] = .object([
        "key_id": .string("test-key"),
        "algorithm": .string("ed25519"),
        "value": .string(Base64URL.encode(signature)),
    ])
    return try JSONValue.object(members).canonicalBytes()
}

func installerTestBootstrapReport(
    authorityKey: Data? = nil,
    tlsFingerprint: String? = nil
) throws -> Data {
    let key = authorityKey ?? Data(repeating: 0x11, count: 32)
    let members: [String: JSONValue] = [
        "node_id": .string("6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f"),
        "node_name": .string("Spark"),
        "authority_fingerprint": .string(SHA256Hex.of(key)),
        "authority_public_key": .string(key.hexString),
        "tls_fingerprint": .string(tlsFingerprint ?? String(repeating: "c", count: 64)),
        "expires_at": .string("2026-08-27T00:05:00Z"),
        "invitation": .object([
            "invitation_id": .string("2f2f2f2f-2f2f-4f2f-8f2f-2f2f2f2f2f2f"),
            "role": .string("owner"),
        ]),
    ]
    return try JSONValue.object(members).canonicalBytes()
}

func installerTestInstaller(
    trustRoot: ReleaseTrustRoot? = nil,
    manifest: Data? = nil,
    package: Data = installerTestPackageBytes,
    signature: Data? = nil
) throws -> RuntimeBootstrapInstaller {
    let root = try trustRoot ?? installerTestTestTrustRoot()
    let manifestData = try manifest ?? installerTestSignedManifest()
    let signatureData = try signature ?? installerTestSigningKey.signature(for: package)
    return RuntimeBootstrapInstaller(
        trustRoot: root,
        source: InstallerTestFakeReleaseSource(
            manifestData: manifestData,
            packageData: package,
            signatureData: signatureData
        ),
        now: { installerTestMoment }
    )
}

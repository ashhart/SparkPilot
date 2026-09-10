import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

@Test func aPackageThatDoesNotMatchTheManifestNeverLeavesTheDevice() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    // Change artifact bytes without changing size so the test exercises digest verification.
    let swapped = Data("A PACKAGE THAT PRETENDS TO BE A DEB".utf8)
    #expect(swapped.count == installerTestPackageBytes.count)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(
            package: swapped,
            signature: try installerTestSigningKey.signature(for: swapped)
        )
        .install(over: session, administratorPassword: "hunter2")
    }
    #expect(await session.commands.isEmpty, "nothing was sent to the Spark")
}

@Test func aTruncatedDownloadIsCaughtBySize() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    let short = installerTestPackageBytes.prefix(10)
    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(
            package: Data(short),
            signature: try installerTestSigningKey.signature(for: Data(short))
        ).install(over: session, administratorPassword: "hunter2")
    }
    #expect(await session.commands.isEmpty)
}

@Test func aMissingOrShortDetachedSignatureIsRefused() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await #expect(
        throws: RuntimeBootstrapError.artifactSignatureInvalid(
            "the detached signature is not 64 bytes"
        )
    ) {
        _ = try await installerTestInstaller(signature: Data()).install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    #expect(await session.commands.isEmpty)
}

@Test func aSignatureFromAnotherKeyIsRefusedBeforeTransfer() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    let attacker = Curve25519.Signing.PrivateKey()
    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(
            signature: try attacker.signature(for: installerTestPackageBytes)
        )
        .install(over: session, administratorPassword: "hunter2")
    }
    #expect(await session.commands.isEmpty)
}

@Test func anUnsignedManifestNeverReachesTheSpark() async throws {
    var members = try #require(JSONValue.parse(try installerTestSignedManifest()).objectValue)
    members.removeValue(forKey: "signature")
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(
            manifest: try JSONValue.object(members).canonicalBytes()
        )
        .install(over: session, administratorPassword: "hunter2")
    }
    #expect(await session.commands.isEmpty)
}

@Test func aProductionChannelManifestIsRefusedUnderADirectTrustRoot() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await #expect(throws: RuntimeBootstrapError.trust(.delegationRequired("stable"))) {
        _ = try await installerTestInstaller(
            trustRoot: try installerTestTestTrustRoot(channels: ["stable"]),
            manifest: try installerTestSignedManifest(channel: "stable")
        ).install(over: session, administratorPassword: "hunter2")
    }
    #expect(await session.commands.isEmpty)
}

@Test func anOlderDGXOSThanTheReleaseNeedsIsRefused() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(
            manifest: try installerTestSignedManifest(minimumDGXOS: "7.2")
        )
        .install(over: session, administratorPassword: "hunter2", dgxOSVersion: "7.0")
    }
    #expect(await session.commands.isEmpty)

    // Verify that supported artifacts proceed through the gate.
    let ok = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller(
        manifest: try installerTestSignedManifest(minimumDGXOS: "7.0")
    )
    .install(over: ok, administratorPassword: "hunter2", dgxOSVersion: "7.2")
    #expect(await ok.commands.contains(.installPackage))
}

@Test func aSubstitutedAuthorityKeyIsCaughtBeforePairing() async throws {
    // Reject bootstrap authority keys that do not match their reported fingerprint before attempting pairing.
    let report = JSONValue.object([
        "node_id": .string("6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f"),
        "node_name": .string("Spark"),
        "authority_fingerprint": .string(String(repeating: "d", count: 64)),
        "authority_public_key": .string(Data(repeating: 0x11, count: 32).hexString),
        "tls_fingerprint": .string(String(repeating: "c", count: 64)),
        "expires_at": .string("2026-08-27T00:05:00Z"),
        "invitation": .object(["role": .string("owner")]),
    ])
    let session = InstallerTestFakeSession(bootstrapReport: try report.canonicalBytes())

    await #expect(
        throws: RuntimeBootstrapError.malformedBootstrapReport(
            "authority_public_key does not hash to authority_fingerprint"
        )
    ) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    #expect(await session.commands.contains(.cleanUp))
}

@Test func aReportThatConfusesTheTwoFingerprintsIsRefused() async throws {
    let key = Data(repeating: 0x11, count: 32)
    let fingerprint = SHA256Hex.of(key)
    // Reject an authority fingerprint reused as the TLS pin.
    let session = InstallerTestFakeSession(
        bootstrapReport: try installerTestBootstrapReport(
            authorityKey: key,
            tlsFingerprint: fingerprint
        )
    )
    await #expect(
        throws: RuntimeBootstrapError.malformedBootstrapReport(
            "tls_fingerprint and authority_fingerprint are the same value"
        )
    ) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
}

@Test func aReportMissingTheTLSPinIsRefused() async throws {
    let report = JSONValue.object([
        "node_id": .string("6b0f2f4a-6f7e-4a5b-9d0b-0f0b0a0d0e0f"),
        "authority_fingerprint": .string(SHA256Hex.of(Data(repeating: 0x11, count: 32))),
        "authority_public_key": .string(Data(repeating: 0x11, count: 32).hexString),
        "expires_at": .string("2026-08-27T00:05:00Z"),
        "invitation": .object(["role": .string("owner")]),
    ])
    let session = InstallerTestFakeSession(bootstrapReport: try report.canonicalBytes())
    await #expect(throws: RuntimeBootstrapError.malformedBootstrapReport("missing tls_fingerprint"))
    {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
}

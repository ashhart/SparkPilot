import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

// MARK: - Tests

@Test func theApprovedSequenceRunsInOrder() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    let result = try await installerTestInstaller().install(
        over: session,
        administratorPassword: "hunter2"
    )

    let commands = await session.commands
    let expected: [BootstrapCommand] = [
        // The machine is read before it is touched (§10.2 step 5).
        .surveyHost,
        .prepareWorkDirectory,
        .receiveFile(.package),
        .receiveFile(.signature),
        .receiveFile(.publicKey),
        .receiveFile(.manifest),
        .verifyDigest,
        .verifyDetachedSignature,
        .verifyAgainstInstalledTrustRoot,
        .installPackage,
        .installRecommendedTools,
        .enablePrivilegedHelper,
        .enableRuntime,
        .bootstrapOwner,
        .cleanUp,
    ]
    #expect(commands == expected)
    #expect(result.nodeName == "Spark")
    #expect(result.trustRootSource == .supplied)
}

@Test func anUpgradeInstallsAndRestartsWithoutBootstrappingAnotherOwner() async throws {
    let session = InstallerTestFakeSession(
        bootstrapReport: try installerTestBootstrapReport(),
        installedTrustRoot: true
    )
    try await installerTestInstaller().upgrade(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    #expect(commands.contains(.installPackage))
    #expect(commands.contains(.enablePrivilegedHelper))
    #expect(commands.contains(.enableRuntime))
    #expect(!commands.contains(.bootstrapOwner))
    #expect(commands.last == .cleanUp)
}

@Test func aPairedUpdateBundleIsLocallyVerifiedWithoutOpeningSSH() async throws {
    let release = try await installerTestInstaller().prepareUpdateBundle()
    let manifest = try ReleaseManifest.parse(release.manifest)

    #expect(release.releaseID == "dev-0.1.0-1")
    #expect(manifest.version == "0.1.0")
    #expect(manifest.channel == "dev")
    #expect(release.package == installerTestPackageBytes)
    #expect(release.detachedSignature.count == 64)
}

@Test func updateDetectionVerifiesOnlyTheSignedManifest() async throws {
    let detected = try await RuntimeBootstrapInstaller(
        trustRoot: installerTestTestTrustRoot(),
        source: InstallerTestManifestOnlyReleaseSource(manifestData: installerTestSignedManifest()),
        now: { installerTestMoment }
    ).availableUpdateReleaseID()

    #expect(detected == "dev-0.1.0-1")
}

@Test func aTamperedPairedUpdateBundleNeverLeavesTheAppleDevice() async throws {
    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller(package: Data("same-size-but-wrong-package".utf8))
            .prepareUpdateBundle()
    }
}

@Test func nothingIsInstalledBeforeBothOnSparkChecksPass() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    let digest = try #require(commands.firstIndex(of: .verifyDigest))
    let signature = try #require(commands.firstIndex(of: .verifyDetachedSignature))
    let install = try #require(commands.firstIndex(of: .installPackage))
    #expect(digest < install)
    #expect(signature < install)
}

@Test func aFailedDigestCheckStopsBeforeInstalling() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.fail(.verifyDigest)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    let commands = await session.commands
    #expect(!commands.contains(.installPackage))
    #expect(!commands.contains(.enableRuntime))
    // Clean temporary artifacts after failed installation.
    #expect(commands.last == .cleanUp)
}

@Test func aFailedSignatureCheckStopsBeforeInstalling() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.fail(.verifyDetachedSignature)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    let commands = await session.commands
    #expect(!commands.contains(.installPackage))
    #expect(commands.contains(.cleanUp))
}

@Test func thePasswordReachesOnlyElevatedCommandsAndOnlyOnStdin() async throws {
    let password = "correct-horse-battery-staple"
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: password)

    let recorded = await session.recorded
    for entry in recorded {
        // Never in a rendered command line.
        let parameters = try BootstrapCommand.Parameters(
            operationID: UUID(),
            artifactName: "spark-runtime_0.1.0-1_arm64.deb",
            sha256: String(repeating: "a", count: 64),
            size: 1
        )
        #expect(!entry.command.line(parameters).contains(password))

        if entry.command.requiresElevation {
            let input = try #require(entry.standardInput)
            #expect(input == Data((password + "\n").utf8), "sudo -S expects a trailing newline")
        } else if case .receiveFile = entry.command {
            // A transferred file must never carry the password.
            let input = try #require(entry.standardInput)
            #expect(!String(decoding: input, as: UTF8.self).contains(password))
        } else {
            #expect(entry.standardInput == nil)
        }
    }
}

@Test func theTransferredFilesAreTheOnesThatWereVerified() async throws {
    let manifestData = try installerTestSignedManifest()
    let signature = try installerTestSigningKey.signature(for: installerTestPackageBytes)
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller(manifest: manifestData, signature: signature)
        .install(over: session, administratorPassword: "hunter2")

    #expect(await session.input(for: .receiveFile(.package)) == installerTestPackageBytes)
    #expect(await session.input(for: .receiveFile(.signature)) == signature)
    #expect(await session.input(for: .receiveFile(.manifest)) == manifestData)

    // Verify the transferred PEM SubjectPublicKeyInfo contains the manifest's signing key.
    let pem = String(
        decoding: try #require(await session.input(for: .receiveFile(.publicKey))),
        as: UTF8.self
    )
    #expect(pem.hasPrefix("-----BEGIN PUBLIC KEY-----"))
    #expect(pem.hasSuffix("-----END PUBLIC KEY-----\n"))
    let base64 = pem.split(separator: "\n").dropFirst().dropLast().joined()
    let der = try #require(Data(base64Encoded: base64))
    #expect(der.count == 44, "an Ed25519 SubjectPublicKeyInfo is 44 bytes")
    #expect(der.suffix(32) == installerTestSigningKey.publicKey.rawRepresentation)
}

@Test func anAlreadyInstalledTrustRootIsReportedAsTheStrongerCheck() async throws {
    let session = InstallerTestFakeSession(
        bootstrapReport: try installerTestBootstrapReport(),
        installedTrustRoot: true
    )
    let result = try await installerTestInstaller().install(
        over: session,
        administratorPassword: "hunter2"
    )
    #expect(result.trustRootSource == .installed)
}

@Test func aFailedInstallStillRemovesTheWorkingDirectory() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.fail(.installPackage, status: 100)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    #expect(await session.commands.last == .cleanUp)
}

@Test func anArtifactNameThatCouldReachAShellFailsBeforeAnythingRuns() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    let hostile = try installerTestSignedManifest(name: "spark; rm -rf /.deb")
    await #expect(throws: BootstrapCommandError.self) {
        _ = try await installerTestInstaller(manifest: hostile).install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    #expect(await session.commands.isEmpty)
}

@Test func updateDetectionDistinguishesSignedPackageRevisions() async throws {
    var releases: [String] = []
    for revision in [2, 3] {
        let manifest = try installerTestSignedManifest(
            name: "spark-runtime_0.1.0-0qa20260907.\(revision)_arm64.deb"
        )
        let release = try await RuntimeBootstrapInstaller(
            trustRoot: installerTestTestTrustRoot(),
            source: InstallerTestManifestOnlyReleaseSource(manifestData: manifest),
            now: { installerTestMoment }
        ).availableUpdateReleaseID()
        releases.append(release)
    }
    #expect(releases == ["dev-0.1.0-0qa20260907.2", "dev-0.1.0-0qa20260907.3"])
}

@Test(arguments: [
    ("dev-0.1.13-0qa20260907.10", "0.1.13-0qa20260907.3", ComparisonResult.orderedDescending),
    ("dev-0.1.13-0qa20260908.1", "0.1.13-0qa20260907.10", .orderedDescending),
    ("stable-0.1.13-1", "0.1.13-0qa20260907.10", .orderedDescending),
    ("dev-0.1.13-0qa20260907.3", "0.1.13-0qa20260907.03", .orderedSame),
    ("dev-0.1.13-1", "0.1.13-1a", .orderedAscending),
    ("dev-0.1.13-1a", "0.1.13-1.1", .orderedAscending),
    ("dev-0.1.13-1", "0.1.14", .orderedAscending),
    ("dev-0.1.13-1-1", "0.1.13-2", .orderedDescending),
    ("dev-0.2.0-1", "0.1.13-999", .orderedDescending),
])
func runtimeRevisionComparisonFollowsPackageOrdering(
    bundled: String,
    installed: String,
    expected: ComparisonResult
) {
    #expect(
        RuntimeReleaseIdentity.compare(releaseID: bundled, installedVersion: installed) == expected
    )
}

@Test func unknownRuntimeVersionsCannotAuthorizeAReplacement() {
    for installed in ["", "unknown", "0.1", "0.1.13-", "0.1.13-1/2"] {
        #expect(
            RuntimeReleaseIdentity.compare(releaseID: "dev-0.1.13-1", installedVersion: installed)
                == nil
        )
    }
    #expect(
        RuntimeReleaseIdentity.compare(releaseID: "other-0.1.13-1", installedVersion: "0.1.13")
            == nil
    )
}

// MARK: - Naming an unnamed Spark

@Test func aReportedNodeNameIsPreferredOverTheHostItWasReachedOn() {
    #expect(
        RuntimeBootstrapInstaller.nodeName(reported: "Workshop Spark", fallback: "spark-a8bf.local")
            == "Workshop Spark"
    )
}

@Test func anUnnamedSparkIsNamedAfterItsHostRatherThanAGenericLabel() {
    #expect(
        RuntimeBootstrapInstaller.nodeName(reported: nil, fallback: "spark-a8bf.local")
            == "spark-a8bf"
    )
    #expect(
        RuntimeBootstrapInstaller.nodeName(reported: "  ", fallback: "192.168.1.50")
            == "192.168.1.50"
    )
}

@Test func twoUnnamedSparksOnDifferentHostsDoNotShareOneName() {
    let first = RuntimeBootstrapInstaller.nodeName(reported: nil, fallback: "spark-a8bf.local")
    let second = RuntimeBootstrapInstaller.nodeName(reported: nil, fallback: "spark-c410.local")
    #expect(first != second)
}

@Test func aSparkReachedWithoutAHostStillReceivesAName() {
    #expect(RuntimeBootstrapInstaller.nodeName(reported: nil, fallback: nil) == "Spark")
    #expect(RuntimeBootstrapInstaller.nodeName(reported: nil, fallback: ".local") == "Spark")
}

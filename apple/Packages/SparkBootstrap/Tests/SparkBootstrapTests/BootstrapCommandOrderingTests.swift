import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

@Test func theInstallerBinaryIsNeverInvokedUnguardedBeforeTheePackageIsInstalled() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let lines = try installerTestRenderedLines(await session.commands)
    let install = try #require(lines.firstIndex { $0.contains("dpkg -i") })

    for (index, line) in lines.enumerated() where line.contains(installerTestInstallerPath) {
        if index > install { continue }
        // Guard the pre-install trust-root probe with an existence check for previously installed binaries.
        #expect(
            line.contains("if [ -x \(installerTestInstallerPath) ]"),
            "step \(index) names the installer before dpkg without guarding it: \(line)"
        )
        #expect(line.contains("spark-bootstrap-no-installed-trust-root"))
    }
}

@Test func everySystemctlAndOwnerStepRunsAfterTheInstall() async throws {
    // These are the steps that need the package's units and binary on disk.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let lines = try installerTestRenderedLines(await session.commands)
    let install = try #require(lines.firstIndex { $0.contains("dpkg -i") })

    for needle in ["systemctl enable --now spark-privd", "systemctl enable --now sparkd"] {
        let index = try #require(lines.firstIndex { $0.contains(needle) })
        #expect(index > install, "\(needle) ran before the package was installed")
    }
    let bootstrapOwner = try #require(lines.firstIndex { $0.contains("bootstrap-owner") })
    #expect(bootstrapOwner > install)
    #expect(
        lines[bootstrapOwner].contains(
            "sudo -S -p '' /usr/lib/spark-runtime/spark-installer bootstrap-owner"
        ),
        "the installer loads root-owned authority and drops privileges before opening the database"
    )
}

@Test func nothingElevatedRunsBeforeTheDigestAndSignatureAreChecked() async throws {
    // Verify the package before granting it elevated execution.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let lines = try installerTestRenderedLines(await session.commands)
    let digest = try #require(lines.firstIndex { $0.contains("sha256sum -c") })
    let signature = try #require(lines.firstIndex { $0.contains("openssl pkeyutl -verify") })

    for (index, line) in lines.enumerated() where line.contains("sudo") {
        #expect(
            index > digest && index > signature,
            "an elevated step ran before verification: \(line)"
        )
    }
}

@Test func noRenderedCommandOpensAShellOrATerminal() throws {
    // Keep manifest-derived values inside the fixed validated exec command set (§11.4).
    let all: [BootstrapCommand] = [
        .prepareWorkDirectory, .receiveFile(.package), .receiveFile(.signature),
        .receiveFile(.publicKey), .receiveFile(.manifest), .verifyDigest,
        .verifyDetachedSignature, .verifyAgainstInstalledTrustRoot, .installPackage,
        .enablePrivilegedHelper, .enableRuntime, .bootstrapOwner, .cleanUp,
    ]
    for line in try installerTestRenderedLines(all) {
        for forbidden in ["bash -c", "sh -c", "ssh ", "scp ", "curl ", "wget ", "eval "] {
            #expect(!line.contains(forbidden), "\(forbidden) appears in: \(line)")
        }
    }
}

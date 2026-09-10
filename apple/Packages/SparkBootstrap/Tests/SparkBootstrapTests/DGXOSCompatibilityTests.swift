import Foundation
import Testing

@testable import SparkBootstrap

/// PLAN 11.3.3 selects an Arm64 .deb compatible with the detected DGX OS.

private func survey(_ os: String) -> String {
    """
    survey=1
    os=\(os)
    runtime_package=absent
    path_package=none
    unit_sparkd=absent
    unit_privd=absent
    state_dir=absent
    install_dir=absent
    disk=1921802240,1402398720
    memory_kb=131728896
    services=48
    listening=22
    netplan=2
    """
}

@Test func theSurveyReadsTheDGXOSVersionOutOfWhatTheSparkReports() {
    #expect(HostSurvey.parse(survey("DGX OS 7.2 (Ubuntu 24.04)")).dgxOSVersion == "7.2")
    #expect(HostSurvey.parse(survey("DGX OS 6.1.1")).dgxOSVersion == "6.1.1")
}

/// An Ubuntu version measured against a DGX OS minimum would refuse a Spark that is fine.
@Test func aHostThatDoesNotSayDGXReportsNoVersionRatherThanItsUbuntuOne() {
    #expect(HostSurvey.parse(survey("Ubuntu 24.04.1 LTS")).dgxOSVersion == nil)
    #expect(HostSurvey.parse(survey("")).dgxOSVersion == nil)
}

/// The selection has to read the Spark first; before this the check had nothing to check.
@Test func anIncompatibleDGXOSStopsTheInstallBeforeAnythingIsTransferred() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(survey("DGX OS 6.0"))
    let installer = try installerTestInstaller(
        manifest: try installerTestSignedManifest(minimumDGXOS: "7.0")
    )

    do {
        _ = try await installer.install(over: session, administratorPassword: "hunter2")
        Issue.record("an incompatible DGX OS must not install")
    } catch let error as RuntimeBootstrapError {
        guard case .incompatible(let reason) = error else {
            Issue.record("expected an incompatibility, got \(error)")
            return
        }
        #expect(reason.contains("6.0"))
        #expect(reason.contains("7.0"))
    }

    let commands = await session.commands
    #expect(commands.contains(.surveyHost), "the version can only come from reading the Spark")
    #expect(!commands.contains(.prepareWorkDirectory), "nothing is staged on an unsuitable Spark")
    #expect(!commands.contains(.receiveFile(.package)))
    #expect(!commands.contains(.installPackage))
}

@Test func aCompatibleDGXOSInstallsAsBefore() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(survey("DGX OS 7.2"))
    let installer = try installerTestInstaller(
        manifest: try installerTestSignedManifest(minimumDGXOS: "7.0")
    )

    _ = try await installer.install(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    #expect(commands.contains(.installPackage))
    #expect(commands.contains(.bootstrapOwner))
}

/// A Spark that does not name DGX OS is still installable; nothing is inferred about it.
@Test func aHostWithNoDGXVersionIsNotBlockedByAVersionItNeverStated() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(survey("Ubuntu 24.04.1 LTS"))
    let installer = try installerTestInstaller(
        manifest: try installerTestSignedManifest(minimumDGXOS: "7.0")
    )

    _ = try await installer.install(over: session, administratorPassword: "hunter2")

    #expect(await session.commands.contains(.installPackage))
}

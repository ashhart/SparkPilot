import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

@Test func theSurveyRunsBeforeAnythingIsTransferred() async throws {
    // Complete the read-only survey before any transfer or mutation.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    #expect(commands.first == .surveyHost)
    let firstTransfer = try #require(commands.firstIndex(of: .receiveFile(.package)))
    let survey = try #require(commands.firstIndex(of: .surveyHost))
    #expect(survey < firstTransfer)
}

@Test func aPortConflictStopsTheInstallBeforeItTouchesTheSpark() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(installerTestOccupiedPortSurvey)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }

    // Leave the host unchanged when preflight blocks installation.
    let commands = await session.commands
    #expect(!commands.contains(.prepareWorkDirectory))
    #expect(!commands.contains(.receiveFile(.package)))
    #expect(!commands.contains(.installPackage))
}

@Test func aBlockedInstallNamesTheConflictAndItsRecovery() async throws {
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(installerTestOccupiedPortSurvey)

    do {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
        Issue.record("a blocked install must not succeed")
    } catch let error as RuntimeBootstrapError {
        guard case .preflightBlocked(let conflicts) = error else {
            Issue.record("expected a blocked preflight, got \(error)")
            return
        }
        let conflict = try #require(conflicts.first)
        #expect(conflict.kind == .port)
        // Provide actionable conflict guidance rather than requiring the owner to interpret a code (§10.2).
        #expect(conflict.summary.contains("7443"))
        #expect(!conflict.recovery.isEmpty)
    }
}

@Test func aSparkAlreadyRunningSparkRuntimeIsNotItsOwnConflict() async throws {
    // Recognize existing runtime-owned resources so interrupted installations remain repairable.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(
        """
        survey=1
        os=DGX OS 7.2
        runtime_package=0.1.0-7
        path_package=spark-runtime
        unit_sparkd=enabled
        unit_privd=enabled
        state_dir=present
        install_dir=present
        listening=22,7443,7444
        """
    )

    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")
    let commands = await session.commands
    #expect(commands.contains(.installPackage))
}

@Test func aBusySparkWithoutAConflictInstallsAndIsLeftServing() async throws {
    // Preserve unrelated inference services, ports and containers during assisted setup.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(
        """
        survey=1
        os=DGX OS 7.2
        runtime_package=absent
        listening=22,30000
        containers=3
        container=deepseek-serve lmsysorg/sglang:v0.4.1
        """
    )

    _ = try await installerTestInstaller().install(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    #expect(commands.contains(.installPackage))
    // Run only the survey before transfer and never stop existing containers.
    #expect(commands.filter { $0 == .surveyHost }.count == 1)
}

@Test func aSurveyTheSparkCouldNotProduceBlocksRatherThanAssumingAnEmptyMachine() async throws {
    // Refuse installation when the host survey could not run.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.fail(.surveyHost)

    await #expect(throws: RuntimeBootstrapError.self) {
        _ = try await installerTestInstaller().install(
            over: session,
            administratorPassword: "hunter2"
        )
    }
    let commands = await session.commands
    #expect(!commands.contains(.installPackage))
}

@Test func upgradingASparkThatIsAlreadyRunningIsNotBlockedByItsOwnServices() async throws {
    // Permit repair when runtime-owned package, units, paths and listeners already exist.
    let session = InstallerTestFakeSession(
        bootstrapReport: try installerTestBootstrapReport(),
        installedTrustRoot: true
    )
    await session.reportSurvey(
        """
        survey=1
        os=DGX OS 7.2
        runtime_package=0.1.0-6
        path_package=spark-runtime
        unit_sparkd=enabled
        unit_privd=enabled
        state_dir=present
        install_dir=present
        listening=22,7443,7444
        """
    )

    try await installerTestInstaller().upgrade(over: session, administratorPassword: "hunter2")

    let commands = await session.commands
    #expect(commands.first == .surveyHost)
    #expect(commands.contains(.installPackage))
    #expect(!commands.contains(.bootstrapOwner))
}

@Test func thePreflightCanBeReadWithoutInstallingAnything() async throws {
    // Keep reviewing preflight evidence separate from accepting the installation.
    let session = InstallerTestFakeSession(bootstrapReport: try installerTestBootstrapReport())
    await session.reportSurvey(installerTestOccupiedPortSurvey)

    let preflight = try await installerTestInstaller().preflight(over: session)

    #expect(!preflight.canInstall)
    #expect(preflight.survey.operatingSystem == "DGX OS 7.2")
    let commands = await session.commands
    #expect(commands == [.surveyHost])
}

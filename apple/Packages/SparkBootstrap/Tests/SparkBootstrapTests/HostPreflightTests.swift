import Foundation
import Testing

@testable import SparkBootstrap

/// Test observed absence separately from unavailable survey evidence before applying install-conflict rules (§10.2).

// MARK: - The transcript a busy Spark produces

private let busySpark = """
    survey=1
    os=DGX OS 7.2 (Ubuntu 24.04)
    runtime_package=absent
    path_package=none
    unit_sparkd=absent
    unit_privd=absent
    state_dir=absent
    install_dir=absent
    disk=1921802240,1402398720
    memory_kb=131728896
    services=48
    listening=22,80,30000
    containers=2
    container=deepseek-serve lmsysorg/sglang:v0.4.1
    container=open-webui ghcr.io/open-webui/open-webui:main
    fabric=enp1s0f0np0 1 200000
    fabric=enp1s0f1np1 0 -1
    netplan=2
    """

// MARK: - Reading a Spark

@Test func aBusySparkIsReadInFull() {
    let survey = HostSurvey.parse(busySpark)

    #expect(survey.isWellFormed)
    #expect(survey.operatingSystem == "DGX OS 7.2 (Ubuntu 24.04)")
    #expect(survey.runtimePackageState == .absent)
    #expect(survey.runtimePackageVersion == nil)
    #expect(!survey.hasSparkRuntimeInstalled)
    #expect(survey.diskFreeKilobytes == 1_402_398_720)
    #expect(survey.memoryTotalKilobytes == 131_728_896)
    #expect(survey.runningServices == 48)
    #expect(survey.listeningPorts == [22, 80, 30000])
    #expect(survey.containerCount == 2)
    #expect(survey.containers.first?.name == "deepseek-serve")
    #expect(survey.containers.first?.image == "lmsysorg/sglang:v0.4.1")
    #expect(survey.netplanFileCount == 2)
}

@Test func aSparkAlreadyRunningTheRuntimeReportsItsVersion() {
    let survey = HostSurvey.parse(
        """
        survey=1
        runtime_package=0.1.0-7
        path_package=spark-runtime
        unit_sparkd=enabled
        """
    )
    #expect(survey.hasSparkRuntimeInstalled)
    #expect(survey.runtimePackageVersion == "0.1.0-7")
    #expect(survey.installPathOwner == "spark-runtime")
    #expect(survey.sparkdUnit == .present)
}

@Test func aFactThatCouldNotBeEstablishedIsNeverReadAsAbsent() {
    // Keep unavailable survey facts unknown rather than inventing absence.
    let survey = HostSurvey.parse(
        """
        survey=1
        runtime_package=unknown
        path_package=unknown
        unit_sparkd=unknown
        unit_privd=unknown
        listening=unknown
        containers=unknown
        services=unknown
        netplan=unknown
        """
    )
    #expect(survey.runtimePackageState == .unknown)
    #expect(!survey.hasSparkRuntimeInstalled)
    #expect(survey.sparkdUnit == .unknown)
    #expect(survey.privilegedHelperUnit == .unknown)
    #expect(survey.installPathOwner == nil)
    #expect(survey.listeningPorts == nil, "an unread socket table is not an empty one")
    #expect(survey.containerCount == nil, "an unreadable runtime is not an idle one")
    #expect(survey.runningServices == nil)
    #expect(survey.netplanFileCount == nil)
}

@Test func anEmptyValueIsUnknownRatherThanAGuess() {
    // Do not turn empty survey output into a zero measurement.
    let survey = HostSurvey.parse("survey=1\nos=\nmemory_kb=\ndisk=\nlistening=\n")
    #expect(survey.operatingSystem == nil)
    #expect(survey.memoryTotalKilobytes == nil)
    #expect(survey.diskTotalKilobytes == nil)
    #expect(survey.listeningPorts == nil)
}

@Test func aTranscriptThatIsNotASurveyIsRefusedRatherThanMined() {
    // Reject login banners and unrelated key-value output without the survey marker.
    for transcript in [
        "",
        "Welcome to Ubuntu 24.04\nLast login: Tue\n",
        "os=DGX OS 7.2\nlistening=22\n",
        "survey=2\nos=DGX OS 7.2\n",
    ] {
        #expect(!HostSurvey.parse(transcript).isWellFormed, "\(transcript)")
        #expect(!HostPreflight(survey: HostSurvey.parse(transcript)).canInstall)
    }
}

@Test func aValueThisBuildWillNotRepeatIsDroppedRatherThanTruncated() {
    // Convert invalid survey values to unknown rather than truncating them into different identifiers.
    let long = String(repeating: "n", count: HostSurvey.maximumValueLength + 1)
    let survey = HostSurvey.parse("survey=1\nos=\(long)\ncontainer=fine acme/x:1\n")
    #expect(survey.operatingSystem == nil)
    #expect(survey.containers.count == 1)
}

@Test func aTranscriptCannotGrowWithoutBound() {
    var transcript = "survey=1\n"
    for index in 0..<200 {
        transcript += "container=service-\(index) acme/x:1\n"
        transcript += "fabric=port\(index) 1 200000\n"
    }
    // Exercise realistic port lists that exceed display and collection limits without exceeding the line bound.
    transcript += "listening=\((30000..<30040).map(String.init).joined(separator: ","))\n"
    let survey = HostSurvey.parse(transcript)
    #expect(survey.containers.count == HostSurvey.maximumContainers)
    #expect(survey.fabricPorts.count == HostSurvey.maximumFabricPorts)
    #expect(survey.listeningPorts?.count == HostSurvey.maximumListeningPorts)
}

@Test func aFabricPortWithNoLinkHasNoSpeed() {
    // Treat the kernel's no-carrier speed sentinel as unavailable.
    let survey = HostSurvey.parse(busySpark)
    #expect(survey.fabricPorts.count == 2)
    #expect(survey.fabricPorts[0].carrier == .present)
    #expect(survey.fabricPorts[0].speedMbps == 200_000)
    #expect(survey.fabricPorts[1].carrier == .absent)
    #expect(survey.fabricPorts[1].speedMbps == nil)
}

// MARK: - What blocks an install

@Test func aBusySparkWithNothingOfOursInTheWayCanBeInstalledOn() {
    // Allow installation alongside pre-existing inference endpoints without modifying their services or ports.
    let preflight = HostPreflight(survey: HostSurvey.parse(busySpark))
    #expect(preflight.canInstall)
    #expect(preflight.conflicts.isEmpty)
}

@Test func aStrangerOnOurPortBlocksTheInstallAndSaysWhichPort() {
    for port in HostSurvey.requiredPorts {
        let preflight = HostPreflight(
            survey: HostSurvey.parse("survey=1\nruntime_package=absent\nlistening=22,\(port)\n")
        )
        #expect(!preflight.canInstall)
        let conflict = preflight.conflicts.first { $0.kind == .port }
        #expect(conflict?.summary.contains(String(port)) == true, "port \(port)")
        #expect(conflict?.recovery.contains(String(port)) == true, "port \(port)")
    }
}

@Test func anotherPackageOwningOurFolderBlocksTheInstallAndNamesIt() {
    let preflight = HostPreflight(
        survey: HostSurvey.parse("survey=1\nruntime_package=absent\npath_package=acme-runtime\n")
    )
    let conflict = try! #require(preflight.conflicts.first { $0.kind == .package })
    #expect(conflict.summary.contains("acme-runtime"))
    #expect(conflict.recovery.contains("acme-runtime"))
}

@Test func aForeignServiceWithOurNameBlocksTheInstall() {
    let preflight = HostPreflight(
        survey: HostSurvey.parse(
            "survey=1\nruntime_package=absent\nunit_sparkd=enabled\nunit_privd=enabled\n"
        )
    )
    let conflict = try! #require(preflight.conflicts.first { $0.kind == .serviceUnit })
    #expect(conflict.summary.contains("sparkd"))
    #expect(conflict.summary.contains("spark-privd"))
}

@Test func leftoverStateWithNoPackageBlocksTheInstall() {
    let preflight = HostPreflight(
        survey: HostSurvey.parse("survey=1\nruntime_package=absent\nstate_dir=present\n")
    )
    let conflict = try! #require(preflight.conflicts.first { $0.kind == .filesystem })
    #expect(conflict.summary.contains("/var/lib/spark-runtime"))
}

@Test func ourOwnInstallationIsNeverACollisionWithItself() {
    // Allow repair when the runtime's own resources already exist.
    let preflight = HostPreflight(
        survey: HostSurvey.parse(
            """
            survey=1
            runtime_package=0.1.0-7
            path_package=spark-runtime
            unit_sparkd=enabled
            unit_privd=enabled
            state_dir=present
            install_dir=present
            listening=22,7443,7444
            """
        )
    )
    #expect(preflight.canInstall)
    #expect(preflight.conflicts.isEmpty)
}

@Test func aGapInTheEvidenceDoesNotBlockButAFailedReadingDoes() {
    // Allow individually unknown observations while refusing a survey that could not be parsed at all.
    let gap = HostPreflight(
        survey: HostSurvey.parse(
            "survey=1\nruntime_package=absent\nlistening=unknown\nunit_sparkd=unknown\n"
        )
    )
    #expect(gap.canInstall)

    let failed = HostPreflight(survey: HostSurvey.parse("bash: ss: command not found\n"))
    #expect(!failed.canInstall)
}

@Test func everyConflictExplainsItselfAndOffersNoWayThrough() {
    // Explain every non-overridable preflight conflict with actionable recovery (§10.2).
    let preflight = HostPreflight(
        survey: HostSurvey.parse(
            """
            survey=1
            runtime_package=absent
            path_package=acme-runtime
            unit_sparkd=enabled
            state_dir=present
            listening=7443
            """
        )
    )
    #expect(preflight.conflicts.count == 4, "one per kind")
    #expect(
        Set(preflight.conflicts.map(\.kind))
            == Set([.port, .package, .serviceUnit, .filesystem])
    )
    for conflict in preflight.conflicts {
        #expect(conflict.summary.count > 20, "\(conflict.kind) must say what was found")
        #expect(conflict.recovery.count > 20, "\(conflict.kind) must say what to do")
        #expect(!conflict.recovery.lowercased().contains("anyway"))
        #expect(!conflict.recovery.lowercased().contains("force"))
    }
}

// MARK: - The command that produces all of this

@Test func theSurveyNeitherElevatesNorWrites() {
    // Verify read-only behavior in the survey command itself.
    #expect(!BootstrapCommand.surveyHost.requiresElevation)

    let script = BootstrapCommand.hostSurveyScript
    for writer in [
        "sudo", "systemctl start", "systemctl stop", "systemctl restart", "docker run",
        "docker stop", "docker rm", "docker exec", "dpkg -i", "apt-get", "rm ", "mv ",
        "install -d", "touch ", "tee ",
    ] {
        #expect(!script.contains(writer), "the survey must not contain \(writer)")
    }

    // After removing output-discard redirections, reject any remaining filesystem write in the survey script.
    let redirectionsRemoved =
        script
        .replacingOccurrences(of: "2>/dev/null", with: "")
        .replacingOccurrences(of: ">/dev/null 2>&1", with: "")
        .replacingOccurrences(of: ">/dev/null", with: "")
    #expect(!redirectionsRemoved.contains(">"), "the survey must write nothing")
}

@Test func theSurveyTakesNothingFromTheCaller() {
    // Render byte-identical survey commands for different operation parameters.
    let first = try! BootstrapCommand.Parameters(
        operationID: UUID(),
        artifactName: "spark-runtime_0.1.0-7_arm64.deb",
        sha256: String(repeating: "a", count: 64),
        size: 10
    )
    let second = try! BootstrapCommand.Parameters(
        operationID: UUID(),
        artifactName: "other_9.9.9_arm64.deb",
        sha256: String(repeating: "b", count: 64),
        size: 999
    )
    #expect(BootstrapCommand.surveyHost.line(first) == BootstrapCommand.surveyHost.line(second))
    #expect(BootstrapCommand.surveyHost.line(first) == BootstrapCommand.hostSurveyScript)
}

@Test func theSurveyReadsOsReleaseWithoutExecutingIt() {
    // Parse os-release as data instead of sourcing untrusted shell-shaped contents.
    let script = BootstrapCommand.hostSurveyScript
    #expect(script.contains("/etc/os-release"))
    #expect(!script.contains(". /etc/os-release"))
    #expect(!script.contains("source /etc/os-release"))
}

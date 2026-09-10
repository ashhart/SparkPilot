import Foundation
import SparkBootstrap
import SparkCore
import SparkDiscovery
import Testing

@testable import SparkAppComposition

/// Verifies existing-Spark inspection, installation disclosure and non-bypassable conflict recovery before installation.

// MARK: - A Spark that is already busy

private let busySparkSurvey = """
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
    listening=22,30000
    containers=1
    container=deepseek-serve lmsysorg/sglang:v0.4.1
    fabric=enp1s0f0np0 1 200000
    netplan=2
    """

/// The same Spark, but something already holds the port the runtime needs.
private let occupiedPortSurvey = """
    survey=1
    os=DGX OS 7.2 (Ubuntu 24.04)
    runtime_package=absent
    listening=22,7443,30000
    containers=1
    container=deepseek-serve lmsysorg/sglang:v0.4.1
    """

private func preflight(_ transcript: String) -> HostPreflight {
    HostPreflight(survey: HostSurvey.parse(transcript))
}

// MARK: - What the owner is shown before they agree to anything

@Test func theOwnerIsToldWhatIsAlreadyOnTheSpark() {
    // Show discovered workloads before promising that they will remain externally managed.
    let report = ExistingSparkPreflightPresentation(preflight: preflight(busySparkSurvey))

    #expect(report.found.contains { $0.contains("DGX OS 7.2") })
    #expect(report.found.contains { $0.contains("48") && $0.lowercased().contains("service") })
    #expect(report.found.contains { $0.contains("deepseek-serve") })
    #expect(report.found.contains { $0.contains("200") && $0.contains("GbE") })
}

@Test func theOwnerIsToldExactlyWhatTheInstallWillAdd() {
    // Name the exact units, paths and ports affected by installation (§10.2).
    let report = ExistingSparkPreflightPresentation(preflight: preflight(busySparkSurvey))

    let added = report.willAdd.joined(separator: " ")
    #expect(added.contains("sparkd"))
    #expect(added.contains("spark-privd"))
    #expect(added.contains("/usr/lib/spark-runtime"))
    #expect(added.contains("7443"))
}

@Test func theOwnerIsToldTheirWorkloadsStayTheirs() {
    // Place the required installation disclosure beside the workloads it describes.
    let report = ExistingSparkPreflightPresentation(preflight: preflight(busySparkSurvey))
    #expect(report.workloadAssurance != nil)
    let assurance = try! #require(report.workloadAssurance)
    #expect(assurance.lowercased().contains("externally managed"))
    #expect(assurance.lowercased().contains("keep running"))
}

@Test func aSparkWithNothingOnItIsNotGivenAnAssuranceAboutNothing() {
    // Show preservation guidance only for workloads that actually exist.
    let report = ExistingSparkPreflightPresentation(
        preflight: preflight("survey=1\nos=DGX OS 7.2\nruntime_package=absent\ncontainers=0\n")
    )
    #expect(report.workloadAssurance == nil)
}

@Test func aFactTheSparkCouldNotEstablishIsNotPrintedAsZero() {
    // Keep unavailable container observations unknown rather than reporting zero.
    let report = ExistingSparkPreflightPresentation(
        preflight: preflight(
            "survey=1\nos=DGX OS 7.2\nruntime_package=absent\ncontainers=unknown\nservices=unknown\n"
        )
    )
    #expect(!report.found.contains { $0.contains("0 containers") })
    #expect(report.notEstablished.contains { $0.lowercased().contains("container") })
    #expect(report.notEstablished.contains { $0.lowercased().contains("service") })
}

// MARK: - What stops an install

@Test func aConflictIsShownWithItsRecoveryAndNoWayPast() {
    let report = ExistingSparkPreflightPresentation(preflight: preflight(occupiedPortSurvey))

    #expect(!report.canContinue)
    #expect(report.conflicts.count == 1)
    let conflict = try! #require(report.conflicts.first)
    #expect(conflict.summary.contains("7443"))
    #expect(!conflict.recovery.isEmpty)
    // Do not suggest an override for a blocked preflight.
    #expect(report.continueTitle == nil)
}

@Test func aSparkWithNoConflictsOffersToContinue() {
    let report = ExistingSparkPreflightPresentation(preflight: preflight(busySparkSurvey))
    #expect(report.canContinue)
    #expect(report.continueTitle != nil)
}

@Test func aSparkThatCouldNotBeCheckedIsNotOfferedAnInstall() {
    // An unreadable machine is not a clear one.
    let report = ExistingSparkPreflightPresentation(
        preflight: preflight("bash: unexpected output\n")
    )
    #expect(!report.canContinue)
    #expect(report.continueTitle == nil)
    #expect(report.checkFailed)
}

// MARK: - The route

@MainActor
@Test func checkingASparkReadsItWithoutInstallingAnything() async {
    let installer = PreflightingInstaller(preflight: preflight(busySparkSurvey))
    let model = await modelReadyToCheckExistingSpark(installer: installer)

    await model.checkExistingSpark()

    #expect(model.hostPreflight?.canInstall == true)
    #expect(await installer.preflightCount == 1)
    #expect(await installer.installCount == 0, "checking must not install")
}

@MainActor
@Test func aBlockedSparkIsExplainedRatherThanReportedAsAFailedInstall() async {
    // Distinguish a refused installation due to a port conflict from execution failure.
    let installer = PreflightingInstaller(preflight: preflight(occupiedPortSurvey))
    let model = await modelReadyToCheckExistingSpark(installer: installer)

    await model.checkExistingSpark()

    #expect(model.hostPreflight?.canInstall == false)
    #expect(model.hostPreflight?.conflicts.first?.kind == .port)
    #expect(model.preflightError == nil, "a conflict is a finding, not an error")
}

@MainActor
@Test func aSparkThatWouldNotAnswerIsReportedAsUncheckedNotAsClear() async {
    let installer = PreflightingInstaller(
        failure: RuntimeBootstrapError.preflightUnavailable("this Spark could not be checked")
    )
    let model = await modelReadyToCheckExistingSpark(installer: installer)

    await model.checkExistingSpark()

    #expect(model.hostPreflight == nil)
    #expect(model.preflightError != nil)
}

@MainActor
@Test func theRouteAsksForAReviewOnceAndThenStopsAsking() async {
    // Preserve the displayed preflight report when credentials are submitted again.
    let installer = PreflightingInstaller(preflight: preflight(busySparkSurvey))
    let model = await modelReadyToCheckExistingSpark(installer: installer)

    #expect(model.needsExistingSparkReview)
    await model.checkExistingSpark()
    #expect(!model.needsExistingSparkReview)

    model.clearExistingSparkCheck()
    #expect(model.needsExistingSparkReview, "dismissing the report asks again")
}

@MainActor
@Test func aReportIsOfferedForEveryOutcomeTheCheckCanHave() async {
    // Present clear, blocked and unreadable preflight outcomes without dropping any report.
    let clear = await modelReadyToCheckExistingSpark(
        installer: PreflightingInstaller(preflight: preflight(busySparkSurvey))
    )
    await clear.checkExistingSpark()
    #expect(clear.existingSparkReport?.canContinue == true)

    let blocked = await modelReadyToCheckExistingSpark(
        installer: PreflightingInstaller(preflight: preflight(occupiedPortSurvey))
    )
    await blocked.checkExistingSpark()
    let blockedReport = try! #require(blocked.existingSparkReport)
    #expect(!blockedReport.canContinue)
    #expect(blockedReport.conflicts.count == 1)

    let unreadable = await modelReadyToCheckExistingSpark(
        installer: PreflightingInstaller(
            failure: SparkBootstrap.RuntimeBootstrapError.preflightUnavailable("no answer")
        )
    )
    await unreadable.checkExistingSpark()
    let failedReport = try! #require(unreadable.existingSparkReport)
    #expect(failedReport.checkFailed)
    #expect(!failedReport.canContinue)
}

@Test func aReportBuiltFromARefusedInstallShowsTheReasonAndNoAction() {
    // A post-approval preflight refusal must show its reason without an action that bypasses the conflict.
    let conflicts = HostPreflight(survey: HostSurvey.parse(occupiedPortSurvey)).conflicts
    let report = ExistingSparkPreflightPresentation(blockedBy: conflicts)

    #expect(!report.canContinue)
    #expect(report.continueTitle == nil)
    #expect(report.conflicts.count == 1)
    #expect(report.found.isEmpty, "a stale reading must not be presented as current")
    #expect(!report.checkFailed)
}

// MARK: - Doubles

private actor PreflightingInstaller: RuntimeBootstrapInstalling {
    private(set) var preflightCount = 0
    private(set) var installCount = 0
    private let report: HostPreflight?
    private let failure: (any Error)?

    init(preflight: HostPreflight? = nil, failure: (any Error)? = nil) {
        self.report = preflight
        self.failure = failure
    }

    func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        preflightCount += 1
        if let failure { throw failure }
        guard let report else { throw RuntimeBootstrapError.notConfigured }
        return report
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        installCount += 1
        throw RuntimeBootstrapError.notConfigured
    }
}

@MainActor
private func modelReadyToCheckExistingSpark(
    installer: any RuntimeBootstrapInstalling
) async -> RetailOnboardingModel {
    let model = RetailOnboardingModel(runtimeInstaller: installer)
    model.chooseSparkToAdd()
    _ = model.chooseExistingSpark(host: "preflight-fixture.local")
    model.finishInterruptedFirstOwnerSetup()
    model.administratorUsername = "owner"
    model.administratorPassword = "hunter2"
    return model
}

@Test func customDistributedSetupIsInspectedWithoutClaimingRecipeCompatibility() {
    for ports in ["22,8080,8888,11000,25000,28028", "22,8080,11000,28028"] {
        let survey = HostSurvey.parse(
            """
            survey=1
            os=Ubuntu 24.04.4 LTS
            runtime_package=absent
            path_package=none
            unit_sparkd=absent
            unit_privd=absent
            state_dir=absent
            install_dir=absent
            listening=\(ports)
            containers=1
            container=deepseek-v4-flash-vllm-dspark-1 ghcr.io/anemll/dspark-vllm-gx10:0.1.1
            fabric=enP2p1s0f0np0 0 -1
            fabric=enP2p1s0f1np1 1 200000
            fabric=enp1s0f0np0 0 -1
            fabric=enp1s0f1np1 1 200000
            netplan=3
            """
        )
        let report = ExistingSparkPreflightPresentation(preflight: HostPreflight(survey: survey))
        #expect(report.canContinue)
        #expect(survey.dgxOSVersion == nil)
        #expect(survey.fabricPorts.filter { $0.carrier == .present }.count == 2)
        #expect(report.found.contains { $0.contains("deepseek-v4-flash-vllm-dspark-1") })
        #expect(report.workloadAssurance?.contains("externally managed") == true)
        #expect(!report.found.contains { $0.contains("Nemotron") })
    }
}

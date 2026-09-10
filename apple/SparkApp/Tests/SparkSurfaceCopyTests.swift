import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Checks that state labels convey colour distinctions and runtime data stays in its designated presentation fields.
private func readableOwnerCopy(_ text: String, _ what: String) {
    #expect(!text.isEmpty, "\(what) says nothing")
    #expect(text.trimmingCharacters(in: .whitespaces) == text, "\(what) is padded")
    #expect(!text.contains("_"), "\(what) shows an identifier")
    #expect(!text.contains("://"), "\(what) shows a route")
}

// MARK: - Model services

@Test func everyServiceStateCarriesTextAndNotOnlyColour() {
    let states: [ModelServiceRunState] = [
        .running, .installed, .readyToInstall, .needsAttention, .unavailable, .unknown,
    ]
    var labels: Set<String> = []
    var details: Set<String> = []
    for state in states {
        let label = ModelServicePresentation.stateLabel(state)
        let detail = ModelServicePresentation.stateDetail(state)
        readableOwnerCopy(label, "\(state) label")
        readableOwnerCopy(detail, "\(state) detail")
        #expect(detail.hasSuffix("."), "\(state) detail is not a sentence")
        labels.insert(label)
        details.insert(detail)
    }
    #expect(labels.count == states.count, "two service states share a label")
    #expect(details.count == states.count, "two service states share a detail")
}

@Test func everyServiceOwnershipAndFreshnessSaysWhichItIs() {
    var ownerships: Set<String> = []
    for ownership in [ModelServiceOwnership.sparkPilot, .external] {
        let label = try! #require(ModelServicePresentation.ownershipLabel(ownership))
        readableOwnerCopy(label, "\(ownership) ownership")
        ownerships.insert(label)
    }
    #expect(ownerships.count == 2)
    // Unknown ownership claims nothing rather than guessing.
    #expect(ModelServicePresentation.ownershipLabel(.unknown) == nil)

    let now = Date(timeIntervalSince1970: 1_756_000_000)
    var freshness: Set<String> = []
    for state in [
        ModelLibraryEvidenceFreshness.current(observedAt: now), .stale(observedAt: now),
        .unavailable,
    ] {
        let label = ModelServicePresentation.freshnessLabel(state)
        readableOwnerCopy(label, "freshness")
        freshness.insert(label)
    }
    #expect(freshness.count == 3, "two freshness states read the same")
}

@Test func everyUpdateCountStateReadsAsCopyRatherThanANumberAlone() {
    var headlines: Set<String> = []
    for count in [nil, 0, 1, 4] as [Int?] {
        let headline = ModelServicePresentation.updateHeadline(count)
        let short = ModelServicePresentation.updateCount(count)
        readableOwnerCopy(headline, "update headline for \(String(describing: count))")
        readableOwnerCopy(short, "update count for \(String(describing: count))")
        headlines.insert(headline)
    }
    #expect(headlines.count == 4, "two update states read the same")
    // Render the reported count as a localised number.
    #expect(ModelServicePresentation.updateHeadline(4).contains("4"))
}

/// Format parsed remote timestamps locally and omit malformed raw values.
@Test func anUnparsableCheckTimeIsNotShownAsItArrived() {
    let parsed = ModelServicePresentation.checkedAtLabel("2026-08-31T09:15:00Z")
    #expect(!parsed.contains("T"))
    #expect(!parsed.contains("Z"))

    let raw = "not-a-timestamp-from-a-newer-runtime"
    let shown = ModelServicePresentation.checkedAtLabel(raw)
    #expect(!shown.contains(raw))
    #expect(shown == String(localized: "Not reported"))
}

@Test func twoClausesAreJoinedThroughTheCatalogueRatherThanASeparator() {
    let both = ModelServicePresentation.joined("Managed by SparkPilot", "Version 1.2")
    #expect(both.contains("Managed by SparkPilot"))
    #expect(both.contains("Version 1.2"))
    // One clause is itself, not itself with a dangling separator.
    #expect(ModelServicePresentation.joined("Only this", nil) == "Only this")
    #expect(ModelServicePresentation.joined(nil, "Only this") == "Only this")
    #expect(ModelServicePresentation.joined(nil, nil).isEmpty)
}

// MARK: - Workloads

private func workload(
    ownership: GeneratedAPI.WorkloadOwnership = .externalObserved,
    kind: GeneratedAPI.WorkloadKind = .unknown,
    engine: GeneratedAPI.WorkloadEngine = .none,
    origin: GeneratedAPI.WorkloadManagementOrigin? = nil,
    state: GeneratedAPI.WorkloadState = .running,
    name: String? = "example",
    ports: [GeneratedAPI.ObservedWorkloadPort] = []
) -> GeneratedAPI.ObservedWorkload {
    GeneratedAPI.ObservedWorkload(
        workloadId: "9d4c6a2e",
        name: name,
        ownership: ownership,
        kind: kind,
        recognisedEngine: engine,
        managementOrigin: origin,
        state: state,
        imageReference: "ghcr.io/private/inference@sha256:deadbeef",
        publishedPorts: ports
    )
}

@Test func everyWorkloadLifecycleStateSaysWhatItIs() {
    let states: [GeneratedAPI.WorkloadState] = [
        .created, .running, .paused, .restarting, .removing, .exited, .dead, .unknown,
    ]
    var labels: Set<String> = []
    for state in states {
        let label = SparkWorkloadPresentation.stateLabel(state)
        readableOwnerCopy(label, "workload state \(state)")
        #expect(label != state.rawValue, "\(state) shows its raw token")
        labels.insert(label)
    }
    #expect(labels.count == states.count, "two lifecycle states read the same")
}

@Test func everyOwnershipStateSaysWhoControlsTheWorkload() {
    let cases: [(String, GeneratedAPI.ObservedWorkload)] = [
        ("sparkManaged", workload(ownership: .sparkManaged, origin: .sparkStarted)),
        ("adopted", workload(ownership: .sparkManaged, origin: .externalAdoption)),
        ("externalObserved", workload(ownership: .externalObserved)),
        ("adoptionAvailable", workload(ownership: .adoptionAvailable)),
        ("unknownExternal", workload(ownership: .unknownExternal)),
    ]
    var labels: Set<String> = []
    for (name, observed) in cases {
        let label = SparkWorkloadPresentation.ownershipLabel(observed)
        readableOwnerCopy(label, "ownership \(name)")
        labels.insert(label)
    }
    #expect(labels.count == cases.count, "two ownership states read the same")
}

@Test func everyEngineAndKindReadsAsWhatItIs() {
    var descriptions: Set<String> = []
    for engine in [
        GeneratedAPI.WorkloadEngine.vllm, .sglang, .ray, .openWebui,
    ] {
        let text = SparkWorkloadPresentation.description(engine: engine, kind: .unknown)
        readableOwnerCopy(text, "engine \(engine)")
        descriptions.insert(text)
    }
    for kind in [
        GeneratedAPI.WorkloadKind.projectContainer, .inferenceEngine, .optionalService,
        .clusterRuntime, .unknown,
    ] {
        let text = SparkWorkloadPresentation.description(engine: .none, kind: kind)
        readableOwnerCopy(text, "kind \(kind)")
        descriptions.insert(text)
    }
    #expect(descriptions.count == 9, "two engines or kinds read the same")
}

/// Display image references and published ports only in their technical-data fields.
@Test func aWorkloadsPrivateImageAppearsOnlyWhereItIsLabelledAsData() {
    let row = SparkWorkloadPresentation.row(
        workload(
            engine: .vllm,
            state: .running,
            ports: [
                GeneratedAPI.ObservedWorkloadPort(
                    hostIp: "192.168.1.44",
                    hostPort: 8000,
                    containerPort: 8000,
                    protocol: .tcp
                )
            ]
        ),
        adoptionSupported: true
    )
    let image = "ghcr.io/private/inference@sha256:deadbeef"
    #expect(row.imageReference == image, "the image field is where the image belongs")
    #expect(!row.detail.contains(image), "the detail line repeats the image")
    #expect(!row.ownership.contains(image))
    #expect(!row.title.contains(image))
    #expect(!row.accessibilityLabel.contains(image), "VoiceOver reads out a private image")
    // Display protocol, address and port unchanged only in the endpoint field.
    #expect(row.endpoints == ["192.168.1.44:8000 → 8000/tcp"])
    #expect(!row.detail.contains("192.168.1.44"))
}

/// A workload the runtime did not name still has something to call it.
@Test func anUnnamedWorkloadIsStillGivenAName() {
    let row = SparkWorkloadPresentation.row(workload(name: nil), adoptionSupported: false)
    readableOwnerCopy(row.title, "unnamed workload title")
    #expect(row.title != "9d4c6a2e", "the workload identifier is used as its name")
}

/// Join catalogue clauses through a translatable key so their order remains controllable.
@Test func theWorkloadDetailIsBothHalvesAndNeitherIsLost() {
    let detail = SparkWorkloadPresentation.detail(workload(engine: .vllm, state: .paused))
    #expect(detail.contains(SparkWorkloadPresentation.description(engine: .vllm, kind: .unknown)))
    #expect(detail.contains(SparkWorkloadPresentation.stateLabel(.paused)))
}

// MARK: - Node status

@Test func everyConnectionStateHasATitleASecondaryLineAndABadge() {
    let states: [SparkConnectionState] = [
        .discovering, .foundUnpaired, .connecting, .connectedWiFi, .connectedDirect,
        .connectedRemote, .offlineCached, .identityMismatch, .updateRequired,
    ]
    var seen: Set<String> = []
    for state in states {
        let presentation = NodeStatusPresentation.resolve(state)
        readableOwnerCopy(presentation.title, "\(state) title")
        readableOwnerCopy(presentation.secondary, "\(state) secondary")
        #expect(presentation.title != presentation.secondary)
        // Use text to distinguish states that share a badge colour.
        seen.insert("\(presentation.title)|\(presentation.secondary)")
    }
    #expect(seen.count == states.count, "two connection states read the same")
}

/// Differentiate Ready states through their secondary connection detail.
@Test func theThreeReadyStatesAreSeparatedByTextRatherThanByBadge() {
    let ready: [SparkConnectionState] = [.connectedWiFi, .connectedDirect, .connectedRemote]
    #expect(Set(ready.map(NodeStatusPresentation.badge(for:))) == [.ready])
    let secondaries = Set(ready.map { NodeStatusPresentation.resolve($0).secondary })
    #expect(secondaries.count == 3, "the three ready states are told apart only by colour")
}

@Test func everyStateOffersTheActionItsRecoveryNeeds() {
    #expect(NodeStatusPresentation.resolve(.foundUnpaired).action == .continueSetup)
    #expect(NodeStatusPresentation.resolve(.offlineCached).action == .retry)
    #expect(NodeStatusPresentation.resolve(.identityMismatch).action == .reviewRecovery)
    #expect(NodeStatusPresentation.resolve(.updateRequired).action == .update)
    #expect(NodeStatusPresentation.resolve(.connectedWiFi).action == .open)
    #expect(NodeStatusPresentation.resolve(.discovering).action == .none)
}

@Test func everyEmptyStateSaysWhatHappenedAndWhatToDo() {
    let kinds: [DashboardEmptyState.Kind] = [
        .noNodes, .permissionDenied, .permissionRestricted, .allOffline,
    ]
    var titles: Set<String> = []
    for kind in kinds {
        let state = DashboardEmptyState(kind: kind)
        readableOwnerCopy(state.title, "\(kind) title")
        readableOwnerCopy(state.message, "\(kind) message")
        if let action = state.actionLabel { readableOwnerCopy(action, "\(kind) action") }
        titles.insert(state.title)
    }
    #expect(titles.count == kinds.count, "two empty states share a title")
    // Omit actions that cannot change the current restriction.
    #expect(DashboardEmptyState(kind: .permissionRestricted).actionLabel == nil)
}

// MARK: - Identity settings

@MainActor
private func identityFailure(_ runtime: any SparkHostnameControlling) async -> String? {
    let (model, _, _, _) = makeIdentitySettings(runtime: runtime)
    model.draftHostname = "spark1"
    model.requestHostnameChange()
    await model.confirmHostnameChange()
    return model.errorMessage
}

private actor RefusingHostname: SparkHostnameControlling {
    private let error: any Error
    init(_ error: any Error) { self.error = error }
    func setSparkHostname(
        route: URL,
        hostname: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw error
    }
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation { throw error }
}

@MainActor
@Test func everyHostnameFailureBranchSaysSomethingDifferentAndActionable() async {
    let poison = "SPARK_TEST_DIAGNOSTIC hostname rejected by /var/lib/spark-runtime"
    let branches: [(String, any Error)] = [
        (
            "invalid",
            APIError(.reported, statusCode: 400, code: "INVALID_HOSTNAME", diagnosticDetail: poison)
        ),
        ("unauthorised", APIError(.reported, statusCode: 403, code: "FORBIDDEN")),
        ("timeout", APIError(.reported, statusCode: 504, code: "HOSTNAME_CHANGE_TIMEOUT")),
        ("transport", APIError(.malformedResponse, diagnosticDetail: poison)),
    ]
    var messages: Set<String> = []
    for (name, error) in branches {
        let message = await identityFailure(RefusingHostname(error))
        let text = try! #require(message, "\(name) reported no failure")
        readableOwnerCopy(text, "hostname failure \(name)")
        #expect(!text.contains("SPARK_TEST_DIAGNOSTIC"), "\(name) repeats the diagnostic")
        #expect(!text.contains("/var/lib"), "\(name) shows a host path")
        messages.insert(text)
    }
    #expect(messages.count == branches.count, "two hostname failures read the same")
}

@MainActor
@Test func aDeclinedPresenceCheckSaysNothingChanged() async {
    let (model, _, _, _) = makeIdentitySettings(
        runtime: FakeHostname(),
        presence: AppTestPresenceAuthorizer(outcome: .decline)
    )
    model.draftHostname = "spark1"
    model.requestHostnameChange()
    await model.confirmHostnameChange()
    let message = try! #require(model.errorMessage)
    readableOwnerCopy(message, "declined presence")
    #expect(message.contains("present"))
}

@MainActor
@Test func everyHostnameValidationBranchExplainsTheRule() {
    let (model, _, _, _) = makeIdentitySettings(runtime: FakeHostname())
    var messages: Set<String> = []
    for draft in ["", String(repeating: "a", count: 64), "-spark", "Spark_One"] {
        model.draftHostname = draft
        let message = try! #require(
            model.hostnameValidationMessage,
            "\(draft.prefix(12)) was accepted"
        )
        #expect(!message.isEmpty)
        #expect(!message.contains(draft), "the rejected draft is echoed back")
        messages.insert(message)
    }
    #expect(messages.count >= 3, "the validation rules are not told apart")
    model.draftHostname = "spark1"
    #expect(model.hostnameValidationMessage == nil)
}

/// Distinguish changes to the device-local label from changes to the Spark hostname.
@MainActor
@Test func savingTheLocalLabelSaysWhereItWasSaved() {
    let (model, _, _, _) = makeIdentitySettings(runtime: FakeHostname())
    model.presentEditor()
    model.draftLabel = "Workshop"
    model.saveLabel()
    let saved = try! #require(model.labelMessage)
    readableOwnerCopy(saved, "label saved")
    #expect(model.errorMessage == nil)

    model.draftLabel = ""
    model.saveLabel()
    let cleared = try! #require(model.labelMessage)
    readableOwnerCopy(cleared, "label cleared")
    #expect(cleared != saved, "clearing the label says the same as setting one")

    model.draftLabel = String(repeating: "a", count: 121)
    let tooLong = try! #require(model.labelValidationMessage)
    readableOwnerCopy(tooLong, "label too long")
}

/// Label missing hostnames explicitly and preserve reported names with their mDNS suffix as untranslated data.
@MainActor
@Test func anUnreportedHostnameIsNamedRatherThanShownAsABareSuffix() {
    for unreported in [nil, "", "   "] as [String?] {
        let (model, _, _, _) = makeIdentitySettings(
            runtime: FakeHostname(),
            hostname: unreported
        )
        let shown = model.hostnameForDisplay
        #expect(shown == String(localized: "Not reported"), "showed \(shown)")
        #expect(!shown.hasSuffix(".local"), "an unreported hostname was given a suffix")
    }

    let (reported, _, _, _) = makeIdentitySettings(
        runtime: FakeHostname(),
        hostname: "spark-example"
    )
    #expect(reported.hostnameForDisplay == "spark-example.local")
    #expect(reported.hostnameForDisplay != String(localized: "Not reported"))
}

/// §51.2: a fit token from the runtime is mapped to localised copy, never rendered raw.
@Test func theFitTokenIsMappedToCopyRatherThanTitleCased() {
    #expect(ModelTargetFit.label(forWireValue: "fits_after_unload") == "Fits after stop")
    #expect(ModelTargetFit.label(forWireValue: "smaller_profile_required") == "Smaller profile")
    #expect(ModelTargetFit.label(forWireValue: "cluster_required") == "Cluster required")
    #expect(ModelTargetFit.label(forWireValue: "something_new") == nil)
}

/// §51.2: percentages come from the formatter, so the glyph and its position follow the locale.
@Test func progressPercentagesAreFormattedNotConcatenated() {
    #expect(!String(localized: .percentComplete(0.5.localisedPercent)).contains("0.5"))
    #expect(String(localized: .percentComplete(0.5.localisedPercent)).contains("50"))
    #expect(
        String(localized: .stageWithPercent(stage: "Downloading", percent: 0.25.localisedPercent))
            .hasPrefix("Downloading · ")
    )
}

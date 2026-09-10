import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

/// Verifies workload ownership boundaries and distinguishes unreadable inventory from an empty host.

private func workload(
    id: String = "9f2c",
    name: String? = "deepseek-serve",
    ownership: GeneratedAPI.WorkloadOwnership = .externalObserved,
    kind: GeneratedAPI.WorkloadKind = .inferenceEngine,
    engine: GeneratedAPI.WorkloadEngine = .sglang,
    state: GeneratedAPI.WorkloadState = .running,
    image: String? = "lmsysorg/sglang:v0.4.1",
    ports: [GeneratedAPI.ObservedWorkloadPort] = [],
    configurationState: GeneratedAPI.ObservedWorkloadConfigurationState = .unavailable,
    apiProtocol: String? = nil,
    apiPort: Int? = nil,
    servedModels: [String] = [],
    managementOrigin: GeneratedAPI.WorkloadManagementOrigin? = nil
) -> GeneratedAPI.ObservedWorkload {
    GeneratedAPI.ObservedWorkload(
        workloadId: id,
        name: name,
        ownership: ownership,
        kind: kind,
        recognisedEngine: engine,
        managementOrigin: managementOrigin,
        state: state,
        imageReference: image,
        publishedPorts: ports,
        configurationState: configurationState,
        apiProtocol: apiProtocol,
        apiPort: apiPort,
        servedModels: servedModels
    )
}

private func inventory(
    available: Bool = true,
    unavailableReason: String? = nil,
    adoptionSupported: Bool = false,
    truncated: Bool = false,
    workloads: [GeneratedAPI.ObservedWorkload] = []
) -> GeneratedAPI.WorkloadInventory {
    GeneratedAPI.WorkloadInventory(
        observedAt: "2026-08-30T09:00:00Z",
        available: available,
        unavailableReason: unavailableReason,
        adoptionSupported: adoptionSupported,
        truncated: truncated,
        workloads: workloads
    )
}

private let managedEngine = workload(
    id: "aaaa",
    name: "spark-model-2b0b0d1e-2b3f-4f7b-9b7a-1c1a4a4a9e11",
    ownership: .sparkManaged,
    kind: .inferenceEngine,
    engine: .vllm,
    image: "vllm/vllm-openai@sha256:aa"
)

@Test func managedAndExternalWorkloadsAreSeparateSectionsNotOneSortedList() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(workloads: [managedEngine, workload(), workload(id: "7e5d", name: "legacy")])
    )

    #expect(sections.count == 2)
    #expect(sections[0].id == SparkWorkloadPresentation.managedSectionID)
    #expect(sections[0].rows.count == 1)
    #expect(sections[0].rows[0].isManagedBySparkPilot)
    #expect(sections[1].id == SparkWorkloadPresentation.externalSectionID)
    #expect(sections[1].rows.count == 2)
    #expect(sections[1].rows.allSatisfy { !$0.isManagedBySparkPilot })
}

@Test func everyRowCarriesItsOwnOwnershipWordRatherThanRelyingOnPosition() {
    // Each workload row must identify its owner independently of section headings.
    let sections = SparkWorkloadPresentation.sections(
        inventory(workloads: [managedEngine, workload()])
    )
    let rows = sections.flatMap(\.rows)
    #expect(rows.count == 2)
    for row in rows {
        #expect(!row.ownership.isEmpty)
        #expect(row.accessibilityLabel.contains(row.ownership))
    }
    #expect(rows[0].ownership == "Managed by SparkPilot")
    #expect(rows[1].ownership == "Externally managed")
}

@Test func theExternalSectionSaysWhatSparkPilotWillNotDo() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(workloads: [workload()])
    )
    let footer = try! #require(sections.first?.footer)
    #expect(footer.contains("did not start these"))
    #expect(footer.contains("never sends them a start, stop, or remove command"))
    // Explain unavailable adoption controls rather than leaving absent actions to resemble a loading failure.
    #expect(footer.contains("not available in this build"))
}

@Test func theTakeoverSentenceDisappearsOnlyWhenAdoptionIsGenuinelySupported() {
    let gated = SparkWorkloadPresentation.externalFooter(adoptionSupported: false)
    let supported = SparkWorkloadPresentation.externalFooter(adoptionSupported: true)
    #expect(gated.contains("not available in this build"))
    #expect(!supported.contains("not available in this build"))
    // Preserve external-workload non-interference even when adoption is unavailable.
    #expect(supported.contains("never sends them a start, stop, or remove command"))
}

@Test func anUnreadableHostIsNotPresentedAsAnIdleOne() {
    let unreadable = inventory(
        available: false,
        unavailableReason: "the container runtime could not be inspected"
    )
    let message = try! #require(SparkWorkloadPresentation.unavailableMessage(unreadable))
    #expect(message.contains("could not be read"))
    #expect(message.contains("the container runtime could not be inspected"))
    // No sections, and explicitly no "nothing is running" claim.
    #expect(SparkWorkloadPresentation.sections(unreadable).isEmpty)
    #expect(SparkWorkloadPresentation.emptyMessage(unreadable) == nil)
}

@Test func anUnreadableHostWithoutAReasonStillSaysItCouldNotBeRead() {
    let message = try! #require(
        SparkWorkloadPresentation.unavailableMessage(inventory(available: false))
    )
    #expect(message.contains("could not be read"))
}

@Test func aGenuinelyIdleSparkSaysSo() {
    let idle = inventory(workloads: [])
    #expect(
        SparkWorkloadPresentation.emptyMessage(idle) == "No workloads are present on this Spark."
    )
    #expect(SparkWorkloadPresentation.unavailableMessage(idle) == nil)
    #expect(SparkWorkloadPresentation.sections(idle).isEmpty)
}

@Test func anIncompleteListSaysItIsIncomplete() {
    let truncated = inventory(truncated: true, workloads: [workload()])
    let notice = try! #require(SparkWorkloadPresentation.truncationNotice(truncated))
    #expect(notice.contains("more workloads than this list shows"))
    // A complete list must not carry the notice.
    #expect(SparkWorkloadPresentation.truncationNotice(inventory(workloads: [workload()])) == nil)
    // An unreadable host is not a truncated one.
    #expect(
        SparkWorkloadPresentation.truncationNotice(inventory(available: false, truncated: true))
            == nil
    )
}

@Test func aWorkloadTheSparkCouldNotIdentifyIsLabelledUnidentifiedNotEmpty() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(
            workloads: [
                workload(
                    name: nil,
                    ownership: .unknownExternal,
                    kind: .unknown,
                    engine: .none,
                    image: nil
                )
            ]
        )
    )
    let row = try! #require(sections.first?.rows.first)
    #expect(row.title == "Unnamed workload")
    #expect(row.ownership == "Externally managed, not identified")
    #expect(row.detail.contains("Not identified"))
    #expect(row.imageReference == nil)
}

@Test func aWorkloadThatCouldBeAdoptedIsStillDescribedAsExternal() {
    // Keep adoptable workloads external until ownership transfer succeeds.
    let sections = SparkWorkloadPresentation.sections(
        inventory(
            adoptionSupported: true,
            workloads: [workload(ownership: .adoptionAvailable)]
        )
    )
    let row = try! #require(sections.first?.rows.first)
    #expect(!row.isManagedBySparkPilot)
    #expect(row.ownership.hasPrefix("Externally managed"))
    #expect(sections.first?.id == SparkWorkloadPresentation.externalSectionID)
}

@Test func recognisedEnginesAreNamedAndUnrecognisedOnesAreNot() {
    #expect(
        SparkWorkloadPresentation.description(engine: .vllm, kind: .inferenceEngine)
            == "vLLM inference engine"
    )
    #expect(
        SparkWorkloadPresentation.description(engine: .sglang, kind: .inferenceEngine)
            == "SGLang inference engine"
    )
    #expect(
        SparkWorkloadPresentation.description(engine: .ray, kind: .clusterRuntime)
            == "Ray cluster runtime"
    )
    #expect(
        SparkWorkloadPresentation.description(engine: .openWebui, kind: .optionalService)
            == "Open WebUI"
    )
    #expect(
        SparkWorkloadPresentation.description(engine: .none, kind: .projectContainer)
            == "Project container"
    )
    #expect(
        SparkWorkloadPresentation.description(engine: .none, kind: .unknown) == "Not identified"
    )
}

@Test func anUnknownLifecycleWordIsNotRenderedAsStopped() {
    // Do not classify unfamiliar workload states as stopped.
    #expect(SparkWorkloadPresentation.stateLabel(.unknown) == "State unknown")
    #expect(SparkWorkloadPresentation.stateLabel(.exited) == "Stopped")
    #expect(SparkWorkloadPresentation.stateLabel(.dead) == "Failed")
    #expect(SparkWorkloadPresentation.stateLabel(.running) == "Running")
}

@Test func publishedEndpointsAreShownSoAnOwnerRecognisesTheirOwnService() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(
            workloads: [
                workload(
                    ports: [
                        GeneratedAPI.ObservedWorkloadPort(
                            hostIp: "0.0.0.0",
                            hostPort: 30000,
                            containerPort: 30000,
                            protocol: .tcp
                        )
                    ]
                )
            ]
        )
    )
    let row = try! #require(sections.first?.rows.first)
    #expect(row.endpoints == ["0.0.0.0:30000 → 30000/tcp"])
    #expect(row.accessibilityLabel.contains("0.0.0.0:30000"))
}

@Test func aVerifiedExternalEngineNamesItsModelsAndOpenAIEndpointWithoutControls() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(
            workloads: [
                workload(
                    configurationState: .verified,
                    apiProtocol: "openai_compatible",
                    apiPort: 30000,
                    servedModels: ["deepseek-ai/DeepSeek-R1"]
                )
            ]
        )
    )
    let row = try! #require(sections.first?.rows.first)
    #expect(row.servedModels == ["deepseek-ai/DeepSeek-R1"])
    #expect(row.apiSummary == "OpenAI-compatible API on port 30000")
    #expect(!row.isManagedBySparkPilot)
    #expect(row.accessibilityLabel.contains("DeepSeek-R1"))
}

@Test func anUnavailableExternalConfigurationDoesNotPretendNoModelIsServed() {
    let sections = SparkWorkloadPresentation.sections(
        inventory(workloads: [workload(configurationState: .unavailable)])
    )
    let row = try! #require(sections.first?.rows.first)
    #expect(row.servedModels.isEmpty)
    #expect(row.apiSummary == nil)
    #expect(row.detail.contains("SGLang inference engine"))
}

@Test func anEmptyGroupProducesNoHeading() {
    // Omit empty ownership groups rather than implying an unobserved management state.
    let sections = SparkWorkloadPresentation.sections(inventory(workloads: [workload()]))
    #expect(sections.count == 1)
    #expect(sections[0].id == SparkWorkloadPresentation.externalSectionID)

    let managedOnly = SparkWorkloadPresentation.sections(inventory(workloads: [managedEngine]))
    #expect(managedOnly.count == 1)
    #expect(managedOnly[0].id == SparkWorkloadPresentation.managedSectionID)
}

@Test func adoptionAndRelinquishControlsFollowExactCapabilityAndOwnershipEvidence() {
    let externalVLLM = workload(
        id: "a",
        ownership: .externalObserved,
        engine: .vllm,
        state: .running
    )
    let externalSGLang = workload(
        id: "b",
        ownership: .externalObserved,
        engine: .sglang,
        state: .running
    )
    let adopted = workload(
        id: "c",
        ownership: .sparkManaged,
        engine: .vllm,
        managementOrigin: .externalAdoption
    )
    let sparkStarted = workload(
        id: "d",
        ownership: .sparkManaged,
        engine: .vllm,
        managementOrigin: .sparkStarted
    )

    let rows = SparkWorkloadPresentation.sections(
        inventory(
            adoptionSupported: true,
            workloads: [externalVLLM, externalSGLang, adopted, sparkStarted]
        )
    ).flatMap(\.rows)

    #expect(rows.first(where: { $0.id == "a" })?.canReviewAdoption == true)
    #expect(rows.first(where: { $0.id == "b" })?.canReviewAdoption == false)
    #expect(rows.first(where: { $0.id == "c" })?.canRelinquish == true)
    #expect(rows.first(where: { $0.id == "d" })?.canRelinquish == false)
    #expect(rows.first(where: { $0.id == "c" })?.ownership.contains("adopted in place") == true)
    #expect(rows.first(where: { $0.id == "d" })?.ownership == "Managed by SparkPilot")
}

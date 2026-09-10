import Foundation
import SparkCore
import SparkLibrary
import Testing
@testable import SparkAppComposition

private let workloadEvidenceDate = Date(timeIntervalSince1970: 1_777_460_400)

private func workloadUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func workloadFreshness(
    _ state: OperationalFreshnessState = .current
) -> OperationalEvidenceFreshness {
    OperationalEvidenceFreshness(
        observedAt: state == .missing ? nil : workloadEvidenceDate,
        evaluatedAt: state == .stale
            ? workloadEvidenceDate.addingTimeInterval(61)
            : workloadEvidenceDate,
        staleAfter: 60
    )
}

private func workloadTargetFreshness(
    health: OperationalFreshnessState = .current,
    inventory: OperationalFreshnessState = .current
) -> TargetEvidenceFreshness {
    TargetEvidenceFreshness(
        health: workloadFreshness(health),
        inventory: workloadFreshness(inventory),
        memory: workloadFreshness(),
        inference: workloadFreshness(),
        operations: workloadFreshness()
    )
}

private func workloadPlacement(
    model: Int = 1,
    name: String = "Model 8B",
    state: ModelPlacementState,
    evidence: OperationalFreshnessState = .current,
    warnings: [OperationalNotice] = [],
    blockers: [OperationalNotice] = []
) -> ModelPlacementSnapshot {
    let identity = ModelPlacementIdentity(
        modelID: "spark/model-\(model)",
        recipeRevision: "2026.08.\(model)"
    )
    return ModelPlacementSnapshot(
        identity: identity,
        displayName: name,
        state: state,
        evidence: workloadFreshness(evidence),
        technicalDetails: ModelPlacementTechnicalDetails(
            modelID: identity.modelID,
            recipeRevision: identity.recipeRevision,
            sourceRevision: "source-\(model)"
        ),
        warnings: warnings,
        blockers: blockers
    )
}

private func workloadMember(
    _ value: Int,
    name: String,
    role: SparkNodeRole,
    reachable: Bool = true,
    linkHealth: String? = "healthy"
) -> TargetMemberSnapshot {
    TargetMemberSnapshot(
        nodeID: SparkNodeID(rawValue: workloadUUID(value)),
        displayName: name,
        role: role,
        reachable: reachable,
        linkHealth: linkHealth,
        lastSuccessfulContact: workloadEvidenceDate
    )
}

private func workloadTarget(
    _ value: Int,
    name: String,
    cluster: Bool = false,
    members: [TargetMemberSnapshot]? = nil,
    healthEvidence: OperationalFreshnessState = .current,
    inventoryEvidence: OperationalFreshnessState = .current,
    runtimeHealth: SparkRuntimeHealthState = .healthy,
    placements: [ModelPlacementSnapshot]
) -> TargetOperationalSnapshot {
    let identity: SparkTargetIdentity =
        cluster
        ? .cluster(SparkClusterID(rawValue: workloadUUID(10_000 + value)))
        : .node(SparkNodeID(rawValue: workloadUUID(value)))
    let resolvedMembers =
        members
        ?? [
            workloadMember(
                value,
                name: name,
                role: cluster ? .leader : .standalone,
                linkHealth: cluster ? "healthy" : nil
            )
        ]
    let evidence = workloadTargetFreshness(
        health: healthEvidence,
        inventory: inventoryEvidence
    )
    return TargetOperationalSnapshot(
        identity: identity,
        displayName: name,
        members: resolvedMembers,
        preferredRoute: nil,
        connectionState: .connectedDirect,
        lastSuccessfulContact: workloadEvidenceDate,
        evaluatedAt: workloadEvidenceDate,
        evidence: evidence,
        runtime: TargetRuntimeSnapshot(
            version: "0.2.0",
            health: runtimeHealth,
            updateState: .current
        ),
        vllmHealth: .ready,
        unifiedMemory: UnifiedMemorySnapshot(
            totalBytes: 128_000_000_000,
            availableBytes: 64_000_000_000,
            pressure: .normal
        ),
        disk: DiskCapacitySnapshot(freeBytes: 500_000_000_000),
        installedModelCount: placements.count {
            $0.state == .installed || $0.state == .running
        },
        activeInference: nil,
        operations: [],
        placements: placements,
        warnings: [],
        blockers: [],
        technicalDetails: TargetTechnicalDetails(
            logicalIdentity: identity.description,
            memberNodeIDs: resolvedMembers.map(\.nodeID)
        )
    )
}

private func workloadSnapshot(
    _ targets: [TargetOperationalSnapshot]
) -> WorkloadComparisonSnapshot {
    WorkloadComparisonBuilder.snapshot(
        from: targets,
        generatedAt: workloadEvidenceDate
    )
}

@Test func oneTargetFixtureBuildsOneReadableColumn() throws {
    let target = workloadTarget(
        1,
        name: "Studio Spark",
        placements: [workloadPlacement(state: .running)]
    )
    let snapshot = workloadSnapshot([target])
    let row = try #require(snapshot.rows.first)
    let column = try #require(snapshot.targets.first)
    let cell = try #require(row.cell(for: column.id))

    #expect(snapshot.targets.count == 1)
    #expect(snapshot.rows.count == 1)
    #expect(column.name == "Studio Spark")
    #expect(column.kind == .spark)
    #expect(cell.state == .running)
    #expect(cell.accessibilitySummary.contains("Running"))
    #expect(WorkloadLayoutMetrics.matrixWidth(targetCount: 1) > 300)
}

@Test func twoTargetFixtureComparesTheSameRecipeWithoutLosingState() throws {
    let installed = workloadTarget(
        1,
        name: "Desk Spark",
        placements: [workloadPlacement(state: .installed)]
    )
    let downloading = workloadTarget(
        2,
        name: "Lab Spark",
        placements: [workloadPlacement(state: .downloading)]
    )
    let snapshot = workloadSnapshot([downloading, installed])
    let row = try #require(snapshot.rows.first)

    #expect(snapshot.targets.map(\.name) == ["Desk Spark", "Lab Spark"])
    #expect(row.cells.map(\.state) == [.installed, .downloading])
    #expect(row.cells.allSatisfy { !$0.state.label.isEmpty && !$0.state.symbolName.isEmpty })
}

@Test func eightTargetFixtureKeepsOneColumnPerLogicalTarget() throws {
    let targets = (1...8).map { index in
        workloadTarget(
            index,
            name: "Spark \(index)",
            placements: [workloadPlacement(state: index == 1 ? .running : .installed)]
        )
    }
    let snapshot = workloadSnapshot(targets)
    let row = try #require(snapshot.rows.first)

    #expect(snapshot.targets.count == 8)
    #expect(row.cells.count == 8)
    #expect(WorkloadLayoutMetrics.matrixWidth(targetCount: 8) > 1_600)
    #expect(WorkloadLayoutMetrics.compactThreshold < 768)
    #expect(Set(snapshot.targets.map(\.id)).count == 8)
}

@Test func compactWidthAndAccessibilityTextUseTheNonTruncatingStackedLayout() {
    #expect(
        WorkloadLayoutPlan.usesStackedLayout(
            preference: .automatic,
            width: 600,
            hasCompactHorizontalSize: false,
            usesAccessibilityTextSize: false
        )
    )
    #expect(
        WorkloadLayoutPlan.usesStackedLayout(
            preference: .automatic,
            width: 1_024,
            hasCompactHorizontalSize: true,
            usesAccessibilityTextSize: false
        )
    )
    #expect(
        WorkloadLayoutPlan.usesStackedLayout(
            preference: .matrix,
            width: 1_024,
            hasCompactHorizontalSize: false,
            usesAccessibilityTextSize: true
        )
    )
    #expect(
        !WorkloadLayoutPlan.usesStackedLayout(
            preference: .automatic,
            width: 1_024,
            hasCompactHorizontalSize: false,
            usesAccessibilityTextSize: false
        )
    )
}

@Test func workloadDetailButtonsHaveSpecificAccessibilityLabels() {
    #expect(
        WorkloadActionPresentation.targetDetailsAccessibilityLabel(targetName: "Studio Spark")
            == "Show workload details for Studio Spark"
    )
    #expect(
        WorkloadActionPresentation.placementDetailsAccessibilityLabel(
            modelName: "Compact 8B",
            targetName: "Studio Spark",
            state: .running
        ) == "Show Compact 8B on Studio Spark. Running"
    )
}

@Test func everyRequiredWorkloadStateHasTextAndANonColourCue() {
    #expect(
        WorkloadDisplayState.allCases.map(\.label)
            == [
                "Running", "Installed", "Downloading", "Planned", "Degraded", "Blocked",
                "Not present", "Unknown",
            ]
    )
    #expect(Set(WorkloadDisplayState.allCases.map(\.symbolName)).count == 8)
}

@Test func placementStatesMapToTheExplicitWorkloadVocabulary() throws {
    let placements = [
        workloadPlacement(model: 1, name: "Running", state: .running),
        workloadPlacement(model: 2, name: "Installed", state: .installed),
        workloadPlacement(model: 3, name: "Downloading", state: .downloading),
        workloadPlacement(model: 4, name: "Planned", state: .starting),
        workloadPlacement(model: 5, name: "Failed", state: .failed),
        workloadPlacement(model: 6, name: "Incompatible", state: .incompatible),
        workloadPlacement(model: 7, name: "Available", state: .available),
        workloadPlacement(model: 8, name: "Unknown", state: .unknown),
    ]
    let snapshot = workloadSnapshot(
        [workloadTarget(1, name: "Studio Spark", placements: placements)]
    )
    let states = Dictionary(
        uniqueKeysWithValues: snapshot.rows.map { row in
            (row.name, row.cells[0].state)
        }
    )

    #expect(states["Running"] == .running)
    #expect(states["Installed"] == .installed)
    #expect(states["Downloading"] == .downloading)
    #expect(states["Planned"] == .planned)
    #expect(states["Failed"] == .blocked)
    #expect(states["Incompatible"] == .blocked)
    #expect(states["Available"] == .notPresent)
    #expect(states["Unknown"] == .unknown)
}

@Test func degradedMemberDegradesDistributedWorkloadAndStaysInsideClusterColumn() throws {
    let members = [
        workloadMember(21, name: "Coordinator", role: .leader),
        workloadMember(22, name: "Second Spark", role: .worker, reachable: false),
    ]
    let cluster = workloadTarget(
        3,
        name: "Studio Cluster",
        cluster: true,
        members: members,
        placements: [workloadPlacement(state: .running)]
    )
    let snapshot = workloadSnapshot([cluster])
    let target = try #require(snapshot.targets.first)
    let cell = try #require(snapshot.rows.first?.cells.first)

    #expect(snapshot.targets.count == 1)
    #expect(target.kind == .cluster)
    #expect(target.members.count == 2)
    #expect(target.clusterHealth == .degraded)
    #expect(cell.state == .degraded)
    #expect(cell.detail.contains("Second Spark"))
    #expect(!cell.accessibilitySummary.contains("Running"))
}

@Test func coordinatorOnlyEvidenceNeverClaimsHealthyClusterWorkload() throws {
    let cluster = workloadTarget(
        4,
        name: "Incomplete Cluster",
        cluster: true,
        members: [workloadMember(31, name: "Coordinator", role: .leader)],
        placements: [workloadPlacement(state: .running)]
    )
    let snapshot = workloadSnapshot([cluster])
    let target = try #require(snapshot.targets.first)
    let cell = try #require(snapshot.rows.first?.cells.first)

    #expect(target.clusterHealth == .unknown)
    #expect(target.memberSummary == "Cluster membership incomplete")
    #expect(cell.state == .unknown)
    #expect(cell.evidence == .missing)
    #expect(cell.detail.contains("complete cluster membership"))
}

@Test func missingInventoryProducesUnknownWhileCurrentAbsenceIsNotPresent() throws {
    let identity = workloadPlacement(model: 9, name: "Model 9", state: .installed)
    let source = workloadTarget(1, name: "Source", placements: [identity])
    let currentEmpty = workloadTarget(2, name: "Current Empty", placements: [])
    let missingEmpty = workloadTarget(
        3,
        name: "Missing Empty",
        inventoryEvidence: .missing,
        placements: []
    )
    let snapshot = workloadSnapshot([source, currentEmpty, missingEmpty])
    let row = try #require(snapshot.rows.first)
    let states = Dictionary(
        uniqueKeysWithValues: snapshot.targets.compactMap { target in
            row.cell(for: target.id).map { (target.name, $0) }
        }
    )

    #expect(states["Current Empty"]?.state == .notPresent)
    #expect(states["Current Empty"]?.evidence == .current)
    #expect(states["Missing Empty"]?.state == .unknown)
    #expect(states["Missing Empty"]?.evidence == .missing)
}

@Test func missingLinkEvidenceCannotBecomeHealthyClusterEvidence() throws {
    let cluster = workloadTarget(
        5,
        name: "Link Unknown Cluster",
        cluster: true,
        members: [
            workloadMember(41, name: "Coordinator", role: .leader),
            workloadMember(
                42,
                name: "Second Spark",
                role: .worker,
                linkHealth: nil
            ),
        ],
        placements: [workloadPlacement(state: .installed)]
    )
    let snapshot = workloadSnapshot([cluster])

    #expect(snapshot.targets.first?.clusterHealth == .unknown)
    #expect(snapshot.rows.first?.cells.first?.state == .unknown)
    #expect(snapshot.rows.first?.cells.first?.evidence == .missing)
    #expect(snapshot.targets.first?.members.last?.state == .unknown)
}

@MainActor
@Test func filterSearchAndSelectionSurviveOpeningClosingAndRefresh() throws {
    let selectedTarget = workloadTarget(
        1,
        name: "Studio Spark",
        placements: [
            workloadPlacement(model: 1, name: "Alpha", state: .installed),
            workloadPlacement(model: 2, name: "Beta", state: .failed),
        ]
    )
    let snapshot = workloadSnapshot([selectedTarget])
    let selectedRow = try #require(snapshot.rows.first { $0.name == "Alpha" })
    let model = WorkloadComparisonModel(snapshot: snapshot)
    model.searchText = "Alpha"
    model.filter = .installed
    model.select(rowID: selectedRow.id, targetID: selectedTarget.identity)
    model.closeDetail()

    #expect(!model.isDetailPresented)
    #expect(model.selectedRowID == selectedRow.id)
    #expect(model.selectedTargetID == selectedTarget.identity)
    #expect(model.visibleRows.map(\.name) == ["Alpha"])

    model.replaceSnapshot(snapshot)
    #expect(model.searchText == "Alpha")
    #expect(model.filter == .installed)
    #expect(model.selectedRowID == selectedRow.id)
    #expect(model.selectedTargetID == selectedTarget.identity)

    model.replaceSnapshot(.empty)
    #expect(model.searchText == "Alpha")
    #expect(model.filter == .installed)
    #expect(model.selectedRowID == nil)
    #expect(model.selectedTargetID == nil)
}

@MainActor
@Test func libraryAdapterUsesOnlySavedOperationalSnapshots() throws {
    let target = workloadTarget(
        71,
        name: "Saved Spark",
        placements: [workloadPlacement(name: "Saved Model", state: .installed)]
    )
    let store = MemoryLibraryStore()
    let memberID = workloadUUID(71)
    let entry = LibraryEntry(
        logicalKey: .node(SparkNodeID(rawValue: memberID)),
        name: "Saved Spark",
        members: [
            LibraryMember(
                nodeID: SparkNodeID(rawValue: memberID),
                name: "Saved Spark",
                role: .standalone,
                reachable: true
            )
        ],
        connectionState: .connectedWiFi,
        lastSeen: workloadEvidenceDate,
        cachedAt: workloadEvidenceDate,
        cachedOperationalSnapshot: target
    )
    try store.save([entry])
    let library = SparkLibrary(store: store, now: { workloadEvidenceDate })
    library.load()

    let snapshot = WorkloadLibraryAdapter.snapshot(
        from: library,
        at: workloadEvidenceDate
    )

    #expect(snapshot.targets.map(\.name) == ["Saved Spark"])
    #expect(snapshot.rows.map(\.name) == ["Saved Model"])
}

@MainActor
@Test func libraryRefreshReplacesEvidenceWithoutResettingWorkloadControls() throws {
    let target = workloadTarget(
        72,
        name: "Refresh Spark",
        placements: [workloadPlacement(name: "Refresh Model", state: .installed)]
    )
    let nodeID = SparkNodeID(rawValue: workloadUUID(72))
    let store = MemoryLibraryStore()
    try store.save([
        LibraryEntry(
            logicalKey: .node(nodeID),
            name: "Refresh Spark",
            members: [
                LibraryMember(
                    nodeID: nodeID,
                    name: "Refresh Spark",
                    role: .standalone,
                    reachable: true
                )
            ],
            cachedAt: workloadEvidenceDate,
            cachedOperationalSnapshot: target
        )
    ])
    let library = SparkLibrary(store: store, now: { workloadEvidenceDate })
    library.load()
    let initial = WorkloadLibraryAdapter.snapshot(from: library, at: workloadEvidenceDate)
    let model = WorkloadComparisonModel(snapshot: initial)
    let row = try #require(initial.rows.first)
    let column = try #require(initial.targets.first)
    model.searchText = "Refresh"
    model.filter = .installed
    model.select(rowID: row.id, targetID: column.id)
    model.closeDetail()

    _ = library.remove(entryID: library.entries[0].id)
    model.replaceSnapshot(
        WorkloadLibraryAdapter.snapshot(from: library, at: workloadEvidenceDate)
    )

    #expect(model.snapshot.targets.isEmpty)
    #expect(model.snapshot.rows.isEmpty)
    #expect(model.searchText == "Refresh")
    #expect(model.filter == .installed)
    #expect(model.selectedRowID == nil)
    #expect(model.selectedTargetID == nil)
}

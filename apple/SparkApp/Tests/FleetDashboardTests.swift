import Foundation
import SparkCore
import SwiftUI
import Testing
@testable import SparkAppComposition

private func dashFreshness(
    _ state: OperationalFreshnessState = .current
) -> OperationalEvidenceFreshness {
    OperationalEvidenceFreshness(
        observedAt: state == .missing ? nil : dashDate,
        evaluatedAt: dashDate,
        staleAfter: 60
    )
}

private let dashDate = Date(timeIntervalSince1970: 1_800_000_000)

private func dashUUID(_ value: Int) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = 0xF0
    bytes[14] = UInt8(value & 0xFF)
    bytes[15] = UInt8((value >> 8) & 0xFF)
    return UUID(
        uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    )
}

private func dashPlacement(
    _ name: String,
    state: ModelPlacementState
) -> ModelPlacementSnapshot {
    ModelPlacementSnapshot(
        identity: ModelPlacementIdentity(
            modelID: "acme/\(name)",
            recipeRevision: "rev-\(name)"
        ),
        displayName: name,
        state: state,
        evidence: dashFreshness(),
        technicalDetails: ModelPlacementTechnicalDetails(
            modelID: "acme/\(name)",
            recipeRevision: "rev-\(name)",
            sourceRevision: "src-\(name)"
        ),
        warnings: [],
        blockers: []
    )
}

private func dashSpark(
    _ value: Int,
    name: String,
    cluster: Bool = false,
    connection: TargetConnectionState = .connectedWiFi,
    memory: UnifiedMemorySnapshot? = UnifiedMemorySnapshot(
        totalBytes: 128_000_000_000,
        availableBytes: 64_000_000_000,
        pressure: .normal
    ),
    temperature: Double? = nil,
    inferenceModel: String? = nil,
    tokensPerSecond: Double? = nil,
    memberReachable: Bool? = nil,
    placements: [ModelPlacementSnapshot] = []
) -> TargetOperationalSnapshot {
    let identity: SparkTargetIdentity =
        cluster
        ? .cluster(SparkClusterID(rawValue: dashUUID(10_000 + value)))
        : .node(SparkNodeID(rawValue: dashUUID(value)))
    let members: [TargetMemberSnapshot] = [
        TargetMemberSnapshot(
            nodeID: SparkNodeID(rawValue: dashUUID(value)),
            displayName: name,
            role: cluster ? .leader : .standalone,
            reachable: memberReachable ?? true,
            linkHealth: cluster ? "healthy" : nil,
            lastSuccessfulContact: dashDate
        )
    ]
    let activeInference: ActiveInferenceSnapshot? =
        inferenceModel.map { model in
            ActiveInferenceSnapshot(
                state: .ready,
                modelIdentity: ModelPlacementIdentity(
                    modelID: "acme/\(model)",
                    recipeRevision: "rev-\(model)"
                ),
                profileID: "balanced-16k",
                activeRequests: 1,
                queueDepth: 0,
                tokensPerSecond: tokensPerSecond,
                timeToFirstTokenMilliseconds: nil
            )
        }
    return TargetOperationalSnapshot(
        identity: identity,
        displayName: name,
        members: members,
        preferredRoute: nil,
        connectionState: connection,
        lastSuccessfulContact: dashDate,
        evaluatedAt: dashDate,
        evidence: TargetEvidenceFreshness(
            health: dashFreshness(),
            inventory: dashFreshness(),
            memory: dashFreshness(),
            inference: dashFreshness(),
            operations: dashFreshness()
        ),
        runtime: TargetRuntimeSnapshot(
            version: "0.2.0",
            health: .healthy,
            updateState: .current
        ),
        vllmHealth: .ready,
        unifiedMemory: memory,
        disk: DiskCapacitySnapshot(freeBytes: 500_000_000_000),
        installedModelCount: placements.count { placement in
            placement.state == .installed || placement.state == .running
        },
        activeInference: activeInference,
        operations: [],
        placements: placements,
        warnings: [],
        blockers: [],
        technicalDetails: TargetTechnicalDetails(
            logicalIdentity: identity.description,
            memberNodeIDs: members.map(\.nodeID)
        ),
        temperatureCelsius: temperature
    )
}

@Test func fleetOverviewTotalsAcrossSparks() {
    let overview = FleetOverviewBuilder.build(
        from: [
            dashSpark(
                1,
                name: "Studio Spark",
                temperature: 58,
                inferenceModel: "model-32b",
                tokensPerSecond: 41.5,
                placements: [dashPlacement("model-32b", state: .running)]
            ),
            dashSpark(
                2,
                name: "Lab Spark",
                cluster: true,
                connection: .connectedDirect,
                memory: UnifiedMemorySnapshot(
                    totalBytes: 256_000_000_000,
                    availableBytes: 128_000_000_000,
                    pressure: .warning
                ),
                temperature: 71,
                memberReachable: false,
                placements: [dashPlacement("model-32b", state: .installed)]
            ),
            dashSpark(3, name: "Attic Spark", connection: .offlineCached, memory: nil),
        ],
        at: dashDate
    )

    #expect(overview.sparks.count == 3)
    #expect(overview.totalMemoryBytes == 384_000_000_000)
    #expect(overview.usedMemoryBytes == 192_000_000_000)
    #expect(overview.memoryReportedCount == 2)
    #expect(overview.runningInferenceCount == 1)
    #expect(overview.connectedCount == 2)
    #expect(overview.clusterCount == 1)

    let running = overview.sparks.first { $0.displayName == "Studio Spark" }
    #expect(running?.inferenceModelName == "model-32b")
    #expect(running?.inferenceTokensPerSecond == 41.5)
    #expect(running?.isConnected == true)

    let hottest = overview.hottestFirst.map { spark in spark.displayName }
    #expect(hottest == ["Lab Spark", "Studio Spark"])

    let offline = overview.sparks.first { $0.displayName == "Attic Spark" }
    #expect(offline?.memoryLabel == "Memory not reported")
    #expect(offline?.isConnected == false)
}

@Test func fleetMatrixCountsFleetCoverageAndPrefersRunning() {
    let overview = FleetOverviewBuilder.build(
        from: [
            dashSpark(
                1,
                name: "A",
                placements: [
                    dashPlacement("shared-model", state: .running),
                    dashPlacement("only-a", state: .installed),
                ]
            ),
            dashSpark(2, name: "B", placements: [dashPlacement("shared-model", state: .installed)]),
        ],
        at: dashDate
    )

    #expect(overview.modelMatrix.count == 2)
    #expect(overview.modelMatrix.first?.modelName == "shared-model")
    #expect(overview.modelMatrix.first?.placements.count == 2)
    #expect(overview.modelMatrix.first?.placements.contains { $0.isRunning } == true)
    let onlyA = overview.modelMatrix.last
    #expect(onlyA?.modelName == "only-a")
    #expect(onlyA?.placements.first?.sparkName == "A")
}

@Test func clusterCardSummarisesMemberReadiness() {
    let overview = FleetOverviewBuilder.build(
        from: [
            dashSpark(1, name: "Pair", cluster: true, memberReachable: false)
        ],
        at: dashDate
    )
    let cluster = overview.sparks.first
    #expect(cluster?.isCluster == true)
    #expect(cluster?.memberReadyCount == 0)
    #expect(cluster?.memberTotalCount == 1)
}

@Test func customizationDefaultsShowEveryCardOnce() {
    let customization = FleetDashboardCustomization()
    #expect(customization.visibleCards == FleetCardKind.allCases)
    #expect(customization.isHidden(.temperatures) == false)
}

@Test func customizationHidesReordersAndSurvivesUnknownEntries() {
    var customization = FleetDashboardCustomization(
        order: [.temperatures, .runningInference, .fleetMemory]
    )
    customization.setHidden(.runningInference, true)
    let visible = customization.visibleCards
    #expect(visible.first == .temperatures)
    #expect(!visible.contains(.runningInference))
    // Cards missing from a saved order still appear after the saved ones.
    #expect(visible.suffix(3).contains(.clusters))
    #expect(visible.filter { $0 == .temperatures }.count == 1)
}

@Test func storeRoundTripsThroughUserDefaults() throws {
    let suiteName = "fleet-dashboard-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FleetDashboardStore(defaults: defaults)

    var saved = FleetDashboardCustomization(order: [.clusters, .temperatures])
    saved.setHidden(.temperatures, true)
    store.save(saved)

    let loaded = store.load()
    #expect(loaded == saved)
    #expect(store.load() != FleetDashboardCustomization() || saved == loaded)
}

@MainActor
@Test func dashboardModelUpdatesMovesAndResets() {
    let suiteName = "fleet-dashboard-model-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FleetDashboardModel(store: FleetDashboardStore(defaults: defaults))

    model.update(from: [dashSpark(1, name: "Solo", temperature: 44)], at: dashDate)
    #expect(model.overview.sparks.count == 1)
    #expect(model.overview.hottestFirst.first?.displayName == "Solo")

    // Default order starts with runningInference; clusters swaps up one slot.
    model.moveCard(.clusters, offset: -1)
    #expect(model.customization.order[2] == .clusters)
    #expect(model.customization.order[3] == .loadedModels)
    // Moving past either edge is refused.
    model.moveCard(.runningInference, offset: -5)
    #expect(model.customization.order.first == .runningInference)
    model.moveCard(.connectivity, offset: 5)
    #expect(model.customization.order.last == .connectivity)

    model.setCard(.temperatures, hidden: true)
    #expect(model.customization.visibleCards.contains(.temperatures) == false)

    model.resetLayout()
    #expect(model.customization == FleetDashboardCustomization())
    // The reset layout persisted: a fresh model on the same defaults sees it.
    let reloaded = FleetDashboardModel(store: FleetDashboardStore(defaults: defaults))
    #expect(reloaded.customization == FleetDashboardCustomization())
}

@Test func overviewRowsCarryTheLibraryEntryTheyOpen() {
    // Carry the library entry ID so a summary row opens the same entry that produced it.
    let overview = FleetOverviewBuilder.build(
        targets: [
            FleetOverviewTarget(entryID: "entry-b", snapshot: dashSpark(2, name: "Beta")),
            FleetOverviewTarget(entryID: "entry-a", snapshot: dashSpark(1, name: "Alpha")),
        ],
        at: dashDate
    )
    #expect(overview.sparks.map(\.entryID) == ["entry-a", "entry-b"])
    #expect(overview.freshestEvidenceAge != nil)
}

@Test func overviewUsesTheFleetCardsConnectionWords() {
    // Keep fleet overview connectivity consistent with the underlying Spark card.
    let overview = FleetOverviewBuilder.build(
        from: [
            dashSpark(1, name: "Near", connection: .connectedWiFi),
            dashSpark(2, name: "Far", connection: .offlineCached),
        ],
        at: dashDate
    )
    let near = overview.sparks.first { $0.displayName == "Near" }
    let far = overview.sparks.first { $0.displayName == "Far" }
    #expect(near?.connectionLabel == "Connected over Wi-Fi")
    #expect(near?.connectionTone == .positive)
    #expect(far?.connectionLabel == "Offline · showing saved state")
    #expect(far?.connectionTone == .caution)
    #expect(overview.connectionTallies.map(\.count) == [1, 1])
}

@Test func oneSparkOffersEveryDashboardCardToCustomize() {
    let overview = FleetOverviewBuilder.build(
        from: [dashSpark(1, name: "Solo", temperature: nil)],
        at: dashDate
    )
    #expect(FleetHomeBuilder.applicableCards(overview) == FleetCardKind.allCases)
    #expect(overview.worstMemoryPressure == .normal)
}

@Test func heatIsWordedAsWellAsColoured() {
    // The guard's shipped defaults are 75 warm, 84 hot, 90 critical.
    #expect(FleetHeat.word(32) == "Cool")
    #expect(FleetHeat.word(78) == "Warm")
    #expect(FleetHeat.word(86) == "Hot")
    #expect(FleetHeat.word(95) == "Very hot")
    #expect(FleetFormat.celsius(31.6) == "32°C")
}

@MainActor
@Test func draggingReordersAndPersistsTheLayout() {
    let suiteName = "fleet-dashboard-drag-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FleetDashboardModel(store: FleetDashboardStore(defaults: defaults))

    model.moveCards(fromOffsets: IndexSet(integer: 5), toOffset: 0)
    #expect(model.customization.order.first == .connectivity)
    let reloaded = FleetDashboardModel(store: FleetDashboardStore(defaults: defaults))
    #expect(reloaded.customization.order.first == .connectivity)
}

// MARK: - Live sweep

/// Fleet refresh must precede the freshness threshold to keep healthy Sparks from appearing slow.
@Test func fleetSweepOutpacesTheDelayedThreshold() {
    let policy = OperationalFreshnessPolicy()
    let sweep = FleetModel.liveSweepInterval
    let sweepSeconds =
        Double(sweep.components.seconds) + Double(sweep.components.attoseconds) / 1e18
    #expect(sweepSeconds > 0)
    #expect(sweepSeconds * 2 <= policy.delayedAfter)
}

// MARK: - Memory card wording and colour

/// Base memory-bar colour on current utilization rather than a latched guard rung.
@Test func memoryBarColourFollowsHowFullItIs() {
    let total: Int64 = 130_600_000_000
    #expect(FleetMemoryFill.color(used: 3_600_000_000, total: total) == .green)
    #expect(FleetMemoryFill.color(used: 96_000_000_000, total: total) == .orange)
    #expect(FleetMemoryFill.color(used: 120_000_000_000, total: total) == .red)
    #expect(FleetMemoryFill.color(used: 0, total: 0) == .secondary)
}

/// Display installed 128 GB Spark capacity rather than reinterpreting Linux usable-memory units.
@Test func memoryCapacityUsesTheInstalledSparkCapacity() {
    #expect(SparkMemoryCapacity.installedBytes(reportedBytes: 130_600_000_000) == 128_000_000_000)
    #expect(FleetFormat.gigabytes(128_000_000_000) == "128.0 GB")

    let overview = FleetOverviewBuilder.build(
        from: [
            dashSpark(
                1,
                name: "Example Spark",
                memory: UnifiedMemorySnapshot(
                    totalBytes: 130_600_000_000,
                    availableBytes: 127_000_000_000,
                    pressure: .emergency
                )
            )
        ],
        at: dashDate
    )
    #expect(overview.totalMemoryBytes == 128_000_000_000)
    #expect(overview.usedMemoryBytes == 3_600_000_000)
    #expect(overview.sparks.first?.memoryShortLabel == "3.6 GB of 128.0 GB")
    #expect(overview.sparks.first?.memoryPressurePresentation.label == "Very low")
    #expect(overview.memoryPressurePresentation.label == "Very low")
    #expect(overview.memoryPressurePresentation.tone == .positive)
}

@Test func memoryPressureTracksHowFullMemoryIs() {
    let total: Int64 = 128_000_000_000
    #expect(
        FleetMemoryPressurePresentation.make(
            pressure: .emergency,
            used: 3_600_000_000,
            total: total
        ).label == "Very low"
    )
    #expect(
        FleetMemoryPressurePresentation.make(
            pressure: .normal,
            used: 120_000_000_000,
            total: total
        ).label == "Very high"
    )
}

/// Describe memory pressure without making ordinary utilization sound like an alarm.
@Test func memoryPressureIsWordedAsPressureNotAnEmergency() {
    #expect(SparkMemoryPressure.normal.word == "Normal")
    #expect(SparkMemoryPressure.warning.word == "Elevated")
    #expect(SparkMemoryPressure.critical.word == "High")
    #expect(SparkMemoryPressure.emergency.word == "Very high")
    #expect(SparkMemoryPressure.unknown.word == "Not reported")
    for pressure in [
        SparkMemoryPressure.normal, .warning, .critical, .emergency, .unknown,
    ] {
        #expect(!pressure.word.lowercased().contains("emergency"))
    }
}

/// Fleet and individual Spark pages must use the same capacity normalisation and memory units.
@Test func everySurfaceReportsTheSameInstalledCapacity() {
    let reportedByLinux: Int64 = 130_595_094_528  // 121.63 GiB on a 128 GB Spark
    let installed = SparkMemoryCapacity.installedBytes(reportedBytes: reportedByLinux)

    #expect(FleetFormat.gigabytes(installed) == "128.0 GB")
    // A machine whose reported size matches no known Spark is left alone.
    #expect(SparkMemoryCapacity.installedBytes(reportedBytes: 999) == 999)
    #expect(SparkMemoryCapacity.installedBytes(reportedBytes: 0) == 0)
}

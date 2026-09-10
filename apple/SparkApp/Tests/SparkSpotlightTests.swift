import Foundation
import SparkCore
import SparkIntents
import SparkLibrary
import Testing
@testable import SparkAppComposition

private actor RecordingSpotlightIndexer: SparkSpotlightIndexing {
    private var replacements: [[SparkSpotlightIndexer.Record]] = []
    private var removalCount = 0

    func replace(_ records: [SparkSpotlightIndexer.Record]) async throws {
        replacements.append(records)
    }

    func removeAll() async throws {
        removalCount += 1
    }

    func donatedRecords() -> [[SparkSpotlightIndexer.Record]] { replacements }
    func removals() -> Int { removalCount }
}

@MainActor
@Test func spotlightStaysOffUntilTheOwnerOptsIn() async {
    let indexer = RecordingSpotlightIndexer()
    let defaults = spotlightDefaults()
    let model = SparkSpotlightModel(indexer: indexer, defaults: defaults)

    await model.observe(entries: [spotlightEntry()], modelSnapshot: .empty)

    #expect(!model.isEnabled)
    #expect(await indexer.donatedRecords().isEmpty)
    #expect(await indexer.removals() == 0)
}

@MainActor
@Test func spotlightDonatesOnlyOwnerLabelsAndVerifiedModelNames() async {
    let indexer = RecordingSpotlightIndexer()
    let model = SparkSpotlightModel(
        indexer: indexer,
        defaults: spotlightDefaults()
    )
    let snapshot = CrossTargetModelLibrarySnapshot(
        generatedAt: Date(),
        targets: [],
        models: [
            spotlightModel(name: "Reasoning 32B", verification: .verified),
            spotlightModel(name: "Untrusted recipe", verification: .unverified),
        ]
    )

    await model.observe(
        entries: [
            spotlightEntry(),
            spotlightEntry(id: 2, customLabel: nil, hostname: "spark-other.local"),
            spotlightEntry(
                id: 3,
                customLabel: "Compromised Spark",
                issue: .identityMismatch
            ),
        ],
        modelSnapshot: snapshot
    )
    await model.setEnabled(true)

    let records = await indexer.donatedRecords().last ?? []
    #expect(Set(records.map(\.title)) == ["Studio Spark", "DGX Spark", "Reasoning 32B"])
    #expect(records.allSatisfy { $0.description == nil && $0.keywords.isEmpty })
    let donatedText = records.map {
        [$0.id, $0.title, $0.description ?? ""].joined(separator: " ")
    }
    .joined(separator: " ")
    #expect(!donatedText.contains("spark-secret.local"))
    #expect(!donatedText.contains("spark-other.local"))
    #expect(!donatedText.contains("Compromised Spark"))
    #expect(!donatedText.contains("192.168.100.63"))
    #expect(!donatedText.contains("diagnostic-secret"))
    #expect(!donatedText.contains("authority-secret"))
}

@MainActor
@Test func deletingLocalMetadataReplacesTheDonationAndOptOutRemovesEverything() async {
    let indexer = RecordingSpotlightIndexer()
    let defaults = spotlightDefaults()
    let model = SparkSpotlightModel(indexer: indexer, defaults: defaults)

    await model.observe(entries: [spotlightEntry()], modelSnapshot: .empty)
    await model.setEnabled(true)
    await model.observe(entries: [], modelSnapshot: .empty)
    await model.setEnabled(false)

    let replacements = await indexer.donatedRecords()
    #expect(replacements.map(\.count) == [1, 0])
    #expect(await indexer.removals() == 1)
    #expect(defaults.bool(forKey: "sparkpilot.spotlight.enabled") == false)
}

private func spotlightDefaults() -> UserDefaults {
    let name = "SparkSpotlightTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func spotlightEntry(
    id: Int = 1,
    customLabel: String? = "Studio Spark",
    issue: LibraryEntryIssue? = nil,
    hostname: String = "spark-secret.local"
) -> LibraryEntry {
    let nodeID = SparkNodeID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
    )
    return LibraryEntry(
        logicalKey: .node(nodeID),
        name: hostname,
        customLabel: customLabel,
        members: [
            LibraryMember(
                nodeID: nodeID,
                name: hostname,
                role: .standalone,
                authorityFingerprint: "authority-secret",
                hostname: hostname,
                routes: [
                    CachedRoute(
                        baseURL: URL(string: "https://192.168.100.63:7443")!,
                        kind: .localWiFi
                    )
                ]
            )
        ],
        issue: issue
    )
}

private func spotlightModel(
    name: String,
    verification: ModelLibraryRecipeVerification
) -> CrossTargetModelLibraryItem {
    CrossTargetModelLibraryItem(
        id: name.lowercased().replacingOccurrences(of: " ", with: "-"),
        displayName: name,
        summary: "diagnostic-secret",
        versionLabel: "v1",
        taskLabel: "Text generation",
        capabilityLabels: [],
        downloadBytes: nil,
        verification: verification,
        topologyLabel: "Single Spark",
        coverage: ModelLibraryCoverage(runningTargets: [], installedTargets: []),
        placements: [],
        recommendation: nil,
        technicalDetails: ModelLibraryTechnicalDetails(
            modelID: "private/model",
            recipeRevision: "recipe-secret",
            sourceRevision: "source-secret"
        ),
        profiles: []
    )
}

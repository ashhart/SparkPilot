import Foundation
import SparkCore
import Testing

@testable import SparkAppComposition

/// UX-12: the chat target menu reads per Spark, each model carrying its state.
struct SparkChatTargetMenuTests {
    private func target(spark: String, name: String, model: String) -> SparkChatTarget {
        SparkChatTarget(
            id: spark,
            displayName: name,
            nodeID: SparkNodeID(rawValue: UUID()),
            route: URL(string: "https://\(spark).example:8443")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: model,
            modelName: model.uppercased()
        )
    }

    @Test func groupsModelsBySparkWithStateGlyphs() {
        let runningA = target(spark: "a", name: "Studio", model: "qwen")
        let installedA = target(spark: "a", name: "Studio", model: "llama")
        let runningB = target(spark: "b", name: "Lab", model: "mistral")
        let catalogue = SparkChatTargetCatalogue(
            targets: [runningA, runningB],
            pairedTargetCount: 3,
            unavailableTargets: [
                SparkChatUnavailableTarget(name: "Attic", reason: .offline, id: "c")
            ],
            installedTargets: [installedA]
        )
        let groups = SparkChatTargetMenu.groups(
            choices: catalogue.modelChoices,
            catalogue: catalogue,
            selectedID: runningA.selectionID
        )
        #expect(groups.map(\.displayName) == ["Studio", "Lab"])
        #expect(groups[0].items.map(\.state) == [.selected, .installed])
        #expect(groups[1].items.map(\.state) == [.running])
        #expect(groups[0].items[1].symbol == "arrow.down.circle")
        let unavailable = SparkChatTargetMenu.unavailable(catalogue)
        #expect(unavailable.count == 1)
        #expect(unavailable[0].title.contains("Attic"))
        #expect(unavailable[0].title.contains("Offline"))
        #expect(unavailable[0].symbol == "wifi.slash")
    }

    /// UX-02: every empty state names the tap that gets the owner out of it.
    @Test func everyEmptyStateEndsInAnAction() {
        let states: [SparkChatEmptyState] = [
            .emptyFleet, .noActiveModel, .modelLoading, .checkingStatus, .offline,
            .identityMismatch, .authenticationUnavailable,
        ]
        for state in states {
            #expect(!state.actionTitle.isEmpty)
        }
        #expect(SparkChatEmptyState.noActiveModel.action == .loadModel)
        #expect(SparkChatEmptyState.offline.action == .checkAgain)
        #expect(SparkChatEmptyState.identityMismatch.action == .reviewSparks)
        #expect(SparkChatEmptyState.authenticationUnavailable.action == .pairAgain)
    }
}

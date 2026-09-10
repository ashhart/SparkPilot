import AppIntents
import CoreSpotlight
import Foundation
import Testing
@testable import SparkIntents

/// The services seam is process-global; serialize the suite.
@Suite(.serialized)
struct SparkIntentTests {
    @Test func textActionsReturnSpokenDialogAlongsideShortcutValues() async throws {
        IntentServices.install(FakeServices())
        defer { IntentServices.install(IntentServices.unavailable) }
        func hasDialog<R: ProvidesDialog & ReturnsValue<String>>(_ result: R, value: String) {
            #expect(result.value == value)
        }
        hasDialog(
            try await AskSparkIntent(question: "A question").perform(),
            value: "Because the cable is green."
        )
        hasDialog(
            try await SummarizeWithSparkIntent(text: "Some text").perform(),
            value: "transformed"
        )
        hasDialog(
            try await RewriteWithSparkIntent(text: "Some text").perform(),
            value: "transformed"
        )
        hasDialog(
            try await DraftReplyWithSparkIntent(text: "Some text").perform(),
            value: "transformed"
        )
        hasDialog(
            try await DraftEmailWithSparkIntent(text: "Email brief").perform(),
            value: "transformed"
        )
        #expect(DraftEmailWithSparkIntent.authenticationPolicy == .requiresAuthentication)
    }

    private final class ShortcutRefreshCounter: @unchecked Sendable {
        var count = 0

        func refresh() {
            count += 1
        }
    }

    private final class FakeServices: IntentServicing, @unchecked Sendable {
        var statusSnapshot: SparkStatusSnapshot?
        var answer = "Because the cable is green."
        var askCaptured: [String] = []
        var targetCaptured: String?
        var transformKind: TextTransformKind?
        var loadCalled: String?
        var unloadCalled = false
        var nodes: [IntentNodeSnapshot] = []
        var models: [IntentModelSnapshot] = []
        var failure: SparkIntentError?

        func reset() {
            askCaptured = []
            targetCaptured = nil
            transformKind = nil
            loadCalled = nil
            unloadCalled = false
            failure = nil
        }

        func status(targetID: String?) async throws -> SparkStatusSnapshot {
            if let failure { throw failure }
            targetCaptured = targetID
            return statusSnapshot
                ?? SparkStatusSnapshot(
                    nodeName: "Alex's Spark",
                    reachability: .readyLocalNetwork,
                    loadedModelName: "Reasoning 32B",
                    memoryUsedPercent: 82,
                    waitingJobs: 0
                )
        }

        func ask(_ question: String, targetID: String?) async throws -> String {
            if let failure { throw failure }
            askCaptured.append(question)
            targetCaptured = targetID
            return answer
        }

        func transform(_ text: String, kind: TextTransformKind, targetID: String?) async throws
            -> String
        {
            if let failure { throw failure }
            transformKind = kind
            targetCaptured = targetID
            return "transformed"
        }

        func loadModel(_ modelID: String, targetID: String) async throws -> String {
            if let failure { throw failure }
            loadCalled = modelID
            targetCaptured = targetID
            return "op-1"
        }

        func unloadActiveModel(targetID: String?) async throws -> String {
            if let failure { throw failure }
            unloadCalled = true
            targetCaptured = targetID
            return "op-2"
        }

        func analyseFile(
            _ input: SparkFileAnalysisInput,
            instruction: String,
            targetID: String?
        ) async throws -> SparkAnalysisHandoff {
            // Keep this fake conformant while AnalysisIntentTests exercises analysis behavior.
            throw SparkIntentError.noPairedSpark
        }

        func analysisResult(
            jobID: String,
            targetID: String?
        ) async throws -> SparkAnalysisHandoff {
            throw SparkIntentError.noPairedSpark
        }

        func knownTargets() async throws -> [IntentTargetSnapshot] { nodes }

        func knownModels() async throws -> [IntentModelSnapshot] { models }
    }

    /// §40.4: the status sentence matches the spec example shape.
    @Test func statusSummaryMatchesTheSpecSentence() {
        let snapshot = SparkStatusSnapshot(
            nodeName: "Alex's Spark",
            reachability: .readyLocalNetwork,
            loadedModelName: "Reasoning 32B",
            memoryUsedPercent: 82,
            waitingJobs: 0
        )
        #expect(
            snapshot.spokenSummary
                == "Alex's Spark is ready over local Wi-Fi. Reasoning 32B is loaded, unified memory is 82 percent used, and no jobs are waiting."
        )

        let idle = SparkStatusSnapshot(
            nodeName: "Studio",
            reachability: .unreachable,
            loadedModelName: nil,
            memoryUsedPercent: 10,
            waitingJobs: 3
        )
        #expect(idle.spokenSummary.contains("not reachable"))
        #expect(idle.spokenSummary.contains("No model is loaded"))
        #expect(idle.spokenSummary.contains("3 jobs are waiting"))
    }

    @Test func installingServicesAndReconciliationCanRefreshShortcutParameters() {
        let counter = ShortcutRefreshCounter()
        IntentServices.install(
            FakeServices(),
            refreshShortcutParameters: counter.refresh
        )
        defer { IntentServices.install(IntentServices.unavailable) }

        #expect(counter.count == 1)
        IntentServices.refreshShortcutParameters()
        #expect(counter.count == 2)
    }

    /// §40.3: the ask intent routes through the services seam.
    @Test func askIntentRoutesQuestionAndTarget() async throws {
        let services = FakeServices()
        services.nodes = [IntentNodeSnapshot(id: "node-1", displayName: "Studio Spark")]
        IntentServices.install(services)
        defer { IntentServices.install(IntentServices.unavailable) }

        let intent = AskSparkIntent(
            question: "Why is the sky blue?",
            target: SparkNodeEntity(id: "node-1", displayName: "Studio Spark")
        )
        let result = try await intent.perform()
        _ = result
        #expect(services.askCaptured == ["Why is the sky blue?"])
        #expect(services.targetCaptured == "node-1")

        // The perform above ran on the installed copy; assert via the entity query.
        let query = SparkNodeQuery()
        let resolved = try await query.entities(for: ["node-1"])
        #expect(resolved.map(\.displayName) == ["Studio Spark"])
    }

    /// §40.9: no paired Spark surfaces actionable copy, not a crash.
    @Test func unavailableServicesFailWithPairingCopy() async {
        IntentServices.install(IntentServices.unavailable)
        defer { IntentServices.install(IntentServices.unavailable) }

        let intent = AskSparkIntent(question: "hello")
        await #expect(throws: SparkIntentError.self) {
            _ = try await intent.perform()
        }
        #expect(
            SparkIntentError.noPairedSpark.displayMessage
                == "No Spark is paired yet. Open the app to set one up."
        )
        #expect(
            SparkIntentError.modelNotReady(modelID: "llama").displayMessage.contains("loading")
        )
        #expect(
            SparkIntentError.deviceRevoked.displayMessage.contains("revoked")
        )
    }

    @Test func draftReplyReturnsTextWithoutCallingModelOperations() async throws {
        let services = FakeServices()
        IntentServices.install(services)
        defer { IntentServices.install(IntentServices.unavailable) }
        let result = try await DraftReplyWithSparkIntent(text: "Can we meet tomorrow?").perform()
        #expect(result.value == "transformed")
        #expect(services.transformKind == .draftReply)
        #expect(services.loadCalled == nil)
        #expect(!services.unloadCalled)
    }

    /// Load refuses uninstalled models with actionable copy (§40.9).
    @Test func loadIntentRejectsUninstalledModels() async {
        let services = FakeServices()
        services.models = [
            IntentModelSnapshot(
                id: "node-1:m1",
                modelID: "m1",
                targetID: "node-1",
                displayName: "Reasoning 32B",
                installed: true
            ),
            IntentModelSnapshot(
                id: "node-1:m2",
                modelID: "m2",
                targetID: "node-1",
                displayName: "Huge 405B",
                installed: false
            ),
        ]
        IntentServices.install(services)
        defer { IntentServices.install(IntentServices.unavailable) }

        await #expect(throws: SparkIntentError.self) {
            _ = try await LoadSparkModelIntent(
                model: SparkModelEntity(
                    id: "node-1:m2",
                    modelID: "m2",
                    targetID: "node-1",
                    displayName: "Huge 405B",
                    installed: false
                )
            ).perform()
        }
    }

    /// §40.6: entity queries resolve identifiers against known snapshots.
    @Test func modelQueryResolvesKnownModels() async throws {
        let services = FakeServices()
        services.models = [
            IntentModelSnapshot(
                id: "node-1:m1",
                modelID: "m1",
                targetID: "node-1",
                displayName: "Reasoning 32B",
                installed: true
            ),
            IntentModelSnapshot(
                id: "node-1:m2",
                modelID: "m2",
                targetID: "node-1",
                displayName: "Huge 405B",
                installed: false
            ),
        ]
        IntentServices.install(services)
        defer { IntentServices.install(IntentServices.unavailable) }

        let query = SparkModelQuery()
        let resolved = try await query.entities(for: ["node-1:m2", "missing"])
        #expect(resolved.count == 1)
        #expect(resolved[0].displayName == "Huge 405B")
        #expect(resolved[0].modelID == "m2")
        #expect(resolved[0].targetID == "node-1")

        let suggested = try await query.suggestedEntities()
        #expect(suggested.count == 2)
    }

    @Test func targetQueryKeepsClusterIdentityAndPermissions() async throws {
        let services = FakeServices()
        services.nodes = [
            IntentTargetSnapshot(
                id: "cluster:lab",
                displayName: "Lab Cluster",
                kind: .cluster,
                allowedActions: [.readStatus, .runInference]
            )
        ]
        IntentServices.install(services)
        defer { IntentServices.install(IntentServices.unavailable) }

        let resolved = try await SparkTargetQuery().entities(for: ["cluster:lab"])

        #expect(resolved.count == 1)
        #expect(resolved[0].kind == .cluster)
        #expect(resolved[0].allowedActions == [.readStatus, .runInference])
    }

    /// Enforce title-only conversation indexing through factories that cannot accept prompt bodies (§40.8).
    @Test func spotlightIndexesMetadataOnly() {
        let indexer = SparkSpotlightIndexer()

        let conversation = SparkSpotlightIndexer.conversationRecord(
            id: "c1",
            title: "Kitchen renovation plan"
        )
        #expect(conversation?.title == "Kitchen renovation plan")
        #expect(conversation?.description == nil, "there is no parameter that could carry one")

        // Untitled conversations are skipped entirely.
        #expect(SparkSpotlightIndexer.conversationRecord(id: "c2", title: nil) == nil)

        let item = indexer.searchableItem(
            for: SparkSpotlightIndexer.modelRecord(id: "llama-8b", name: "Reasoning 32B")
        )
        #expect(item.uniqueIdentifier == "app.spark.spark-fabric/model/llama-8b")
        #expect(item.domainIdentifier == "app.spark.spark-fabric")
        #expect(item.attributeSet.title == "Reasoning 32B")

        // Every domain type has a distinct identifier prefix.
        let records: [SparkSpotlightIndexer.Record] = [
            SparkSpotlightIndexer.nodeRecord(id: "x", name: "T"),
            SparkSpotlightIndexer.clusterRecord(id: "x", name: "T"),
            SparkSpotlightIndexer.modelRecord(id: "x", name: "T"),
            SparkSpotlightIndexer.projectRecord(id: "x", name: "T"),
            SparkSpotlightIndexer.artefactRecord(id: "x", title: "T"),
        ]
        for record in records {
            #expect(
                indexer.searchableItem(for: record).uniqueIdentifier.contains(
                    record.domain.rawValue
                )
            )
        }
        let conversationRecord = SparkSpotlightIndexer.conversationRecord(id: "x", title: "T")
        #expect(conversationRecord?.domain == .conversation)
    }

}

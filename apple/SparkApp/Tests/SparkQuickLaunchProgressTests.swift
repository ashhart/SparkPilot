import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

/// The launch sheet shows runtime progress and keeps the ready-to-chat action visible.
@MainActor
struct SparkQuickLaunchProgressTests {
    private final class ReportingLauncher: SparkModelLaunching {
        let target: SparkChatTarget
        var appliedPlans: [SparkModelLaunchPlan] = []
        var staleSavedPreset: String?
        init(target: SparkChatTarget) { self.target = target }

        func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
            [try SparkQuickLaunchProgressTests.profile()]
        }

        func staleSavedProfile(for target: SparkChatTarget, profiles: [SparkModelProfile])
            -> String?
        {
            staleSavedPreset
        }

        func prepare(target: SparkChatTarget, profileID: String?) async throws
            -> SparkModelLaunchPlan
        {
            SparkModelLaunchPlan(target: target)
        }

        func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget { target }

        func apply(
            _ plan: SparkModelLaunchPlan,
            progress: @escaping @MainActor (SparkModelLaunchProgress) -> Void
        ) async throws -> SparkChatTarget {
            appliedPlans.append(plan)
            await progress(SparkModelLaunchProgress(stage: "Pulling the image", fraction: 0.2))
            await progress(SparkModelLaunchProgress(stage: "Loading weights", fraction: 0.7))
            return target
        }

        func discard(_ plan: SparkModelLaunchPlan) {}
    }

    private static func profile() throws -> SparkModelProfile {
        let json = #"""
            {"id":"agent-64k","display_name":"Agent 64K","max_model_length":65536,"max_sequences":4,
             "expected_peak_bytes":1,"measured_peak_bytes":null,"safe":true,"idle_policy":null,
             "supported_idle_policies":null}
            """#
        return try JSONDecoder().decode(SparkModelProfile.self, from: Data(json.utf8))
    }

    private static func target(id: String = "spark-a", name: String = "Example Spark")
        -> SparkChatTarget
    {
        SparkChatTarget(
            id: id,
            displayName: name,
            nodeID: SparkNodeID(rawValue: UUID()),
            route: URL(string: "https://spark.local:7443")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: "nvidia/nemotron",
            modelName: "Nemotron"
        )
    }

    @Test func theSheetCarriesTheSparksStageAndPercent() async {
        let target = Self.target()
        let model = SparkQuickLaunchModel(launcher: ReportingLauncher(target: target)) { [target] }
        await model.refresh()
        #expect(model.statusLine == "Preparing the model…")
        await model.prepare()
        #expect(model.ready)
        #expect(!model.isLoading)
        #expect(model.progress?.line == "Loading weights · 70%")
        #expect(model.errorMessage == nil)
    }
    @Test func launchPreservesTappedSparkDespiteCatalogueOrderAndStartsOnlyOnce() async {
        let other = Self.target(id: "spark-a", name: "Alpha")
        let tapped = Self.target(id: "spark-z", name: "Zulu")
        let launcher = ReportingLauncher(target: tapped)
        let model = SparkQuickLaunchModel(
            launcher: launcher,
            targetID: tapped.id,
            launchOnOpen: true
        ) { [other, tapped] }
        await model.start()
        await model.start()
        await model.refresh()
        #expect(model.choices == [tapped])
        #expect(model.selectedTarget == tapped)
        #expect(launcher.appliedPlans.count == 1)
        #expect(launcher.appliedPlans.first?.target == tapped)
        #expect(model.readyTarget == tapped)
    }

    @Test func absentTappedSparkNeverFallsBackToAnotherSpark() async {
        let other = Self.target()
        let launcher = ReportingLauncher(target: other)
        let model = SparkQuickLaunchModel(
            launcher: launcher,
            targetID: "missing",
            launchOnOpen: true
        ) { [other] }
        await model.start()
        #expect(model.selectedTarget == nil)
        #expect(!model.ready)
        #expect(model.errorMessage != nil)
        #expect(launcher.appliedPlans.isEmpty)
    }

    /// ADR-043: a remembered preset the recipe dropped is named on the sheet; the default stands in for it.
    @Test func aDroppedSavedPresetIsExplainedAndTheDefaultIsSelected() async {
        let target = Self.target()
        let launcher = ReportingLauncher(target: target)
        launcher.staleSavedPreset = "long-256k"
        let model = SparkQuickLaunchModel(launcher: launcher) { [target] }
        await model.refresh()
        #expect(model.selectedProfileID == "agent-64k")
        #expect(model.defaultProfileID == "agent-64k")
        #expect(model.presetNote?.contains("long-256k") == true)
        #expect(model.errorMessage == nil)
        launcher.staleSavedPreset = nil
        await model.select(target.selectionID)
        #expect(model.presetNote == nil)
    }

    @Test func configureDoesNotLaunchUntilTheOwnerAsks() async {
        let target = Self.target()
        let launcher = ReportingLauncher(target: target)
        let model = SparkQuickLaunchModel(launcher: launcher, targetID: target.id) { [target] }
        await model.start()
        #expect(launcher.appliedPlans.isEmpty)
        #expect(model.selectedProfileID == "agent-64k")
        await model.prepare()
        #expect(launcher.appliedPlans.count == 1)
    }

}

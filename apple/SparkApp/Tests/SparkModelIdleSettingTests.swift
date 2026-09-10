import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

@Suite @MainActor
struct SparkModelIdleSettingTests {
    static func profile(
        id: String = "agent",
        custom: Bool = true,
        seconds: Int? = nil,
        policy: String = "unload_after_30m"
    ) throws -> SparkModelProfile {
        var value: [String: Any] = [
            "id": id, "display_name": "Agent", "max_model_length": 65536,
            "max_sequences": 4, "expected_peak_bytes": 1, "safe": true, "idle_policy": policy,
            "supported_idle_policies": [
                "keep_ready", "unload_after_15m", "unload_after_30m", "unload_after_60m",
                "manual_only",
            ],
            "supports_custom_idle_timeout": custom,
        ]
        if let seconds { value["idle_timeout_seconds"] = seconds }
        return try JSONDecoder().decode(
            SparkModelProfile.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    }

    private final class Launcher: SparkModelLaunching {
        var saved: [(String, String, SparkModelIdleSetting)] = []
        var calls: [String] = []
        var fails = false
        func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
            [
                try SparkModelIdleSettingTests.profile(),
                try SparkModelIdleSettingTests.profile(id: "chat"),
            ]
        }
        func prepare(target: SparkChatTarget, profileID: String?) async throws
            -> SparkModelLaunchPlan
        {
            calls.append("prepare")
            return SparkModelLaunchPlan(target: target)
        }
        func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
            calls.append("load")
            return plan.target
        }
        func saveIdleSetting(
            _ setting: SparkModelIdleSetting,
            for target: SparkChatTarget,
            profile: SparkModelProfile
        ) async throws {
            calls.append("save")
            if fails { throw SparkModelLaunchError(message: "Refused") }
            saved.append((target.id, profile.id, setting))
        }
    }
    private func target(_ id: String = "desk") -> SparkChatTarget {
        .init(
            id: id,
            displayName: "Desk Spark",
            nodeID: .init(rawValue: UUID()),
            route: URL(string: "https://spark.example")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: "nemotron",
            modelName: "Nemotron"
        )
    }

    @Test func defaultsAndSavedServerValuesAreReadCorrectly() throws {
        #expect(SparkModelIdleSetting(profile: try Self.profile()).minutes == 30)
        #expect(SparkModelIdleSetting(profile: try Self.profile(seconds: 2520)).minutes == 42)
        #expect(
            SparkModelIdleSetting(profile: try Self.profile(policy: "keep_ready")).minutes == nil
        )
        let request = try SparkModelIdleSetting(minutes: 42).request(
            modelID: "nemotron",
            profile: Self.profile()
        )
        #expect(request.idleTimeoutSeconds == 2520)
        #expect(request.idlePolicy == .unloadAfter30M)
        let never = try SparkModelIdleSetting(minutes: nil).request(
            modelID: "nemotron",
            profile: Self.profile()
        )
        #expect(never.idlePolicy == .keepReady)
        #expect(never.idleTimeoutSeconds == nil)
    }

    @Test func customTimesAreBoundedAndOlderRuntimesKeepTheirSupportedChoices() throws {
        for minutes in [0, -1, 10081] {
            #expect(throws: (any Error).self) {
                try SparkModelIdleSetting(minutes: minutes).request(
                    modelID: "nemotron",
                    profile: Self.profile()
                )
            }
        }
        #expect(throws: (any Error).self) {
            try SparkModelIdleSetting(minutes: 42).request(
                modelID: "nemotron",
                profile: Self.profile(custom: false)
            )
        }
        #expect(
            try SparkModelIdleSetting(minutes: nil).request(
                modelID: "nemotron",
                profile: Self.profile(custom: false)
            ).idlePolicy == .keepReady
        )
        #expect(
            try SparkModelIdleSetting(minutes: 10080).request(
                modelID: "nemotron",
                profile: Self.profile()
            ).idleTimeoutSeconds == 604800
        )
    }

    @Test func launchSavesChangedTimerOnTheSelectedSparkBeforeLoading() async {
        let launcher = Launcher()
        let selected = target()
        let model = SparkQuickLaunchModel(launcher: launcher) { [selected] }
        await model.start()
        launcher.calls = []
        model.idleSetting.minutes = 42
        await model.prepare()
        #expect(launcher.calls == ["save", "prepare", "load"])
        #expect(launcher.saved.first?.0 == selected.id)
        #expect(launcher.saved.first?.1 == "agent")
        #expect(launcher.saved.first?.2.minutes == 42)
        #expect(!model.idleSettingChanged)
        #expect(model.ready)
    }

    @Test func unchangedPresetLaunchDoesNotPromptToSaveAgain() async {
        let launcher = Launcher()
        let selected = target()
        let model = SparkQuickLaunchModel(launcher: launcher) { [selected] }
        await model.start()
        await model.prepare()
        #expect(launcher.saved.isEmpty)
        #expect(model.ready)
    }

    @Test func savedTimerSurvivesProfileSwitchAndDoesNotLeakToAnotherSpark() async {
        let launcher = Launcher()
        let first = target("first")
        let second = target("second")
        let model = SparkQuickLaunchModel(launcher: launcher) { [first, second] }
        await model.start()
        model.selectedProfileID = "agent"
        model.idleSetting.minutes = 42
        await model.saveIdleSetting()
        model.selectedProfileID = "chat"
        #expect(model.idleSetting.minutes == 30)
        model.selectedProfileID = "agent"
        #expect(model.idleSetting.minutes == 42)
        #expect(!model.idleSettingChanged)
        await model.select(second.selectionID)
        #expect(model.idleSetting.minutes == 30)
        #expect(!model.idleSettingChanged)
        #expect(launcher.saved.count == 1)
    }

    @Test func refusedSaveKeepsTheChoiceAndDoesNotLaunch() async {
        let launcher = Launcher()
        launcher.fails = true
        let selected = target()
        let model = SparkQuickLaunchModel(launcher: launcher) { [selected] }
        await model.start()
        launcher.calls = []
        model.idleSetting.minutes = nil
        await model.prepare()
        #expect(launcher.calls == ["save"])
        #expect(model.idleSettingChanged)
        #expect(model.errorMessage == "Refused")
        #expect(!model.ready)
    }
}

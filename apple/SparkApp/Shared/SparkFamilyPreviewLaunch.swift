#if DEBUG
    import Foundation
    import SparkAPI
    import SparkCore
    import SparkLibrary
    import SwiftUI

    /// The shipping dashboard with the same invented Spark used by the fleet preview.
    @MainActor
    struct FamilyPreviewDashboard: View {
        private let library = FleetSampleFleet.library(["--spark-sample-fleet=running"])!
        @State private var dashboard = SparkDashboardModel(
            route: SampleSpark.serving.route,
            runtime: FamilyPreviewDashboardRuntime(),
            targetID: SparkTargetIdentity.node(SampleSpark.serving.nodeID).description
        )

        var body: some View {
            SparkDashboardView(model: dashboard, library: library)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("Preview · sample data").font(.caption).padding(8)
                        .frame(maxWidth: .infinity).background(.bar)
                }
        }
    }

    private struct FamilyPreviewDashboardRuntime: SparkRuntimeReading {
        func health(route: URL) async throws -> Health {
            Health(
                status: "ok",
                apiVersion: 1,
                runtimeVersion: SampleWire.runtimeVersion,
                nodeID: SampleSpark.serving.nodeID,
                authProtocols: [Health.signingProtocol]
            )
        }

        func status(route: URL) async throws -> SparkStatus {
            try decode(SampleWire.status(.serving))
        }

        func models(route: URL) async throws -> ModelCatalogue {
            try decode(SampleWire.catalogue(.serving))
        }

        func activeInference(route: URL) async throws -> ActiveInference {
            try decode(SampleWire.inference(.serving))
        }

        func capabilities(route: URL) async throws -> SparkCapabilities {
            SparkCapabilities(apiVersion: 1, features: ["container_runtime": true])
        }

        private func decode<Value: Decodable>(_ json: String) throws -> Value {
            try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        }
    }

    /// Drives the real launch sheet with invented progress, without touching a Spark.
    @MainActor
    final class FamilyPreviewModelLauncher: SparkModelLaunching {
        static let target = SparkChatTarget(
            id: "launch-preview",
            displayName: "Sample family Spark",
            nodeID: SparkNodeID(rawValue: UUID()),
            route: URL(string: "https://launch-preview.invalid")!,
            tlsFingerprint: "sample",
            authorityFingerprint: "sample",
            modelID: "sample-model",
            modelName: "Nemotron 3.5 Lightning 30B"
        )

        static func model() -> SparkQuickLaunchModel {
            SparkQuickLaunchModel(launcher: FamilyPreviewModelLauncher()) { [target] }
        }

        func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
            let data = Data(
                #"{"id":"agent-64k","display_name":"Agent 64K","max_model_length":65536,"max_sequences":4,"expected_peak_bytes":1,"safe":true,"idle_policy":"unload_after_30m","supported_idle_policies":["keep_ready","unload_after_15m","unload_after_30m","unload_after_60m"],"supports_custom_idle_timeout":true}"#
                    .utf8
            )
            return [try JSONDecoder().decode(SparkModelProfile.self, from: data)]
        }
        func saveIdleSetting(
            _ setting: SparkModelIdleSetting,
            for target: SparkChatTarget,
            profile: SparkModelProfile
        ) async throws {
            _ = try setting.request(modelID: target.modelID, profile: profile)
        }
        func prepare(target: SparkChatTarget, profileID: String?) async throws
            -> SparkModelLaunchPlan
        {
            SparkModelLaunchPlan(target: target)
        }
        func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
            try await apply(plan, progress: { _ in })
        }
        func apply(
            _ plan: SparkModelLaunchPlan,
            progress: @escaping @MainActor (SparkModelLaunchProgress) -> Void
        ) async throws -> SparkChatTarget {
            progress(
                .init(
                    stage: SparkDashboardOwnerPresentation.operationStageLabel(
                        "health_check",
                        action: .load
                    ),
                    fraction: 0.3,
                    detail: SparkDashboardOwnerPresentation.operationStageDetail("health_check")
                )
            )
            try await Task.sleep(for: .seconds(2))
            progress(
                .init(
                    stage: SparkDashboardOwnerPresentation.operationStageLabel(
                        "serving_probe",
                        action: .load
                    ),
                    fraction: 0.84,
                    detail: SparkDashboardOwnerPresentation.operationStageDetail("serving_probe")
                )
            )
            try await Task.sleep(for: .seconds(4))
            progress(.init(stage: String(localized: "Ready"), fraction: 1))
            return plan.target
        }
    }
#endif

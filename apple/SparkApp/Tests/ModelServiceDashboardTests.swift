import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

private let serviceEvidenceDate = Date(timeIntervalSince1970: 1_788_169_600)

private func serviceSettings() throws -> GeneratedAPI.SparkSettingsSnapshot {
    try JSONDecoder().decode(
        GeneratedAPI.SparkSettingsSnapshot.self,
        from: Data(
            """
            {
              "api_version":1,"observed_at":"2026-08-31T10:00:00Z",
              "direct_ethernet_enabled":false,
              "travel_access_point":{"enabled":false,"ssid":null,"security":"wpa3","auto_revert_seconds":60},
              "bluetooth":{"available":true,"powered":false,"discovering":false,"nearby_devices":[]},
              "power_profile":{"available":true,"current_mode_id":0,"current_name":"Balanced","modes":[],"reboot_required":false,"temperature_celsius":45,"power_draw_watts":30,"power_limit_watts":140},
              "software_updates":{"checked_at":"2026-08-31T10:00:00Z","system_packages_available":4,"firmware_updates_available":1,"runtime_release_id":"runtime-0.2.0","reboot_required":true},
              "memory_guard":{"warning_available_bytes":17179869184,"critical_available_bytes":10737418240,"emergency_available_bytes":6442450944},
              "model_idle_policies":[],
              "time":{"timezone":"Europe/London","ntp_enabled":true,"synchronized":true},
              "telemetry_consent":{"functional":false,"technical":false}
            }
            """.utf8
        )
    )
}

private func openWebUIUpdate() -> GeneratedAPI.OptionalServiceStatus {
    GeneratedAPI.OptionalServiceStatus(
        id: .openWebui,
        displayName: .openWebUI,
        state: .healthy,
        installed: true,
        running: true,
        healthy: true,
        installedImageDigest: "sha256:installed",
        availableRevision: "2026-08-31.2",
        availableVersion: "0.7.1",
        updateAvailable: true,
        accessPath: "/open-webui",
        accessPort: 7444,
        accessTls: true,
        inferenceGateway: .init(
            scopes: [.modelsRead, .chatCompletionsCreate],
            healthy: true,
            port: 18_081,
            loopbackOnly: true
        ),
        recovery: nil
    )
}

@Test func existingExternalVllmIsReportedWithoutClaimingOwnership() {
    let inventory = GeneratedAPI.WorkloadInventory(
        observedAt: "2026-08-31T10:00:00Z",
        available: true,
        adoptionSupported: false,
        truncated: false,
        workloads: [
            .init(
                workloadId: "external-vllm",
                name: "production-vllm",
                ownership: .externalObserved,
                kind: .inferenceEngine,
                recognisedEngine: .vllm,
                state: .running,
                imageReference: "vllm/vllm-openai@sha256:observed",
                publishedPorts: [],
                configurationState: .verified,
                apiProtocol: "openai",
                apiPort: 8_000,
                servedModels: ["deepseek-r1"]
            )
        ]
    )
    let snapshot = ModelServiceDashboardAdapter.snapshot(
        observedAt: serviceEvidenceDate,
        runtimeVersion: "0.1.0",
        runtimeHealthy: true,
        capabilities: SparkCapabilities(
            apiVersion: 1,
            features: ["container_runtime": true]
        ),
        workloads: inventory,
        openWebUI: nil,
        settings: nil,
        catalogueStatus: nil,
        catalogueRecipeCount: 1
    )

    #expect(snapshot.engines.count == 1)
    #expect(snapshot.engines.first?.name == "vLLM")
    #expect(snapshot.engines.first?.state == .running)
    #expect(snapshot.engines.first?.ownership == .external)
    #expect(snapshot.engines.first?.servedModels == ["deepseek-r1"])
}

@Test func serviceDashboardReportsOpenWebUIAndEveryUpdateKind() throws {
    let snapshot = ModelServiceDashboardAdapter.snapshot(
        observedAt: serviceEvidenceDate,
        runtimeVersion: "0.1.0",
        runtimeHealthy: true,
        capabilities: SparkCapabilities(
            apiVersion: 1,
            features: ["container_runtime": true]
        ),
        workloads: .init(
            observedAt: "2026-08-31T10:00:00Z",
            available: true,
            adoptionSupported: false,
            truncated: false,
            workloads: []
        ),
        openWebUI: openWebUIUpdate(),
        settings: try serviceSettings(),
        catalogueStatus: .init(
            source: .deviceLocalSignedSnapshot,
            refreshAvailable: true,
            recipeCount: 8,
            currentDigest: String(repeating: "a", count: 64),
            signatureKeyId: "catalogue-key",
            previousSnapshotAvailable: true,
            activeEngineUnaffected: true
        ),
        catalogueRecipeCount: 8
    )

    #expect(snapshot.engines.first?.state == .readyToInstall)
    #expect(snapshot.openWebUI?.state == .running)
    #expect(snapshot.openWebUI?.updateAvailable == true)
    #expect(snapshot.updates?.systemPackagesAvailable == 4)
    #expect(snapshot.updates?.firmwareUpdatesAvailable == 1)
    #expect(snapshot.updates?.runtimeReleaseID == "runtime-0.2.0")
    #expect(snapshot.updates?.totalKnownUpdates == 6)
    #expect(snapshot.updates?.rebootRequired == true)
    #expect(snapshot.catalogueRecipeCount == 8)
    #expect(snapshot.catalogueRefreshAvailable == true)
}

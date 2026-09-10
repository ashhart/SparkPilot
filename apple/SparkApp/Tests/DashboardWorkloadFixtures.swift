import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

// MARK: - Host workload inventory

@MainActor
func dashboardTestHostWorkloadInventory(
    available: Bool = true,
    truncated: Bool = false,
    workloads: [GeneratedAPI.ObservedWorkload] = []
) -> GeneratedAPI.WorkloadInventory {
    GeneratedAPI.WorkloadInventory(
        observedAt: "2026-08-30T09:00:00Z",
        available: available,
        unavailableReason: available ? nil : "the container runtime could not be inspected",
        adoptionSupported: false,
        truncated: truncated,
        workloads: workloads
    )
}

@MainActor
let dashboardTestExternalDeepSeek = GeneratedAPI.ObservedWorkload(
    workloadId: "1a3b",
    name: "deepseek-serve",
    ownership: .externalObserved,
    kind: .inferenceEngine,
    recognisedEngine: .sglang,
    state: .running,
    imageReference: "lmsysorg/sglang:v0.4.1",
    publishedPorts: [],
    configurationState: .unavailable,
    apiProtocol: nil,
    apiPort: nil,
    servedModels: []
)

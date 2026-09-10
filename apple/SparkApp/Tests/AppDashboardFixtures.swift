import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

// MARK: - Dashboard pressure mapping

func appShellTestDecode<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

extension SHA256 {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct FakeRuntime: SparkRuntimeReading {
    var statusJSON: String

    func health(route: URL) async throws -> Health {
        try appShellTestDecode(
            #"{"api_version":1,"node_id":"7a836150-16e1-46b5-8ac0-32b2a5f2f820","runtime_version":"0.1.0","status":"ok"}"#
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        try JSONDecoder().decode(SparkStatus.self, from: Data(statusJSON.utf8))
    }

    func models(route: URL) async throws -> ModelCatalogue {
        try appShellTestDecode(#"{"items":[],"next_cursor":null}"#)
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        try appShellTestDecode(
            #"{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}"#
        )
    }
}

let emergencyStatusJSON = """
    {
      "api_version": 1,
      "node": {"node_id": "7a836150-16e1-46b5-8ac0-32b2a5f2f820", "cluster_id": null,
               "name": "Alex's Spark", "role": "standalone",
               "authority_fingerprint": "t9lNEpIu94qMhG3XG2ThMg", "runtime_version": "0.1.0",
               "dgx_os_version": null},
      "cluster": null,
      "system": {"unified_memory_total_bytes": 137438953472,
                 "unified_memory_available_bytes": 5000000000,
                 "memory_pressure": "emergency", "cpu_utilisation": 0.4,
                 "disk_free_bytes": 91827364512, "uptime_seconds": 100,
                 "temperature_celsius": null, "power_state": "normal"},
      "inference": {"state": "unloaded", "model_id": null, "profile_id": null,
                    "active_requests": 0, "queue_depth": 0,
                    "tokens_per_second": null, "time_to_first_token_ms": null}
    }
    """

@MainActor
@Test func dashboardMapsPressureToTheEmergencyBanner() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: FakeRuntime(statusJSON: emergencyStatusJSON)
    )
    await model.refresh()

    #expect(model.memoryPressure == .emergency)
    let presentation = model.pressurePresentation
    #expect(presentation != nil, "emergency shows the banner")
    #expect(presentation?.actions == [.chooseSmallerModel, .getDiagnostics])
    #expect(model.pressureLabel == "Needs attention")
    #expect(model.memorySummary?.contains("of") == true)
}

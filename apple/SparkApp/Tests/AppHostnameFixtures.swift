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

actor FakeHostname: SparkHostnameControlling {
    private var operationStates: [SparkAPI.Operation.OperationState]
    private var calls: [(String, UUID)] = []

    init(operationStates: [SparkAPI.Operation.OperationState] = [.queued, .succeeded]) {
        self.operationStates = operationStates
    }

    func setSparkHostname(
        route: URL,
        hostname: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        calls.append((hostname, idempotencyKey))
        return try nextOperation()
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        try nextOperation()
    }

    private func nextOperation() throws -> SparkAPI.Operation {
        let state = operationStates.isEmpty ? .succeeded : operationStates.removeFirst()
        return try appShellTestDecode(
            "{\"id\":\"63e82da2-7fb7-4b4b-9584-4a528000ac94\","
                + "\"kind\":\"system.hostname\",\"state\":\"\(state.rawValue)\","
                + "\"cancellable\":false}"
        )
    }

    func recordedCalls() -> [(String, UUID)] { calls }
}

/// Share hostname fixtures across model and copy tests, including the missing-hostname state.
@MainActor
func makeIdentitySettings(
    runtime: (any SparkHostnameControlling)? = nil,
    canChangeHostname: Bool = true,
    presence: any UserPresenceAuthorizing = AppTestPresenceAuthorizer(),
    hostname: String? = "spark-example.local"
) -> (SparkIdentitySettingsModel, SparkLibrary, String, SparkNodeID) {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let nodeID = SparkNodeID(
        rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
    )
    let route = CachedRoute(
        baseURL: URL(string: "https://192.168.100.63:7443")!,
        kind: .localWiFi
    )
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "DGX Spark",
            role: .standalone,
            authorityFingerprint: "authority",
            displayName: "spark-example",
            routes: [route]
        )
    ).entry
    let model = SparkIdentitySettingsModel(
        route: route.baseURL,
        entryID: entry.id,
        nodeID: nodeID,
        displayName: entry.displayName,
        hostname: hostname,
        library: library,
        runtime: runtime,
        canChangeHostname: canChangeHostname,
        userPresenceAuthorizer: presence,
        operationDelay: { _ in }
    )
    return (model, library, entry.id, nodeID)
}

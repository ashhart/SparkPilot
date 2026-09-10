import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

struct ChatTestChatTargetFixtureDocument: Decodable, Sendable {
    struct Target: Decodable, Sendable {
        let id: String
        let displayName: String
        let nodeID: UUID
        let route: URL
        let tlsFingerprint: String
        let authorityFingerprint: String
        let modelID: String
        let modelName: String

        var value: SparkChatTarget {
            SparkChatTarget(
                id: id,
                displayName: displayName,
                nodeID: SparkNodeID(rawValue: nodeID),
                route: route,
                tlsFingerprint: tlsFingerprint,
                authorityFingerprint: authorityFingerprint,
                modelID: modelID,
                modelName: modelName
            )
        }
    }

    let targets: [Target]

    static func load() throws -> ChatTestChatTargetFixtureDocument {
        let url = try #require(
            Bundle.module.url(forResource: "chat-targets", withExtension: "json")
        )
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

func chatTestDecodeChatFixture<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

@MainActor
func chatTestFixtureLibrary(
    inferenceState: String = "ready",
    vision: Bool? = nil,
    modelID: String? = "open/compact-8b"
) throws -> (library: SparkLibrary, target: ChatTestChatTargetFixtureDocument.Target, now: Date) {
    let target = try #require(ChatTestChatTargetFixtureDocument.load().targets.first)
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore(), now: { now })
    library.reconcile(
        AuthenticatedTarget(
            nodeID: SparkNodeID(rawValue: target.nodeID),
            clusterID: nil,
            name: target.displayName,
            role: .standalone,
            authorityFingerprint: target.authorityFingerprint,
            displayName: "desk-spark",
            routes: [CachedRoute(baseURL: target.route, kind: .localWiFi)],
            reachedAt: now
        )
    )
    let encodedModelID = modelID.map { "\"\($0)\"" } ?? "null"
    let inference: ActiveInference = try chatTestDecodeChatFixture(
        """
        {"state":"\(inferenceState)","model_id":\(encodedModelID),"profile_id":null,
         "context_length":4096,"active_requests":0,"queue_depth":0,
         "tokens_per_second":null,"time_to_first_token_ms":null}
        """
    )
    let catalogue: ModelCatalogue = try chatTestDecodeChatFixture(
        """
        {"items":[{"id":"open/compact-8b","display_name":"Compact 8B",
        "description":null,"recipe_revision":"recipe-1","source_revision":"source-1",
        "install_state":"installed","total_bytes":1,"capabilities":{"chat":true\(vision.map { ",\"vision\":\($0)" } ?? "")},
        "fit":"safe","profiles":[]}],"next_cursor":null}
        """
    )
    let entryID = SparkTargetIdentity.node(SparkNodeID(rawValue: target.nodeID)).description
    _ = library.recordOperationalEvidence(
        TargetOperationalEvidence(
            identity: .node(SparkNodeID(rawValue: target.nodeID)),
            respondingNodeID: SparkNodeID(rawValue: target.nodeID),
            inventory: TimedOperationalEvidence(catalogue, observedAt: now),
            inference: TimedOperationalEvidence(inference, observedAt: now)
        ),
        for: entryID,
        at: now
    )
    return (library, target, now)
}

func chatTestTrust(for target: ChatTestChatTargetFixtureDocument.Target) -> NodeTrust {
    NodeTrust(
        nodeID: target.nodeID.uuidString.lowercased(),
        nodeName: target.displayName,
        tlsFingerprint: target.tlsFingerprint,
        authorityFingerprint: target.authorityFingerprint,
        authorityPublicKey: "fixture-public-key",
        pairedAt: Date(timeIntervalSince1970: 1_787_000_000)
    )
}

@MainActor
func chatTestFixtureCatalogue() throws -> SparkChatTargetCatalogue {
    let targets = try ChatTestChatTargetFixtureDocument.load().targets.map(\.value)
    return SparkChatTargetCatalogue(targets: targets, pairedTargetCount: targets.count)
}

/// The conversation a Spark receives, without the system note SparkPilot always puts first.
func chatTestPrompts(_ request: ChatCompletionRequest) -> [ChatMessage] {
    Array(request.messages.dropFirst())
}

@MainActor
func chatTestWaitUntil(
    _ condition: @MainActor () async -> Bool,
    attempts: Int = 2_000
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for chat state")
}

import Foundation
import SparkAPI
import SparkCore
import Testing
@testable import SparkAppComposition

@MainActor
private final class MemoryInferenceRuns: SparkInferenceRunStoring {
    var rows: [SparkInferenceRunRecord] = []
    var failing = false
    func read() throws -> [SparkInferenceRunRecord] {
        if failing { throw CocoaError(.fileReadCorruptFile) }
        return rows
    }
    func write(_ records: [SparkInferenceRunRecord]) throws {
        if failing { throw CocoaError(.fileWriteOutOfSpace) }
        rows = records
    }
}

private func runRecord(
    id: UUID = UUID(),
    started: Date = Date(),
    outcome: String = "succeeded",
    runtimeRecord: SparkInferenceRequestRecord? = nil
) -> SparkInferenceRunRecord {
    SparkInferenceRunRecord(
        id: id,
        harnessVersion: "sparkpilot-inference-smoke-v1",
        modelID: "example/model",
        profileID: "balanced",
        startedAt: started,
        finishedAt: outcome == "checking" ? nil : started.addingTimeInterval(1),
        outcome: outcome,
        firstOutputSeconds: 0.2,
        elapsedSeconds: 1,
        promptTokens: 12,
        completionTokens: 8,
        outputReceived: true,
        stateChanged: false,
        runtimeRecord: runtimeRecord
    )
}

@Suite @MainActor
struct SparkInferenceRunHistoryTests {
    @Test func terminalEvidenceCannotBeChangedAndClearKeepsLiveRuns() {
        let store = MemoryInferenceRuns()
        let history = SparkInferenceRunHistory(store: store)
        let id = UUID()
        history.save(runRecord(id: id, outcome: "checking"))
        history.save(runRecord(id: id))
        history.save(runRecord(id: id, outcome: "failed"))
        #expect(history.records.first?.outcome == "succeeded")
        history.save(runRecord(outcome: "checking"))
        history.clearFinished()
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == "checking")
        #expect(store.rows == history.records)
    }

    @Test func restartNeverCallsAnInterruptedRunSuccessfulOrReplaysIt() {
        let store = MemoryInferenceRuns()
        let now = Date()
        store.rows = [runRecord(started: now.addingTimeInterval(-1), outcome: "checking")]
        let history = SparkInferenceRunHistory(store: store, now: { now })
        #expect(history.records.first?.outcome == "interrupted_unknown")
        #expect(history.records.first?.promptTokens == nil)
        #expect(history.records.first?.elapsedSeconds == nil)
        #expect(store.rows == history.records)
    }

    @Test func retentionBoundsBothAgeAndCount() {
        let store = MemoryInferenceRuns()
        let now = Date()
        store.rows = [
            runRecord(started: now.addingTimeInterval(-SparkInferenceRunHistory.retention - 1))
        ]
        let history = SparkInferenceRunHistory(store: store, now: { now })
        #expect(history.records.isEmpty)
        for offset in 0..<205 {
            history.save(runRecord(started: now.addingTimeInterval(TimeInterval(offset))))
        }
        #expect(history.records.count == 200)
        #expect(history.records.last?.startedAt == now.addingTimeInterval(5))
    }

    @Test func failedReadDoesNotOverwriteOrClearTheOriginalArchive() {
        let store = MemoryInferenceRuns()
        store.rows = [runRecord()]
        let original = store.rows
        store.failing = true
        let history = SparkInferenceRunHistory(store: store)
        store.failing = false
        history.save(runRecord())
        history.clearFinished()
        #expect(history.errorMessage != nil)
        #expect(store.rows == original)
    }

    @Test func unavailableRuntimeHistoryDoesNotClaimServerTiming() throws {
        let export = runRecord(runtimeRecord: nil).export
        #expect(export.serverTimingSource == "not_reported")
        #expect(export.admissionMs == nil)
        #expect(export.firstFrameMs == nil)
        #expect(export.serverElapsedMs == nil)
    }

    @Test func exportHasNoConversationFieldsIdentitiesRoutesOrRegistryHosts() throws {
        let node = UUID(), caller = UUID(), attempt = UUID()
        let json: [String: Any] = [
            "attempt_id": attempt.uuidString, "request_id": UUID().uuidString,
            "caller_device_id": caller.uuidString, "node_id": node.uuidString,
            "model_id": "example/model", "profile_id": "balanced", "started_at": 1_800_000_000,
            "finished_at": 1_800_000_001, "outcome": "succeeded", "admission_ms": 1.0,
            "first_frame_ms": 2.0, "elapsed_ms": 500.0, "prompt_tokens": 12, "completion_tokens": 8,
            "provenance": [
                "recipe_digest": String(repeating: "a", count: 64),
                "recipe_revision": "2026-09-04.1",
                "source_revision": String(repeating: "b", count: 40),
                "engine_recipe": "vllm-private-host",
                "engine_image": "private.registry.internal/private/image@sha256:"
                    + String(repeating: "c", count: 64),
                "context_length": 8192, "max_sequences": 4, "runtime_version": "0.1.12",
                "verification": "admitted_recipe_only",
            ],
        ]
        let runtime = try JSONDecoder().decode(
            SparkInferenceRequestRecord.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let exported = try runRecord(runtimeRecord: runtime).export.encoded()
        for secret in [
            node.uuidString, caller.uuidString, attempt.uuidString, "private.registry",
            "private-host", "callerDeviceID", "nodeID", "startedAt", "messages", "reasoning",
            "answer",
        ] {
            #expect(!exported.contains(secret))
        }
        #expect(exported.contains(String(repeating: "c", count: 64)))
        #expect(exported.contains("diagnostic_only"))
        #expect(exported.contains("runtime_proxy_not_engine_queue_or_first_token"))
    }

    @Test func fileIntegrityCorruptionIsRefusedWithoutReplacingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSparkInferenceRunStore(url: directory.appendingPathComponent("runs.json"))
        let original = runRecord()
        try store.write([original])
        #expect(try store.read() == [original])
        var json = try String(contentsOf: store.url, encoding: .utf8)
        json = json.replacingOccurrences(of: "succeeded", with: "failed")
        try Data(json.utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.read() }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == json)
    }
}

import CryptoKit
import Foundation
import Observation
import SparkAPI

/// Store only fixed-workload metrics, excluding responses, thoughts, arbitrary errors, routes and credentials.
struct SparkInferenceRunRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let harnessVersion: String
    let modelID: String
    let profileID: String?
    let startedAt: Date
    let finishedAt: Date?
    let outcome: String
    let firstOutputSeconds: TimeInterval?
    let elapsedSeconds: TimeInterval?
    let promptTokens: Int?
    let completionTokens: Int?
    let outputReceived: Bool
    let stateChanged: Bool
    let runtimeRecord: SparkInferenceRequestRecord?

    var isTerminal: Bool { !["checking", "waiting", "receiving"].contains(outcome) }
    var canReproduce: Bool { harnessVersion == "sparkpilot-inference-smoke-v1" && isTerminal }

    func interrupted(at now: Date) -> Self {
        Self(
            id: id,
            harnessVersion: harnessVersion,
            modelID: modelID,
            profileID: profileID,
            startedAt: startedAt,
            finishedAt: now,
            outcome: "interrupted_unknown",
            firstOutputSeconds: nil,
            elapsedSeconds: nil,
            promptTokens: nil,
            completionTokens: nil,
            outputReceived: false,
            stateChanged: false,
            runtimeRecord: nil
        )
    }

    /// Uses a separate export schema so new local history fields cannot silently enter shared evidence.
    var export: SparkInferenceRunExport {
        SparkInferenceRunExport(
            harnessVersion: harnessVersion,
            modelID: modelID,
            profileID: profileID,
            outcome: outcome,
            firstOutputSeconds: firstOutputSeconds,
            elapsedSeconds: elapsedSeconds,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            outputReceived: outputReceived,
            stateChanged: stateChanged,
            admissionMs: runtimeRecord?.admissionMs,
            firstFrameMs: runtimeRecord?.firstFrameMs,
            serverElapsedMs: runtimeRecord?.elapsedMs,
            deployment: runtimeRecord?.provenance.map(SparkInferenceDeploymentExport.init),
            // The runtime always reports admission time with a record, so a record is the whole signal.
            serverTimingSource: runtimeRecord == nil
                ? "not_reported" : "runtime_proxy_not_engine_queue_or_first_token"
        )
    }
}

/// Registry addresses and arbitrary serving names stay out of shared evidence.
struct SparkInferenceDeploymentExport: Codable, Equatable {
    let recipeDigest: String?
    let recipeRevision: String
    let sourceRevision: String?
    let engineImageDigest: String?
    let runtimeVersion: String
    let contextLength: UInt64?
    let maxSequences: UInt32?
    var verification = "admitted_recipe_only_not_independent_attestation"
    init(_ value: SparkRequestDeploymentEvidence) {
        func hex(_ value: String, lengths: Set<Int>) -> String? {
            guard lengths.contains(value.count), value.allSatisfy({ $0.isHexDigit && $0.isASCII })
            else { return nil }
            return value.lowercased()
        }
        recipeDigest = hex(value.recipeDigest, lengths: [64])
        recipeRevision = value.recipeRevision
        sourceRevision = hex(value.sourceRevision, lengths: [40, 64])
        engineImageDigest = value.engineImage.components(separatedBy: "@sha256:").last.flatMap {
            hex($0, lengths: [64])
        }
        runtimeVersion = value.runtimeVersion
        contextLength = value.contextLength
        maxSequences = value.maxSequences
    }
}

struct SparkInferenceRunExport: Codable, Equatable {
    let harnessVersion: String
    let modelID: String
    let profileID: String?
    let outcome: String
    let firstOutputSeconds: TimeInterval?
    let elapsedSeconds: TimeInterval?
    let promptTokens: Int?
    let completionTokens: Int?
    let outputReceived: Bool
    let stateChanged: Bool
    let admissionMs: Double?
    let firstFrameMs: Double?
    let serverElapsedMs: Double?
    let deployment: SparkInferenceDeploymentExport?
    var workload = "one fixed synthetic completion; maximum 1024 output tokens; 60 second deadline"
    var qualification = "diagnostic_only_not_quality_context_concurrency_or_stability_qualification"
    var clientTimingSource = "client_monotonic_clock"
    let serverTimingSource: String

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

@MainActor
protocol SparkInferenceRunStoring {
    func read() throws -> [SparkInferenceRunRecord]
    func write(_ records: [SparkInferenceRunRecord]) throws
}

@MainActor
struct FileSparkInferenceRunStore: SparkInferenceRunStoring {
    let url: URL
    private struct Sealed: Codable {
        let record: SparkInferenceRunRecord
        let sha256: String
    }
    static func applicationStore() -> Self {
        Self(
            url: URL.applicationSupportDirectory.appendingPathComponent(
                "SparkInferenceRuns",
                isDirectory: true
            ).appendingPathComponent("runs.json")
        )
    }
    private func digest(_ record: SparkInferenceRunRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }
            .joined()
    }
    func read() throws -> [SparkInferenceRunRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 4 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sealed = try JSONDecoder().decode([Sealed].self, from: Data(contentsOf: url))
        guard sealed.count <= SparkInferenceRunHistory.maximumRecords,
            Set(sealed.map(\.record.id)).count == sealed.count
        else { throw CocoaError(.fileReadCorruptFile) }
        for item in sealed where try digest(item.record) != item.sha256 {
            throw CocoaError(.fileReadCorruptFile)
        }
        return sealed.map(\.record)
    }
    func write(_ records: [SparkInferenceRunRecord]) throws {
        let encoded = try JSONEncoder().encode(
            records.map { try Sealed(record: $0, sha256: digest($0)) }
        )
        guard records.count <= SparkInferenceRunHistory.maximumRecords,
            encoded.count <= 4 * 1024 * 1024
        else { throw CocoaError(.fileWriteOutOfSpace) }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
            try encoded.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor @Observable
final class SparkInferenceRunHistory {
    static let maximumRecords = 200
    static let retention: TimeInterval = 90 * 86_400
    private(set) var records: [SparkInferenceRunRecord] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let store: any SparkInferenceRunStoring
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var writable = true

    init(
        store: any SparkInferenceRunStoring = FileSparkInferenceRunStore.applicationStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        do {
            let loaded = try store.read()
            let recovered = loaded.map { $0.isTerminal ? $0 : $0.interrupted(at: now()) }
            records = retained(recovered)
            if records != loaded { try store.write(records) }
        } catch {
            writable = false
            errorMessage = String(
                localized: "Saved measurement history could not be read; it has been preserved."
            )
        }
    }

    func save(_ record: SparkInferenceRunRecord) {
        guard writable else { return }
        if let old = records.first(where: { $0.id == record.id }), old.isTerminal { return }
        let next = retained(records.filter { $0.id != record.id } + [record])
        do {
            try store.write(next)
            records = next
            errorMessage = nil
        } catch { errorMessage = String(localized: "The measurement could not be saved.") }
    }

    func clearFinished() {
        guard writable else { return }
        let next = records.filter { !$0.isTerminal }
        do {
            try store.write(next)
            records = next
            errorMessage = nil
        } catch { errorMessage = String(localized: "Measurement history could not be cleared.") }
    }

    private func retained(_ rows: [SparkInferenceRunRecord]) -> [SparkInferenceRunRecord] {
        Array(
            rows.filter {
                !$0.isTerminal || now().timeIntervalSince($0.startedAt) <= Self.retention
            }
            .sorted { $0.startedAt > $1.startedAt }.prefix(Self.maximumRecords)
        )
    }
}

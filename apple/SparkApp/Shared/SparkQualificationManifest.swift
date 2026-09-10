import CryptoKit
import Foundation
import SparkAPI

/// Restrict qualification manifests to versioned synthetic workloads without arbitrary prompts, options, images, endpoints or mutations.
enum SparkQualificationWorkload: String, Codable, CaseIterable, Sendable {
    case arithmetic, echo, latency1, latency2, latency3, context, concurrent1, concurrent2
    case stability1, stability2, stability3

    var outputLimit: Int {
        switch self {
        case .arithmetic, .echo: 32
        case .context, .stability1, .stability2, .stability3: 64
        default: 128
        }
    }
    var expectedAnswer: String? {
        switch self {
        case .arithmetic: "42"
        case .echo: "SPARK CHECK"
        default: nil
        }
    }
    var prompt: String {
        switch self {
        case .arithmetic: "What is 17 plus 25? Reply only with the integer."
        case .echo: "Reply exactly with these two words, with no punctuation: SPARK CHECK"
        case .context:
            "Read the following synthetic filler and then reply READY.\n"
                + String(repeating: " a", count: 2048) + "\nReply READY."
        case .concurrent1, .concurrent2:
            "Write a paragraph of at least 100 words explaining how rain forms, using plain language."
        default:
            "Explain why the sky looks blue in a short paragraph."
        }
    }
}

struct SparkQualificationPreset: Codable, Equatable, Sendable {
    let id: String
    let maximumRequests: Int
    let maximumGeneratedTokens: Int
    let requestedPromptTokens: Int
    let simultaneousClientRequests: Int
    let stabilitySpanSeconds: Double
    let maximumDurationSeconds: Double
    static let quick = Self(
        id: "sparkpilot-local-qualification-v1",
        maximumRequests: 11,
        maximumGeneratedTokens: 960,
        requestedPromptTokens: 2048,
        simultaneousClientRequests: 2,
        stabilitySpanSeconds: 30,
        maximumDurationSeconds: 240
    )
}

enum SparkQualificationCase: String, Codable, CaseIterable, Sendable {
    case correctness, context, latency, concurrency, memory, stability
    var title: String {
        switch self {
        case .correctness: String(localized: "Synthetic correctness")
        case .context: String(localized: "Measured context")
        case .latency: String(localized: "Client latency")
        case .concurrency: String(localized: "Observed concurrency")
        case .memory: String(localized: "Sampled memory headroom")
        case .stability: String(localized: "Short stability check")
        }
    }
}

enum SparkQualificationVerdict: String, Codable, Sendable {
    case pending, measured, failed, notDemonstrated, interrupted
    var title: String {
        switch self {
        case .pending: String(localized: "Not run")
        case .measured: String(localized: "Measured")
        case .failed: String(localized: "Failed")
        case .notDemonstrated: String(localized: "Not demonstrated")
        case .interrupted: String(localized: "Interrupted")
        }
    }
}

struct SparkQualificationIdentity: Codable, Equatable, Sendable {
    let modelID: String
    let profileID: String
    let recipeDigest: String
    let recipeRevision: String
    let sourceRevision: String
    let runtimeVersion: String
    let contextLimit: Int
    let sequenceLimit: Int
    let systemReserveBytes: Int64?
    // Learn the engine image only from an exactly correlated admitted record while other attestations remain unknown.
    var deployment: SparkRequestDeploymentEvidence?
}

struct SparkQualificationRequestMeasurement: Codable, Equatable, Sendable, Identifiable {
    var id: String { workload.rawValue }
    let workload: SparkQualificationWorkload
    let startedSeconds: Double
    let elapsedSeconds: Double
    let firstOutputSeconds: Double?
    let promptTokens: Int?
    let completionTokens: Int?
    let exactAnswerMatched: Bool?
    let terminalConfirmed: Bool
    let outputReceived: Bool
    let runtimeAttemptID: UUID?
    let deployment: SparkRequestDeploymentEvidence?
    var finishReason: String? = nil
}

struct SparkQualificationMemorySample: Codable, Equatable, Sendable {
    let elapsedSeconds: Double
    let availableBytes: Int64
    let memoryPressure: String
    let proxyActiveRequests: Int
    let observedEngineRunning: Int?
    // Bound possible engine sample time relative to the receiver, including cache age and signed-read uncertainty.
    var engineSampleEarliestSeconds: Double? = nil
    var engineSampleLatestSeconds: Double? = nil
    var observationStartedSeconds: Double? = nil
}

struct SparkQualificationCaseResult: Codable, Equatable, Identifiable, Sendable {
    var id: String { kind.rawValue }
    let kind: SparkQualificationCase
    let verdict: SparkQualificationVerdict
    let code: String
    let sampleCount: Int
    let value: Double?
    let secondaryValue: Double?
}

struct SparkQualificationManifest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let preset: SparkQualificationPreset
    let createdAt: Date
    let reproductionOf: UUID?
    var state: String
    var failureCode: String?
    var identity: SparkQualificationIdentity?
    var requests: [SparkQualificationRequestMeasurement]
    var memorySamples: [SparkQualificationMemorySample]
    var cases: [SparkQualificationCaseResult]
    // These gaps prevent this run from authorizing or promoting a profile; a stored run keeps the list it was made with.
    var missingAttestations = [
        "installed_model_bytes", "tokenizer", "template", "driver", "libraries",
        "hardware_topology", "sustained_stability", "broader_quality",
    ]
    var isTerminal: Bool { state != "running" }

    static func new(reproductionOf: UUID? = nil) -> Self {
        Self(
            id: UUID(),
            preset: .quick,
            createdAt: Date(),
            reproductionOf: reproductionOf,
            state: "running",
            identity: nil,
            requests: [],
            memorySamples: [],
            cases: []
        )
    }

    var evidenceDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SparkQualificationStore {
    let directory: URL
    init(
        directory: URL = URL.applicationSupportDirectory.appendingPathComponent(
            "SparkQualification",
            isDirectory: true
        )
    ) {
        self.directory = directory
    }
    private struct Envelope: Codable {
        let manifest: SparkQualificationManifest
        let digest: String
    }

    func save(_ manifest: SparkQualificationManifest) throws {
        var directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        let url = directory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            if try read(url).isTerminal { return }
        } else {
            let count = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                $0.hasSuffix(".json")
            }.count
            guard count < 100 else { throw CocoaError(.fileWriteOutOfSpace) }
        }
        let data = try JSONEncoder().encode(
            Envelope(manifest: manifest, digest: manifest.evidenceDigest)
        )
        guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
            try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(activeIDs: Set<UUID> = []) throws -> [SparkQualificationManifest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        .filter {
            $0.pathExtension == "json"
                && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
        // Refuse oversized evidence directories without replacing their existing contents.
        guard files.count <= 100 else { throw CocoaError(.fileReadTooLarge) }
        return try files.map { url in
            var manifest = try read(url)
            if !manifest.isTerminal, !activeIDs.contains(manifest.id) {
                manifest.state = "interrupted"
                manifest.failureCode = "APP_RESTARTED_OUTCOME_UNKNOWN"
                try save(manifest)
            }
            return manifest
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func read(_ url: URL) throws -> SparkQualificationManifest {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= 2 * 1024 * 1024
        else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard value.manifest.evidenceDigest == value.digest,
            value.manifest.preset == .quick, value.manifest.requests.count <= 11,
            value.manifest.memorySamples.count <= 242
        else { throw CocoaError(.fileReadCorruptFile) }
        return value.manifest
    }

    func clearFinished(activeIDs: Set<UUID> = []) throws {
        for manifest in try load(activeIDs: activeIDs) where manifest.isTerminal {
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
            )
        }
    }
}

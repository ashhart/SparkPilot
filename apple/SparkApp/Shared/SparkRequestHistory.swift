import Foundation
import Observation
import SparkAPI
import SparkSecurity

@MainActor
protocol SparkRequestHistoryLoading {
    func load(target: SparkChatTarget, modelID: String?, outcome: String?, after: Int64?)
        async throws -> SparkInferenceRequestHistory
    func clear(target: SparkChatTarget, key: UUID) async throws
    func cancel(target: SparkChatTarget, id: UUID, key: UUID) async throws
}

@MainActor
struct PinnedSparkRequestHistoryLoader: SparkRequestHistoryLoading {
    private func api(_ target: SparkChatTarget) async throws -> SparkAPIClient {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.route)
        guard identity.nodeID == target.nodeID, identity.clusterID == nil,
            identity.authorityFingerprint == target.authorityFingerprint
        else { throw SparkChatConnectionError.identityMismatch }
        return api
    }
    func load(target: SparkChatTarget, modelID: String?, outcome: String?, after: Int64?)
        async throws -> SparkInferenceRequestHistory
    {
        try await api(target).inferenceRequestHistory(
            route: target.route,
            modelID: modelID,
            outcome: outcome,
            after: after,
            limit: 200
        )
    }
    func clear(target: SparkChatTarget, key: UUID) async throws {
        _ = try await api(target).clearInferenceRequestHistory(
            route: target.route,
            idempotencyKey: key
        )
    }
    func cancel(target: SparkChatTarget, id: UUID, key: UUID) async throws {
        _ = try await api(target).cancelInferenceRequest(
            route: target.route,
            attemptID: id,
            idempotencyKey: key
        )
    }
}

@MainActor @Observable
final class SparkRequestHistoryModel {
    let target: SparkChatTarget
    private(set) var records: [SparkInferenceRequestRecord] = []
    private(set) var recording: Bool?
    private(set) var busy = false
    private(set) var errorMessage: String?
    var modelFilter: String
    var outcomeFilter: String
    var periodHours: Int
    @ObservationIgnored private let loader: any SparkRequestHistoryLoading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var clearKey: UUID?
    @ObservationIgnored private var cancelKeys: [UUID: UUID] = [:]

    init(
        target: SparkChatTarget,
        loader: any SparkRequestHistoryLoading = PinnedSparkRequestHistoryLoader(),
        defaults: UserDefaults = .standard
    ) {
        self.target = target
        self.loader = loader
        self.defaults = defaults
        modelFilter = defaults.string(forKey: "inferenceHistory.model") ?? ""
        let storedOutcome = defaults.string(forKey: "inferenceHistory.outcome") ?? ""
        outcomeFilter = Self.outcomes.contains(storedOutcome) ? storedOutcome : ""
        let hours = defaults.integer(forKey: "inferenceHistory.hours")
        periodHours = [0, 1, 24, 168].contains(hours) ? hours : 0
    }
    static let outcomes = [
        "", "running", "succeeded", "failed", "incomplete", "cancelled_unconfirmed",
        "interrupted_unknown",
    ]

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        defaults.set(modelFilter, forKey: "inferenceHistory.model")
        defaults.set(outcomeFilter, forKey: "inferenceHistory.outcome")
        defaults.set(periodHours, forKey: "inferenceHistory.hours")
        do {
            let history = try await loader.load(
                target: target,
                modelID: modelFilter.isEmpty ? nil : modelFilter,
                outcome: outcomeFilter.isEmpty ? nil : outcomeFilter,
                after: periodHours == 0
                    ? nil : Int64(Date().timeIntervalSince1970) - Int64(periodHours) * 3600
            )
            guard
                history.records.allSatisfy({ UUID(uuidString: $0.nodeID) == target.nodeID.rawValue }
                )
            else { throw SparkChatConnectionError.identityMismatch }
            records = history.records
            recording = history.recording
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Request history could not be refreshed; the runtime may need an update."
            )
        }
    }

    func clearFinished() async {
        guard !busy else { return }
        busy = true
        let key = clearKey ?? UUID()
        clearKey = key
        do {
            try await loader.clear(target: target, key: key)
            clearKey = nil
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Request history could not be cleared; retrying is safe."
            )
        }
        busy = false
        if clearKey == nil { await refresh() }
    }

    func cancel(_ record: SparkInferenceRequestRecord) async -> Bool {
        guard !busy, record.outcome == "running", let id = UUID(uuidString: record.attemptID) else {
            return false
        }
        busy = true
        let key = cancelKeys[id] ?? UUID()
        cancelKeys[id] = key
        do {
            try await loader.cancel(target: target, id: id, key: key)
            cancelKeys[id] = nil
            errorMessage = nil
        } catch {
            errorMessage = String(
                localized: "Cancellation could not be confirmed; the request may still be running."
            )
        }
        busy = false
        let confirmed = cancelKeys[id] == nil
        if confirmed { await refresh() }
        return confirmed
    }
}

func sparkRequestOutcomeTitle(_ value: String) -> String {
    switch value {
    case "checking": String(localized: "Checking loaded model")
    case "waiting", "receiving", "running": String(localized: "Running")
    case "succeeded": String(localized: "Completed")
    case "limited": String(localized: "Output limit reached")
    case "failed": String(localized: "Failed")
    case "incomplete": String(localized: "Incomplete response")
    case "cancelled", "cancelled_unconfirmed":
        String(localized: "Cancelled; engine stop unconfirmed")
    case "interrupted_unknown": String(localized: "Interrupted; outcome unknown")
    default: String(localized: "Not reported")
    }
}

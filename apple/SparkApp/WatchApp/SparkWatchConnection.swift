import Foundation
import Observation
import SparkWatchSupport
@preconcurrency import WatchConnectivity

@MainActor @Observable
final class SparkWatchConnection: NSObject, WCSessionDelegate {
    private(set) var reachable = false
    private(set) var activated = false
    private(set) var companionInstalled = true
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<Data, any Error>] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var connectionMessage: String {
        if !activated { return "Connecting to iPhone…" }
        if !companionInstalled { return "Install SparkPilot on your paired iPhone." }
        return reachable
            ? "Connected through iPhone" : "Open SparkPilot on your paired iPhone to reconnect."
    }

    func send(_ request: SparkWatchRequest) async throws -> SparkWatchResponse {
        guard activated, companionInstalled, reachable else {
            throw SparkWatchFailure(connectionMessage)
        }
        let data = try SparkWatchCodec.encode(request)
        let token = UUID()
        let reply: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[token] = continuation
                timeouts[token] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        token,
                        result: .failure(
                            SparkWatchFailure(
                                "Your iPhone did not reply. Reconnect to check this request."
                            )
                        )
                    )
                }
                WCSession.default.sendMessageData(
                    data,
                    replyHandler: { [weak self] data in
                        Task { @MainActor in self?.finish(token, result: .success(data)) }
                    },
                    errorHandler: { [weak self] _ in
                        Task { @MainActor in
                            self?.finish(
                                token,
                                result: .failure(
                                    SparkWatchFailure(
                                        "Connection lost. Reconnect to check this request."
                                    )
                                )
                            )
                        }
                    }
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(token, result: .failure(CancellationError()))
            }
        }
        let response = try SparkWatchCodec.decode(SparkWatchResponse.self, from: reply)
        guard response.version == 1, response.id == (request.jobID ?? request.id) else {
            throw SparkWatchFailure(
                "The iPhone reply did not match. Update both apps and reconnect."
            )
        }
        return response
    }

    private func finish(_ token: UUID, result: Result<Data, any Error>) {
        timeouts.removeValue(forKey: token)?.cancel()
        pending.removeValue(forKey: token)?.resume(with: result)
    }

    private func update() {
        let session = WCSession.default
        activated = session.activationState == .activated
        reachable = session.isReachable
        companionInstalled = session.isCompanionAppInstalled
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) { Task { @MainActor in update() } }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in update() }
    }
    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in update() }
    }
}

import AVFoundation
import Foundation
import LocalAuthentication
import Observation
import SparkWatchSupport
import WatchKit

@MainActor @Observable
final class SparkWatchStore {
    let connection = SparkWatchConnection()
    private(set) var isPreview = false
    private(set) var targets: [SparkWatchTarget] = []
    private(set) var models: [SparkWatchModel] = []
    private(set) var telemetry: SparkWatchTelemetry?
    private(set) var messages: [SparkWatchMessage] = []
    private(set) var targetID: String =
        UserDefaults.standard.string(forKey: "spark.watch.target") ?? ""
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var pendingID: UUID?
    private(set) var notice: String?
    private(set) var error: String?
    private(set) var connectionError: String?
    var draft = ""
    var readsAloud =
        UserDefaults.standard.object(forKey: "spark.watch.reads-aloud") as? Bool ?? true
    {
        didSet { UserDefaults.standard.set(readsAloud, forKey: "spark.watch.reads-aloud") }
    }
    @ObservationIgnored private let speaker = SparkWatchSpeech()
    @ObservationIgnored private var action: Task<Void, Never>?
    @ObservationIgnored private var actionID = UUID()
    @ObservationIgnored private var pendingCommand: SparkWatchCommand?
    @ObservationIgnored private var pendingTargetID: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var authentication: LAContext?

    init() {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--spark-watch-preview") {
                isPreview = true
                targetID = "preview-spark"
                targets = [
                    .init(id: targetID, name: "Studio Spark", canAsk: false, canManageModels: false)
                ]
                models = [.init(id: "nemotron", targetID: targetID, name: "Nemotron Lightning")]
                telemetry = .init(
                    targetID: targetID,
                    observedAt: Date(),
                    modelName: "Nemotron Lightning",
                    modelState: "ready",
                    memoryPercent: 64,
                    cpuPercent: 23,
                    gpuPercent: 71,
                    temperatureCelsius: 56,
                    powerWatts: 83,
                    queuedRequests: 2
                )
                messages = [
                    .init(role: .user, text: "How is my Spark doing?"),
                    .init(
                        role: .assistant,
                        text:
                            "Nemotron Lightning is ready. Memory is at 64%, with two requests queued."
                    ),
                ]
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--watch-state=empty") {
                    targets = []
                    models = []
                    telemetry = nil
                    messages = []
                } else if arguments.contains("--watch-state=stale") {
                    telemetry?.observedAt = Date().addingTimeInterval(-120)
                } else if arguments.contains("--watch-state=missing") {
                    telemetry?.gpuPercent = nil
                    telemetry?.cpuPercent = nil
                    telemetry?.temperatureCelsius = nil
                    telemetry?.powerWatts = nil
                } else if arguments.contains("--watch-state=draft") {
                    messages = []
                    draft = "Summarise the latest model activity."
                } else if arguments.contains("--watch-state=error") {
                    error =
                        "Spark is busy. Open SparkPilot on iPhone to review the active workload."
                } else if arguments.contains("--watch-state=working") {
                    messages = [.init(role: .user, text: "How is my Spark doing?")]
                    busy = true
                }
                return
            }
        #endif
        pendingID = UserDefaults.standard.string(forKey: "spark.watch.pending-id").flatMap(
            UUID.init(uuidString:)
        )
        pendingCommand = UserDefaults.standard.string(forKey: "spark.watch.pending-command")
            .flatMap(SparkWatchCommand.init(rawValue:))
        pendingTargetID = UserDefaults.standard.string(forKey: "spark.watch.pending-target")
    }

    var target: SparkWatchTarget? { targets.first { $0.id == targetID } }
    // Drafting is local and remains available while a phone connection is interrupted.
    var canCompose: Bool {
        (target?.canAsk == true || isPreview) && !busy && pendingID == nil
    }
    var canAsk: Bool {
        target?.canAsk == true && !busy && !refreshing && pendingID == nil && connection.reachable
    }
    var canManage: Bool {
        target?.canManageModels == true && !busy && !refreshing && pendingID == nil
            && connection.reachable
    }
    var installedModels: [SparkWatchModel] { models.filter { $0.targetID == targetID } }

    func select(_ id: String) {
        guard !busy, pendingID == nil, id != targetID else { return }
        targetID = id
        UserDefaults.standard.set(id, forKey: "spark.watch.target")
        telemetry = nil
        models = []
        newChat()
        notice = nil
        error = nil
    }

    func newChat() {
        guard !busy, pendingID == nil else { return }
        stopSpeaking()
        messages = []
        draft = ""
    }

    func setActive(_ value: Bool) {
        active = value
        #if DEBUG
            if value, isPreview,
                ProcessInfo.processInfo.arguments.contains("--watch-state=working")
            {
                busy = true
            }
        #endif
        if !value {
            stopSpeaking()
            authentication?.invalidate()
            actionID = UUID()
            action?.cancel()
            action = nil
            busy = false
        }
    }

    func refresh() async {
        guard !isPreview, connection.reachable, !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if let pendingID {
                let response = try await poll(pendingID)
                if response.phase != .pending { consume(response) }
            }
            let overview = try await completeRead(SparkWatchRequest(.overview))
            targets = overview.targets ?? []
            if !targets.contains(where: { $0.id == targetID }), pendingID == nil {
                select(targets.first?.id ?? "")
            }
            guard !targetID.isEmpty else {
                telemetry = nil
                models = []
                return
            }
            let selected = targetID
            let status = try await completeRead(SparkWatchRequest(.status, targetID: selected))
            guard selected == targetID else { return }
            telemetry = status.telemetry
            models = status.models ?? []
            connectionError = nil
        } catch is CancellationError {
        } catch {
            connectionError = error.localizedDescription
            telemetry = nil
            models = []
            targets = []
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !text.isEmpty else { return }
        var request = SparkWatchRequest(.ask, targetID: targetID)
        do {
            request.messages = try SparkWatchConversation.appending(text, to: messages)
        } catch {
            self.error = error.localizedDescription
            return
        }
        messages = request.messages
        draft = ""
        begin(request)
    }

    func changeModel(_ model: SparkWatchModel?) {
        guard canManage else { return }
        busy = true
        error = nil
        let selected = targetID
        let id = UUID()
        actionID = id
        action = Task { [weak self] in
            guard let self else { return }
            defer {
                if actionID == id {
                    busy = false
                    authentication = nil
                }
            }
            do {
                let context = LAContext()
                authentication = context
                guard
                    try await context.evaluatePolicy(
                        .deviceOwnerAuthenticationWithWristDetection,
                        localizedReason: "Confirm changing the model on your Spark"
                    )
                else { throw SparkWatchFailure("Unlock your watch to confirm this change.") }
                try Task.checkCancellation()
                guard active, selected == targetID, actionID == id else { return }
                var request = SparkWatchRequest(model == nil ? .stop : .load, targetID: selected)
                request.modelID = model?.id
                request.authenticatedAt = Date()
                await run(request)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, actionID == id else { return }
                self.error =
                    "Model change was not authorized. Wear and unlock your watch, then try again."
            }
        }
    }

    private func begin(_ request: SparkWatchRequest) {
        busy = true
        stopSpeaking()
        let id = UUID()
        actionID = id
        action = Task { [weak self] in
            guard let self else { return }
            defer { if actionID == id { busy = false } }
            await run(request)
        }
    }

    private func run(_ request: SparkWatchRequest) async {
        error = nil
        notice = nil
        remember(request)
        do {
            var result = try await connection.send(request)
            while result.phase == .pending {
                try await Task.sleep(for: .seconds(2))
                result = try await poll(request.id)
            }
            try Task.checkCancellation()
            consume(result)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func poll(_ id: UUID) async throws -> SparkWatchResponse {
        var request = SparkWatchRequest(.poll)
        request.jobID = id
        return try await connection.send(request)
    }

    private func completeRead(_ request: SparkWatchRequest) async throws -> SparkWatchResponse {
        var response = try await connection.send(request)
        for _ in 0..<30 {
            if response.phase != .pending { break }
            try await Task.sleep(for: .seconds(1))
            response = try await poll(request.id)
        }
        guard response.phase == .complete else {
            throw SparkWatchFailure(
                response.message ?? "Your Spark did not reply. Try refreshing again."
            )
        }
        return response
    }

    private func remember(_ request: SparkWatchRequest) {
        pendingID = request.id
        pendingCommand = request.command
        pendingTargetID = request.targetID
        UserDefaults.standard.set(request.id.uuidString, forKey: "spark.watch.pending-id")
        UserDefaults.standard.set(request.command.rawValue, forKey: "spark.watch.pending-command")
        UserDefaults.standard.set(request.targetID, forKey: "spark.watch.pending-target")
    }

    private func consume(_ response: SparkWatchResponse) {
        guard response.id == pendingID else { return }
        let command = pendingCommand
        let selected = pendingTargetID
        clearPending()
        if response.phase == .complete {
            if command == .ask, let text = response.message, selected == targetID {
                messages.append(.init(role: .assistant, text: text))
                if active, readsAloud { speak(text) }
            } else {
                notice = response.message
            }
            WKInterfaceDevice.current().play(.success)
        } else {
            error = response.message ?? "The request did not finish. Refresh to check your Spark."
            if command == .ask, messages.last?.role == .user {
                draft = messages.removeLast().text
            }
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func clearPending() {
        pendingID = nil
        pendingCommand = nil
        pendingTargetID = nil
        for key in [
            "spark.watch.pending-id", "spark.watch.pending-command", "spark.watch.pending-target",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func cancel() {
        guard let id = pendingID else { return }
        action?.cancel()
        let token = UUID()
        actionID = token
        busy = true
        action = Task {
            defer { if actionID == token { busy = false } }
            do {
                var request = SparkWatchRequest(.cancel)
                request.jobID = id
                consume(try await connection.send(request))
            } catch { self.error = error.localizedDescription }
        }
    }

    func speak(_ text: String) {
        guard active else { return }
        do { try speaker.speak(text) } catch {
            notice = "The reply is ready to read; audio is unavailable."
        }
    }

    func stopSpeaking() { speaker.stop() }
}

@MainActor
private final class SparkWatchSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ text: String) throws {
        synthesizer.stopSpeaking(at: .immediate)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }
    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { deactivate() } }
    }
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { deactivate() } }
    }
}

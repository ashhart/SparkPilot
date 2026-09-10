import Foundation
import Observation
import SparkAPI
import SparkLibrary
import SparkProjects

struct SparkCarPlayDevelopmentTarget: Identifiable, Equatable, Codable, Sendable {
    let workspaceID: UUID
    let targetID: String
    let sparkName: String
    let projectID: String
    let projectName: String
    let terminalID: String
    let harness: ProjectDevelopmentHarness
    var id: String { targetID + "::" + projectID + "::" + terminalID }

    init?(record: SparkDevelopmentRecord) {
        guard let terminal = record.terminal, record.automaticallyResume != false else {
            return nil
        }
        workspaceID = record.id
        targetID = record.targetID
        sparkName = record.sparkName
        projectID = record.projectID
        projectName = record.projectName
        terminalID = terminal.terminalId
        harness = record.selection.harness
    }
}

@MainActor
protocol SparkCarPlayDevelopmentProviding: AnyObject {
    func routeIdentity(_ target: SparkCarPlayDevelopmentTarget) throws -> String
    func connect(_ target: SparkCarPlayDevelopmentTarget) async throws
        -> any ProjectTerminalConnecting
    func state(_ target: SparkCarPlayDevelopmentTarget) async throws -> String?
}

/// Existing sessions only: attaching and leaving must never create or terminate a remote process.
@MainActor @Observable
final class SparkCarPlayDevelopmentAdapter {
    private(set) var target: SparkCarPlayDevelopmentTarget?
    private(set) var isWorking = false
    private(set) var connected = false
    private(set) var error: String?
    private(set) var lastOutputAt: Date?
    private(set) var lastReadback: String?
    private(set) var pendingReadback: String?
    private let provider: any SparkCarPlayDevelopmentProviding
    private let defaults: UserDefaults
    private let now: () -> Date
    private let authorize: (SparkCarPlayDevelopmentTarget) -> Bool
    private var attachedRoute: String?
    private var socket: (any ProjectTerminalConnecting)?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var readback = ProjectTerminalReadback()
    private var lastScreen = ""
    private var startedAt = Date.distantPast
    private var lastAnnouncementAt = Date.distantPast
    private var attemptedInput = false
    private static let receiptKey = "spark.carplay.terminal.delivery"

    init(
        provider: any SparkCarPlayDevelopmentProviding,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        authorize: @escaping (SparkCarPlayDevelopmentTarget) -> Bool
    ) {
        self.provider = provider
        self.defaults = defaults
        self.now = now
        self.authorize = authorize
    }

    static func targets(workspace: SparkDevelopmentWorkspace) -> [SparkCarPlayDevelopmentTarget] {
        workspace.records.compactMap(SparkCarPlayDevelopmentTarget.init(record:))
    }

    func attach(_ target: SparkCarPlayDevelopmentTarget) async throws {
        detach()
        let id = generation
        guard authorize(target) else {
            throw APIError(
                .local(message: String(localized: "Unlock SparkPilot on your iPhone first."))
            )
        }
        let route = try provider.routeIdentity(target)
        let state = try await provider.state(target)
        guard try provider.routeIdentity(target) == route else { throw CancellationError() }
        guard id == generation, !Task.isCancelled else { throw CancellationError() }
        guard state == "running" else {
            throw APIError(
                .local(
                    message: String(
                        localized: "This session is not running. Open it on your iPhone first."
                    )
                )
            )
        }
        let connection = try await provider.connect(target)
        do {
            try await connection.start()
            guard id == generation, !Task.isCancelled, authorize(target),
                try provider.routeIdentity(target) == route
            else { throw CancellationError() }
        } catch {
            await connection.cancel()
            throw error
        }
        self.target = target
        attachedRoute = route
        socket = connection
        connected = true
        startedAt = now()
        error = nil
        readback = ProjectTerminalReadback()
        lastScreen = ""
        pendingReadback = nil
        reader = Task { [weak self, connection] in
            do {
                while !Task.isCancelled {
                    let text = try await connection.receive()
                    guard !Task.isCancelled else { return }
                    self?.receive(text, generation: id)
                }
            } catch {
                self?.receiveFailure(generation: id)
            }
        }
    }

    func detach() {
        generation = UUID()
        reader?.cancel()
        reader = nil
        let old = socket
        socket = nil
        attachedRoute = nil
        connected = false
        pendingReadback = nil
        if let old { Task { await old.cancel() } }
    }

    /// One bounded paste and Return frame, sent once. WebSockets have no application acknowledgement.
    func submit(_ spoken: String) async -> String {
        guard !isWorking, connected, let target, let socket else {
            return String(localized: "Reconnect to the session before sending an instruction.")
        }
        guard authorize(target) else { return SparkCarPlayCopy.lockedPhone }
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 7_000,
            text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
        else {
            return String(
                localized:
                    "That instruction is too long or contains unsupported characters. Please try a shorter instruction."
            )
        }
        var receipts = defaults.dictionary(forKey: Self.receiptKey) as? [String: String] ?? [:]
        guard receipts[target.id] == nil else {
            return String(
                localized:
                    "The previous delivery is uncertain. Check the session on your phone before sending again."
            )
        }
        isWorking = true
        defer { isWorking = false }
        let id = generation
        attemptedInput = false
        do {
            let state = try await provider.state(target)
            guard try provider.routeIdentity(target) == attachedRoute else {
                return String(
                    localized: "The connection changed. Reopen this session before sending."
                )
            }
            guard id == generation, !Task.isCancelled, authorize(target) else {
                throw CancellationError()
            }
            guard state == "running" else {
                return String(
                    localized: "This session has ended. Your project is still on the Spark."
                )
            }
            // Persist uncertainty BEFORE I/O. Neither reconnect nor app restart may replay this input.
            receipts[target.id] = "uncertain"
            defaults.set(receipts, forKey: Self.receiptKey)
            readback.markRead()
            attemptedInput = true
            try await socket.send("\u{1b}[200~" + text + "\u{1b}[201~\r")
            // Only successful transport delivery clears the warning; this is not a claim that the task finished.
            clearDeliveryWarning(for: target)
            guard id == generation, !Task.isCancelled else { return "" }
            return String(localized: "I've sent that to your session. I'll read out its updates.")
        } catch {
            guard id == generation, !Task.isCancelled else { return "" }
            self.error = APIError.message(for: error)
            return attemptedInput
                ? String(
                    localized:
                        "The connection changed while sending. Check the session on your phone; I will not send the instruction again automatically."
                )
                : APIError.message(for: error)
        }
    }

    func clearDeliveryWarning(for target: SparkCarPlayDevelopmentTarget) {
        var receipts = defaults.dictionary(forKey: Self.receiptKey) as? [String: String] ?? [:]
        receipts.removeValue(forKey: target.id)
        defaults.set(receipts, forKey: Self.receiptKey)
    }

    func checkStatus() async -> String {
        guard let target else { return String(localized: "Choose a development session first.") }
        do {
            let state = try await provider.state(target)
            if state != "running" {
                connected = false
                return String(
                    localized:
                        "This session is no longer running. Your project is still on the Spark."
                )
            }
            return connected
                ? String(localized: "The session is connected. Ask me to read its latest output.")
                : String(
                    localized: "The session is running on the Spark. Reconnect to hear its output."
                )
        } catch { return APIError.message(for: error) }
    }

    /// Quiet output is an update, never proof of task completion or a successful test run.
    func collectReadback(force: Bool = false) -> String? {
        guard connected, pendingReadback == nil else { return pendingReadback }
        let text = force ? readback.latest : readback.unread
        guard !text.isEmpty else { return nil }
        let date = now()
        guard
            force
                || (date.timeIntervalSince(lastOutputAt ?? date) >= 3
                    && date.timeIntervalSince(startedAt) >= 3
                    && date.timeIntervalSince(lastAnnouncementAt) >= 12)
        else { return nil }
        pendingReadback = text
        readback.markRead()
        return text
    }

    func didReadOutput() {
        lastReadback = pendingReadback
        pendingReadback = nil
        lastAnnouncementAt = now()
    }

    private func receive(_ text: String, generation id: UUID) {
        guard generation == id, connected else { return }
        readback.feed(text)
        let screen = readback.latest
        if screen != lastScreen {
            lastScreen = screen
            lastOutputAt = now()
        }
    }
    private func receiveFailure(generation id: UUID) {
        guard id == generation else { return }
        connected = false
        error = String(
            localized: "The terminal connection closed. Reopen the session to check its status."
        )
    }
}

@MainActor
final class SignedCarPlayDevelopmentProvider: SparkCarPlayDevelopmentProviding {
    private let library: SparkLibrary
    init(library: SparkLibrary) { self.library = library }
    func routeIdentity(_ target: SparkCarPlayDevelopmentTarget) throws -> String {
        try SparkSignedProjectConnection.make(library: library, targetID: target.targetID).route
            .absoluteString
    }
    func connect(_ target: SparkCarPlayDevelopmentTarget) async throws
        -> any ProjectTerminalConnecting
    {
        try await SignedProjectDataProvider(library: library).reconnectTerminal(
            targetID: target.targetID,
            projectID: target.projectID,
            terminalID: target.terminalID
        )
    }
    func state(_ target: SparkCarPlayDevelopmentTarget) async throws -> String? {
        try await SignedProjectDataProvider(library: library).developmentTerminalState(
            targetID: target.targetID,
            projectID: target.projectID,
            terminalID: target.terminalID
        )
    }
}

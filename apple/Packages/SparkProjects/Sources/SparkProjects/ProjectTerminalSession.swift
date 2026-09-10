import Foundation
import Observation
import SparkAPI

/// Own terminal resources and fence every late response to its originating Spark and project.
@MainActor
@Observable
final class ProjectTerminalSession {
    private(set) var terminal: GeneratedAPI.ProjectTerminal?
    private(set) var terminalTranscript = ""
    var terminalInput = ""
    private(set) var terminalState: ProjectLoadState = .idle
    @ObservationIgnored var contextIsCurrent: (String, String) -> Bool = { _, _ in false }
    private let provider: any ProjectDataProviding
    private var terminalConnection: (any ProjectTerminalConnecting)?
    private var inputTask: Task<Bool, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pendingSize: (columns: Int, rows: Int)?
    let screen = ProjectTerminalScreen()
    private var terminalReadTask: Task<Void, Never>?
    private var terminalSequence = 0
    private var terminalEndSequence = 0
    private var terminalTargetID: String?
    private var sanitiser = ProjectTerminalSanitiser()
    private var lastSize: (columns: Int, rows: Int)?
    private var terminalProjectID: String?

    init(provider: any ProjectDataProviding) {
        self.provider = provider
        screen.onInput = { [weak self] text in _ = self?.enqueueInput(text) }
        screen.onResize = { [weak self] columns, rows in
            Task { await self?.resizeTerminal(columns: columns, rows: rows) }
        }
    }

    /// Preserve keystroke order, including terminal replies and large bracketed pastes.
    @discardableResult func enqueueInput(_ text: String) -> Task<Bool, Never> {
        let previous = inputTask
        let sequence = terminalSequence
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, self.terminalSequence == sequence,
                let connection = self.terminalConnection, !Task.isCancelled
            else { return false }
            do {
                for chunk in Self.inputChunks(text) {
                    guard !Task.isCancelled, self.terminalSequence == sequence else { return false }
                    try await connection.send(chunk)
                }
                return true
            } catch {
                if self.terminalSequence == sequence {
                    self.terminalState = .failed(APIError.message(for: error))
                }
                return false
            }
        }
        inputTask = task
        return task
    }

    static func inputChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let next = String(scalar)
            if bytes + next.utf8.count > 8_192 {
                chunks.append(chunk)
                chunk = ""
                bytes = 0
            }
            chunk += next
            bytes += next.utf8.count
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    func startTerminal(
        shell: ProjectTerminalShell,
        targetID: String?,
        projectID: String?,
        permitted: Bool,
        durable: Bool = false
    ) async {
        guard permitted,
            let targetID,
            let projectID
        else {
            terminalState = .failed(String(localized: "Terminal access is not available."))
            return
        }
        if durable { await detach() } else { await stopTerminal() }
        terminalSequence += 1
        let sequence = terminalSequence
        terminalState = .loading
        terminalTranscript = ""
        sanitiser = ProjectTerminalSanitiser()
        screen.reset()
        lastSize = nil
        do {
            let (terminal, connection) = try await provider.createTerminal(
                targetID: targetID,
                projectID: projectID,
                shell: shell
            )
            if terminalEndSequence > sequence {
                await tearDownTerminal(
                    terminal,
                    connection: connection,
                    targetID: targetID,
                    projectID: projectID
                )
                return
            }
            guard terminal.projectId == projectID else {
                await tearDownTerminal(
                    terminal,
                    connection: connection,
                    targetID: targetID,
                    projectID: projectID,
                    closeRemote: !durable
                )
                if terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) {
                    terminalState = .failed(String(localized: "The terminal response was invalid."))
                }
                return
            }
            if durable {
                self.terminal = terminal
                terminalTargetID = targetID
                terminalProjectID = projectID
            }
            guard terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID)
            else {
                await tearDownTerminal(
                    terminal,
                    connection: connection,
                    targetID: targetID,
                    projectID: projectID,
                    closeRemote: !durable
                )
                return
            }
            do {
                try await connection.start()
            } catch {
                await tearDownTerminal(
                    terminal,
                    connection: connection,
                    targetID: targetID,
                    projectID: projectID,
                    closeRemote: !durable
                )
                if terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) {
                    terminalState = .failed(APIError.message(for: error))
                }
                return
            }
            guard terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID)
            else {
                await tearDownTerminal(
                    terminal,
                    connection: connection,
                    targetID: targetID,
                    projectID: projectID,
                    closeRemote: !durable
                )
                return
            }
            self.terminal = terminal
            terminalConnection = connection
            terminalTargetID = targetID
            terminalProjectID = projectID
            await resizeTerminal(columns: screen.columns, rows: screen.rows)
            guard terminalSequence == sequence else { return }
            if terminalState == .loading { terminalState = .loaded }
            terminalReadTask = Task { [weak self] in
                await self?.readTerminal(
                    connection,
                    terminalID: terminal.terminalId,
                    sequence: sequence
                )
            }
        } catch {
            if terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) {
                terminalState = .failed(APIError.message(for: error))
            }
        }
    }

    func sendTerminalInput() async {
        guard let connection = terminalConnection else { return }
        let input = terminalInput
        guard !input.isEmpty else { return }
        do {
            try await connection.send(input.hasSuffix("\n") ? input : "\(input)\n")
            if terminalInput == input { terminalInput = "" }
        } catch {
            terminalState = .failed(APIError.message(for: error))
        }
    }

    func detach() async {
        terminalSequence += 1
        resizeTask?.cancel()
        resizeTask = nil
        pendingSize = nil
        inputTask?.cancel()
        inputTask = nil
        terminalReadTask?.cancel()
        terminalReadTask = nil
        let connection = terminalConnection
        terminalConnection = nil
        terminalState = .idle
        // Do not overwrite a new attachment's state after awaiting an old socket's cancellation.
        if let connection { await connection.cancel() }
    }

    func reconnect(_ terminal: GeneratedAPI.ProjectTerminal, targetID: String, projectID: String)
        async
    {
        guard terminal.projectId == projectID, contextIsCurrent(targetID, projectID) else { return }
        await detach()
        terminalSequence += 1
        let sequence = terminalSequence
        terminalState = .loading
        self.terminal = terminal
        terminalTargetID = targetID
        terminalProjectID = projectID
        do {
            let connection = try await provider.reconnectTerminal(
                targetID: targetID,
                projectID: projectID,
                terminalID: terminal.terminalId
            )
            guard terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID)
            else {
                await connection.cancel()
                return
            }
            do { try await connection.start() } catch {
                await connection.cancel()
                throw error
            }
            guard terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID)
            else {
                await connection.cancel()
                return
            }
            screen.reset()
            terminalTranscript = ""
            sanitiser = ProjectTerminalSanitiser()
            lastSize = nil
            terminalConnection = connection
            await resizeTerminal(columns: screen.columns, rows: screen.rows)
            guard terminalSequence == sequence else { return }
            if terminalState == .loading { terminalState = .loaded }
            terminalReadTask = Task { [weak self] in
                await self?.readTerminal(
                    connection,
                    terminalID: terminal.terminalId,
                    sequence: sequence
                )
            }
        } catch {
            if terminalRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) {
                terminalState = .failed(APIError.message(for: error))
            }
        }
    }

    func stopTerminal(preserveOnFailure: Bool = false) async {
        terminalSequence += 1
        terminalEndSequence = terminalSequence
        let endSequence = terminalSequence
        resizeTask?.cancel()
        resizeTask = nil
        pendingSize = nil
        inputTask?.cancel()
        inputTask = nil
        terminalReadTask?.cancel()
        terminalReadTask = nil
        let connection = terminalConnection
        let terminal = terminal
        let targetID = terminalTargetID
        let projectID = terminalProjectID
        terminalConnection = nil
        self.terminal = nil
        terminalTargetID = nil
        terminalProjectID = nil
        terminalTranscript = ""
        terminalInput = ""
        terminalState = .idle
        if let connection { await connection.cancel() }
        if let terminal, let targetID, let projectID {
            do {
                try await provider.closeTerminal(
                    targetID: targetID,
                    projectID: projectID,
                    terminalID: terminal.terminalId
                )
            } catch {
                guard preserveOnFailure, terminalSequence == endSequence else { return }
                self.terminal = terminal
                terminalTargetID = targetID
                terminalProjectID = projectID
                terminalState = .failed(
                    String(localized: .developmentSessionEndFailed(APIError.message(for: error)))
                )
                return
            }
        }
        guard terminalSequence == endSequence else { return }
        screen.reset()
    }

    private func readTerminal(
        _ connection: any ProjectTerminalConnecting,
        terminalID: String,
        sequence: Int
    ) async {
        do {
            while !Task.isCancelled {
                let output = try await connection.receive()
                guard !Task.isCancelled, terminalSequence == sequence,
                    terminal?.terminalId == terminalID
                else { return }
                screen.feed(output)
                terminalTranscript.append(sanitiser.append(output))
                if terminalTranscript.utf8.count > 1_048_576 {
                    terminalTranscript = Self.boundedTerminalTranscript(terminalTranscript)
                }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, terminalSequence == sequence {
                terminalState = .failed(APIError.message(for: error))
            }
        }
    }

    /// Coalesce layout changes and serialize delivery so an older rotation cannot win a race.
    func resizeTerminal(columns: Int, rows: Int) async {
        guard let connection = terminalConnection, columns > 0, rows > 0 else { return }
        if resizeTask == nil, lastSize?.columns == columns, lastSize?.rows == rows { return }
        pendingSize = (columns, rows)
        if let resizeTask {
            await resizeTask.value
            return
        }
        let sequence = terminalSequence
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.terminalSequence == sequence { self.resizeTask = nil } }
            while !Task.isCancelled, self.terminalSequence == sequence,
                let size = self.pendingSize
            {
                self.pendingSize = nil
                if self.lastSize?.columns == size.columns, self.lastSize?.rows == size.rows {
                    continue
                }
                do {
                    try await connection.resize(columns: size.columns, rows: size.rows)
                    guard !Task.isCancelled, self.terminalSequence == sequence else { return }
                    self.lastSize = size
                } catch {
                    guard !Task.isCancelled, self.terminalSequence == sequence else { return }
                    self.lastSize = nil
                    self.terminalState = .failed(APIError.message(for: error))
                }
            }
        }
        resizeTask = task
        await task.value
    }

    private func terminalRequestIsCurrent(
        _ sequence: Int,
        targetID: String,
        projectID: String
    ) -> Bool {
        sequence == terminalSequence
            && contextIsCurrent(targetID, projectID)
    }

    private func tearDownTerminal(
        _ terminal: GeneratedAPI.ProjectTerminal,
        connection: any ProjectTerminalConnecting,
        targetID: String,
        projectID: String,
        closeRemote: Bool = true
    ) async {
        await connection.cancel()
        guard closeRemote else { return }
        try? await provider.closeTerminal(
            targetID: targetID,
            projectID: projectID,
            terminalID: terminal.terminalId
        )
    }

    static func boundedTerminalTranscript(_ transcript: String) -> String {
        let retained = Array(transcript.utf8.suffix(524_288))
        let scalarStart =
            retained.firstIndex { ($0 & 0b1100_0000) != 0b1000_0000 }
            ?? retained.endIndex
        return String(decoding: retained[scalarStart...], as: UTF8.self)
    }

}

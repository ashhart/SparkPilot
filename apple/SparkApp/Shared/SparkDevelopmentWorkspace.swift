import Foundation
import Observation
import SparkAPI
import SparkLibrary
import SparkProjects

@MainActor
protocol SparkDevelopmentProviding: ProjectDataProviding {
    var developmentSelection: ProjectDevelopmentSelection? { get set }
    var developmentIdempotencyKey: UUID { get set }
    func developmentTerminalState(targetID: String, projectID: String, terminalID: String)
        async throws -> String?
}

struct SparkDevelopmentRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let targetID: String
    let projectID: String
    let projectName: String
    let sparkName: String
    let selection: ProjectDevelopmentSelection
    var launchKey: UUID
    var terminal: GeneratedAPI.ProjectTerminal?
    var draft: String
    var automaticallyResume: Bool? = nil
}

/// One writer across OS windows; only non-secret identities and presentation data are archived.
@MainActor @Observable
final class SparkDevelopmentWorkspace {
    private(set) var records: [SparkDevelopmentRecord] = []
    private(set) var storageError: String?
    let library: SparkLibrary
    private let archiveURL: URL
    private var canWrite = true
    private static var sharedInstance: SparkDevelopmentWorkspace?

    static func shared(library: SparkLibrary) -> SparkDevelopmentWorkspace {
        if let sharedInstance { return sharedInstance }
        let instance = SparkDevelopmentWorkspace(library: library)
        sharedInstance = instance
        return instance
    }

    init(library: SparkLibrary, archiveURL: URL? = nil) {
        self.library = library
        self.archiveURL =
            archiveURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SparkPilot/development-workspaces.json")
        do {
            if FileManager.default.fileExists(atPath: self.archiveURL.path) {
                records = try JSONDecoder().decode(
                    [SparkDevelopmentRecord].self,
                    from: Data(contentsOf: self.archiveURL)
                )
                guard Set(records.map(\.id)).count == records.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        } catch {
            canWrite = false
            storageError = String(
                localized: "Saved workspaces could not be opened; the archive has been kept."
            )
        }
    }

    func update(_ record: SparkDevelopmentRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save()
    }
    func removeProject(targetID: String, projectID: String) {
        records.removeAll { $0.targetID == targetID && $0.projectID == projectID }
        save()
    }

    private func save() {
        guard canWrite else { return }
        do {
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: archiveURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: archiveURL.path
            )
            storageError = nil
        } catch {
            storageError =
                String(
                    localized:
                        "Workspace changes could not be saved on this device; keep this window open and try again."
                )
        }
    }
    func record(_ id: UUID) -> SparkDevelopmentRecord? { records.first { $0.id == id } }
}

/// Each visible pane owns its model, emulator, editor and voice draft, never another pane's selection.
@MainActor @Observable
final class SparkDevelopmentContext: Identifiable {
    let id: UUID
    let model: ProjectsModel
    private let provider: any SparkDevelopmentProviding
    private let workspace: SparkDevelopmentWorkspace
    private let engineeringEnabled: () -> Bool
    private var prepared = false
    private var opening = false
    private var lifecycle = 0
    private(set) var isEnding = false
    private var visible = false
    private var visibleConsumers: Set<UUID> = []
    var showingInput = false
    private var recoverySuspended = false
    private var recovery: Task<Void, Never>?
    var draft: String { didSet { persistDraft() } }
    var isListening = false
    var voiceError: String?
    var openError: String?
    var isInserting = false
    var insertError: String?
    var voiceLevel = 0.0
    private let capture = SparkVoiceCapture()
    private var voiceAttempt = UUID()

    init(
        record: SparkDevelopmentRecord,
        workspace: SparkDevelopmentWorkspace,
        provider suppliedProvider: (any SparkDevelopmentProviding)? = nil,
        engineeringEnabled: @escaping () -> Bool = { SparkEngineeringMode.isEnabled() }
    ) {
        id = record.id
        self.workspace = workspace
        draft = record.draft
        self.engineeringEnabled = engineeringEnabled
        let provider = suppliedProvider ?? SignedProjectDataProvider(library: workspace.library)
        provider.developmentSelection = record.selection
        provider.developmentIdempotencyKey = record.launchKey
        self.provider = provider
        model = ProjectsModel(provider: provider)
    }
    var record: SparkDevelopmentRecord? { workspace.record(id) }

    func open(allowRestart: Bool = true, forceReconnect: Bool = false) async {
        guard !opening, !isEnding, var record, engineeringEnabled() else { return }
        guard allowRestart || record.automaticallyResume != false else { return }
        let generation = lifecycle
        opening = true
        defer { opening = false }
        openError = nil
        if allowRestart {
            recoverySuspended = false
            if record.automaticallyResume == false {
                record.automaticallyResume = true
                workspace.update(record)
            }
        }
        if !prepared {
            await model.load()
            guard generation == lifecycle else { return }
            await model.selectTarget(record.targetID)
            guard generation == lifecycle else { return }
            guard let project = model.projects.first(where: { $0.id == record.projectID }) else {
                openError =
                    String(
                        localized:
                            "This workspace is unavailable; reconnect its Spark and check project access."
                    )
                return
            }
            await model.openProject(project)
            guard generation == lifecycle else { return }
            prepared = true
        }
        if forceReconnect { await model.detachTerminal() }
        guard generation == lifecycle else { return }
        if model.terminalState == .loaded { return }
        var launchRecord = record
        do {
            if let terminal = launchRecord.terminal {
                var status = try await provider.developmentTerminalState(
                    targetID: record.targetID,
                    projectID: record.projectID,
                    terminalID: terminal.terminalId
                )
                guard generation == lifecycle else { return }
                for _ in 0..<60 where status == "starting" {
                    guard generation == lifecycle else { return }
                    try await Task.sleep(for: .seconds(1))
                    status = try await provider.developmentTerminalState(
                        targetID: record.targetID,
                        projectID: record.projectID,
                        terminalID: terminal.terminalId
                    )
                }
                guard generation == lifecycle else { return }
                if status == "starting" {
                    openError = String(
                        localized:
                            "The Spark is still preparing this session; reconnect in a moment."
                    )
                    return
                }
                if status == nil || status == "stopped" || status == "failed" {
                    guard allowRestart else {
                        recoverySuspended = true
                        openError =
                            String(
                                localized:
                                    "This session has ended; open it again to continue from the saved workspace."
                            )
                        return
                    }
                    // Confirmed loss or exit only: preserve the folder and harness history, renew the process identity.
                    if status == "stopped" {
                        try await provider.closeTerminal(
                            targetID: record.targetID,
                            projectID: record.projectID,
                            terminalID: terminal.terminalId
                        )
                    }
                    guard generation == lifecycle else { return }
                    launchRecord.terminal = nil
                    launchRecord.launchKey = UUID()
                    provider.developmentIdempotencyKey = launchRecord.launchKey
                    workspace.update(launchRecord)
                } else {
                    await model.reconnectTerminal(terminal)
                }
            }
            guard generation == lifecycle else { return }
            if launchRecord.terminal == nil {
                provider.developmentIdempotencyKey = launchRecord.launchKey
                await model.startTerminal(shell: .bash, durable: true)
                if let terminal = model.terminal {
                    var updated = workspace.record(id) ?? launchRecord
                    updated.terminal = terminal
                    workspace.update(updated)
                }
            }
        } catch is CancellationError { return } catch {
            openError = APIError.message(for: error)
            return
        }
        guard generation == lifecycle else { return }
        await model.refreshProjectContents()
    }
    func reconnect() async { await open(allowRestart: false, forceReconnect: true) }

    func resume() async {
        visible = true
        recoverySuspended = record?.automaticallyResume == false
        if !recoverySuspended { await open(allowRestart: false) }
        guard visible, recovery == nil else { return }
        recovery = Task { [weak self] in
            var delay = 2
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.visible else { return }
                guard !self.recoverySuspended else { continue }
                if self.model.terminalState == .loaded {
                    delay = 2
                    continue
                }
                if self.opening { continue }
                await self.open(allowRestart: false)
                delay = self.model.terminalState == .loaded ? 2 : min(8, delay * 2)
            }
        }
    }
    /// A pane moving into full screen can briefly have both old and new view owners.
    func resume(consumer: UUID) async {
        guard visibleConsumers.insert(consumer).inserted else { return }
        await resume()
    }
    func detach(consumer: UUID) async {
        guard visibleConsumers.remove(consumer) != nil, visibleConsumers.isEmpty else { return }
        await detach()
    }
    func detach() async {
        lifecycle += 1
        visibleConsumers.removeAll()
        visible = false
        recovery?.cancel()
        recovery = nil
        stopVoice()
        await model.detachTerminal()
    }
    func end() async {
        guard !isEnding else { return }
        let current = model.terminal ?? record?.terminal
        guard current != nil || opening else {
            openError = String(localized: "Reconnect to this session before ending it.")
            return
        }
        lifecycle += 1
        isEnding = true
        defer { isEnding = false }
        recoverySuspended = true
        openError = nil
        stopVoice()
        if model.terminal != nil || current == nil {
            await model.endDevelopmentTerminal()
        } else if let record, let current {
            do {
                try await provider.closeTerminal(
                    targetID: record.targetID,
                    projectID: record.projectID,
                    terminalID: current.terminalId
                )
            } catch {
                openError =
                    String(localized: .developmentSessionEndFailed(APIError.message(for: error)))
                return
            }
        }
        guard model.terminal == nil, var record else { return }
        record.terminal = nil
        record.launchKey = UUID()
        record.automaticallyResume = false
        provider.developmentIdempotencyKey = record.launchKey
        workspace.update(record)
    }
    func sendDraft(submit: Bool = false) async {
        guard !isInserting, model.terminalState == .loaded,
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        isInserting = true
        defer { isInserting = false }
        insertError = nil
        let submitted = draft
        // Submit only after the user presses Send or Return; dictation itself never executes a command.
        if await model.pasteTerminalText(submitted, submit: submit) {
            if draft == submitted { draft = "" }
        } else {
            insertError =
                String(
                    localized:
                        "Your draft is saved; check the terminal after reconnecting before inserting it again."
                )
        }
    }
    private func persistDraft() {
        guard var record else { return }
        record.draft = draft
        workspace.update(record)
    }
    func dictate() async {
        if isListening {
            capture.finish()
            return
        }
        let attempt = UUID()
        voiceAttempt = attempt
        let prefix = draft.isEmpty ? "" : draft + " "
        isListening = true
        voiceError = nil
        do {
            try await capture.start(
                partial: { [weak self] text, level in
                    guard let self, self.voiceAttempt == attempt else { return }
                    self.draft = prefix + text
                    self.voiceLevel = level
                },
                completion: { [weak self] result in
                    guard let self, self.voiceAttempt == attempt else { return }
                    self.isListening = false
                    self.voiceLevel = 0
                    switch result {
                    case .success(let text): self.draft = prefix + text
                    case .failure(let error): self.voiceError = Self.voiceMessage(error)
                    }
                }
            )
        } catch {
            guard voiceAttempt == attempt else { return }
            isListening = false
            voiceError = Self.voiceMessage(error)
        }
    }
    func stopVoice() {
        voiceAttempt = UUID()
        capture.stop()
        isListening = false
        voiceLevel = 0
    }
    private static func voiceMessage(_ error: any Error) -> String {
        if let failure = error as? SparkVoiceCapture.Failure {
            return SparkVoiceCaptureFailurePresentation.message(for: failure)
        }
        return String(localized: "Dictation stopped; your draft is still here.")
    }
}

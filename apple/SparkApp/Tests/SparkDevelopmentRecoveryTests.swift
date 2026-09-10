import Foundation
import SparkAPI
import SparkLibrary
import SparkProjects
import Testing
@testable import SparkAppComposition

@MainActor
struct SparkDevelopmentRecoveryTests {
    @Test func endingWhileReconnectChecksTheServerCannotReopenTheEndedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        fixture.provider.delayStatus = true
        let reconnecting = Task { await context.reconnect() }
        try await eventually { fixture.provider.statusContinuation != nil }
        await context.end()
        fixture.provider.releaseStatus()
        await reconnecting.value
        #expect(context.model.terminal == nil)
        #expect(context.model.terminalState == .idle)
        #expect(fixture.store.record(fixture.record.id)?.automaticallyResume == false)
        #expect(fixture.provider.reconnected.isEmpty)
        #expect(fixture.provider.closed == 1)
        await context.detach()
    }

    @Test func closingAndReopeningAPanePreservesTheProcessAndAcceptsInput() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        let firstPane = UUID()
        await context.resume(consumer: firstPane)
        let identity = context.model.terminal
        await context.detach(consumer: firstPane)
        await context.resume(consumer: UUID())
        #expect(context.model.terminal == identity)
        context.draft = "continue working"
        await context.sendDraft(submit: true)
        #expect(await fixture.provider.connection.sent.joined().contains("continue working"))
        #expect(fixture.provider.created == 1)
        #expect(fixture.provider.closed == 0)
        await context.detach()
    }

    @Test func manualReconnectReplacesAnApparentlyLiveSocketWithoutRestartingTheHarness()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        let identity = try #require(context.model.terminal)
        await context.reconnect()
        #expect(fixture.provider.reconnected == [identity.terminalId])
        #expect(context.model.terminalState == .loaded)
        #expect(fixture.provider.created == 1)
        #expect(fixture.provider.closed == 0)
        await context.detach()
    }

    @Test func aLostConnectionRecoversAutomaticallyAndRelaunchKeepsTheSameProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        let identity = try #require(fixture.store.record(fixture.record.id)?.terminal)
        #expect(context.model.terminalState == .loaded)
        fixture.provider.statusFailure = true
        await fixture.provider.connection.drop()
        try await eventually { context.model.terminalState != .loaded }
        // A failed reachability check is never evidence that the process has ended.
        await context.open(allowRestart: false)
        #expect(fixture.provider.created == 1)
        #expect(fixture.store.record(fixture.record.id)?.terminal == identity)
        fixture.provider.statusFailure = false
        try await eventually { context.model.terminalState == .loaded }
        #expect(fixture.provider.reconnected == [identity.terminalId])
        #expect(fixture.provider.created == 1)
        await context.detach()
        let restored = SparkDevelopmentWorkspace(library: fixture.library, archiveURL: fixture.url)
        let saved = try #require(restored.record(fixture.record.id))
        let relaunched = SparkDevelopmentContext(
            record: saved,
            workspace: restored,
            provider: fixture.provider,
            engineeringEnabled: { true }
        )
        await relaunched.resume()
        #expect(relaunched.model.terminal?.terminalId == identity.terminalId)
        #expect(relaunched.model.terminalState == .loaded)
        #expect(fixture.provider.created == 1)
        #expect(fixture.provider.closed == 0)
        await relaunched.detach()
    }

    @Test func losingTheCreationResponseRetriesTheSameIdempotencyKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.provider.loseFirstCreationResponse = true
        let context = fixture.context()
        await context.resume()
        #expect(fixture.provider.created == 1)
        #expect(fixture.store.record(fixture.record.id)?.terminal == nil)
        try await eventually { context.model.terminalState == .loaded }
        #expect(fixture.provider.created == 1)
        #expect(Set(fixture.provider.creationKeys).count == 1)
        #expect(fixture.store.record(fixture.record.id)?.terminal != nil)
        await context.detach()
    }

    @Test func explicitEndStaysEndedWhenTheAppReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        await context.end()
        await context.detach()
        let restored = SparkDevelopmentWorkspace(library: fixture.library, archiveURL: fixture.url)
        let saved = try #require(restored.record(fixture.record.id))
        #expect(saved.automaticallyResume == false)
        let relaunched = SparkDevelopmentContext(
            record: saved,
            workspace: restored,
            provider: fixture.provider,
            engineeringEnabled: { true }
        )
        await relaunched.resume()
        #expect(relaunched.model.terminal == nil)
        #expect(fixture.provider.created == 1)
        #expect(fixture.provider.closed == 1)
        await relaunched.detach()
    }

    @Test func sendingADictatedDraftSubmitsOnlyOnExplicitSend() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        context.draft = "Build a weather app"
        #expect(await fixture.provider.connection.sent.isEmpty)
        await context.sendDraft(submit: true)
        #expect(await fixture.provider.connection.sent.joined() == "Build a weather app\r")
        #expect(context.draft.isEmpty)
        await context.detach()
    }

    @Test func anInsertFailureKeepsTheDraftForReviewAfterReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        context.draft = "Please explain the failing test"
        await fixture.provider.connection.drop()
        await context.sendDraft()
        #expect(context.draft == "Please explain the failing test")
        #expect(fixture.store.record(fixture.record.id)?.draft == context.draft)
        await context.detach()
    }

    @Test func returningToANaturallyEndedHarnessDoesNotLaunchAnotherProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        await context.resume()
        let original = try #require(context.record?.terminal)
        await context.detach()
        fixture.provider.sessionState = "stopped"
        await context.resume()
        #expect(fixture.provider.created == 1)
        #expect(context.record?.terminal == original)
        #expect(context.openError != nil)
        await context.detach()
    }

    @Test func movingBetweenPaneAndFullScreenKeepsOneRunningHarness() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = fixture.context()
        let pane = UUID(), fullScreen = UUID()
        await context.resume(consumer: pane)
        let identity = context.model.terminal?.terminalId
        await context.resume(consumer: fullScreen)
        await context.detach(consumer: pane)
        #expect(context.model.terminalState == .loaded)
        #expect(context.model.terminal?.terminalId == identity)
        #expect(fixture.provider.created == 1)
        #expect(fixture.provider.closed == 0)
        await context.resume(consumer: pane)
        await context.detach(consumer: fullScreen)
        #expect(context.model.terminalState == .loaded)
        #expect(fixture.provider.reconnected.isEmpty)
        await context.detach(consumer: pane)
        #expect(context.model.terminalState == .idle)
        #expect(fixture.provider.closed == 0)
    }

    @Test func thePickerOffersTheFourRequestedHarnessesAndRetainsLegacyDecoding() throws {
        #expect(SparkDevelopmentHarnessPicker.choices == [.ohMyPi, .openCode, .claudeCode, .codex])
        #expect(
            try JSONDecoder().decode(ProjectDevelopmentHarness.self, from: Data("\"pi\"".utf8))
                == .pi
        )
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }

    @MainActor
    private struct Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "development-recovery-\(UUID()).json"
        )
        let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
        let provider = RecoveryProvider()
        let record: SparkDevelopmentRecord
        let store: SparkDevelopmentWorkspace
        init() throws {
            record = SparkDevelopmentRecord(
                id: UUID(),
                targetID: "node:recovery",
                projectID: provider.project.id,
                projectName: "Recovery",
                sparkName: "Test Spark",
                selection: .init(harness: .ohMyPi, modelID: "test-model", clusterID: nil),
                launchKey: UUID(),
                terminal: nil,
                draft: ""
            )
            store = SparkDevelopmentWorkspace(library: library, archiveURL: url)
            store.update(record)
        }
        func context() -> SparkDevelopmentContext {
            SparkDevelopmentContext(
                record: record,
                workspace: store,
                provider: provider,
                engineeringEnabled: { true }
            )
        }
        func cleanUp() { try? FileManager.default.removeItem(at: url) }
    }
}

private actor RecoveryConnection: ProjectTerminalConnecting {
    private var dropped = false
    func drop() { dropped = true }
    func start() async throws {}
    private(set) var sent: [String] = []
    func send(_ text: String) async throws {
        if dropped { throw URLError(.networkConnectionLost) }
        sent.append(text)
    }
    func receive() async throws -> String {
        while !dropped { try await Task.sleep(for: .milliseconds(50)) }
        throw URLError(.networkConnectionLost)
    }
    func cancel() async { dropped = true }
}

@MainActor
private final class RecoveryProvider: SparkDevelopmentProviding {
    var developmentSelection: ProjectDevelopmentSelection?
    var developmentIdempotencyKey = UUID()
    var statusFailure = false
    var sessionState: String? = "running"
    var loseFirstCreationResponse = false
    var delayStatus = false
    var statusContinuation: CheckedContinuation<Void, Never>?
    func releaseStatus() {
        statusContinuation?.resume()
        statusContinuation = nil
    }
    var creationKeys: [UUID] = []
    var created = 0
    var closed = 0
    var reconnected: [String] = []
    var connection = RecoveryConnection()
    let project = GeneratedAPI.Project(
        id: "10000000-0000-4000-8000-000000000001",
        name: "Recovery",
        state: .ready,
        defaultBranch: "main",
        capabilities: [.read, .write, .terminal],
        createdAt: "2026-09-05T12:00:00Z",
        updatedAt: "2026-09-05T12:00:00Z"
    )
    private var identities: [UUID: GeneratedAPI.ProjectTerminal] = [:]
    func targets() async -> [ProjectTarget] {
        [
            .init(
                id: "node:recovery",
                name: "Test Spark",
                status: .available,
                permissions: .init(canWrite: true, canUseTerminal: true)
            )
        ]
    }
    func projects(targetID: String) async throws -> ProjectCollection {
        .init(items: [project], canCreate: true)
    }
    func createProject(targetID: String, name: String, repositoryURL: String?) async throws {
        throw URLError(.unsupportedURL)
    }
    func files(targetID: String, projectID: String) async throws -> [GeneratedAPI.ProjectFileEntry]
    { [] }
    func changes(targetID: String, projectID: String) async throws -> [GeneratedAPI.ProjectChange] {
        []
    }
    func file(targetID: String, projectID: String, path: String) async throws
        -> GeneratedAPI.ProjectFileContents
    { throw URLError(.unsupportedURL) }
    func saveFile(
        targetID: String,
        projectID: String,
        path: String,
        content: String,
        revision: String
    ) async throws -> ProjectFileSaveOutcome { throw URLError(.unsupportedURL) }
    func preview(targetID: String, projectID: String, port: Int, path: String) async throws
        -> String
    { throw URLError(.unsupportedURL) }
    func startAgent(targetID: String, projectID: String, task: String) async throws {
        throw URLError(.unsupportedURL)
    }
    func approve(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String?
    ) async throws -> GeneratedAPI.ProjectChange { throw URLError(.unsupportedURL) }
    func requestChanges(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String
    ) async throws -> GeneratedAPI.ProjectChange { throw URLError(.unsupportedURL) }
    func createTerminal(targetID: String, projectID: String, shell: ProjectTerminalShell)
        async throws -> (GeneratedAPI.ProjectTerminal, any ProjectTerminalConnecting)
    {
        creationKeys.append(developmentIdempotencyKey)
        if identities[developmentIdempotencyKey] == nil {
            created += 1
            identities[developmentIdempotencyKey] = .init(
                terminalId: UUID().uuidString.lowercased(),
                projectId: projectID,
                state: .running,
                createdAt: "2026-09-05T12:00:00Z"
            )
        }
        if loseFirstCreationResponse {
            loseFirstCreationResponse = false
            throw URLError(.networkConnectionLost)
        }
        connection = RecoveryConnection()
        return (identities[developmentIdempotencyKey]!, connection)
    }
    func developmentTerminalState(targetID: String, projectID: String, terminalID: String)
        async throws -> String?
    {
        if delayStatus { await withCheckedContinuation { statusContinuation = $0 } }
        if statusFailure { throw URLError(.notConnectedToInternet) }
        return sessionState
    }
    func reconnectTerminal(targetID: String, projectID: String, terminalID: String) async throws
        -> any ProjectTerminalConnecting
    {
        reconnected.append(terminalID)
        connection = RecoveryConnection()
        return connection
    }
    func closeTerminal(targetID: String, projectID: String, terminalID: String) async throws {
        closed += 1
    }
}

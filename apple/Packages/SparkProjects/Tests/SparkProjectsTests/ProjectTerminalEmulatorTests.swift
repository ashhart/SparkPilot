import Foundation
import Testing
@testable import SparkProjects

@MainActor
@Test func nativeTerminalInterpretsCursorErasureAndAlternateScreens() {
    let screen = ProjectTerminalScreen()
    screen.feed("old prompt\r\u{1b}[2Knew prompt")
    #expect(
        screen.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
            == "new prompt"
    )
    screen.feed("\u{1b}[?1049h\u{1b}[Hinside harness")
    #expect(
        screen.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
            == "inside harness"
    )
    screen.feed("\u{1b}[?1049l")
    #expect(
        screen.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
            == "new prompt"
    )
}
@Test func largeUnicodePastesAreChunkedWithoutSplittingScalarsOrLosingEscapeSequences() async {
    let source = "\u{1b}[200~" + String(repeating: "👩🏽‍💻東京", count: 1600) + "\u{1b}[201~"
    let pieces = await ProjectTerminalSession.inputChunks(source)
    #expect(pieces.count > 1)
    #expect(pieces.allSatisfy { $0.utf8.count <= 8192 })
    #expect(pieces.joined() == source)
}
@MainActor
@Test func detachingAPaneDoesNotDeleteItsRemoteTerminal() async throws {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login)
    let identity = try #require(model.terminal)
    await model.detachTerminal()
    #expect(model.terminal == identity)
    #expect(provider.closedTerminals.isEmpty)
    #expect(await provider.terminal.cancelled)
    await model.stopTerminal()
    #expect(provider.closedTerminals.count == 1)
}

@MainActor
@Test func durableLaunchRetainsItsRemoteIdentityWhenTheSignedSocketHandshakeFails() async throws {
    let provider = ProjectModelTestTestProvider()
    await provider.terminal.setFailsStart(true)
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login, durable: true)
    #expect(model.terminal != nil)
    #expect(provider.closedTerminals.isEmpty)
    if case .failed = model.terminalState {
    } else {
        Issue.record("Expected a visible connection failure")
    }
}

@MainActor
@Test func endingADurableSessionRetainsIdentityUntilTheServerConfirmsClose() async throws {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login, durable: true)
    let identity = try #require(model.terminal)
    provider.closeFailure = ProjectModelTestProjectTestError.unavailable
    await model.endDevelopmentTerminal()
    #expect(model.terminal == identity)
    provider.closeFailure = nil
    await model.endDevelopmentTerminal()
    #expect(model.terminal == nil)
}

@MainActor
@Test func aRelaunchedClientReattachesToTheArchivedTerminalWithoutCreatingOrClosingIt() async throws
{
    let provider = ProjectModelTestTestProvider()
    let first = ProjectsModel(provider: provider)
    await first.load()
    await first.openProject(ProjectModelTestFixtures.project)
    await first.startTerminal(shell: .login, durable: true)
    let saved = try #require(first.terminal)
    await first.detachTerminal()
    let relaunched = ProjectsModel(provider: provider)
    await relaunched.load()
    await relaunched.openProject(ProjectModelTestFixtures.project)
    await relaunched.reconnectTerminal(saved)
    #expect(relaunched.terminal == saved)
    #expect(relaunched.terminalState == .loaded)
    #expect(provider.closedTerminals.isEmpty)
    #expect(provider.reconnectedTerminals == ["node:1::\(saved.projectId)::\(saved.terminalId)"])
    await relaunched.detachTerminal()
}

@MainActor
@Test func explicitEndClosesACreationResponseThatArrivesLate() async throws {
    let provider = ProjectModelTestTestProvider()
    provider.delaysTerminalCreation = true
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    let opening = Task { await model.startTerminal(shell: .login, durable: true) }
    for _ in 0..<1000 where provider.terminalCreationContinuation == nil { await Task.yield() }
    #expect(provider.terminalCreationContinuation != nil)
    await model.endDevelopmentTerminal()
    provider.resumeTerminalCreation()
    await opening.value
    #expect(model.terminal == nil)
    #expect(provider.closedTerminals.count == 1)
}

@MainActor
@Test func terminalAppearanceChangesWithoutLosingItsScreenOrSession() {
    let screen = ProjectTerminalScreen()
    screen.feed("agent still running\r\n> ")
    let terminal = screen.view.getTerminal()
    let row = terminal.getLine(row: 0)?.translateToString(trimRight: true)
    screen.applyAppearance(.light)
    let lightBackground = screen.view.nativeBackgroundColor
    let lightForeground = screen.view.nativeForegroundColor
    screen.applyAppearance(.dark)
    #expect(screen.view.nativeBackgroundColor != lightBackground)
    #expect(screen.view.nativeForegroundColor != lightForeground)
    #expect(screen.view.getTerminal() === terminal)
    #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true) == row)
    screen.applyAppearance(.light)
    #expect(screen.view.nativeBackgroundColor == lightBackground)
    #expect(screen.view.nativeForegroundColor == lightForeground)
    #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true) == row)
}

@MainActor
@Test func endingSessionClearsTheEmulatorOnlyAfterConfirmedClose() async throws {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login, durable: true)
    let screen = model.terminalSession.screen
    screen.feed("OMP is running")
    provider.closeFailure = ProjectModelTestProjectTestError.unavailable
    await model.endDevelopmentTerminal()
    #expect(
        screen.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
            == "OMP is running"
    )
    provider.closeFailure = nil
    await model.endDevelopmentTerminal()
    #expect(model.terminal == nil)
    #expect(screen.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == "")
}

@MainActor
@Test func rotationKeepsTheLastRequestedTerminalSizeWhenEarlierResizeIsSlow() async throws {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login, durable: true)
    await provider.terminal.delayResize()
    let landscape = Task { await model.resizeTerminal(columns: 140, rows: 20) }
    for _ in 0..<1000 {
        if await provider.terminal.resizing { break }
        await Task.yield()
    }
    #expect(await provider.terminal.resizing)
    let portrait = Task { await model.resizeTerminal(columns: 45, rows: 55) }
    for _ in 0..<100 { await Task.yield() }
    await provider.terminal.releaseResize()
    await landscape.value
    await portrait.value
    #expect(await provider.terminal.resizes.last == .init(columns: 45, rows: 55))
    await model.detachTerminal()
}

@MainActor
@Test func failedResizeIsVisibleAndTheSameDimensionsCanBeRetried() async throws {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login, durable: true)
    await provider.terminal.failResize()
    await model.resizeTerminal(columns: 51, rows: 43)
    if case .failed = model.terminalState {} else { Issue.record("Resize failure was hidden") }
    await model.resizeTerminal(columns: 51, rows: 43)
    #expect(await provider.terminal.resizes.last == .init(columns: 51, rows: 43))
    await model.detachTerminal()
}

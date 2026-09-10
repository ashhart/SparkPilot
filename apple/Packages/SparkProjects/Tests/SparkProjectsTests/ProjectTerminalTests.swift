import Foundation
import SparkAPI
import Testing
@testable import SparkProjects

@MainActor
@Test func terminalOffersSelectableScreenReaderTextAndClosesTheSession() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)

    await model.startTerminal(shell: .login)
    for _ in 0..<20 where model.terminalTranscript.isEmpty { await Task.yield() }
    model.terminalDisplayMode = .accessibleText
    model.terminalInput = "pwd"
    await model.sendTerminalInput()

    #expect(model.terminalTranscript == "ready\n")
    #expect(model.terminalDisplayMode == .accessibleText)
    #expect(await provider.terminal.sent == ["pwd\n"])
    await model.stopTerminal()
    #expect(await provider.terminal.cancelled)
}

@MainActor
@Test func staleTerminalCreationIsClosedAgainstItsOrigin() async {
    let provider = ProjectModelTestTestProvider()
    provider.targetValues = [
        ProjectTarget(id: "node:1", name: "First", status: .available),
        ProjectTarget(id: "node:2", name: "Second", status: .available),
    ]
    provider.collectionsByTarget = [
        "node:1": ProjectCollection(items: [ProjectModelTestFixtures.project], canCreate: true),
        "node:2": ProjectCollection(
            items: [ProjectModelTestFixtures.secondProject],
            canCreate: true
        ),
    ]
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    provider.delaysTerminalCreation = true

    let start = Task { await model.startTerminal(shell: .login) }
    for _ in 0..<20 where provider.terminalCreationContinuation == nil { await Task.yield() }
    await model.selectTarget("node:2")
    provider.resumeTerminalCreation()
    await start.value

    #expect(model.terminal == nil)
    #expect(model.terminalState == .idle)
    #expect(await provider.terminal.cancelled)
    #expect(
        provider.closedTerminals
            == [
                "node:1::\(ProjectModelTestFixtures.project.id)::20000000-0000-4000-8000-000000000002"
            ]
    )
}

@Test func diffAccessibilityNamesTheFileHunksAdditionsAndRemovals() {
    #expect(
        ProjectAccessibility.diffSummary(ProjectModelTestFixtures.changedFile)
            == "Sources/App.swift, 1 additions, 1 removals, 1 hunks"
    )
    #expect(
        ProjectAccessibility.diffLine(ProjectModelTestFixtures.changedFile.hunks[0].lines[0])
            == "Removed: let answer = 41"
    )
}

@MainActor
@Test func terminalTranscriptBoundIsMeasuredInUTF8Bytes() {
    let transcript = String(repeating: "é", count: 600_000)
    let bounded = ProjectsModel.boundedTerminalTranscript(transcript)

    #expect(bounded.utf8.count <= 524_288)
    #expect(!bounded.contains("�"))
}

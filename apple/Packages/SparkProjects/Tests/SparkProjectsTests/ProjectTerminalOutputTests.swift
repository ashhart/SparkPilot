import CoreGraphics
import Testing

@testable import SparkProjects

@Test func colourEscapesAreStrippedFromTerminalOutput() {
    var sanitiser = ProjectTerminalSanitiser()
    let coloured = "\u{1B}[31mbuild failed\u{1B}[0m\n"
    #expect(sanitiser.append(coloured) == "build failed\n")
}

@Test func anEscapeSplitAcrossTwoFramesIsStillRemoved() {
    var sanitiser = ProjectTerminalSanitiser()
    var output = sanitiser.append("ok \u{1B}[1")
    output += sanitiser.append(";32mgreen\u{1B}[0m")
    #expect(output == "ok green")
}

@Test func anOperatingSystemCommandCannotRetitleTheWindow() {
    var sanitiser = ProjectTerminalSanitiser()
    let title = "\u{1B}]0;pretend prompt\u{07}$ real"
    #expect(sanitiser.append(title) == "$ real")
    var stTerminated = ProjectTerminalSanitiser()
    #expect(stTerminated.append("\u{1B}]8;;https://example.test\u{1B}\\link") == "link")
}

@Test func aRightToLeftOverrideCannotReverseWhatIsDisplayed() {
    var sanitiser = ProjectTerminalSanitiser()
    let spoofed = "rm -rf \u{202E}gpj.exe\u{202C}"
    #expect(sanitiser.append(spoofed) == "rm -rf gpj.exe")
    #expect(!ProjectTerminalSanitiser.isDisplayable("\u{200B}"))
    #expect(!ProjectTerminalSanitiser.isDisplayable("\u{FEFF}"))
}

@Test func carriageReturnsAndOtherControlBytesDoNotReachTheTranscript() {
    var sanitiser = ProjectTerminalSanitiser()
    #expect(sanitiser.append("one\r\ntwo\u{0007}\u{0000}\tthree") == "one\ntwo\tthree")
}

@Test func anUnterminatedEscapeCannotSwallowTheRestOfTheSession() {
    var sanitiser = ProjectTerminalSanitiser()
    let flood = "\u{1B}[" + String(repeating: "1", count: 5000)
    _ = sanitiser.append(flood)
    #expect(sanitiser.append("visible again") == "visible again")
}

@MainActor
@Test func aContainerCannotPaintAFakePromptInTheLiveTranscript() async {
    let provider = ProjectModelTestTestProvider()
    await provider.terminal.emit("\u{1B}[2J\u{1B}[H\u{1B}]0;spoof\u{07}rm -rf \u{202E}gpj.exe\n")
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)

    await model.startTerminal(shell: .login)
    for _ in 0..<50 where model.terminalTranscript.isEmpty { await Task.yield() }

    #expect(model.terminalTranscript == "rm -rf gpj.exe\n")
    await model.stopTerminal()
}

@Test func theCharacterGridFollowsTheRenderedSizeWithinTheRuntimesBounds() {
    let wide = ProjectTerminalGrid.size(of: CGSize(width: 1_000, height: 720))
    #expect(wide.columns == 125)
    #expect(wide.rows == 40)
    let tiny = ProjectTerminalGrid.size(of: CGSize(width: 40, height: 20))
    #expect(tiny.columns == 20, "never below the runtime's floor")
    #expect(tiny.rows == 5)
    let huge = ProjectTerminalGrid.size(of: CGSize(width: 100_000, height: 100_000))
    #expect(huge.columns == 500, "never above the runtime's clamp")
    #expect(huge.rows == 250)
}

@MainActor
@Test func aResizedTerminalTellsTheSparkOnceAndNotAgainForTheSameSize() async {
    let provider = ProjectModelTestTestProvider()
    let model = ProjectsModel(provider: provider)
    await model.load()
    await model.openProject(ProjectModelTestFixtures.project)
    await model.startTerminal(shell: .login)

    await model.resizeTerminal(columns: 100, rows: 30)
    await model.resizeTerminal(columns: 100, rows: 30)
    await model.resizeTerminal(columns: 120, rows: 30)

    #expect(
        Array(await provider.terminal.resizes.suffix(2)) == [
            ProjectTerminalGrid.Size(columns: 100, rows: 30),
            ProjectTerminalGrid.Size(columns: 120, rows: 30),
        ]
    )
    #expect(
        await provider.terminal.resizes.count == 3,
        "One initial grid followed by two distinct sizes"
    )
    await model.stopTerminal()
}

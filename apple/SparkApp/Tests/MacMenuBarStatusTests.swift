import Foundation
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// PLAN 41.3 gives the Mac a menu-bar status item, so it has to have something honest to say.
@MainActor
@Test func theMenuBarSaysHowManyOfThePairedSparksAnswer() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    var offline = activityTimelineTestEntry(name: "Study Spark", instant: instant)
    offline.connectionState = .offlineCached
    let status = MacMenuBarStatus.resolve(entries: [
        activityTimelineTestEntry(name: "Desk Spark", instant: instant), offline,
    ])

    #expect(status.summary == "1 of 2 reachable")
    #expect(status.sparks.count == 2)
    #expect(status.sparks[0].isReachable)
    #expect(!status.sparks[1].isReachable)
}

@MainActor
@Test func anEmptyLibrarySaysSoRatherThanShowingAnEmptyMenu() {
    let status = MacMenuBarStatus.resolve(entries: [])

    #expect(status.summary == "No Sparks paired")
    #expect(status.sparks.isEmpty)
    #expect(!status.needsAttention)
}

/// §51.1: the status item's symbol is never the only thing that says a Spark needs the owner.
@MainActor
@Test func aSparkThatNeedsTheOwnerIsWordedAsWellAsSymbolised() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    var mismatched = activityTimelineTestEntry(name: "Desk Spark", instant: instant)
    mismatched.connectionState = .identityMismatch
    let status = MacMenuBarStatus.resolve(entries: [mismatched])

    #expect(status.needsAttention)
    #expect(status.symbol == "exclamationmark.triangle.fill")
    #expect(status.sparks[0].state == "Identity changed")
    #expect(MacSparkMenuBarView.line(for: status.sparks[0]).contains("Identity changed"))
    #expect(MacSparkMenuBarView.line(for: status.sparks[0]).contains("Desk Spark"))
}

/// The scenes are compiled only by xcodebuild, so hold the app file to what 41.3 lists.
@Test func theMacAppDeclaresEveryScene41_3Requires() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let app = try String(
        contentsOf: appRoot.appending(path: "macOS/SparkMacApp.swift"),
        encoding: .utf8
    )
    let projects = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkProjectsComposition.swift"),
        encoding: .utf8
    )
    let action = try String(
        contentsOf: appRoot.appending(path: "Shared/SparkIntentActionView.swift"),
        encoding: .utf8
    )

    #expect(app.contains("MenuBarExtra"), "41.3: menu-bar status item")
    #expect(app.contains("MacSparkMenuBarView(library:"))
    #expect(app.contains("Window(String(localized: \"Ask Spark\")"), "41.3: Ask Spark window")
    #expect(app.contains("WindowGroup(id: MacSparkWindowID.project"), "41.3: project windows")
    #expect(app.contains(".commands { MacSparkCommands() }"), "41.3: global Ask Spark shortcut")
    #expect(projects.contains("openWindow("), "a project window has to be openable")
    #expect(action.contains("dropDestination(for: URL.self)"), "41.3: drag and drop from Finder")
}

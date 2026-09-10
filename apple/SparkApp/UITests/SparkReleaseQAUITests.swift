import XCTest

@MainActor
extension SparkUITests {
    func testReleaseAboutShowsBuildAndOpensFeedback() {
        openHelp()
        tap("About")
        for identifier in ["spark.about.version", "spark.about.build"] {
            let value = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(value.waitForExistence(timeout: 5))
            XCTAssertFalse(value.label.contains("Not available"))
            XCTAssertFalse(value.label.isEmpty)
        }
        XCTAssertTrue(app.buttons["spark.about.website"].isHittable)
        capture("release-about")
        tap("Feedback & bug reports")
        XCTAssertTrue(app.navigationBars["Feedback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["About"].isHittable)
    }

    func testReleaseChatSettingPersistsAndCanBeRestored() {
        openAppSettings()
        tap("Chat")
        let toggle = app.switches["Plain style (no em dashes, no filler)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        toggleReleaseSwitch(toggle)
        let changed = original == "1" ? "0" : "1"
        XCTAssertEqual(toggle.value as? String, changed)
        app.terminate()
        app.launch()
        openAppSettings()
        tap("Chat")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, changed)
        capture("release-chat-setting-persisted")
        toggleReleaseSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, original)
    }

    func testReleaseExecutionChoicesUpdateTheSettingsSummary() {
        openAppSettings()
        let label = "AI execution"
        func policyRow() -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        }
        let originalSummary = policyRow().label
        let choices = [
            "Any paired target", "My Sparks only", "My hardware only", "On this device only",
        ]
        let original = choices.first { originalSummary.contains($0) } ?? choices[0]
        for choice in choices + [original] {
            policyRow().tap()
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", choice))
                .firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            capture("release-execution-\(choice)")
            app.navigationBars.buttons["Settings"].tap()
            XCTAssertTrue(policyRow().waitForExistence(timeout: 5))
            XCTAssertTrue(policyRow().label.contains(choice))
        }
    }

    func testReleaseSpotlightCanBeEnabledAndDisabled() {
        openAppSettings()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Spotlight"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let toggle = app.switches["Show Sparks and models in Spotlight"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        toggleReleaseSwitch(toggle)
        let changed = original == "1" ? "0" : "1"
        expectReleaseSwitch(toggle, changed)
        capture("release-spotlight-setting")
        toggleReleaseSwitch(toggle)
        expectReleaseSwitch(toggle, original ?? "0")
    }

    func testReleaseChatHistoryRenameAndDelete() {
        familyPreview()
        tap("Restore six messages")
        tap("Chat history")
        let original = app.cells.containing(.staticText, identifier: "Saved conversation")
            .firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.swipeLeft()
        tap("Rename")
        let name = app.alerts.textFields["Chat name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Saved conversation".count)
        )
        name.typeText("QA renamed chat")
        app.alerts.buttons["Save"].tap()
        let renamed = app.cells.containing(.staticText, identifier: "QA renamed chat").firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        capture("release-chat-renamed")
        renamed.swipeLeft()
        tap("Delete")
        let confirmation = app.alerts["Delete this chat?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        capture("release-chat-delete-confirmation")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(renamed.exists)
        renamed.swipeLeft()
        tap("Delete")
        confirmation.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete"))
            .firstMatch.tap()
        XCTAssertFalse(renamed.exists)
        XCTAssertTrue(app.buttons["Chat history"].waitForExistence(timeout: 5))
    }

    func testReleaseIPadSidebarCanLeaveNestedSettings() throws {
        try XCTSkipUnless(isPad, "The iPhone keeps independent tab navigation stacks")
        openAppSettings()
        tap("Chat")
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 5))
        sidebar("home").tap()
        XCTAssertTrue(app.staticTexts["Fleet Overview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Chat"].exists)
        capture("release-sidebar-leaves-nested-settings")
        sidebar("settings").tap()
        XCTAssertTrue(app.buttons["Siri & Apple Apps"].waitForExistence(timeout: 5))
    }

    func testReleaseRepeatedLaunchReachesInteractiveHome() {
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options)
        {
            app.launch()
            XCTAssertTrue(
                (isPad ? sidebar("home") : app.tabBars.buttons["Home"]).waitForExistence(
                    timeout: 10
                )
            )
        }
    }

    private func openAppSettings() {
        openHelp()
        if !isPad { tap("Settings") }
    }

    private func toggleReleaseSwitch(_ toggle: XCUIElement) {
        // SwiftUI exposes the entire labelled row as a switch; tap its trailing control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -40, dy: 0)).tap()
    }

    private func expectReleaseSwitch(_ toggle: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ AND enabled == true", value),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }
}

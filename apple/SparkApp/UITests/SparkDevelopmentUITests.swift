import XCTest

@MainActor
extension SparkUITests {
    func testTerminalKeyboardButtonOpensWithoutTappingTheTerminal() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        let keyboardButton = app.buttons.matching(
            NSPredicate(format: "label MATCHES '(Show|Hide) Keyboard'")
        ).firstMatch
        let keyboard = app.keyboards.firstMatch
        func expectKeyboard(visible: Bool) {
            let predicate = NSPredicate { _, _ in
                (keyboard.exists && keyboard.isHittable) == visible
            }
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                    timeout: 5
                ),
                .completed,
                "The software keyboard must be \(visible ? "visible" : "hidden")"
            )
        }
        XCTAssertTrue(keyboardButton.waitForExistence(timeout: 10))
        expectKeyboard(visible: false)
        keyboardButton.tap()
        expectKeyboard(visible: true)
        capture("terminal-keyboard-open")
        keyboardButton.tap()
        expectKeyboard(visible: false)
        keyboardButton.tap()
        expectKeyboard(visible: true)
        XCTAssertEqual(keyboardButton.label, "Hide Keyboard")
        XCUIDevice.shared.orientation = isPad ? .portrait : .landscapeLeft
        expectKeyboard(visible: true)
        XCTAssertTrue(keyboardButton.isHittable)
        capture("terminal-keyboard-reopened")
    }

    func testProjectToolsUseOneNavigationBarAndDeletionRequiresConfirmation() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        tap("Project Tools")
        let projectRow = app.cells.containing(.staticText, identifier: "Sample project").firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 8))
        projectRow.tap()
        XCTAssertTrue(app.scrollViews["spark.project.tools"].waitForExistence(timeout: 8))
        if !isPad { XCTAssertEqual(app.tabBars.count, 1) }
        for title in ["Changes", "Terminal", "Preview", "Files"] {
            let tools = app.scrollViews["spark.project.tools"]
            let button = tools.buttons[title]
            if !button.isHittable { tools.swipeLeft() }
            if !button.isHittable { tools.swipeRight() }
            XCTAssertTrue(button.isHittable)
            button.tap()
        }
        capture("project-tools-single-navigation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.cells.containing(.staticText, identifier: "Sample project").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        let confirmation = app.alerts["Delete project from Spark?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            confirmation.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'cannot be undone' ")
            ).firstMatch.exists
        )
        capture("project-delete-confirmation")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        row.swipeLeft()
        app.buttons["Delete"].tap()
        confirmation.buttons["Delete Project"].tap()
        XCTAssertTrue(app.staticTexts["No projects"].waitForExistence(timeout: 8))
        capture("project-deleted")
    }

    func testDevelopmentRotationReconnectAndClosedTabCanResume() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.waitForExistence(timeout: 10))
        for orientation: UIDeviceOrientation in [
            .landscapeLeft, .portrait, .landscapeRight, .portrait,
        ] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(
                app.buttons["spark.terminal.return"].firstMatch.waitForExistence(timeout: 8)
            )
            XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.isHittable)
        }
        tap("Workspace actions")
        tap("Reconnect")
        XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["Close tab"].firstMatch.tap()
        tap("Saved workspaces")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Weather app' ")).firstMatch.tap()
        XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["Open Session"].exists)
        capture("development-rotated-and-reconnected")
    }

    func testDevelopmentIsOptionalOnPhoneAndPad() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "NO"]
        app.launch()
        openHelp()
        if isPad {
            XCTAssertFalse(sidebar("projects").exists)
            XCTAssertTrue(app.switches["spark.engineeringMode.toggle"].exists)
        } else {
            XCTAssertFalse(app.buttons["Develop"].exists)
            tap("Settings")
            XCTAssertTrue(app.switches["spark.engineeringMode.toggle"].exists)
        }
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "--spark-sample-fleet=running",
            "-spark.engineeringMode.enabled", "YES",
        ]
        app.launch()
        if isPad {
            sidebar("projects").tap()
        } else {
            app.tabBars.buttons["Develop"].tap()
        }
        XCTAssertTrue(app.staticTexts["A place to build"].waitForExistence(timeout: 8))
        capture("development-opt-in")
    }

    func testEngineeringModeReplacesActivityTabAndKeepsItsTimelineInMore() throws {
        try XCTSkipIf(isPad)
        app.terminate()
        app.launch()
        openHelp()
        tap("Settings")
        let toggle = app.switches["spark.engineeringMode.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        if toggle.value as? String == "1" { toggle.tap() }
        XCTAssertTrue(app.tabBars.buttons["Activity"].waitForExistence(timeout: 8))
        toggle.tap()
        XCTAssertTrue(app.tabBars.buttons["Develop"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.buttons["Activity"].exists)
        app.tabBars.buttons["Develop"].tap()
        XCTAssertTrue(app.staticTexts["A place to build"].waitForExistence(timeout: 8))
        capture("develop-main-tab")
        openHelp()
        if app.navigationBars.buttons["More"].exists { app.navigationBars.buttons["More"].tap() }
        tap("Activity")
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 8))
        capture("engineering-activity-in-more")
        app.navigationBars.buttons["More"].tap()
        tap("Settings")
        toggle.tap()
        XCTAssertTrue(app.tabBars.buttons["Activity"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.buttons["Develop"].exists)
    }

    func testHarnessChoicesDefaultToOhMyPi() {
        familyPreview()
        tap("Harness choices")
        let picker = app.buttons["spark.development.harness"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Oh My Pi · Default"].exists)
        picker.tap()
        for name in ["Oh My Pi · Default", "OpenCode", "Claude Code", "Codex"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.buttons["Pi"].exists)
        tap("Codex")
        capture("harness-chooser-codex")
    }

    func testHarnessFullScreenRestoresTheSplitLayout() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        XCTAssertTrue(
            app.buttons.matching(identifier: "Full screen").firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.textFields["Workspace message draft"].exists)
        if isPad {
            tap("Split workspace")
            tap("Personal website")
            XCTAssertEqual(app.buttons.matching(identifier: "Full screen").count, 2)
        }
        for _ in 0..<2 {
            app.buttons.matching(identifier: "Full screen").allElementsBoundByIndex.last!.tap()
            XCTAssertTrue(app.buttons["Restore layout"].waitForExistence(timeout: 8))
            XCTAssertFalse(app.tabBars.firstMatch.isHittable)
            XCTAssertFalse(app.textFields["Workspace message draft"].exists)
            capture("harness-full-screen")
            tap("Restore layout")
            XCTAssertTrue(
                app.buttons.matching(identifier: "Full screen").firstMatch.waitForExistence(
                    timeout: 8
                )
            )
            XCTAssertEqual(app.buttons.matching(identifier: "Full screen").count, isPad ? 2 : 1)
            let returns = app.buttons.matching(identifier: "spark.terminal.return")
            XCTAssertEqual(returns.count, isPad ? 2 : 1)
            for key in returns.allElementsBoundByIndex {
                XCTAssertTrue(key.isHittable)
                XCTAssertLessThanOrEqual(key.frame.maxX, app.frame.maxX)
            }
        }
        capture("harness-restored-layout")
        app.buttons["Workspace actions"].firstMatch.tap()
        let end = app.buttons["End Session"]
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        end.tap()
        XCTAssertTrue(app.alerts["End this harness session?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
    }

    func testEndedWorkspaceClearsTerminalAndRequiresExplicitRestart() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        XCTAssertTrue(app.buttons["Dictate message"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["More terminal keys"].firstMatch.exists)
        tap("Workspace actions")
        tap("End Session")
        app.alerts.buttons["End Session"].tap()
        XCTAssertTrue(app.staticTexts["Session ended"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Open Session"].exists)
        XCTAssertFalse(app.buttons["spark.terminal.return"].isEnabled)
        capture("ended-workspace")
        tap("Open Session")
        XCTAssertTrue(app.buttons["spark.terminal.return"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Session ended"].exists)
    }

    func testDevelopmentPanesKeepDraftsSeparateAndExposeFiles() {
        app.terminate()
        app.launchArguments += ["-spark.engineeringMode.enabled", "YES"]
        app.launch()
        openHelp()
        tap("Development preview")
        tap("Workspace actions")
        tap("Dictate or paste")
        let drafts = app.textFields.matching(identifier: "Workspace message draft")
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 10))
        drafts.firstMatch.tap()
        drafts.firstMatch.typeText("First project draft")
        capture("development-keyboard")
        tap("Hide Keyboard")
        tap("Personal website")
        tap("Workspace actions")
        tap("Dictate or paste")
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(drafts.firstMatch.value as? String, "")
        drafts.firstMatch.tap()
        drafts.firstMatch.typeText("Second project draft")
        tap("Hide Keyboard")
        tap("Weather app")
        XCTAssertTrue(drafts.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(drafts.firstMatch.value as? String, "First project draft")
        if isPad {
            tap("Split workspace")
            tap("Personal website")
            if drafts.count != 2 {
                app.buttons.matching(identifier: "Workspace actions").allElementsBoundByIndex.last!
                    .tap()
                tap("Dictate or paste")
            }
            XCTAssertEqual(drafts.count, 2)
            let values = Set(drafts.allElementsBoundByIndex.compactMap { $0.value as? String })
            XCTAssertEqual(values, ["First project draft", "Second project draft"])
        }
        XCTAssertTrue(app.buttons["spark.terminal.return"].firstMatch.isHittable)
        capture("development-panes")
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Workspace Files"].waitForExistence(timeout: 8))
        capture("development-files")
    }
}

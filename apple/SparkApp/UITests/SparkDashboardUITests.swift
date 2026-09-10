import UIKit
import XCTest

@MainActor
final class SparkDashboardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        XCUIDevice.shared.orientation =
            UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "--spark-sample-fleet=running",
        ]
        app.launch()
    }

    override func tearDownWithError() throws { app.terminate() }

    func testSingleSparkDashboardCustomizationSurvivesRelaunch() {
        customize()
        app.buttons["Reset to Default Layout"].tap()
        let memory = app.switches["spark.dashboard.toggle.fleetMemory"]
        XCTAssertTrue(memory.waitForExistence(timeout: 5))
        memory.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertEqual(memory.value as? String, "0")
        app.buttons["Done"].tap()
        capture("single-spark-custom-dashboard")
        app.terminate()
        app.launch()
        customize()
        XCTAssertEqual(app.switches["spark.dashboard.toggle.fleetMemory"].value as? String, "0")
        XCTAssertTrue(app.switches["spark.dashboard.toggle.runningInference"].exists)
        XCTAssertTrue(app.switches["spark.dashboard.toggle.temperatures"].exists)
        app.buttons["Reset to Default Layout"].tap()
        XCTAssertEqual(app.switches["spark.dashboard.toggle.fleetMemory"].value as? String, "1")
        app.buttons["Done"].tap()
        capture("single-spark-dashboard-restored")
    }

    func testFleetOverviewPullToRefreshKeepsLayoutStable() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let heading = app.staticTexts["Fleet Overview"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let initial = heading.frame
        let scroll = app.scrollViews.containing(.staticText, identifier: "Fleet Overview")
            .firstMatch
        XCTAssertTrue(scroll.exists)
        capture("fleet-before-pull")
        for _ in 0..<3 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.3))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.65))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 80, thenHoldForDuration: 2)
            XCTAssertEqual(heading.frame.minX, initial.minX, accuracy: 1)
            XCTAssertEqual(heading.frame.width, initial.width, accuracy: 1)
        }
        capture("fleet-after-pull")
    }

    func testSparkCardOpensManagementInsteadOfAnInspector() {
        let card = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "spark.fleet.open.")
        ).firstMatch
        for _ in 0..<8 where !card.exists || !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.exists, "The Spark card's name must be an actionable management link")
        card.tap()
        // Unpaired samples must enter the connection flow and show its failure.
        XCTAssertTrue(app.otherElements["saved-spark-open-failure"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Choose Details on a card to inspect its evidence."].exists)
        capture("fleet-open-management-connection-feedback")
    }

    private func customize() {
        let options = app.buttons["spark.dashboard.options"]
        XCTAssertTrue(
            options.waitForExistence(timeout: 15),
            "A single Spark must keep its dashboard controls"
        )
        for _ in 0..<5 where !options.isHittable { app.swipeDown() }
        options.tap()
        XCTAssertTrue(app.navigationBars["Customize Overview"].waitForExistence(timeout: 5))
        capture("dashboard-card-customization")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

// Pairing starts from Home on both phone and tablet.
extension SparkUITests {
    func testSparkOverviewOffersSwitchModelWithoutDuplicateChatAction() {
        familyPreview()
        tap("Spark overview preview")
        let switchModel = app.buttons["spark.dashboard.switch-model"]
        XCTAssertTrue(switchModel.waitForExistence(timeout: 10))
        XCTAssertTrue(switchModel.isHittable)
        XCTAssertGreaterThanOrEqual(switchModel.frame.height, 44)
        XCTAssertFalse(app.buttons["Ask your Spark"].exists)
        capture("spark-overview-switch-model")
        switchModel.tap()
        XCTAssertTrue(app.navigationBars["Launch model"].waitForExistence(timeout: 10))
        capture("spark-overview-model-picker")
    }

    func testUnloadTimeCanBeNeverOrCustomInLaunchConfiguration() {
        familyPreview()
        tap("Launch a saved preset")
        let idle = app.buttons["spark.model.unload-time"]
        for _ in 0..<5 where !idle.isHittable { app.swipeUp() }
        XCTAssertTrue(idle.waitForExistence(timeout: 8))
        idle.tap()
        tap("Never unload")
        XCTAssertTrue(
            idle.label.contains("Never unload")
                || (idle.value as? String)?.contains("Never unload") == true
        )
        capture("model-never-unload")
        idle.tap()
        tap("Custom time")
        let minutes = app.textFields["spark.model.unload-minutes"]
        for _ in 0..<5 where !minutes.isHittable { app.swipeUp() }
        XCTAssertTrue(minutes.waitForExistence(timeout: 8))
        minutes.doubleTap()
        minutes.typeText("42")
        XCTAssertEqual(minutes.value as? String, "42")
        let form = app.collectionViews.containing(
            .textField,
            identifier: "spark.model.unload-minutes"
        ).firstMatch
        let save = app.buttons["spark.model.unload-save"]
        let launch = app.buttons["spark.model.launch.preset"]
        // Drag inside the visible sheet body, above its keyboard and pinned launch action.
        for _ in 0..<5 {
            let top = app.navigationBars["Launch model"].frame.maxY + 12
            let bottom = launch.frame.minY - 12
            if save.exists, save.isHittable,
                save.frame.minY >= top, save.frame.maxY <= bottom
            {
                break
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: form.frame.midX, dy: bottom - 12))
            let end = origin.withOffset(CGVector(dx: form.frame.midX, dy: top + 12))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 8))
        capture("model-custom-unload")
        app.buttons["spark.model.launch.preset"].tap()
        XCTAssertTrue(app.buttons["spark.model.launch.chat"].waitForExistence(timeout: 15))
    }

    func testUnpairedSetupOffersNewOrExistingSparkAndKeepsPairingSeparate() {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "--spark-sample-fleet=0",
        ]
        app.launch()
        if isPad {
            XCTAssertFalse(sidebar("models").exists)
            XCTAssertFalse(sidebar("clusters").exists)
            XCTAssertFalse(sidebar("automations").exists)
            XCTAssertTrue(sidebar("settings").exists)
        }
        tap(isPad ? "Add a Spark" : "Add Spark")
        XCTAssertTrue(app.buttons["Set Up a New Spark"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["spark.setup.existing"].exists)
        XCTAssertFalse(app.buttons["Pair with QR"].exists)
        capture("setup-new-or-existing")
        tap("Already using SparkPilot? Pair this device")
        XCTAssertTrue(app.buttons["Pair with QR"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["IP address or hostname"].exists)
        XCTAssertFalse(app.staticTexts["No Sparks found yet"].exists)
        XCTAssertFalse(app.buttons["Pair Several Sparks"].exists)
        capture("setup-qr-first")
        tap("Back")
        XCTAssertTrue(app.buttons["spark.setup.existing"].waitForExistence(timeout: 8))
        tap("Already using SparkPilot? Pair this device")
        tap("Use a six-digit code")
        XCTAssertTrue(
            app.staticTexts["Connect to the same network as your Spark, then choose it below."]
                .waitForExistence(timeout: 8)
        )
        tap("Enter an address manually")
        XCTAssertTrue(app.textFields["IP address or hostname"].waitForExistence(timeout: 8))
        capture("setup-manual-disclosure")
        app.textFields["IP address or hostname"].tap()
        app.textFields["IP address or hostname"].typeText("192.0.2.10")
        tap("Continue with This Spark")
        XCTAssertTrue(app.textFields["6-digit join code"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["Spark fingerprint from owner device"].exists)
        XCTAssertFalse(app.buttons["Join This Spark"].isEnabled)
        capture("pairing-qr-and-code-no-fingerprint")
    }

    func testExistingSparkSetupIsVisibleAndManualAddressReachesInspection() {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "--spark-sample-fleet=0",
        ]
        app.launch()
        tap(isPad ? "Add a Spark" : "Add Spark")
        tap("Set up a Spark already in use")
        let address = app.textFields["IP address or hostname"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        let check = app.buttons["Check This Spark"]
        for _ in 0..<4 where !check.isHittable { app.swipeUp() }
        XCTAssertFalse(check.isEnabled)
        capture("existing-spark-runtime-included")
        address.tap()
        address.typeText("192.0.2.10")
        for _ in 0..<4 where !check.isHittable { app.swipeUp() }
        check.tap()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["6-digit join code"].exists)
        capture("existing-spark-admin-inspection")
    }

    func testManualSetupExplainsPasswordRequirementsAndCanBeCancelled() {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        tap(isPad ? "Add a Spark" : "Add Spark")
        tap("Set Up a New Spark")
        tap("Enter details manually")
        // Bring the fields above the pinned actions before the keyboard reduces the viewport.
        app.scrollViews.firstMatch.swipeUp()
        let network = app.textFields["Spark Wi-Fi name"]
        for _ in 0..<4 where !network.isHittable { app.swipeUp() }
        XCTAssertTrue(network.waitForExistence(timeout: 8))
        network.tap()
        network.typeText("spark-abcd")
        let password = app.secureTextFields["Wi-Fi password"]
        let join = app.buttons["Join Spark"]
        for _ in 0..<3 where password.frame.maxY >= join.frame.minY {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: join.frame.minY - 20))
            let end = origin.withOffset(
                CGVector(dx: app.frame.midX, dy: app.navigationBars.firstMatch.frame.maxY + 30)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertLessThan(
            password.frame.maxY,
            join.frame.minY,
            "The actions cover the password field"
        )
        password.tap()
        password.typeText("123")
        XCTAssertFalse(app.buttons["Join Spark"].isEnabled)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "at least 8"))
                .firstMatch.exists
        )
        password.typeText("45678")
        XCTAssertTrue(app.buttons["Join Spark"].isEnabled)
        capture("manual-setup-ready-with-synthetic-details")
        tap("Cancel")
        XCTAssertTrue(app.navigationBars["Add Spark"].waitForExistence(timeout: 8))
    }
}

/// Optional hardware check attaches to the installed app without changing its saved Spark data.
@MainActor
final class SparkInstalledDashboardUITests: XCTestCase {
    func testInstalledFleetPullToRefresh() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPARK_INSTALLED_QA"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.sparkfabric.Spark")
        app.launch()
        let home = app.descendants(matching: .any)["spark.sidebar.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        home.tap()
        let heading = app.staticTexts["Fleet Overview"]
        XCTAssertTrue(heading.waitForExistence(timeout: 15))
        let scroll = app.scrollViews.containing(.staticText, identifier: "Fleet Overview")
            .firstMatch
        for i in 0..<3 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "installed-fleet-\(i)"
            shot.lifetime = .keepAlways
            add(shot)
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.65))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 80, thenHoldForDuration: 2)
        }
    }
}

extension SparkUITests {
    func testAutomationsCanChooseSparkWithoutOpeningDashboard() {
        if isPad {
            sidebar("automations").tap()
        } else {
            app.tabBars.buttons["More"].tap()
            tap("Automations")
        }
        let add = app.buttons["spark.automations.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.tap()
        XCTAssertTrue(app.navigationBars["Choose a Spark"].waitForExistence(timeout: 5))
        capture("automation-spark-picker")
        let target = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "spark.automations.pick.")
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.navigationBars["New automation"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Runs on"].exists)
        let name = app.textFields["spark.automation.name"]
        name.tap()
        name.typeText("Morning plan")
        let instructions = app.textFields["spark.automation.instructions"]
        XCTAssertTrue(instructions.exists)
        instructions.tap()
        instructions.typeText("Suggest three things to learn today.")
        capture("automation-editor-with-spark")
        let save = app.buttons["spark.automation.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Morning plan"].waitForExistence(timeout: 8))
        capture("automation-created-on-chosen-spark")
    }

}

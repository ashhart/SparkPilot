import XCTest
import UIKit

/// These tests operate real SwiftUI screens with the app's explicitly labelled, in-memory sample data.
@MainActor
final class SparkUITests: XCTestCase {
    var app: XCUIApplication!
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_GB", "--spark-sample-fleet=running",
        ]
        app.launch()
        XCTAssertTrue(
            (isPad ? sidebar("home") : app.tabBars.firstMatch).waitForExistence(timeout: 15)
        )
    }

    override func tearDownWithError() throws { app.terminate() }

    func tap(_ label: String) {
        let button = app.buttons[label].firstMatch
        for _ in 0..<6 {
            if button.waitForExistence(timeout: 1), button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing control: \(label)")
        button.tap()
    }

    func familyPreview() {
        openHelp()
        tap("Family flow preview")
    }

    func sidebar(_ id: String) -> XCUIElement {
        // Activate the row because SwiftUI repeats the identifier on its decorative image.
        app.cells.containing(.any, identifier: "spark.sidebar.\(id)").firstMatch
    }

    func openHelp() {
        if isPad {
            sidebar("settings").tap()
        } else {
            app.tabBars.buttons["More"].tap()
        }
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func visibleTranscript(containing text: String) {
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 8), "Restored text never appeared")
        let transcript = app.scrollViews["spark.chat.transcript"].firstMatch
        XCTAssertTrue(transcript.exists)
        XCTAssertGreaterThan(
            message.frame.intersection(transcript.frame).height,
            20,
            "The restored conversation is outside the visible transcript before any gesture"
        )
    }

    func testActivityUsesTheOperationTimelineOnPhoneAndPad() {
        if isPad {
            sidebar("activity").tap()
            XCTAssertTrue(app.buttons["Compare workloads"].waitForExistence(timeout: 8))
        } else {
            app.tabBars.buttons["Activity"].tap()
        }
        capture("activity-operation-timeline")
        XCTAssertFalse(app.navigationBars["Workloads"].exists)
    }

    func testChatExplainsWhenPhotosAreNotSupported() {
        familyPreview()
        tap("New conversation")
        let draft = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        draft.tap()
        draft.typeText("Keep my question")
        tap("Chat tools")
        let photos = app.buttons["Photo library"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        XCTAssertTrue(app.alerts["Images unavailable for this model"].waitForExistence(timeout: 5))
        capture("chat-photos-unsupported-model")
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(draft.value as? String, "Keep my question")
        tap("Chat tools")
        XCTAssertTrue(app.buttons["Attach files"].isEnabled)
    }

    func testChatCanAttachAndSendAPhotoFromTheLibrary() {
        familyPreview()
        tap("Conversation with photo support")
        let composer = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        composer.tap()
        composer.typeText("Describe this photo")
        tap("Chat tools")
        tap("Photo library")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        capture("chat-photo-library-picker")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Describe this photo")
        chooseLibraryPhoto()
        let remove = app.buttons["Remove attachment"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["This model can read your photos."].exists)
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
        capture("chat-library-photo-ready")
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        chooseLibraryPhoto()
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        tap("Send message")
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Photo.jpg"].waitForExistence(timeout: 8))
        capture("chat-library-photo-sent")
    }

    private func chooseLibraryPhoto() {
        tap("Chat tools")
        tap("Photo library")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,"))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        // The system's visible Photos thumbnail sometimes reports no accessibility hit point on iPhone.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Done"].tap()
    }

    func testSetupOffersWebAccessAndAllowsSkippingIt() {
        familyPreview()
        tap("Web access during setup")
        XCTAssertTrue(app.buttons["Enable web access"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Not now"].exists)
        capture("onboarding-web-choice")
        tap("Not now")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Setup finished"].waitForExistence(timeout: 8))
        tap("Web access during setup")
        tap("Enable web access")
        XCTAssertTrue(app.staticTexts["Setup finished"].waitForExistence(timeout: 8))
    }

    func testLaunchPresetShowsConfigurationAndProgress() {
        familyPreview()
        tap("Launch a saved preset")
        let launch = app.buttons["spark.model.launch.preset"]
        XCTAssertTrue(launch.waitForExistence(timeout: 8))
        capture("model-preset-before-launch")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Agent 64K"))
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertTrue(launch.isEnabled)
        let thinking = app.buttons["spark.model.thinking-budget"]
        for _ in 0..<3 where !thinking.exists { app.swipeUp() }
        XCTAssertTrue(thinking.exists)
        for _ in 0..<3 where thinking.frame.maxY >= launch.frame.minY { app.swipeUp() }
        XCTAssertTrue(thinking.isEnabled)
        thinking.tap()
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 5))
        app.buttons["Off"].tap()
        capture("model-preset-configuration")
        let context = app.staticTexts["Context tokens"]
        for _ in 0..<4 where !context.exists { app.swipeUp() }
        XCTAssertTrue(context.exists)
        launch.tap()
        let progress = app.descendants(matching: .any)["spark.model.launch.progress"].firstMatch
        for _ in 0..<3 where !progress.exists { app.swipeUp() }
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertTrue((progress.value as? String)?.contains("%") == true)
        capture("model-preset-progress")
        XCTAssertTrue(
            app.staticTexts["Waiting for a successful response before showing the model as ready."]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["spark.model.launch.chat"].waitForExistence(timeout: 15))
        capture("model-ready-chat-action")
        XCTAssertFalse(app.buttons["spark.model.launch.preset"].exists)
    }

    func testPresetTipStaysDismissedAfterRelaunch() {
        // Reset through the debug preview; launch-argument defaults would pin the value during dismissal.
        familyPreview()
        tap("Reset preview tips")
        tap("Launch a saved preset")
        let dismissTip = app.buttons["spark.tip.launchPreset.dismiss"]
        XCTAssertTrue(dismissTip.waitForExistence(timeout: 8))
        capture("preset-tip-visible")
        dismissTip.tap()
        XCTAssertTrue(dismissTip.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        familyPreview()
        tap("Launch a saved preset")
        XCTAssertTrue(app.buttons["spark.model.launch.preset"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["spark.tip.launchPreset.dismiss"].exists)
        capture("preset-tip-dismissed-after-relaunch")
    }

    func testSetupNameIsOptionalAndDoesNotBlockFirstModel() {
        familyPreview()
        tap("Setup finishing touches")
        XCTAssertFalse(app.textFields["spark.setup.name"].exists)
        tap("Optional: name your Spark")
        let name = app.textFields["spark.setup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Family Spark")
        XCTAssertEqual(name.value as? String, "Family Spark")
        capture("optional-setup-name")
        tap("Choose your first model")
        XCTAssertTrue(app.staticTexts["Setup preview finished"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("Setup finishing touches")
        tap("Choose your first model")
        XCTAssertTrue(app.staticTexts["Setup preview finished"].waitForExistence(timeout: 5))
    }

    func testRestoredChatsAppearWithoutAFlickOrReload() {
        familyPreview()
        for iteration in 0..<4 {
            tap("Restore 80 messages")
            visibleTranscript(containing: "a short part of a saved family planning conversation")
            capture("restored-80-messages-\(iteration)")
            app.scrollViews["spark.chat.transcript"].swipeUp()
            capture("restored-chat-after-scroll-\(iteration)")
            tap("Close preview")
            tap("Restore a long reply")
            visibleTranscript(containing: "Start with one small task")
            capture("restored-long-reply-\(iteration)")
            tap("Close preview")
        }
    }

    func testStreamingAndRetryKeepTheConversationVisible() {
        familyPreview()
        tap("Retry after connection loss")
        let composer = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Please plan three family meals.")
        tap("Send message")
        tap("Retry last message")
        let reply = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "sample reply for checking the app")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        capture("chat-retry-streaming")
        tap("Close preview")
    }

    func testOlderReplyActionsStayHiddenUntilTapped() {
        familyPreview()
        tap("Restore six messages")
        let first = sampleReply(2)
        let second = sampleReply(4)
        let latest = sampleReply(6)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        capture("reply-actions-before-interaction")
        XCTAssertFalse(first.buttons["Read aloud"].exists)
        XCTAssertFalse(second.buttons["Read aloud"].exists)
        XCTAssertTrue(latest.buttons["Read aloud"].exists)
        first.staticTexts.firstMatch.tap()
        XCTAssertTrue(first.buttons["Read aloud"].waitForExistence(timeout: 3))
        XCTAssertTrue(first.buttons["Share response"].exists)
        first.buttons["Copy response"].tap()
        XCTAssertTrue(first.buttons["Copied"].waitForExistence(timeout: 2))
        second.staticTexts.firstMatch.tap()
        XCTAssertTrue(second.buttons["Read aloud"].waitForExistence(timeout: 3))
        XCTAssertFalse(first.buttons["Read aloud"].exists)
        capture("older-reply-actions-revealed")
        // UIKit can report obscured text as hittable; bring the last reply above the composer first.
        app.scrollViews["spark.chat.transcript"].swipeUp()
        latest.staticTexts.firstMatch.tap()
        XCTAssertTrue(second.buttons["Read aloud"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(latest.buttons["Read aloud"].exists)
    }

    func testChatCanSetUpWebAccessWithoutLeavingTheConversation() {
        familyPreview()
        tap("New conversation")
        tap("Chat tools")
        let setup = app.buttons["Set up web access"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        XCTAssertTrue(setup.isEnabled)
        setup.tap()
        XCTAssertTrue(app.buttons["Enable web access"].waitForExistence(timeout: 5))
        capture("chat-web-setup")
        tap("Enable web access")
        let chip = app.descendants(matching: .any)["spark.chat.web.chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        capture("chat-web-enabled")
        tap("Turn off web access")
        XCTAssertFalse(chip.exists)
    }

    private func sampleReply(_ number: Int) -> XCUIElement {
        app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "spark.chat.reply.")
        ).containing(
            .staticText,
            identifier: "Message \(number): a short part of a saved family planning conversation."
        ).firstMatch
    }

    func testQuotedReplyCanBeCancelledSentAndOpenedAtItsSource() {
        familyPreview()
        tap("Restore six messages")
        let original = sampleReply(2)
        XCTAssertTrue(original.waitForExistence(timeout: 8))
        original.staticTexts.firstMatch.tap()
        original.buttons["Reply"].tap()
        let draftQuote = app.descendants(matching: .any)["spark.chat.reply-draft"].firstMatch
        XCTAssertTrue(draftQuote.waitForExistence(timeout: 3))
        let composer = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        composer.typeText("Could you explain that earlier point?")
        capture("quoted-reply-composer")
        tap("Cancel reply")
        XCTAssertFalse(draftQuote.exists)
        XCTAssertEqual(composer.value as? String, "Could you explain that earlier point?")
        tap("Close preview")
        tap("Restore six messages")
        original.staticTexts.firstMatch.tap()
        original.buttons["Reply"].tap()
        composer.typeText("Explain this earlier message.")
        tap("Send message")
        XCTAssertFalse(draftQuote.exists)
        let sentQuote = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "spark.chat.sent-reply.")
        ).firstMatch
        XCTAssertTrue(sentQuote.waitForExistence(timeout: 8))
        XCTAssertTrue((sentQuote.value as? String)?.contains("Message 2:") == true)
        let transcript = app.scrollViews["spark.chat.transcript"]
        for _ in 0..<5 where !sentQuote.isHittable { transcript.swipeDown() }
        capture("quoted-reply-sent")
        sentQuote.tap()
        let text = original.staticTexts.firstMatch
        XCTAssertGreaterThan(text.frame.intersection(transcript.frame).height, 20)
        capture("quoted-reply-original-message")
    }

    func testIPadConversationStaysInsideTheWorkspace() throws {
        try XCTSkipUnless(isPad, "The iPad keeps its sidebar beside the conversation")
        familyPreview()
        tap("Restore 80 messages")
        visibleTranscript(containing: "a short part of a saved family planning conversation")
        let home = sidebar("home")
        XCTAssertTrue(home.isHittable, "Chat must leave the workspace sidebar available")
        capture("ipad-chat-in-workspace")
        home.tap()
        XCTAssertTrue(home.isSelected, "Leaving chat must not require closing a floating window")
        sidebar("chats").tap()
        XCTAssertTrue(sidebar("chats").isSelected)
        XCTAssertTrue(home.isHittable)
    }

    func testFeedbackReviewAndCancelPreserveTheDraft() {
        openHelp()
        tap("Feedback & bug reports")
        let field = app.descendants(matching: .any)["spark.feedback.description"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("UI test sample: a conversation was blank until I scrolled.")
        app.swipeUp()
        tap("Review report")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "UI test sample:"))
                .firstMatch.waitForExistence(timeout: 8)
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "device_id"))
                .firstMatch.exists
        )
        capture("feedback-review")
        tap("Back to editing")
        tap("Discard draft")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.alerts.buttons["Keep draft"].exists,
            "A destructive confirmation must expose its way back"
        )
        app.alerts.buttons["Keep draft"].tap()
        XCTAssertTrue(app.buttons["Review report"].isEnabled)
        tap("Discard draft")
        app.alerts.buttons["Discard draft"].tap()
    }

    func testHouseholdNotesExposeAnExplicitSharingReview() {
        familyPreview()
        tap("Household notes")
        XCTAssertTrue(app.staticTexts["Sample household"].waitForExistence(timeout: 8))
        capture("household-notes")
        app.swipeUp()
        tap("Add")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["Cancel"].exists)
        capture("household-sharing-review")
        app.alerts.buttons["Cancel"].tap()
        tap("Done")
    }

    func testEveryPrimaryDestinationIsReachable() {
        if isPad {
            for id in [
                "home", "chats", "models", "clusters", "automations", "activity",
                "settings",
            ] {
                let row = sidebar(id)
                XCTAssertTrue(row.exists)
                row.tap()
                XCTAssertTrue(row.isSelected, "The \(id) sidebar destination did not open")
                capture("sidebar-\(id)")
            }
        } else {
            for label in ["Home", "Chats", "Activity", "More"] {
                let tab = app.tabBars.buttons[label]
                XCTAssertTrue(tab.exists)
                tab.tap()
                XCTAssertTrue(tab.isSelected)
                capture("compact-\(label.lowercased())")
            }
        }
    }

    func testLargestTextLeavesRoomForTheConversationAndComposer() {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        familyPreview()
        tap("Restore a long reply")
        let transcript = app.scrollViews["spark.chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        capture("chat-accessibility-largest-text")
        let composer = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        XCTAssertTrue(composer.exists)
        let visibleHeight = composer.frame.minY - app.buttons["Close preview"].frame.maxY
        XCTAssertGreaterThan(
            visibleHeight,
            transcript.frame.height * 0.35,
            "The composer must not leave only a strip of conversation at the largest text size"
        )
        XCTAssertGreaterThan(
            composer.frame.width,
            min(transcript.frame.width * 0.75, 480),
            "The message field must remain wide enough to compose a sentence at the largest text size"
        )
        XCTAssertFalse(app.buttons["Dictate a message"].exists)
        XCTAssertTrue(app.buttons["Start voice chat"].isHittable)
    }

    func testAllSettingsPagesHaveAWayBack() {
        openHelp()
        if !isPad { tap("Settings") }
        for label in [
            "Siri & Apple Apps", "Chat", "App lock", "AI execution", "Notifications", "Spotlight",
        ] {
            let link = app.buttons.matching(
                NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
            ).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 8), "Missing settings page: \(label)")
            link.tap()
            let back = app.navigationBars.buttons["Settings"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 8), "No way back from \(label)")
            capture("settings-\(label)")
            back.tap()
        }
    }

    func testEveryPhoneMoreDestinationOpens() throws {
        try XCTSkipIf(isPad, "The iPad sidebar is exercised by the primary-destinations test")
        openHelp()
        for label in ["Models", "Clusters", "Automations", "Settings"] {
            tap(label)
            let back = app.navigationBars.buttons["More"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 8), "No way back from \(label)")
            capture("more-\(label)")
            back.tap()
        }
    }

    func testFeedbackCategoriesRetainTextAndUseTheSupportAddress() {
        openHelp()
        tap("Feedback & bug reports")
        let description = app.descendants(matching: .any)["spark.feedback.description"].firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 8))
        description.tap()
        description.typeText("E2E sample: please make the next step clearer.")
        for kind in ["Bug report", "Feedback", "Feature request"] {
            app.swipeDown()
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Type"))
                .firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 8))
            picker.tap()
            tap(kind)
            tap("Review report")
            let recipient = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value == %@",
                    "feedback@sparkpilot.dev",
                    "feedback@sparkpilot.dev"
                )
            ).firstMatch
            capture("feedback-\(kind)-review")
            XCTAssertTrue(recipient.waitForExistence(timeout: 8))
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "E2E sample:"))
                    .firstMatch.exists
            )
            #if targetEnvironment(simulator)
                tap("Continue to email")
                let status = app.staticTexts["bug-report-delivery-status"]
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                XCTAssertTrue(status.label.contains("Mail is not set up"))
                XCTAssertTrue(app.buttons["Share report"].exists)
            #endif
            capture("feedback-\(kind)")
            tap("Back to editing")
        }
        tap("Discard draft")
        app.alerts.buttons["Discard draft"].tap()
    }

    func testLargestTextKeepsHelpAndFeedbackReachable() {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        openHelp()
        capture("help-largest-text")
        tap("Feedback & bug reports")
        let description = app.descendants(matching: .any)["spark.feedback.description"].firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars.buttons[isPad ? "Settings" : "More"].exists)
        capture("feedback-largest-text")
    }

    func testWelcomeAndHelpPassSystemAccessibilityChecks() throws {
        continueAfterFailure = true
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        let add = app.buttons[isPad ? "Add a Spark" : "Add Spark"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        let audits: XCUIAccessibilityAuditType = [
            .contrast, .hitRegion, .sufficientElementDescription, .textClipped,
        ]
        capture("welcome-before-system-accessibility-audit")
        try auditAccessibility(audits)
        openHelp()
        capture("help-before-system-accessibility-audit")
        try auditAccessibility(audits)
    }

    private func auditAccessibility(_ audits: XCUIAccessibilityAuditType) throws {
        try app.performAccessibilityAudit(for: audits) { issue in
            let evidence = XCTAttachment(
                string:
                    "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No element supplied by the system")"
            )
            evidence.name = "system-accessibility-issue"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            return false
        }
    }

    func testHelpPassesSystemAccessibilityChecksWithoutASidebar() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        openHelp()
        if isPad { app.buttons["Hide Sidebar"].tap() }
        capture("help-fresh-system-accessibility-audit")
        try auditAccessibility([.contrast, .hitRegion, .sufficientElementDescription, .textClipped])
    }
}

import UIKit
import XCTest

@MainActor
extension SparkUITests {
    func testSpeakingBarsMoveAndSettleWhenPlaybackStops() throws {
        familyPreview()
        tap("Speaking controls preview")
        let speaking = app.staticTexts["Speaking"]
        XCTAssertTrue(speaking.waitForExistence(timeout: 8))
        let region = CGRect(
            x: app.frame.midX - 100,
            y: speaking.frame.minY - 184,
            width: 200,
            height: 160
        )
        func waveformPixels() throws -> Data {
            let screenshot = XCUIScreen.main.screenshot()
            let upright = UIGraphicsImageRenderer(size: app.frame.size).image { _ in
                screenshot.image.draw(in: CGRect(origin: .zero, size: app.frame.size))
            }
            let image = try XCTUnwrap(upright.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            let crop = try XCTUnwrap(
                image.cropping(to: region.applying(.init(scaleX: scale, y: scale)))
            )
            return try XCTUnwrap(UIImage(cgImage: crop).pngData())
        }
        let first = try waveformPixels()
        capture("voice-speaking-first")
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertNotEqual(first, try waveformPixels(), "Speaking bars must move during playback")
        capture("voice-speaking-next")
        app.buttons["Pause"].tap()
        Thread.sleep(forTimeInterval: 0.4)
        let stopped = try waveformPixels()
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(stopped, try waveformPixels(), "Bars must settle when playback stops")
        app.buttons["Close voice"].tap()
    }

    func testComposerUsesOneVoiceButtonUntilAMessageIsTyped() {
        familyPreview()
        tap("New conversation")
        let voice = app.buttons["Start voice chat"]
        XCTAssertTrue(voice.waitForExistence(timeout: 8))
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(voice.isHittable)
        XCTAssertFalse(app.buttons["Dictate a message"].exists)
        capture("composer-empty-voice-button")
        voice.tap()
        XCTAssertTrue(app.buttons["Close voice"].waitForExistence(timeout: 8))
        app.buttons["Close voice"].tap()
        let draft = app.descendants(matching: .any)["spark.chat.composer"].firstMatch
        draft.tap()
        draft.typeText("Hello")
        XCTAssertFalse(voice.exists)
        XCTAssertTrue(app.buttons["Send message"].exists)
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
        capture("composer-typed-send-button")
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.isEnabled)
        XCTAssertFalse(app.buttons["Dictate a message"].exists)
    }

    func testVoiceUsesFullScreenAndKeepsPreferencesInAudioSettings() {
        familyPreview()
        tap("Restore six messages")
        if !isPad { app.scrollViews["spark.chat.transcript"].swipeUp() }
        tap("Read aloud")
        XCTAssertTrue(app.buttons["Close voice"].waitForExistence(timeout: 8))
        capture("voice-before-layout-check")
        XCTAssertFalse(app.switches["Use Apple's speech service"].exists)
        XCTAssertEqual(app.navigationBars["Read aloud"].frame.width, app.frame.width, accuracy: 2)
        let settings = app.buttons["Audio settings"]
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        let speech = app.switches["spark.audio.apple-speech"]
        XCTAssertTrue(speech.waitForExistence(timeout: 8))
        let originalSpeech = speech.value as? String
        app.buttons["spark.audio.output"].tap()
        app.buttons["Apple voice on this device"].tap()
        XCTAssertEqual(speech.value as? String, originalSpeech)
        capture("voice-audio-settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Close voice"].waitForExistence(timeout: 5))
        capture("voice-full-screen")
        app.buttons["Close voice"].tap()
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(
            (isPad ? sidebar("settings") : app.tabBars.firstMatch).waitForExistence(timeout: 15)
        )
        openHelp()
        if !isPad { tap("Settings") }
        tap("Audio")
        XCTAssertTrue(app.buttons["spark.audio.output"].waitForExistence(timeout: 5))
        let output = app.buttons["spark.audio.output"]
        XCTAssertTrue(
            (output.label + " " + (output.value as? String ?? "")).contains("Apple voice")
        )
        app.buttons["spark.audio.output"].tap()
        app.buttons["Kokoro on Spark"].tap()
    }
    func testVoiceConversationControlsRemainVisibleAfterRotation() {
        familyPreview()
        tap("Voice controls preview")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let send = app.buttons["Send now"]
            let chat = app.buttons["Back to chat"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertTrue(send.isHittable)
            XCTAssertTrue(chat.isHittable)
            XCTAssertGreaterThanOrEqual(send.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(chat.frame.maxY, app.frame.maxY)
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            XCTAssertFalse(app.switches["spark.audio.apple-speech"].exists)
            capture(
                orientation == .portrait ? "voice-listening-portrait" : "voice-listening-landscape"
            )
        }
        app.buttons["Back to chat"].tap()
        XCTAssertTrue(app.buttons["Voice controls preview"].waitForExistence(timeout: 5))
    }

}

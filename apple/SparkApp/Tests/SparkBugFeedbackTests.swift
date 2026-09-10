import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SparkAppComposition

@Suite struct SparkBugFeedbackTests {
    @Test func aReportContainsOnlyWrittenFieldsAndNoCollectedDetails() {
        var draft = SparkBugDraft()
        draft.happened = "Chat is blank"
        draft.steps = "Open a saved conversation"
        let report = SparkBugReport(draft: draft, screenshot: nil, recipient: nil)
        #expect(
            report.body
                == "What happened?\nChat is blank\n\nHow to reproduce it\nOpen a saved conversation"
        )
        #expect(report.screenshot == nil)
        #expect(report.subject == "Bug report")
    }

    @Test func reviewFreezesTheTextAndSwitchingTypeDoesNotShareHiddenReproductionSteps() {
        var draft = SparkBugDraft()
        draft.happened = "Add larger chat text"
        draft.steps = "Private reproduction detail"
        draft.kind = .feature
        let reviewed = SparkBugReport(
            draft: draft,
            screenshot: nil,
            recipient: "feedback@sparkpilot.dev"
        )
        draft.happened = "Unreviewed detail"
        #expect(reviewed.subject == "Feature request")
        #expect(reviewed.body.contains("Add larger chat text"))
        #expect(!reviewed.body.contains("Private reproduction detail"))
        #expect(!reviewed.body.contains("Unreviewed detail"))
        #expect(reviewed.recipient == "feedback@sparkpilot.dev")
        draft.kind = .feedback
        #expect(SparkBugReport(draft: draft, screenshot: nil, recipient: nil).subject == "Feedback")
    }

    @Test(arguments: [
        "bugs@example.test\r\nBcc: someone@example.test",
        "bugs@example.test?bcc=someone@example.test", "mailto:bugs@example.test",
        "bugs@example.test,another@example.test", " bugs@example.test", "$(SPARK_FEEDBACK_EMAIL)",
        "bugs@", "@example.test", "bugs@.example.test", "bugs@example.test\u{0000}",
        "bugs@example.test/path",
    ])
    func malformedRecipientsCannotInjectAnotherDestination(_ recipient: String) {
        #expect(SparkBugFeedbackConfiguration.validatedEmail(recipient) == nil)
    }

    @Test func reviewRequiresAnExplanationAndBoundsMultibyteReports() {
        var draft = SparkBugDraft()
        draft.happened = " \n "
        #expect(!draft.canReview)
        draft.happened = "The app stops during setup"
        #expect(draft.canReview)
        draft.steps = String(repeating: "😀", count: 4_097)
        #expect(!draft.canReview)
        draft.kind = .feature
        #expect(draft.canReview)
    }

    @Test func userTextCannotAlterTheMailSubject() {
        var draft = SparkBugDraft()
        draft.happened = "Subject: injected\r\nBcc: another@example.test"
        let report = SparkBugReport(draft: draft, screenshot: nil, recipient: nil)
        #expect(report.subject == "Bug report")
        #expect(report.body.contains(draft.happened))
    }

    @Test func screenshotsKeepOrientationButRemoveLocationAndDeviceMetadata() throws {
        let original = try imageData()
        let screenshot = try SparkBugScreenshot(data: original)
        let source = try #require(CGImageSourceCreateWithData(screenshot.data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        #expect(Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]))
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 10)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 20)
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }

    @Test func screenshotDraftCanBeRemovedAndTheShareSnapshotMatchesTheReviewedContents() throws {
        let root = URL.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let screenshot = try SparkBugScreenshot(data: imageData())
        let store = SparkBugScreenshotStore(directory: root.appending(path: "draft"))
        try store.save(screenshot)
        #expect(try store.load() != nil)
        var draft = SparkBugDraft()
        draft.happened = "The button is clipped"
        let report = SparkBugReport(draft: draft, screenshot: screenshot, recipient: nil)
        let files = try SparkBugShareFiles(report: report, root: root)
        #expect(files.urls.count == 2)
        #expect(try String(contentsOf: files.urls[0], encoding: .utf8) == report.body)
        #expect(try Data(contentsOf: files.urls[1]) == screenshot.data)
        try store.remove()
        #expect(try store.load() == nil)
        #expect(try Data(contentsOf: files.urls[1]) == screenshot.data)
    }

    @Test func arbitraryFilesAndOversizedInputsCannotBeAttachedAsScreenshots() {
        #expect(throws: (any Error).self) {
            try SparkBugScreenshot(data: Data("private logfile".utf8))
        }
        #expect(throws: (any Error).self) {
            try SparkBugScreenshot(
                data: Data(repeating: 0, count: SparkBugScreenshot.maximumInputBytes + 1)
            )
        }
    }

    private func imageData() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: 20,
                height: 10,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let pixels = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(
            destination,
            pixels,
            [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                ],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Private device name"],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:09:05 12:34:56",
                    kCGImagePropertyExifUserComment: "Private capture note",
                ],
            ] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

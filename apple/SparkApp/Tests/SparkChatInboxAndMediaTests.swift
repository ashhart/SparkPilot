import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import SparkAPI
import SparkCore
import Testing
import UniformTypeIdentifiers

@testable import SparkAppComposition

/// Shared-inbox handling and media limits (A5, A6, A13, A14), split from the attachment tests to stay within the file-size gate.
struct SparkChatInboxAndMediaTests {
    @Test func sharedInboxRoundTripsAndAcknowledgesExplicitly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        let share = SparkSharedChat(
            text: "Message from another app",
            files: [SparkSharedFile(name: "note.txt", data: Data("hello".utf8))]
        )
        try inbox.enqueue(share)
        #expect(try inbox.next()?.text == share.text)
        #expect(try inbox.next()?.files == share.files)
        try inbox.remove(id: share.id)
        #expect(try inbox.next() == nil)
    }

    /// An unreadable envelope is set aside so the readable ones behind it still open, and only it is discarded (A6).
    @Test func sharedInboxRefusesDuplicatesAndQuarantinesUnreadableEnvelopes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The unreadable envelope is older, so it is met first and set aside on the way to the readable one.
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("000-invalid.json"))
        let share = SparkSharedChat(text: "keep this", files: [])
        try inbox.enqueue(share)
        #expect(throws: (any Error).self) { try inbox.enqueue(share) }
        #expect(try inbox.next()?.id == share.id)
        #expect(inbox.unreadableCount() == 1)
        try inbox.discardUnreadableShares()
        #expect(inbox.unreadableCount() == 0)
        #expect(
            try inbox.next()?.id == share.id,
            "discarding unreadable items keeps readable shares"
        )
        try inbox.remove(id: share.id)
        #expect(try inbox.next() == nil)
    }

    /// When the inbox is full the extension may trade the oldest pending share for the new one (A13).
    @Test func sharedInboxCanReplaceTheOldestShareWhenFull() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        let first = SparkSharedChat(
            createdAt: Date(timeIntervalSince1970: 1),
            text: "first",
            files: []
        )
        try inbox.enqueue(first)
        for index in 1..<10 {
            try inbox.enqueue(SparkSharedChat(text: "share \(index)", files: []))
        }
        let eleventh = SparkSharedChat(text: "eleventh", files: [])
        #expect(throws: (any Error).self) { try inbox.enqueue(eleventh) }
        try inbox.enqueue(eleventh, replacingOldestWhenFull: true)
        var seen: [String] = []
        while let share = try inbox.next() {
            seen.append(share.text)
            try inbox.remove(id: share.id)
        }
        #expect(seen.count == 10)
        #expect(!seen.contains("first"))
        #expect(seen.contains("eleventh"))
    }

    @Test func sharedInboxRejectsTraversalOversizeAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        #expect(throws: (any Error).self) {
            try inbox.enqueue(
                SparkSharedChat(
                    text: "",
                    files: [SparkSharedFile(name: "../secret.txt", data: Data([1]))]
                )
            )
        }
        #expect(throws: (any Error).self) {
            try inbox.enqueue(
                SparkSharedChat(text: String(repeating: "a", count: 120_001), files: [])
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(UUID().uuidString + ".json"),
            withDestinationURL: target
        )
        #expect(try inbox.next() == nil)
        #expect(inbox.unreadableCount() == 1, "a symlink is set aside, never followed")
    }

    /// A full-resolution phone photo is downscaled, not refused (A5).
    @Test func largePhotosAreDownscaledNotRefused() throws {
        let width = 7000
        let height = 6000
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let attachment = try SparkChatAttachmentReader.read(data: output as Data, name: "photo.jpg")
        #expect(attachment.isImage)
        #expect((attachment.jpeg?.count ?? 0) <= SparkChatAttachmentReader.maximumImageBytes)
    }

    /// A blank page is marked, not fatal, so one empty cover does not block the readable pages (A14).
    @Test func blankPDFPagesAreMarkedNotFatal() throws {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Second page text",
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]
            )
        )
        pdf.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let text = try #require(
            SparkChatAttachmentReader.read(data: output as Data, name: "cover.pdf").text
        )
        #expect(text.contains("[Page 1 has no readable text]"))
        #expect(text.contains("Second page text"))
    }
}

import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum SparkBugScreenshotError: Error { case unreadable, tooLarge }

struct SparkBugScreenshot: Equatable {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static var failureMessage: String {
        String(
            localized:
                "This image could not be attached; choose a PNG, JPEG or HEIC image under 20 MB."
        )
    }
    let data: Data

    init(data: Data) throws {
        guard data.count <= Self.maximumInputBytes else { throw SparkBugScreenshotError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 20_000, height <= 20_000
        else { throw SparkBugScreenshotError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400,
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw SparkBugScreenshotError.unreadable }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw SparkBugScreenshotError.unreadable }
        // Copy pixels only: the selected file's location, device, capture and text metadata are not shared.
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= Self.maximumInputBytes
        else { throw SparkBugScreenshotError.tooLarge }
        self.data = encoded as Data
    }

    static func readBoundedFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumInputBytes + 1) ?? Data()
        guard data.count <= maximumInputBytes else { throw SparkBugScreenshotError.tooLarge }
        return data
    }
}

struct SparkBugScreenshotStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? URL.applicationSupportDirectory
            .appending(path: "SparkPilot/Feedback", directoryHint: .isDirectory)
    }
    private var file: URL { directory.appending(path: "draft-screenshot.png") }

    func load() throws -> SparkBugScreenshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try SparkBugScreenshot(data: SparkBugScreenshot.readBoundedFile(file))
    }

    func save(_ screenshot: SparkBugScreenshot) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if os(iOS)
            try screenshot.data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
            try screenshot.data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

struct SparkBugShareFiles {
    let urls: [URL]
    init(report: SparkBugReport, root: URL = .temporaryDirectory) throws {
        let directory = root.appending(
            path: "SparkPilotFeedback/\(report.id.uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let text = directory.appending(path: "Feedback.txt")
        try Data(report.body.utf8).write(to: text, options: .atomic)
        var urls = [text]
        if let screenshot = report.screenshot {
            let image = directory.appending(path: "Screenshot.png")
            try screenshot.data.write(to: image, options: .atomic)
            urls.append(image)
        }
        for url in urls {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        self.urls = urls
    }
}

struct SparkBugScreenshotPreview: View {
    let screenshot: SparkBugScreenshot
    var body: some View {
        if let source = CGImageSourceCreateWithData(screenshot.data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit().frame(maxHeight: 360)
                .accessibilityLabel("Your selected screenshot")
                .privacySensitive()
        }
    }
}

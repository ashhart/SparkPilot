import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

public enum SparkAttachmentError: LocalizedError, Sendable {
    case unsupported, tooLarge, tooMany, unreadable, encryptedPDF, tooManyPages, noText,
        unreadablePage, visionUnavailable, contextTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Choose a PDF, DOCX, RTF, text document, or photo.")
        case .tooLarge:
            String(localized: "This attachment exceeds the size limit; choose a smaller file.")
        case .tooMany: String(localized: "Attach up to eight files per message.")
        case .unreadable:
            String(localized: "This file could not be read; export a fresh copy and try again.")
        case .encryptedPDF: String(localized: "Unlock this PDF before attaching it.")
        case .tooManyPages: String(localized: "Choose a PDF with no more than 30 pages.")
        case .unreadablePage:
            String(
                localized:
                    "A PDF page has no readable text; remove that page or attach it as a photo for a vision model."
            )
        case .noText: String(localized: "No readable text was found in this document.")
        case .visionUnavailable:
            String(
                localized:
                    "Images aren't available for this model. Remove the photos or choose a model that supports images. If the photos are in earlier messages, you can start a new chat."
            )
        case .contextTooLarge:
            String(
                localized:
                    "These attachments and messages exceed the chat size limit; use a shorter document or start a new chat."
            )
        }
    }
}

public struct SparkChatAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let text: String?
    public let jpeg: Data?
    public var isImage: Bool { jpeg != nil }
    public var imageDataURL: String? {
        jpeg.map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    public init(id: UUID = UUID(), name: String, text: String? = nil, jpeg: Data? = nil) {
        self.id = id
        self.name = String(name.prefix(180))
        self.text = text
        self.jpeg = jpeg
    }
}

public enum SparkChatAttachmentReader {
    public static let maximumFileBytes = 20 * 1024 * 1024
    public static let maximumTextBytes = 120_000
    public static let maximumImageBytes = 1024 * 1024
    public static let supportedTypes: [UTType] = [
        .pdf, .plainText, .rtf, .image, .commaSeparatedText, .json,
        UTType(filenameExtension: "docx")!, UTType(filenameExtension: "md") ?? .plainText,
    ]

    public static func read(url: URL) throws -> SparkChatAttachment {
        try read(data: readFile(url), name: url.lastPathComponent)
    }

    static func readPhoto(url: URL) throws -> SparkChatAttachment {
        SparkChatAttachment(
            name: String(localized: "Photo.jpg"),
            jpeg: try normalizedImage(readFile(url))
        )
    }

    private static func readFile(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SparkAttachmentError.unsupported }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SparkAttachmentError.unsupported
        }
        guard let size = values.fileSize, size <= maximumFileBytes else {
            throw SparkAttachmentError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw SparkAttachmentError.tooLarge }
        guard !data.isEmpty else { throw SparkAttachmentError.unreadable }
        return data
    }

    public static func read(data: Data, name: String) throws -> SparkChatAttachment {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw SparkAttachmentError.unreadable }
        guard data.count <= maximumFileBytes else { throw SparkAttachmentError.tooLarge }
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true {
            return SparkChatAttachment(name: name, jpeg: try normalizedImage(data))
        }
        let text: String
        switch ext {
        case "pdf": text = try pdfText(data)
        case "docx": text = try SparkDOCXReader.text(data)
        case "rtf":
            text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
        case "txt", "md", "csv", "tsv", "json", "log", "xml", "yaml", "yml":
            let utf16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            guard let decoded = String(data: data, encoding: utf16 ? .utf16 : .utf8),
                !decoded.contains("\0")
            else { throw SparkAttachmentError.unreadable }
            text = decoded
        default: throw SparkAttachmentError.unsupported
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw SparkAttachmentError.noText }
        guard cleaned.utf8.count <= maximumTextBytes else { throw SparkAttachmentError.tooLarge }
        return SparkChatAttachment(name: name, text: cleaned)
    }

    private static func normalizedImage(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            // Bound decoding to 120 megapixels; the thumbnailer below keeps memory small for anything under that.
            width > 0, height > 0, width <= 120_000_000 / height,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1536,
                ] as CFDictionary
            )
        else { throw SparkAttachmentError.unreadable }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { throw SparkAttachmentError.unreadable }
        // A fresh JPEG discards location, camera metadata, and extra image frames.
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length <= maximumImageBytes else {
            throw SparkAttachmentError.tooLarge
        }
        return output as Data
    }

    private static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else { throw SparkAttachmentError.unreadable }
        guard !document.isLocked else { throw SparkAttachmentError.encryptedPDF }
        guard document.pageCount <= 30 else { throw SparkAttachmentError.tooManyPages }
        var pages: [String] = []
        var size = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw SparkAttachmentError.unreadable }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                let thumbnail = page.thumbnail(
                    of: CGSize(width: 1536, height: 1536),
                    for: .mediaBox
                )
                #if os(macOS)
                    let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                    let cgImage = thumbnail.cgImage
                #endif
                guard let cgImage else { throw SparkAttachmentError.unreadable }
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: cgImage).perform([recognition])
                text =
                    recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(
                        separator: "\n"
                    ) ?? ""
            }
            // Mark a page with nothing to read instead of failing the document, so a blank cover does not block 29 readable pages.
            if text.isEmpty {
                text = String(localized: .blankPDFPage(index + 1))
            }
            size += text.utf8.count + 2
            guard size <= maximumTextBytes else { throw SparkAttachmentError.tooLarge }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }
}

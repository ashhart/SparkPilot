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

private func attachmentTarget(vision: Bool? = nil, context: Int? = nil) -> SparkChatTarget {
    SparkChatTarget(
        id: "test-spark",
        displayName: "Test Spark",
        nodeID: SparkNodeID(rawValue: UUID()),
        route: URL(string: "https://spark.example:8443")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: "example/model",
        modelName: "Example model",
        contextLength: context,
        visionSupported: vision
    )
}

private actor AttachmentRecordingStreamer: SparkChatStreaming {
    var requests: [ChatCompletionRequest] = []
    var failing = false
    func fail() { failing = true }
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        requests.append(request)
        if failing { throw URLError(.notConnectedToInternet) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.chunk(id: nil, model: nil, delta: "Read it", finishReason: "stop"))
            continuation.finish()
        }
    }
}

private func attachmentImage() throws -> Data {
    let context = try #require(
        CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0]] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func attachmentPDF(pages: Int = 1, scanned: Bool = false) throws -> Data {
    let output = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: output))
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<pages {
        pdf.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "Quarterly revenue 42",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString,
                        20,
                        nil
                    )
                ]
            )
        )
        if scanned {
            let bitmap = try #require(
                CGContext(
                    data: nil,
                    width: 600,
                    height: 400,
                    bitsPerComponent: 8,
                    bytesPerRow: 2400,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            )
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            bitmap.scaleBy(x: 2, y: 2)
            bitmap.textPosition = CGPoint(x: 12, y: 100)
            CTLineDraw(line, bitmap)
            pdf.draw(try #require(bitmap.makeImage()), in: box)
        } else {
            pdf.textPosition = CGPoint(x: 12, y: 100)
            CTLineDraw(line, pdf)
        }
        pdf.endPDFPage()
    }
    pdf.closePDF()
    return output as Data
}

@Suite("Chat attachments")
struct SparkChatAttachmentTests {
    @Test func readsTextAndRTF() throws {
        #expect(
            try SparkChatAttachmentReader.read(data: Data("hello £42".utf8), name: "notes.txt").text
                == "hello £42"
        )
        let rtf = Data(#"{\rtf1\ansi Read \b this \b0 document}"#.utf8)
        #expect(
            try SparkChatAttachmentReader.read(data: rtf, name: "notes.rtf").text?.contains(
                "Read this document"
            ) == true
        )
    }

    @Test func readsPDFAndScannedPDF() throws {
        #expect(
            try SparkChatAttachmentReader.read(data: attachmentPDF(), name: "report.pdf").text?
                .contains("Quarterly revenue 42") == true
        )
        #expect(
            try SparkChatAttachmentReader.read(data: attachmentPDF(scanned: true), name: "scan.pdf")
                .text?.contains("42") == true
        )
    }

    @Test func readsDOCXAndRejectsEntityExpansionAndLargeExtractedText() throws {
        let sample = try #require(
            Bundle.module.url(forResource: "chat-document", withExtension: "docx")
        )
        #expect(
            try SparkChatAttachmentReader.read(url: sample).text
                == "Quarterly revenue: £42\nSecond paragraph"
        )
        for name in ["chat-entity", "chat-large"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "docx"))
            #expect(throws: (any Error).self) { try SparkChatAttachmentReader.read(url: url) }
        }
        var corrupt = try Data(contentsOf: sample)
        corrupt[40] ^= 0xff
        #expect(throws: (any Error).self) { try SparkDOCXReader.text(corrupt) }
    }

    @Test func rejectsUnsupportedMalformedOversizedAndTooManyPages() throws {
        for (data, name) in [
            (Data("not a PDF".utf8), "bad.pdf"), (Data([0, 1, 2]), "bad.png"),
            (Data("code".utf8), "run.exe"), (Data(), "empty.txt"),
        ] {
            #expect(throws: (any Error).self) {
                try SparkChatAttachmentReader.read(data: data, name: name)
            }
        }
        #expect(throws: (any Error).self) {
            try SparkChatAttachmentReader.read(
                data: Data(count: 20 * 1024 * 1024 + 1),
                name: "big.txt"
            )
        }
        #expect(throws: (any Error).self) {
            try SparkChatAttachmentReader.read(data: attachmentPDF(pages: 31), name: "long.pdf")
        }
    }

    @Test func rejectsLockedPDFAndBinaryText() throws {
        let document = try #require(PDFDocument(data: attachmentPDF()))
        let protected = try #require(
            document.dataRepresentation(options: [
                PDFDocumentWriteOption.userPasswordOption.rawValue: "fixture-password",
                PDFDocumentWriteOption.ownerPasswordOption.rawValue: "fixture-owner",
            ])
        )
        #expect(throws: (any Error).self) {
            try SparkChatAttachmentReader.read(data: protected, name: "locked.pdf")
        }
        #expect(throws: (any Error).self) {
            try SparkChatAttachmentReader.read(data: Data([0, 0, 0, 0]), name: "binary.txt")
        }
    }

    @Test func oldStoredModelMetadataDoesNotInventVisionSupport() throws {
        let old = Data(#"{"modelID":"example/model","recipeRevision":"r1"}"#.utf8)
        #expect(
            try JSONDecoder().decode(ModelPlacementTechnicalDetails.self, from: old).visionSupported
                == nil
        )
    }

    @Test func normalizesImagesAndRemovesMetadata() throws {
        let attachment = try SparkChatAttachmentReader.read(
            data: attachmentImage(),
            name: "photo.png"
        )
        let jpeg = try #require(attachment.jpeg)
        #expect(attachment.imageDataURL?.hasPrefix("data:image/jpeg;base64,") == true)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(jpeg.count < SparkChatAttachmentReader.maximumImageBytes)
    }

    @Test func textWireFormatIsUnchangedAndImagesUseContentParts() throws {
        let text = ChatMessage(content: "hello")
        let encoded = try JSONEncoder().encode(text)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["content"] as? String == "hello")
        let image = ChatMessage(content: "look", imageDataURLs: ["data:image/jpeg;base64,YQ=="])
        let imageJSON = try JSONEncoder().encode(image)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: imageJSON) == image)
        let content = try #require(
            (JSONSerialization.jsonObject(with: imageJSON) as? [String: Any])?["content"]
                as? [[String: Any]]
        )
        #expect(content.map { $0["type"] as? String } == ["text", "image_url"])
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(
                ChatMessage(content: "look", imageDataURLs: ["https://example.com/private.png"])
            )
        }
    }

    @Test @MainActor func textOnlyModelsCanReadDocumentsWithoutAPrompt() async throws {
        let stream = AttachmentRecordingStreamer()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [attachmentTarget(vision: false)],
                pairedTargetCount: 1
            ),
            streamer: stream
        )
        await model.importSharedFiles([
            SparkSharedFile(name: "notes.txt", data: Data("Important document".utf8))
        ])
        #expect(model.canSend)
        let task = try #require(model.send())
        await task.value
        #expect(model.pendingAttachments.isEmpty)
        #expect(model.messages.first?.attachments.count == 1)
        let sent = try #require(await stream.requests.first)
        #expect(chatTestSpoken(sent).first?.content.contains("Important document") == true)
        #expect(chatTestSpoken(sent).first?.imageDataURLs.isEmpty == true)
    }

    @Test @MainActor func unknownAndDisabledVisionBlockPhotosWithoutLosingDraft() async throws {
        for vision: Bool? in [nil, false] {
            let stream = AttachmentRecordingStreamer()
            let model = SparkChatModel(
                catalogue: SparkChatTargetCatalogue(
                    targets: [attachmentTarget(vision: vision)],
                    pairedTargetCount: 1
                ),
                streamer: stream
            )
            await model.importSharedFiles([
                SparkSharedFile(name: "photo.png", data: try attachmentImage())
            ])
            model.draft = "What is this?"
            #expect(!model.canSend)
            #expect(model.attachmentBlocker != nil)
            #expect(model.send() == nil)
            #expect(model.draft == "What is this?")
            #expect(await stream.requests.isEmpty)
            model.removeAttachment(id: try #require(model.pendingAttachments.first?.id))
            #expect(model.canSend)
        }
    }

    @Test @MainActor func photosSurviveRetryAndCannotBeSentToATextOnlyReplacement() async throws {
        let stream = AttachmentRecordingStreamer()
        await stream.fail()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [attachmentTarget(vision: true)],
                pairedTargetCount: 1
            ),
            streamer: stream
        )
        await model.importSharedFiles([
            SparkSharedFile(name: "photo.png", data: try attachmentImage())
        ])
        await model.send()?.value
        #expect(model.canRetry)
        await model.retry()?.value
        let requests = await stream.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages == requests[1].messages)
        #expect(chatTestSpoken(requests[0]).first?.imageDataURLs.count == 1)
        model.replaceCatalogue(
            SparkChatTargetCatalogue(
                targets: [attachmentTarget(vision: false)],
                pairedTargetCount: 1
            )
        )
        model.draft = "Continue"
        #expect(!model.canRetry)
        #expect(!model.canSend)
        model.newConversation()
        #expect(model.messages.isEmpty)
        #expect(model.attachmentBlocker == nil)
    }

    @Test @MainActor func oversizedAndFailedImportsAreAtomic() async {
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [attachmentTarget()],
                pairedTargetCount: 1
            ),
            streamer: AttachmentRecordingStreamer()
        )
        await model.importSharedFiles([SparkSharedFile(name: "notes.txt", data: Data("keep".utf8))])
        await model.importSharedFiles([
            SparkSharedFile(name: "good.txt", data: Data("new".utf8)),
            SparkSharedFile(name: "bad.pdf", data: Data([0, 1])),
        ])
        #expect(model.pendingAttachments.map(\.name) == ["notes.txt"])
        #expect(model.attachmentError != nil)
        await model.importSharedFiles(
            Array(repeating: SparkSharedFile(name: "extra.txt", data: Data("x".utf8)), count: 8)
        )
        #expect(model.pendingAttachments.count == 1)
    }

    @Test @MainActor func contextBudgetRefusesBeforeMutatingConversation() async {
        let stream = AttachmentRecordingStreamer()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [attachmentTarget(context: 2100)],
                pairedTargetCount: 1
            ),
            streamer: stream
        )
        model.draft = String(repeating: "x", count: 100)
        #expect(model.send() == nil)
        #expect(model.messages.isEmpty)
        #expect(model.draft.count == 100)
        #expect(model.attachmentError != nil)
    }
}

@Test @MainActor func attachmentHistoryPreservesDraftsAndMultimodalFollowUps() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
    let stream = AttachmentRecordingStreamer()
    let model = SparkChatModel(
        catalogue: SparkChatTargetCatalogue(
            targets: [attachmentTarget(vision: true)],
            pairedTargetCount: 1
        ),
        streamer: stream
    )
    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    let first = workspace.selectedID
    await model.importSharedFiles([
        SparkSharedFile(name: "notes.txt", data: Data("Document to remember".utf8)),
        SparkSharedFile(name: "photo.png", data: try attachmentImage()),
    ])
    let attachments = model.pendingAttachments
    #expect(attachments.count == 2)
    workspace.newChat()
    #expect(workspace.selectedID != first)
    workspace.selected.model.draft = "Keep this separate draft"
    workspace.select(first)
    workspace.flush()
    let restored = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    #expect(restored.conversations.count == 2)
    #expect(restored.selected.model.pendingAttachments == attachments)
    let send = try #require(restored.selected.model.send())
    await send.value
    restored.flush()
    let reopened = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    #expect(reopened.selected.model.messages.first?.attachments == attachments)
    #expect(reopened.selected.model.pendingAttachments.isEmpty)
    reopened.selected.model.draft = "Explain the document and photo again"
    await reopened.selected.model.send()?.value
    let requests = await stream.requests
    #expect(requests.count == 2)
    let latest = chatTestSpoken(try #require(requests.last))
    #expect(latest.first?.content.contains("Document to remember") == true)
    #expect(latest.first?.imageDataURLs.count == 1)
    #expect(
        reopened.conversations.first(where: { $0.id != first })?.model.draft
            == "Keep this separate draft"
    )
}

@Test @MainActor func attachmentMergeStillLoadsArchivesWrittenBeforeAttachments() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
    let record = SparkChatRecord(
        id: UUID(),
        title: "Existing chat",
        updatedAt: Date(),
        targetID: "test-spark",
        draft: "Existing unsent draft",
        messages: [SparkChatMessage(role: .user, content: "Existing message")]
    )
    let archive = SparkChatArchive(selectedID: record.id, conversations: [record])
    var legacy = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any]
    )
    var records = try #require(legacy["conversations"] as? [[String: Any]])
    var messages = try #require(records[0]["messages"] as? [[String: Any]])
    messages[0].removeValue(forKey: "attachments")
    records[0]["messages"] = messages
    records[0].removeValue(forKey: "pendingAttachments")
    legacy["conversations"] = records
    try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)
    let model = SparkChatModel(
        catalogue: SparkChatTargetCatalogue(targets: [attachmentTarget()], pairedTargetCount: 1),
        streamer: AttachmentRecordingStreamer()
    )
    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    #expect(workspace.storageError == nil)
    #expect(workspace.selected.title == "Existing chat")
    #expect(workspace.selected.model.draft == "Existing unsent draft")
    #expect(workspace.selected.model.messages.first?.content == "Existing message")
    #expect(workspace.selected.model.messages.first?.attachments.isEmpty == true)
    #expect(workspace.selected.model.pendingAttachments.isEmpty)
}

@Test @MainActor func voiceDoesNotSendOrDiscardAttachmentsInTheTypedDraft() async throws {
    let stream = AttachmentRecordingStreamer()
    let model = SparkChatModel(
        catalogue: SparkChatTargetCatalogue(targets: [attachmentTarget()], pairedTargetCount: 1),
        streamer: stream
    )
    await model.importSharedFiles([
        SparkSharedFile(name: "private-draft.txt", data: Data("Unsent document".utf8))
    ])
    model.draft = "Unsent question"
    let task = try #require(model.sendVoiceMessage("A separate spoken question"))
    await task.value
    let request = try #require(await stream.requests.first)
    #expect(chatTestConversation(request) == ["A separate spoken question"])
    #expect(model.pendingAttachments.first?.text == "Unsent document")
    #expect(model.draft == "Unsent question")
    model.resetConversation()
    #expect(model.pendingAttachments.isEmpty)
    #expect(model.messages.isEmpty)
}

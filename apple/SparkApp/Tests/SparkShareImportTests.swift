import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SparkAppComposition

@Suite("Incoming chat shares")
@MainActor
struct SparkShareImportTests {
    @Test func loadsSharedTextAndLinksWithoutFetchingThem() async {
        let text = NSItemProvider(
            item: "A message from another app" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let link = NSItemProvider(
            item: URL(string: "https://example.invalid/shared")! as NSURL,
            typeIdentifier: UTType.url.identifier
        )
        let item = NSExtensionItem()
        item.attachments = [text, link]
        let model = SparkShareModel()
        await model.load([item])
        #expect(!model.loading)
        #expect(model.error == nil)
        #expect(model.text.contains("A message from another app"))
        #expect(model.text.contains("https://example.invalid/shared"))
        #expect(model.files.isEmpty)
    }

    @Test func copiesProviderFilesBeforeTheirTemporaryURLExpires() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "chat-document", withExtension: "docx")
        )
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".docx"
        )
        try FileManager.default.copyItem(at: source, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let provider = NSItemProvider()
        provider.suggestedName = "Shared document.docx"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType(filenameExtension: "docx")!.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(temporary, false, nil)
            return nil
        }
        let item = NSExtensionItem()
        item.attachments = [provider]
        let model = SparkShareModel()
        await model.load([item])
        try FileManager.default.removeItem(at: temporary)
        #expect(model.error == nil)
        #expect(model.files.first?.name == "Shared document.docx")
        let file = try #require(model.files.first)
        #expect(
            try SparkChatAttachmentReader.read(data: file.data, name: file.name).text?.contains(
                "£42"
            ) == true
        )
    }

    @Test func rejectsUnsupportedProvidersAndTooManyItemsAtomically() async {
        let item = NSExtensionItem()
        let text = NSItemProvider(
            item: "hello" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let movie = NSItemProvider(
            item: Data([0]) as NSData,
            typeIdentifier: UTType.movie.identifier
        )
        item.attachments = [text, movie]
        let model = SparkShareModel()
        await model.load([item])
        #expect(model.loadFailed)
        #expect(model.text.isEmpty)
        #expect(model.files.isEmpty)
        item.attachments = Array(repeating: text, count: 9)
        let overLimit = SparkShareModel()
        await overLimit.load([item])
        #expect(overLimit.loadFailed)
    }

    @Test func rejectsNonWebLinksAndOversizedSharedText() async {
        for provider in [
            NSItemProvider(
                item: URL(string: "ftp://example.invalid/file")! as NSURL,
                typeIdentifier: UTType.url.identifier
            ),
            NSItemProvider(
                item: String(repeating: "a", count: 120_001) as NSString,
                typeIdentifier: UTType.plainText.identifier
            ),
        ] {
            let item = NSExtensionItem()
            item.attachments = [provider]
            let model = SparkShareModel()
            await model.load([item])
            #expect(model.loadFailed)
            #expect(model.text.isEmpty)
        }
    }
}

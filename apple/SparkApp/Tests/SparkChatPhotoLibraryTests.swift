import Foundation
import SparkAPI
import SparkCore
import SparkLanguageModel
import Testing
@testable import SparkAppComposition

private actor PhotoRecordingStreamer: SparkChatStreaming {
    var requests: [ChatCompletionRequest] = []

    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        requests.append(request)
        return AsyncThrowingStream {
            $0.yield(.chunk(id: nil, model: nil, delta: "Photo received", finishReason: "stop"))
            $0.finish()
        }
    }
}

private actor SuspendedPhoto {
    private var continuation: CheckedContinuation<SparkChatAttachment, Never>?
    private(set) var started = false

    func load() async -> SparkChatAttachment {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }

    func finish() {
        continuation?.resume(returning: .init(name: "photo.jpg", jpeg: Data([1, 2, 3])))
        continuation = nil
    }
}

@Suite("Chat photo library")
@MainActor
struct SparkChatPhotoLibraryTests {
    private func model(vision: Bool?, stream: PhotoRecordingStreamer = .init()) -> SparkChatModel {
        SparkChatModel(
            catalogue: .init(
                targets: [
                    .init(
                        id: "photo-spark",
                        displayName: "Photo Spark",
                        nodeID: .init(rawValue: UUID()),
                        route: URL(string: "https://photo.invalid")!,
                        tlsFingerprint: "sample",
                        authorityFingerprint: "sample",
                        modelID: "photo-model",
                        modelName: "Photo model",
                        visionSupported: vision
                    )
                ],
                pairedTargetCount: 1
            ),
            streamer: stream
        )
    }

    @Test(arguments: [false, nil] as [Bool?])
    func unsupportedModelsExplainBeforeReadingAPhoto(vision: Bool?) async {
        let chat = model(vision: vision)
        chat.draft = "Keep my words"
        await chat.importPhotos([
            .init {
                Issue.record("An unavailable model must not read a selected library photo")
                return .init(name: "photo.jpg", jpeg: Data([1]))
            }
        ])
        #expect(chat.photoLibraryBlocker != nil)
        #expect(chat.attachmentError == chat.photoLibraryBlocker)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.draft == "Keep my words")
        #expect(chat.canSend)
        await chat.importSharedFiles([.init(name: "notes.txt", data: Data("Still works".utf8))])
        #expect(chat.pendingAttachments.first?.text == "Still works")
        #expect(chat.attachmentError == nil)
    }

    @Test func importsRealPhotoFilesAndIncludesImagesInTheModelRequest() async throws {
        let stream = PhotoRecordingStreamer()
        let chat = model(vision: true, stream: stream)
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(
                "../Shared/Assets.xcassets/AppIcon.appiconset/SparkPilotIcon-32.png"
            )
        let source = SparkChatPhotoSource {
            try SparkChatAttachmentReader.readPhoto(url: path)
        }
        chat.draft = "What is in this photo?"
        await chat.importPhotos([source])
        #expect(chat.canSend)
        #expect(chat.pendingAttachments.first?.isImage == true)
        #expect(chat.pendingAttachments.first?.imageDataURL?.hasPrefix("data:image/jpeg;") == true)
        #expect(chat.messages.isEmpty)
        #expect(await stream.requests.isEmpty)
        await chat.send()?.value
        let request = try #require(await stream.requests.first)
        #expect(request.messages.last?.imageDataURLs.count == 1)
        #expect(request.messages.last?.content.contains("What is in this photo?") == true)
    }

    @Test func cancelledPhotoDoesNotReappearInANewDraftOrCancelANewerImport() async throws {
        let chat = model(vision: true)
        let oldPhoto = SuspendedPhoto()
        let oldImport = Task { await chat.importPhotos([.init { await oldPhoto.load() }]) }
        while !(await oldPhoto.started) { await Task.yield() }
        #expect(chat.isImportingAttachments)
        chat.draft = "Wait for the photo"
        #expect(!chat.canSend)
        chat.newConversation()
        #expect(!chat.isImportingAttachments)
        let newPhoto = SuspendedPhoto()
        let newImport = Task { await chat.importPhotos([.init { await newPhoto.load() }]) }
        while !(await newPhoto.started) { await Task.yield() }
        await oldPhoto.finish()
        await oldImport.value
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.isImportingAttachments)
        await newPhoto.finish()
        await newImport.value
        #expect(chat.pendingAttachments.count == 1)
        #expect(!chat.isImportingAttachments)
        #expect(chat.attachmentError == nil)
    }

    @Test func failedPhotoBatchAndAttachmentLimitPreserveExistingDraft() async {
        let chat = model(vision: true)
        await chat.importSharedFiles([.init(name: "notes.txt", data: Data("Keep".utf8))])
        let photo = SparkChatPhotoSource { .init(name: "photo.jpg", jpeg: Data([1])) }
        await chat.importPhotos([photo, .init { throw SparkAttachmentError.unreadable }])
        #expect(chat.pendingAttachments.map(\.name) == ["notes.txt"])
        #expect(chat.attachmentError != nil)
        await chat.importPhotos(Array(repeating: photo, count: 8))
        #expect(chat.pendingAttachments.count == 1)
        #expect(chat.attachmentError == SparkAttachmentError.tooMany.errorDescription)
        await chat.importPhotos([photo])
        #expect(chat.pendingAttachments.count == 2)
        #expect(chat.attachmentError == nil)
    }

    @Test func changingToATextModelWhileAPhotoLoadsKeepsItButBlocksSending() async throws {
        let chat = model(vision: true)
        let photo = SuspendedPhoto()
        let task = Task { await chat.importPhotos([.init { await photo.load() }]) }
        while !(await photo.started) { await Task.yield() }
        chat.replaceCatalogue(model(vision: false).catalogue)
        await photo.finish()
        await task.value
        #expect(chat.pendingAttachments.count == 1)
        #expect(chat.attachmentBlocker != nil)
        #expect(!chat.canSend)
        #expect(chat.send() == nil)
    }
}

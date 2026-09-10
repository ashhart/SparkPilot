import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

/// Own attachment-import tasks and invalidate late completions when a draft is cancelled.
@MainActor
@Observable
final class SparkChatAttachmentDraft {
    var pendingAttachments: [SparkChatAttachment] = [] { didSet { onChange?() } }
    private(set) var isImportingAttachments = false
    var attachmentError: String?
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var importTask: Task<[SparkChatAttachment], any Error>?
    @ObservationIgnored private var importID = UUID()

    func importFiles(_ urls: [URL], allowed: Bool) async {
        guard urls.count + pendingAttachments.count <= 8 else {
            attachmentError = SparkAttachmentError.tooMany.errorDescription
            return
        }
        await importBatch(allowed: allowed) {
            try urls.map { try SparkChatAttachmentReader.read(url: $0) }
        }
    }

    func importSharedFiles(_ files: [SparkSharedFile], allowed: Bool) async {
        guard files.count + pendingAttachments.count <= 8 else {
            attachmentError = SparkAttachmentError.tooMany.errorDescription
            return
        }
        await importBatch(allowed: allowed) {
            try files.map { try SparkChatAttachmentReader.read(data: $0.data, name: $0.name) }
        }
    }

    func importPhotos(_ photos: [SparkChatPhotoSource], allowed: Bool) async {
        guard photos.count + pendingAttachments.count <= 8 else {
            attachmentError = SparkAttachmentError.tooMany.errorDescription
            return
        }
        await importBatch(allowed: allowed) {
            var attachments: [SparkChatAttachment] = []
            for photo in photos {
                try Task.checkCancellation()
                attachments.append(try await photo.load())
            }
            return attachments
        }
    }

    private func importBatch(
        allowed: Bool,
        _ operation: @escaping @Sendable () async throws -> [SparkChatAttachment]
    )
        async
    {
        guard !isImportingAttachments, allowed else {
            return
        }
        isImportingAttachments = true
        attachmentError = nil
        let attempt = UUID()
        importID = attempt
        let task = Task.detached(priority: .userInitiated) { try await operation() }
        importTask = task
        do {
            let attachments = try await task.value
            guard importID == attempt else { return }
            guard pendingAttachments.count + attachments.count <= 8 else {
                throw SparkAttachmentError.tooMany
            }
            guard
                (pendingAttachments + attachments).reduce(0, { $0 + ($1.text?.utf8.count ?? 0) })
                    <= SparkChatAttachmentReader.maximumTextBytes
            else { throw SparkAttachmentError.tooLarge }
            pendingAttachments += attachments
        } catch is CancellationError {
        } catch {
            guard importID == attempt else { return }
            attachmentError =
                (error as? LocalizedError)?.errorDescription
                ?? SparkAttachmentError.unreadable.errorDescription
        }
        guard importID == attempt else { return }
        isImportingAttachments = false
        importTask = nil
    }

    func cancelAttachmentImport() {
        importID = UUID()
        importTask?.cancel()
        importTask = nil
        isImportingAttachments = false
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        attachmentError = nil
    }

    func blocker(messages: [SparkChatMessage], target: SparkChatTarget?) -> String? {
        let hasImages =
            pendingAttachments.contains(where: \.isImage)
            || messages.contains { $0.attachments.contains(where: \.isImage) }
        return hasImages && target?.visionSupported != true
            ? SparkAttachmentError.visionUnavailable.errorDescription : nil
    }

}

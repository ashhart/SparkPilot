import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI

/// The system exports only the photos selected by the owner, without library-wide permission.
struct SparkChatPhotoSource: Sendable {
    let load: @Sendable () async throws -> SparkChatAttachment

    init(load: @escaping @Sendable () async throws -> SparkChatAttachment) { self.load = load }

    init(item: PhotosPickerItem) {
        load = {
            guard let photo = try await item.loadTransferable(type: SparkPickedChatPhoto.self)
            else {
                throw SparkAttachmentError.unreadable
            }
            try Task.checkCancellation()
            return photo.attachment
        }
    }
}

private struct SparkPickedChatPhoto: Transferable {
    let attachment: SparkChatAttachment

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(attachment: try SparkChatAttachmentReader.readPhoto(url: received.file))
        }
    }
}

extension SparkChatModel {
    var photoLibraryBlocker: String? {
        guard let target = selectedTarget else {
            return String(localized: "Choose a model that supports images to attach a photo.")
        }
        switch target.visionSupported {
        case true: return nil
        case false:
            return String(
                localized:
                    "This model doesn't support images. Choose a model with image support from the menu at the top of the chat."
            )
        default:
            return String(
                localized:
                    "Image support hasn't been confirmed for this model. Choose a model with image support from the menu at the top of the chat."
            )
        }
    }
}

@MainActor
struct SparkChatAttachmentPickers: ViewModifier {
    let model: SparkChatModel
    @Binding var showsFiles: Bool
    @Binding var showsPhotos: Bool
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showsFiles,
                allowedContentTypes: SparkChatAttachmentReader.supportedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): Task { await model.importFiles(urls) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        model.attachmentError = SparkAttachmentError.unreadable.errorDescription
                    }
                }
            }
            .photosPicker(
                isPresented: $showsPhotos,
                selection: $photos,
                maxSelectionCount: max(1, 8 - model.pendingAttachments.count),
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: photos) { _, selected in
                guard !selected.isEmpty else { return }
                photos = []
                let sources = selected.map { SparkChatPhotoSource(item: $0) }
                Task { await model.importPhotos(sources) }
            }
    }
}

import SwiftUI

@MainActor
struct SparkChatToolsMenu: View {
    let model: SparkChatModel
    let attachFiles: () -> Void
    let attachPhotos: () -> Void
    let personalActions: () -> Void
    let householdNotes: () -> Void
    let webSettings: () -> Void
    @State private var showsPhotoExplanation = false

    var body: some View {
        Menu {
            Button("Photo library", systemImage: "photo.on.rectangle") {
                if model.photoLibraryBlocker != nil {
                    showsPhotoExplanation = true
                } else {
                    attachPhotos()
                }
            }
            .disabled(
                model.isImportingAttachments || model.generationState == .streaming
                    || model.pendingAttachments.count >= 8
            )
            Button("Attach files", systemImage: "paperclip") { attachFiles() }
                .disabled(model.isImportingAttachments || model.generationState == .streaming)
            Button("Personal actions", systemImage: "checklist") {
                personalActions()
            }
            Button("Household notes", systemImage: "house") {
                householdNotes()
            }
            .disabled(model.selectedTarget == nil || model.generationState == .streaming)
            SparkChatPersonalContextMenuSection(model: model)
            SparkChatWebAccessMenuSection(conversation: model) {
                webSettings()
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 20)).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Chat tools")
        .alert("Images unavailable for this model", isPresented: $showsPhotoExplanation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.photoLibraryBlocker ?? "")
        }
    }

}

@MainActor
struct SparkChatAttachmentTray: View {
    let model: SparkChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.pendingAttachments.contains(where: \.isImage),
                model.selectedTarget?.visionSupported == true
            {
                Text("This model can read your photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isImportingAttachments {
                HStack {
                    ProgressView(String(localized: "Reading attachments…"))
                    Button("Cancel", action: model.cancelAttachmentImport)
                }
            }
            ForEach(model.pendingAttachments) { attachment in
                HStack {
                    Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc.text")
                        .lineLimit(2)
                    Spacer()
                    Button("Remove attachment", systemImage: "xmark.circle") {
                        model.removeAttachment(id: attachment.id)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(attachment.name)
                }
            }
            if model.pendingAttachments.contains(where: { !$0.isImage }) {
                Text(
                    "Documents are sent as extracted text; embedded images and page layout are not sent."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.attachmentError {
                Text(error).foregroundStyle(.red)
            }
            if let blocker = model.attachmentBlocker {
                Label(blocker, systemImage: "eye.slash").foregroundStyle(.primary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

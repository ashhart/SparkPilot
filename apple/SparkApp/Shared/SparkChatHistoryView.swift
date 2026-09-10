import SwiftUI

/// When a chat was last touched, without counting seconds no one waits for.
enum SparkChatHistoryTimestamp {
    /// Under a minute reads "Now"; past that the row carries the relative age it always did.
    static func label(for date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "Now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

@MainActor
struct SparkChatHistoryView: View {
    @Bindable var workspace: SparkChatWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var renaming: SparkChatConversation?
    @State private var deleting: SparkChatConversation?
    @State private var title = ""

    private var results: [SparkChatConversation] {
        workspace.sortedConversations.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.model.messages.contains {
                    $0.content.localizedCaseInsensitiveContains(search)
                }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = workspace.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Section {
                    ForEach(results) { conversation in
                        Button {
                            workspace.select(conversation.id)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(
                                    systemName: conversation.id == workspace.selectedID
                                        ? "bubble.left.fill" : "bubble.left"
                                )
                                .font(.body)
                                .foregroundStyle(
                                    conversation.id == workspace.selectedID
                                        ? Color.primary : .secondary
                                )
                                .frame(width: 24)
                                .padding(.top, 3)
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(conversation.title).font(.body.weight(.semibold))
                                            .lineLimit(2)
                                        Spacer(minLength: 8)
                                        if conversation.model.generationState == .streaming {
                                            ProgressView().controlSize(.small)
                                                .accessibilityLabel("Generating a response")
                                        }
                                    }
                                    Text(conversation.preview)
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    Text(
                                        SparkChatHistoryTimestamp.label(
                                            for: conversation.updatedAt
                                        )
                                    )
                                    .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            conversation.id == workspace.selectedID ? [.isSelected] : []
                        )
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { beginRename(conversation) }
                            SparkChatPlainStyleMenuItems(model: conversation.model)
                            Button("Delete chat", systemImage: "trash", role: .destructive) {
                                deleting = conversation
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deleting = conversation
                            }
                            Button("Rename", systemImage: "pencil") { beginRename(conversation) }
                                .tint(.gray)
                        }
                        .accessibilityAction(named: Text("Rename")) { beginRename(conversation) }
                        .accessibilityAction(named: Text("Delete chat")) { deleting = conversation }
                    }
                } footer: {
                    if search.isEmpty {
                        Text(
                            workspace.isPersistent
                                ? String(
                                    localized:
                                        "Chats are saved on this device and sent to the Spark you select. They are not synced or included in device backups. You can delete them from Chat history."
                                )
                                : String(
                                    localized:
                                        "These chats are kept in memory and sent only to the Spark you select."
                                )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.top, 8)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: search) }
            }
            .navigationTitle("Chats")
            .searchable(text: $search, prompt: Text("Search chats"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        workspace.newChat()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .alert(
                "Rename chat",
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                )
            ) {
                TextField("Chat name", text: $title)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { workspace.rename(renaming.id, to: title) }
                    renaming = nil
                }
            }
            // An alert, because a popover confirmation drops the cancel button it is given.
            .alert(
                "Delete this chat?",
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                )
            ) {
                Button(
                    String(
                        localized: .deleteChatNamed(
                            deleting?.title ?? String(localized: "this chat")
                        )
                    ),
                    role: .destructive
                ) {
                    if let deleting { workspace.delete(deleting.id) }
                    deleting = nil
                }
                // Dismissing by tapping outside is not an action VoiceOver or a keyboard can find.
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text(
                    "This removes the messages from this device and stops any response in progress."
                )
            }
        }
        .frame(idealWidth: 560, idealHeight: 680)
    }

    private func beginRename(_ conversation: SparkChatConversation) {
        title = conversation.title
        renaming = conversation
    }
}

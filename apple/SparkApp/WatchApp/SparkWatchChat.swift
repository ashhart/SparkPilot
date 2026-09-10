import SparkWatchSupport
import SwiftUI

struct SparkWatchChat: View {
    @Bindable var store: SparkWatchStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingOptions = false
    @State private var confirmingNewChat = false

    var body: some View {
        ScrollViewReader { reader in
            SparkWatchPage {
                if store.isPreview { SparkWatchPreviewBadge() }
                if store.messages.isEmpty && store.draft.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What’s on your mind?")
                            .font(.title3.weight(.semibold))
                        Text("Dictate or type, then review before sending.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
                ForEach(store.messages) { message in
                    messageView(message)
                }
                SparkWatchFeedback(store: store).id("feedback")
                if !store.draft.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SparkWatchCaption(text: "Ready to send")
                        Text(store.draft).font(.body)
                        VStack(spacing: 8) {
                            composer(title: "Dictate again", symbol: "mic")
                            Button("Discard", role: .cancel) { store.draft = "" }
                                .buttonStyle(SparkWatchControlStyle())
                        }
                    }
                    .padding(.top, 4)
                    .id("draft")
                }
                if !store.canAsk && !store.busy && store.pendingID == nil && !store.isPreview {
                    Text(
                        store.target?.canAsk == false
                            ? "Chat isn’t available for this Spark. Check its permissions on iPhone."
                            : "Connect your iPhone to send a message."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    if store.draft.isEmpty {
                        composer(
                            title: store.messages.isEmpty ? "Ask" : "Reply",
                            symbol: "mic.fill"
                        )
                    } else {
                        Button {
                            store.sendDraft()
                        } label: {
                            if typeSize >= .xxLarge {
                                Image(systemName: "arrow.up").accessibilityLabel("Send")
                            } else {
                                Label("Send", systemImage: "arrow.up")
                            }
                        }
                        .buttonStyle(SparkWatchControlStyle(prominent: true))
                        .disabled(!store.canAsk)
                    }
                    Button {
                        showingOptions = true
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(SparkWatchStyle.surface, in: Circle())
                    .accessibilityLabel("Chat options")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .task {
                await Task.yield()
                if store.busy || store.pendingID != nil || store.error != nil {
                    reader.scrollTo("feedback", anchor: .top)
                } else if !store.draft.isEmpty {
                    reader.scrollTo("draft", anchor: .top)
                } else if let message = store.messages.last {
                    reader.scrollTo(message.id, anchor: .top)
                }
            }
            .onChange(of: store.busy) { _, busy in
                if busy { reader.scrollTo("feedback", anchor: .bottom) }
            }
            .onChange(of: store.error) { _, error in
                if error != nil { reader.scrollTo("feedback", anchor: .top) }
            }
            .onChange(of: store.messages.last?.id) { _, _ in
                if let message = store.messages.last { reader.scrollTo(message.id, anchor: .top) }
            }
            .onChange(of: store.draft.isEmpty) { _, isEmpty in
                if !isEmpty { reader.scrollTo("draft", anchor: .top) }
            }
        }
        .navigationTitle("Talk")
        .sheet(isPresented: $showingOptions) {
            NavigationStack {
                List {
                    Toggle("Read replies aloud", isOn: $store.readsAloud)
                    if let reply = store.messages.last(where: { $0.role == .assistant }) {
                        Button("Read latest reply") { store.speak(reply.text) }
                    }
                    Button("Stop audio") { store.stopSpeaking() }
                    Button("New conversation", role: .destructive) { confirmingNewChat = true }
                        .disabled(store.busy || store.pendingID != nil || store.messages.isEmpty)
                    Text("Dictation uses your Watch settings. AI replies run on your Spark.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Chat options")
                .toolbarTitleDisplayMode(.inline)
                .confirmationDialog("Clear this conversation?", isPresented: $confirmingNewChat) {
                    Button("Clear conversation", role: .destructive) {
                        store.newChat()
                        showingOptions = false
                    }
                }
            }
        }
    }

    private func composer(title: String, symbol: String) -> some View {
        TextFieldLink(prompt: Text("Ask your AI")) {
            if typeSize >= .xxLarge && ["Ask", "Reply"].contains(title) {
                Image(systemName: symbol).accessibilityLabel(title)
            } else {
                Label(title, systemImage: symbol)
            }
        } onSubmit: {
            store.draft = $0
        }
        .buttonStyle(SparkWatchControlStyle(prominent: store.draft.isEmpty))
        .disabled(!store.canCompose)
        .accessibilityHint("Dictate or type a message, then review it before sending")
    }

    private func messageView(_ message: SparkWatchMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : store.isPreview ? "Sample reply" : "SparkPilot")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(message.role == .user ? Color.secondary : SparkWatchStyle.accent)
            Text(message.text)
                .font(message.role == .user ? .footnote : .body)
                .foregroundStyle(message.role == .user ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(message.role == .user ? 12 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.role == .user ? SparkWatchStyle.surface : .clear,
            in: RoundedRectangle(cornerRadius: SparkWatchStyle.radius)
        )
        .padding(.bottom, 4)
        .id(message.id)
    }
}

import Foundation
import Observation
import SparkLibrary
import SwiftUI

struct SharedChatSession: Identifiable {
    let id: UUID
    let model: SparkChatModel
    let workspace: SparkChatWorkspace
    let share: SparkSharedChat
}

/// Keeps incoming chats across navigation, retaining originals until removal without saving replies.
@MainActor
@Observable
final class SparkSharedChatReceptionModel {
    private(set) var session: SharedChatSession?
    var inboxError: String?
    private let library: SparkLibrary
    let appLock: AppLockModel?
    private let inbox: @MainActor () throws -> SparkChatInbox
    private var deferredID: UUID?
    private var readingInbox = false
    private var reportedUnreadable = false
    private var preparedID: UUID?

    init(
        library: SparkLibrary,
        appLock: AppLockModel? = nil,
        inbox: @escaping @MainActor () throws -> SparkChatInbox = { try .shared() }
    ) {
        self.library = library
        self.appLock = appLock
        self.inbox = inbox
    }

    func becameActive() async {
        deferredID = nil
        await receive()
    }

    func receive() async {
        guard session == nil, !readingInbox, appLock?.isLocked != true else { return }
        guard let inbox = try? inbox() else { return }
        readingInbox = true
        defer { readingInbox = false }
        do {
            let share = try await Task.detached { try inbox.next() }.value
            let unreadable = inbox.unreadableCount()
            if unreadable > 0, !reportedUnreadable {
                reportedUnreadable = true
                inboxError = String(localized: .unreadableShares(unreadable))
            }
            guard let share, share.id != deferredID, session == nil,
                appLock?.isLocked != true
            else { return }
            let model = SparkChatModel(library: library)
            model.draft = share.text
            session = SharedChatSession(
                id: share.id,
                model: model,
                workspace: SparkChatWorkspace(initialModel: model),
                share: share
            )
        } catch {
            inboxError = SparkChatInbox.InboxError.invalid.errorDescription
        }
    }

    func prepare(_ item: SharedChatSession) async {
        guard session?.id == item.id, preparedID != item.id else { return }
        preparedID = item.id
        await item.model.importSharedFiles(item.share.files)
    }

    func keepForLater(_ item: SharedChatSession) {
        guard session?.id == item.id else { return }
        deferredID = item.id
        close(item)
    }

    func finish(_ item: SharedChatSession) {
        guard session?.id == item.id else { return }
        do {
            try inbox().remove(id: item.id)
            close(item)
        } catch {
            inboxError = SparkChatInbox.InboxError.invalid.errorDescription
        }
    }

    func discardUnreadable() {
        do {
            try inbox().discardUnreadableShares()
            inboxError = nil
        } catch {
            inboxError = SparkChatInbox.InboxError.invalid.errorDescription
        }
    }

    private func close(_ item: SharedChatSession) {
        for conversation in item.workspace.conversations {
            conversation.model.cancelAttachmentImport()
            conversation.model.cancel()
        }
        preparedID = nil
        session = nil
    }
}

struct SparkSharedChatView: View {
    let reception: SparkSharedChatReceptionModel
    let item: SharedChatSession

    var body: some View {
        SparkChatView(workspace: item.workspace)
            .safeAreaInset(edge: .top) {
                Text(
                    "The original share stays on this device until you remove it; replies and draft edits are kept only while this chat is open."
                )
                .font(.caption).foregroundStyle(.secondary).padding()
            }
            .navigationTitle("Shared chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep for later") { reception.keepForLater(item) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close and remove share") { reception.finish(item) }
                }
            }
            .task(id: item.id) { await reception.prepare(item) }
            .modifier(SharedChatLock(appLock: reception.appLock))
    }
}

private struct SparkSharedChatInboxObserver: ViewModifier {
    @Bindable var model: SparkSharedChatReceptionModel
    var receivesAfterClosing = true
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await model.receive() }
            .onChange(of: model.appLock?.isLocked) { _, locked in
                if locked != true { Task { await model.receive() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.becameActive() } }
            }
            .onChange(of: model.session?.id) { _, id in
                if id == nil, receivesAfterClosing { Task { await model.receive() } }
            }
            .alert(
                "Some shared items could not be read",
                isPresented: Binding(
                    get: { model.inboxError != nil },
                    set: { if !$0 { model.inboxError = nil } }
                )
            ) {
                Button("Keep them", role: .cancel) { model.inboxError = nil }
                Button("Remove unreadable items", role: .destructive) {
                    model.discardUnreadable()
                }
            } message: {
                Text(model.inboxError ?? "")
            }
    }
}

private struct SparkSharedChatReception: ViewModifier {
    @State private var model: SparkSharedChatReceptionModel

    init(library: SparkLibrary, appLock: AppLockModel?) {
        _model = State(
            initialValue: SparkSharedChatReceptionModel(library: library, appLock: appLock)
        )
    }

    func body(content: Content) -> some View {
        content
            .modifier(SparkSharedChatInboxObserver(model: model, receivesAfterClosing: false))
            .sheet(
                item: Binding(get: { model.session }, set: { _ in }),
                onDismiss: { Task { await model.receive() } }
            ) { item in
                NavigationStack {
                    SparkSharedChatView(reception: model, item: item)
                        .id(item.id)
                }
                .frame(minWidth: 320, idealWidth: 700, minHeight: 480)
                .interactiveDismissDisabled()
            }
    }
}

private struct SharedChatLock: ViewModifier {
    let appLock: AppLockModel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let appLock {
            AppLockGate(model: appLock) { content }
        } else {
            content
        }
    }
}

extension View {
    func observesSparkChatShares(_ model: SparkSharedChatReceptionModel) -> some View {
        modifier(SparkSharedChatInboxObserver(model: model))
    }

    public func receivesSparkChatShares(library: SparkLibrary, appLock: AppLockModel? = nil)
        -> some View
    {
        modifier(SparkSharedChatReception(library: library, appLock: appLock))
    }
}

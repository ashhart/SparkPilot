import Foundation
import Observation
import SparkLibrary

struct SparkChatRecord: Codable, Equatable {
    let id: UUID
    var title: String?
    var updatedAt: Date
    var targetID: String?
    var draft: String
    var messages: [SparkChatMessage]
    var pendingAttachments: [SparkChatAttachment]? = nil
    var modelID: String? = nil
    /// Absent means this conversation follows the app-wide plain-style setting.
    var plainStyleOverride: Bool? = nil
    var sharesPersonalContext: Bool? = nil
    var allowsWebAccess: Bool? = nil
    var replyDraft: SparkChatReplyReference? = nil
}

struct SparkChatArchive: Codable {
    var version = 1
    var selectedID: UUID?
    var conversations: [SparkChatRecord] = []
}

@MainActor
protocol SparkChatStoring {
    func load() throws -> SparkChatArchive
    func save(_ archive: SparkChatArchive) throws
}

/// Restore only transcript target IDs and resolve fresh authenticated evidence for every send.
@MainActor
struct FileSparkChatStore: SparkChatStoring {
    let url: URL

    static func applicationStore() -> Self {
        let support = URL.applicationSupportDirectory
            .appendingPathComponent("SparkChat", isDirectory: true)
        return Self(url: support.appendingPathComponent("conversations.json"))
    }

    func load() throws -> SparkChatArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return SparkChatArchive() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 64 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let archive = try JSONDecoder().decode(SparkChatArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1,
            Set(archive.conversations.map(\.id)).count == archive.conversations.count,
            archive.conversations.allSatisfy({
                Set($0.messages.map(\.id)).count == $0.messages.count
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }

    func save(_ archive: SparkChatArchive) throws {
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
            try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
@Observable
public final class SparkChatConversation: Identifiable {
    public let id: UUID
    public let model: SparkChatModel
    public fileprivate(set) var customTitle: String?
    public fileprivate(set) var updatedAt: Date

    init(id: UUID = UUID(), model: SparkChatModel, title: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.model = model
        customTitle = title
        self.updatedAt = updatedAt
    }

    public var title: String {
        if let customTitle { return customTitle }
        let prompt = model.messages.first(where: { $0.role == .user })?.content ?? model.draft
        let line = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? String(localized: "New chat") : String(line.prefix(64))
    }

    public var preview: String {
        if model.generationState == .streaming {
            return String(localized: "Generating a response…")
        }
        if !model.draft.isEmpty { return String(localized: .chatDraft(model.draft)) }
        return model.messages.last(where: { $0.hasAnswer })?.content
            ?? String(localized: "No messages yet")
    }

    var record: SparkChatRecord {
        SparkChatRecord(
            id: id,
            title: customTitle,
            updatedAt: updatedAt,
            targetID: model.selectedTargetID,
            draft: model.draft,
            messages: model.messages,
            pendingAttachments: model.pendingAttachments.isEmpty ? nil : model.pendingAttachments,
            modelID: model.selectedModelID,
            plainStyleOverride: model.plainStyleOverride,
            sharesPersonalContext: model.sharesPersonalContext ? true : nil,
            allowsWebAccess: model.allowsWebAccess ? true : nil,
            replyDraft: model.replyDraft
        )
    }
}

@MainActor
@Observable
public final class SparkChatWorkspace {
    public private(set) var conversations: [SparkChatConversation] = []
    public private(set) var selectedID: UUID
    public private(set) var storageError: String?
    @ObservationIgnored private let store: (any SparkChatStoring)?
    @ObservationIgnored private let prototype: SparkChatModel
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var loadFailed = false

    private static var sharedWorkspace: SparkChatWorkspace?

    /// Serialize archive writes across windows to prevent independently loaded snapshots from overwriting each other.
    public static func shared(library: SparkLibrary) -> SparkChatWorkspace {
        if let sharedWorkspace { return sharedWorkspace }
        let workspace = SparkChatWorkspace(library: library)
        sharedWorkspace = workspace
        return workspace
    }

    public convenience init(library: SparkLibrary) {
        let model = SparkChatModel(library: library)
        // Every conversation in this workspace is gated by the owner's §39.2 execution policy.
        model.executionPolicy = SparkExecutionPolicyModel()
        self.init(initialModel: model, store: FileSparkChatStore.applicationStore())
    }

    public convenience init(initialModel: SparkChatModel) {
        self.init(initialModel: initialModel, store: nil)
    }

    init(initialModel: SparkChatModel, store: (any SparkChatStoring)?) {
        self.prototype = initialModel
        self.store = store
        let initial = SparkChatConversation(model: initialModel)
        selectedID = initial.id
        conversations = [initial]
        do {
            if let archive = try store?.load(), !archive.conversations.isEmpty {
                conversations = archive.conversations.map { record in
                    let model = initialModel.makeSibling()
                    model.restore(
                        messages: record.messages,
                        draft: record.draft,
                        targetID: record.targetID,
                        at: record.updatedAt,
                        pendingAttachments: record.pendingAttachments ?? [],
                        modelID: record.modelID,
                        sharesPersonalContext: record.sharesPersonalContext ?? false,
                        replyDraft: record.replyDraft
                    )
                    model.allowsWebAccess = record.allowsWebAccess ?? false
                    model.restorePlainStyleOverride(record.plainStyleOverride)
                    return SparkChatConversation(
                        id: record.id,
                        model: model,
                        title: record.title,
                        updatedAt: record.updatedAt
                    )
                }
                selectedID =
                    conversations.first(where: { $0.id == archive.selectedID })?.id
                    ?? conversations[0].id
            }
        } catch {
            loadFailed = true
            storageError = String(
                localized:
                    "Saved chats could not be opened; the saved file has been kept. New messages will stay in memory until you reopen the app."
            )
        }
        for conversation in conversations { observe(conversation) }
    }

    public var selected: SparkChatConversation {
        conversations.first(where: { $0.id == selectedID }) ?? conversations[0]
    }

    public var sortedConversations: [SparkChatConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var isPersistent: Bool { store != nil }

    public func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selected.model.refreshTargets()
        flush()
    }

    public func newChat() {
        if let empty = conversations.first(where: {
            $0.model.messages.isEmpty && $0.model.draft.isEmpty && $0.customTitle == nil
                && $0.model.pendingAttachments.isEmpty && !$0.model.isImportingAttachments
        }) {
            select(empty.id)
            return
        }
        let conversation = SparkChatConversation(model: prototype.makeSibling())
        if let target = selected.model.selectedTarget {
            conversation.model.selectTarget(target)
        }
        observe(conversation)
        conversations.append(conversation)
        select(conversation.id)
    }

    /// Use refreshed route evidence, but never open a different Spark after a launch.
    @discardableResult
    public func openReadyTarget(_ target: SparkChatTarget) -> Bool {
        refreshTargets()
        guard
            let current = selected.model.availableModelChoices.first(where: {
                $0.selectionID == target.selectionID && $0.nodeID == target.nodeID
                    && $0.authorityFingerprint == target.authorityFingerprint
            })
        else { return false }
        selectTarget(current)
        return selected.model.selectedTarget?.selectionID == current.selectionID
    }

    public func selectTarget(_ target: SparkChatTarget) {
        let current = selected.model
        guard current.availableModelChoices.contains(target) else { return }
        if current.selectedTargetID != target.id,
            !current.messages.isEmpty || !current.draft.isEmpty
                || !current.pendingAttachments.isEmpty || current.isImportingAttachments
                || current.replyDraft != nil
        {
            current.cancel()
            let conversation = SparkChatConversation(model: prototype.makeSibling())
            conversation.model.selectTarget(target)
            observe(conversation)
            conversations.append(conversation)
            select(conversation.id)
        } else {
            current.selectTarget(target)
        }
    }

    public func rename(_ id: UUID, to title: String) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        conversation.customTitle = clean.isEmpty ? nil : clean
        flush()
    }

    public func delete(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        conversation.model.onChange = nil
        conversation.model.cancel()
        conversation.model.cancelAttachmentImport()
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let replacement = SparkChatConversation(model: prototype.makeSibling())
            observe(replacement)
            conversations = [replacement]
        }
        if selectedID == id { selectedID = sortedConversations[0].id }
        flush()
    }

    public func refreshTargets() {
        for conversation in conversations { conversation.model.refreshTargets() }
    }

    public func runTargetRefreshes(interval: Duration = .seconds(8)) async {
        while !Task.isCancelled {
            refreshTargets()
            await prototype.refreshTargetEvidence()
            guard !Task.isCancelled else { return }
            refreshTargets()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store, !loadFailed else { return }
        do {
            try store.save(
                SparkChatArchive(selectedID: selectedID, conversations: conversations.map(\.record))
            )
            storageError = nil
        } catch {
            storageError = String(
                localized:
                    "Changes could not be saved on this device; keep the app open and try saving again."
            )
        }
    }

    private func observe(_ conversation: SparkChatConversation) {
        conversation.model.preservesTargetWhenUnavailable = true
        conversation.model.onChange = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            conversation.updatedAt = Date()
            // Persist completed output immediately and checkpoint drafts or streams at least once per active second.
            if conversation.model.generationState != .streaming, conversation.model.draft.isEmpty {
                self.flush()
            } else if self.pendingSave == nil {
                self.pendingSave = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.flush()
                }
            }
        }
    }
}

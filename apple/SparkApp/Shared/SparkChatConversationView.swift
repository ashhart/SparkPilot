import Foundation
import SparkDesignSystem
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

@MainActor
struct SparkChatConversationView: View {
    @Bindable var model: SparkChatModel
    @Bindable private var workspace: SparkChatWorkspace
    @State private var showsHistory = false
    @State private var voiceMode: SparkVoiceMode?
    @State private var showingFilePicker = false
    @State private var showingPhotoPicker = false
    @State private var personalContext: PersonalActionContext?
    @State private var householdTarget: SparkChatTarget?
    @State private var webSettingsTarget: SparkChatTarget?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sparkTypingRestriction) private var typingRestriction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState var composerFocused: Bool
    @State private var scrollState = SparkChatScrollState()
    @State private var scrollPosition = ScrollPosition()
    @State private var revealedReplyID: UUID?
    @State private var highlightedMessageID: UUID?
    private let onAddSpark: (@MainActor () -> Void)?

    init(
        model: SparkChatModel,
        workspace: SparkChatWorkspace,
        onAddSpark: (@MainActor () -> Void)? = nil
    ) {
        self.model = model
        self.workspace = workspace
        self.onAddSpark = onAddSpark
    }

    private var visibleEmptyState: SparkChatEmptyState? {
        guard model.availableModelChoices.isEmpty, model.messages.isEmpty,
            model.draft.isEmpty, model.pendingAttachments.isEmpty
        else { return nil }
        return model.catalogue.emptyState
    }

    public var body: some View {
        Group {
            if let state = visibleEmptyState {
                emptyView(state).accessibilityIdentifier("spark.chat.empty")
            } else {
                transcript
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if visibleEmptyState == nil { composer }
        }
        .modifier(
            SparkChatAttachmentPickers(
                model: model,
                showsFiles: $showingFilePicker,
                showsPhotos: $showingPhotoPicker
            )
        )
        .background(ChatStyle.canvas)
        .navigationTitle("Chat")
        .sparkExecutionPolicyPrompts(model: model)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showsHistory = true
                } label: {
                    Image(systemName: "text.bubble")
                        .frame(minWidth: 36, minHeight: 44)
                }
                .tint(.primary)
                .accessibilityLabel("Chat history")
            }
            ToolbarItem(placement: .principal) {
                SparkChatHeaderView(model: model, selectTarget: workspace.selectTarget)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspace.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 36, minHeight: 44)
                }
                .tint(.primary)
                .accessibilityLabel("New chat")
                .accessibilityHint("Starts another conversation and keeps your other chats")
            }
        }
        .sheet(item: $personalContext) { context in
            SparkPersonalActionsView(chat: model, context: context.text)
        }
        .sheet(item: $householdTarget) { target in
            SparkHouseholdView(
                sparkName: target.displayName,
                service: SparkHouseholdService(target: target)
            ) { file in
                guard model.selectedTarget?.id == target.id else { return }
                await model.importSharedFiles([file])
            }
        }
        .sheet(isPresented: $showsHistory) { SparkChatHistoryView(workspace: workspace) }
        .sheet(item: $webSettingsTarget) { target in
            SparkWebAccessSetupView(target: target, conversation: model)
        }
        #if os(iOS)
            .fullScreenCover(item: $voiceMode) { mode in
                SparkVoiceChatView(model: model, mode: mode)
            }
        #else
            .sheet(item: $voiceMode) { mode in SparkVoiceChatView(model: model, mode: mode) }
        #endif
        .sheet(
            item: Binding(
                get: { model.pendingModelLaunch },
                set: { if $0 == nil, model.pendingModelLaunch != nil { model.cancelModelLaunch() } }
            )
        ) { plan in
            if let confirmation = plan.confirmation {
                ModelActionConfirmationView(
                    confirmation: confirmation,
                    cancel: model.cancelModelLaunch,
                    apply: { _ = model.confirmModelLaunch() }
                )
            }
        }
        .task { model.refreshTargets() }
        .readsWebAccessPolicy(for: model)
    }

    private func emptyView(_ state: SparkChatEmptyState) -> some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.symbol)
        } description: {
            Text(state.message)
        } actions: {
            emptyStateAction(state)
        }
    }

    /// Every empty state ends in a tap: pair, load, look again, or review the Spark that changed.
    @ViewBuilder
    private func emptyStateAction(_ state: SparkChatEmptyState) -> some View {
        switch state.action {
        case .addSpark:
            if let onAddSpark {
                Button("Add Spark", action: onAddSpark)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(SparkChatAccessibility.addSparkLabel)
            }
        case .pairAgain:
            if let onAddSpark {
                Button(state.actionTitle, action: onAddSpark).buttonStyle(.borderedProminent)
            }
        case .loadModel:
            Button(state.actionTitle, action: openModelsForUnavailableSpark)
                .buttonStyle(.borderedProminent)
        case .checkAgain:
            Button(state.actionTitle) { model.refreshTargets() }
                .buttonStyle(.borderedProminent)
        case .reviewSparks:
            Button(state.actionTitle) { SparkWidgetNavigation.shared.requestHome() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func openModelsForUnavailableSpark() {
        let sparks = Set(model.catalogue.unavailableTargets.compactMap(\.id))
        if sparks.count == 1, let id = sparks.first {
            SparkWidgetNavigation.shared.openDashboard(
                targetID: id,
                section: SparkDashboardSection.models.rawValue
            )
        } else {
            SparkWidgetNavigation.shared.requestHome()
        }
    }

    private var transcript: some View {
        let latestReplyID = model.messages.last(where: { $0.role == .assistant })?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if model.messages.isEmpty {
                    SparkChatWelcomeView { prompt in
                        model.draft = prompt
                        composerFocused = true
                    }
                } else {
                    ForEach(model.messages) { message in
                        if message.role == .user {
                            userMessage(message)
                                .contextMenu {
                                    Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                        beginReply(to: message.id)
                                    }
                                    Button("Use for personal actions") {
                                        personalContext = .init(text: message.content)
                                    }
                                }
                                .accessibilityActions {
                                    Button("Reply") { beginReply(to: message.id) }
                                }
                                .background(messageHighlight(for: message.id))
                                .id(message.id)
                        } else {
                            SparkAssistantMessageView(
                                message: message,
                                showsActions: message.id == latestReplyID
                                    || message.id == revealedReplyID,
                                onRevealActions: { revealedReplyID = message.id },
                                onReply: { beginReply(to: message.id) },
                                onReadAloud: { voiceMode = .readAloud(message.content) },
                                onActions: { personalContext = .init(text: message.content) },
                                onInspectReasoning: {
                                    scrollState.pauseFollowing()
                                    scrollPosition = ScrollPosition()
                                }
                            )
                            .background(messageHighlight(for: message.id))
                            .id(message.id)
                        }
                    }
                }
                Color.clear.frame(height: 1).id("chat-bottom")
            }
            .frame(maxWidth: ChatStyle.readingWidth, alignment: .leading)
            .padding(.horizontal, ChatStyle.horizontalInset)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("spark.chat.transcript")
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollPosition($scrollPosition)
        .onChange(of: latestReplyID) { _, _ in revealedReplyID = nil }
        .task(id: highlightedMessageID) {
            guard highlightedMessageID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            highlightedMessageID = nil
        }
        // Follow growing responses only, so restored lazy content can settle before scrolling.
        .defaultScrollAnchor(
            model.generationState == .streaming && scrollState.followsLatest ? .bottom : nil,
            for: .sizeChanges
        )
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
            ChatScrollPosition(
                offset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { previous, current in
            scrollState.positionChanged(
                from: previous,
                to: current,
                isPositionedByUser: scrollPosition.isPositionedByUser
            )
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                scrollState.userScrollBegan()
            case .idle:
                scrollState.userScrollEnded()
            default:
                break
            }
        }
        .onChange(of: model.messages) { previous, current in
            scrollState.messagesChanged(from: previous, to: current)
            guard scrollState.followsLatest else { return }
            // Follow streamed text without per-token animation, pausing when the owner reads earlier messages or expanded reasoning.
            scrollPosition.scrollTo(edge: .bottom)
        }
        .overlay(alignment: .bottom) {
            if scrollState.showsLatestResponse {
                Button {
                    scrollState.resumeFollowing()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                } label: {
                    Label("Latest response", systemImage: "arrow.down")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(ChatStyle.border))
                .padding(.bottom, 8)
            }
        }
    }

    private func userMessage(_ message: SparkChatMessage) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 16 : 44)
            VStack(alignment: .leading, spacing: 8) {
                if let reply = message.replyTo {
                    replyPreview(reply)
                        .accessibilityIdentifier("spark.chat.sent-reply.\(message.id.uuidString)")
                }
                ForEach(message.attachments) { attachment in
                    Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc.text")
                        .font(.callout)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 22))
            .frame(maxWidth: 580, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message.accessibilityLabel)
            .accessibilityValue(message.attachments.map(\.name).joined(separator: ", "))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let message = model.modelLaunchState.message {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).font(.callout)
                        if let progress = model.modelLaunchProgress {
                            Text(progress.line).font(.caption).foregroundStyle(.secondary)
                            if let fraction = progress.fraction {
                                ProgressView(value: fraction).frame(maxWidth: 220)
                                    .accessibilityLabel(Text(verbatim: progress.line))
                                    .accessibilityValue(SparkPercent.text(fraction))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Cancel send", action: model.cancelModelLaunch)
                        .font(.caption)
                }
            } else if let error = model.modelLaunchError {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if model.selectedTarget != nil, !model.isSelectedModelReady,
                !model.isPreparingModel
            {
                Text("Send a message to load this model.").font(.caption)
                    .foregroundStyle(.secondary)
            }
            SparkChatAttachmentTray(model: model)
            if let use = model.contextUse, use.truncationNote != nil || use.hint != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let note = use.truncationNote { Text(note) }
                    if let hint = use.hint { Text(hint) }
                }
                .font(.caption)
                .foregroundStyle(use.tone == .critical ? Color.red : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SparkChatPersonalContextBar(model: model)
            SparkChatWebAccessChips(conversation: model)
            if let error = workspace.storageError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Try saving again") { workspace.flush() }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.selectedTarget == nil {
                Text(
                    model.catalogue.emptyState?.message
                        ?? String(
                            localized: "Choose an available Spark above to continue this chat."
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if case .failed(let failure) = model.generationState {
                failureBanner(failure)
            } else if model.canRetry, model.generationState != .streaming {
                HStack(spacing: 8) {
                    if model.generationState == .cancelled { Text("Response stopped") }
                    Spacer()
                    Button("Try again") {
                        scrollState.resumeFollowing()
                        _ = model.retry()
                    }
                    .accessibilityLabel(SparkChatAccessibility.retryLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            VStack(spacing: 8) {
                if let reply = model.replyDraft {
                    HStack(alignment: .top, spacing: 4) {
                        replyPreview(reply)
                        Button(action: model.cancelReply) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel reply")
                    }
                    .accessibilityIdentifier("spark.chat.reply-draft")
                }
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 4) {
                            draftField
                            HStack {
                                SparkChatToolsMenu(
                                    model: model,
                                    attachFiles: { showingFilePicker = true },
                                    attachPhotos: { showingPhotoPicker = true },
                                    personalActions: { personalContext = .init(text: model.draft) },
                                    householdNotes: { householdTarget = model.selectedTarget },
                                    webSettings: { webSettingsTarget = model.selectedTarget }
                                )
                                Spacer(minLength: 8)
                                voiceAndSendButtons
                            }
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: 8) {
                            SparkChatToolsMenu(
                                model: model,
                                attachFiles: { showingFilePicker = true },
                                attachPhotos: { showingPhotoPicker = true },
                                personalActions: { personalContext = .init(text: model.draft) },
                                householdNotes: { householdTarget = model.selectedTarget },
                                webSettings: { webSettingsTarget = model.selectedTarget }
                            )
                            draftField
                            voiceAndSendButtons
                        }
                    }
                }
            }
            .padding(8)
            .disabled(model.isPreparingModel)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        }
        .frame(maxWidth: ChatStyle.readingWidth)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var draftField: some View {
        if typingRestriction.isPaused {
            SparkDrivingTypingNotice(restriction: .paused) { voiceMode = .conversation }
                .onAppear { composerFocused = false }
        } else {
            TextField("Message Spark", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 6))
                .focused($composerFocused)
                .padding(.vertical, 10)
                .padding(.leading, 8)
                .frame(minHeight: 44)
                .accessibilityLabel(SparkChatAccessibility.composerLabel)
                .accessibilityIdentifier("spark.chat.composer")
                .accessibilityHint(SparkChatAccessibility.composerHint)
        }
    }

    private func beginReply(to id: UUID) {
        guard model.beginReply(to: id) else { return }
        revealedReplyID = nil
        composerFocused = true
    }

    private func replyPreview(_ reply: SparkChatReplyReference) -> some View {
        SparkChatReplyView(
            reply: reply,
            sourceAvailable: model.messages.contains(where: { $0.id == reply.messageID })
        ) {
            composerFocused = false
            scrollState.pauseFollowing()
            highlightedMessageID = reply.messageID
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                scrollPosition.scrollTo(id: reply.messageID, anchor: .center)
            }
        }
    }

    private func messageHighlight(for id: UUID) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.accentColor.opacity(highlightedMessageID == id ? 0.1 : 0))
            .padding(-8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var voiceAndSendButtons: some View {
        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            model.pendingAttachments.isEmpty,
            model.replyDraft == nil,
            model.generationState != .streaming
        {
            Button {
                voiceMode = .conversation
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 38, height: 38)
                    .background(Color.white, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start voice chat")
        } else {
            sendControl
        }
    }

    private var sendControl: some View {
        Button {
            if model.generationState == .streaming {
                model.cancel()
            } else {
                scrollState.resumeFollowing()
                _ = model.send()
                #if os(iOS)
                    composerFocused = false
                #endif
            }
        } label: {
            Image(systemName: model.generationState == .streaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(width: 38, height: 38)
                .background(
                    model.canSend || model.generationState == .streaming
                        ? Color.white : Color.secondary.opacity(0.35),
                    in: Circle()
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend && model.generationState != .streaming)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel(
            model.generationState == .streaming
                ? SparkChatAccessibility.cancelLabel : SparkChatAccessibility.sendLabel
        )
    }

    private func failureBanner(_ failure: SparkChatFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
            Text(failure.message).font(.callout).foregroundStyle(.secondary)
            if model.canRetry {
                Button("Retry") {
                    scrollState.resumeFollowing()
                    _ = model.retry()
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .accessibilityLabel(SparkChatAccessibility.retryLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
}

#if canImport(CarPlay)
    import CarPlay
    import UIKit

    @MainActor
    final class SparkCarPlayInterface {
        private let controller: CPInterfaceController
        private let conversation: SparkCarPlayConversation
        private let bridge: SparkCarPlayBridge
        private var voiceTemplate: CPVoiceControlTemplate?
        private var updates: Task<Void, Never>?
        private var running = false
        private var presenting = false
        private var presentationID = UUID()
        private var renderedAttention: String?
        private var renderedTitle: String?
        private var renderedApproval: UUID?
        private var lastState: SparkCarPlayVoiceState?
        private var lastApproval: UUID?
        private var menuSignature = ""

        init(
            controller: CPInterfaceController,
            conversation: SparkCarPlayConversation,
            bridge: SparkCarPlayBridge
        ) {
            self.controller = controller
            self.conversation = conversation
            self.bridge = bridge
        }
        func start() {
            running = true
            controller.setRootTemplate(root(), animated: false) { _, _ in }
            conversation.loadDevelopmentTargets()
            updates = Task { [weak self] in
                while !Task.isCancelled {
                    self?.update()
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        }
        func stop() {
            running = false
            presentationID = UUID()
            updates?.cancel()
            updates = nil
            voiceTemplate = nil
        }
        private func item(
            _ title: String,
            detail: String? = nil,
            symbol: String,
            action: @escaping () -> Void
        ) -> CPListItem {
            let item = CPListItem(
                text: title,
                detailText: detail,
                image: SparkCarPlayArtwork.symbol(symbol)
            )
            item.handler = { _, completion in
                action()
                completion()
            }
            return item
        }
        private func root() -> CPListTemplate {
            let chats = item(String(localized: "Chats"), symbol: "bubble.left.and.bubble.right") {
                [weak self] in self?.showChats()
            }
            let develop = item(
                String(localized: "Develop"),
                detail: conversation.developmentBlocker(),
                symbol: "terminal"
            ) { [weak self] in self?.showDevelopment() }
            let status = item(SparkCarPlayCopy.statusTitle, symbol: "desktopcomputer") {
                [weak self] in
                self?.presentVoice { [weak self] in self?.conversation.speakStatus() }
            }
            let refresh = item(String(localized: "Refresh"), symbol: "arrow.clockwise") {
                [weak self] in
                self?.conversation.loadDevelopmentTargets()
            }
            return CPListTemplate(
                title: SparkCarPlayCopy.appName,
                sections: [CPListSection(items: [chats, develop, status, refresh])]
            )
        }
        private func chatItems() -> [CPListItem] {
            var items = [
                item(String(localized: "New chat"), symbol: "square.and.pencil") { [weak self] in
                    self?.presentVoice { [weak self] in self?.conversation.newChat() }
                }
            ]
            for chat in conversation.chatChoices.prefix(max(0, CPListTemplate.maximumItemCount - 1))
            {
                items.append(
                    item(chat.title, symbol: "bubble.left") { [weak self] in
                        self?.presentVoice { [weak self] in
                            self?.conversation.start(.conversation(chat.id))
                        }
                    }
                )
            }
            return items
        }
        private func showChats() {
            let list = CPListTemplate(
                title: String(localized: "Chats"),
                sections: [CPListSection(items: chatItems())]
            )
            list.userInfo = "chats"
            controller.pushTemplate(list, animated: true) { _, _ in }
        }
        private func developmentItems() -> [CPListItem] {
            if let blocker = conversation.developmentBlocker() {
                let row = CPListItem(text: String(localized: "Develop"), detailText: blocker)
                row.isEnabled = false
                return [row]
            }
            return conversation.developmentTargets.prefix(CPListTemplate.maximumItemCount).map {
                target in
                item(
                    target.projectName,
                    detail: target.sparkName + " · " + target.harness.name,
                    symbol: "terminal"
                ) { [weak self] in
                    self?.presentVoice { [weak self] in
                        self?.conversation.start(.development(target))
                    }
                }
            }
        }
        private func showDevelopment() {
            let list = CPListTemplate(
                title: String(localized: "Develop"),
                sections: [CPListSection(items: developmentItems())]
            )
            list.emptyViewTitleVariants = [String(localized: "No running sessions")]
            list.emptyViewSubtitleVariants = [
                String(localized: "Open a workspace on your iPhone first.")
            ]
            list.userInfo = "development"
            controller.pushTemplate(list, animated: true) { _, _ in }
        }
        private func presentVoice(_ action: @escaping () -> Void) {
            guard running, !presenting else { return }
            guard voiceTemplate == nil else {
                action()
                return
            }
            presenting = true
            let id = UUID()
            presentationID = id
            let template = makeVoiceTemplate()
            voiceTemplate = template
            controller.presentTemplate(template, animated: true) { [weak self] shown, _ in
                guard let self, self.running, self.presentationID == id else { return }
                self.presenting = false
                if shown {
                    action()
                    self.lastState = nil
                    self.update()
                } else {
                    self.voiceTemplate = nil
                    self.conversation.endVoice()
                }
            }
        }
        private func closeVoice() {
            presentationID = UUID()
            presenting = false
            conversation.endVoice()
            voiceTemplate = nil
            lastState = nil
            controller.dismissTemplate(animated: true) { _, _ in }
        }
        private func button(_ title: String, symbol: String, action: @escaping () -> Void)
            -> CPButton
        {
            let button = CPButton(image: UIImage(systemName: symbol)!) { _ in action() }
            button.title = title
            return button
        }
        private func makeVoiceTemplate() -> CPVoiceControlTemplate {
            let tint = UIColor.label.resolvedColor(with: controller.carTraitCollection)
            let states: [SparkCarPlayVoiceState] = [
                .idle, .listening, .working, .speaking, .attention(""),
            ]
            let approval = conversation.pendingApproval
            renderedTitle = conversation.title
            renderedApproval = approval?.id
            if case .attention(let text) = conversation.state {
                renderedAttention = text
            } else {
                renderedAttention = nil
            }
            let controls = states.map { state in
                let attentionText: String
                if case .attention(let message) = conversation.state {
                    attentionText = message
                } else {
                    attentionText = SparkCarPlayCopy.stopped
                }
                let title =
                    state.identifier == SparkCarPlayVoiceState.attention("").identifier
                    ? attentionText : SparkCarPlayCopy.detail(for: state)
                let art =
                    state == .speaking
                    ? SparkCarPlayArtwork.speakingBars(
                        tint: tint,
                        reduceMotion: UIAccessibility.isReduceMotionEnabled
                    )
                    : SparkCarPlayArtwork.restingBars(tint: tint)
                let control = CPVoiceControlState(
                    identifier: state.identifier,
                    titleVariants: [conversation.title + ": " + title, title],
                    image: art,
                    repeats: state == .speaking && !UIAccessibility.isReduceMotionEnabled
                )
                if #available(iOS 26.4, *) {
                    let primary: CPButton
                    if let approval {
                        primary = button(String(localized: "Continue"), symbol: "checkmark") {
                            [weak self] in self?.conversation.approve(approval.id)
                        }
                    } else {
                        primary = button(
                            state == .listening
                                ? String(localized: "Send") : String(localized: "Talk"),
                            symbol: state == .listening ? "paperplane.fill" : "mic.fill"
                        ) { [weak self] in self?.conversation.primaryVoiceAction() }
                    }
                    let stop = button(String(localized: "Stop voice"), symbol: "stop.fill") {
                        [weak self] in self?.closeVoice()
                    }
                    control.actionButtons = [primary, stop]
                }
                return control
            }
            let template = CPVoiceControlTemplate(voiceControlStates: controls)
            if #available(iOS 26.4, *) {
                template.leadingNavigationBarButtons = [
                    CPBarButton(title: String(localized: "Back")) { [weak self] _ in
                        self?.closeVoice()
                    }
                ]
                template.trailingNavigationBarButtons = [
                    CPBarButton(title: String(localized: "Read back")) { [weak self] _ in
                        guard let self else { return }
                        if case .development = self.conversation.focus {
                            self.conversation.readLatestOutput()
                        } else {
                            self.conversation.repeatLastAnswer()
                        }
                    }
                ]
            }
            return template
        }
        private func update() {
            guard running else { return }
            conversation.synchronizeChoices()
            let signature =
                conversation.chatChoices.map { $0.id.uuidString + $0.title }.joined()
                + conversation.developmentTargets.map(\.id).joined()
                + (conversation.developmentBlocker() ?? "")
            if signature != menuSignature {
                menuSignature = signature
                if let list = controller.topTemplate as? CPListTemplate,
                    list.userInfo as? String == "development"
                {
                    list.updateSections([CPListSection(items: developmentItems())])
                } else if let list = controller.topTemplate as? CPListTemplate,
                    list.userInfo as? String == "chats"
                {
                    list.updateSections([CPListSection(items: chatItems())])
                }
            }
            guard let template = voiceTemplate, !presenting else { return }
            if conversation.endedByOwner {
                closeVoice()
                return
            }
            let state = conversation.state
            let approval = conversation.pendingApproval?.id
            if lastState != state || lastApproval != approval || renderedTitle != conversation.title
            {
                let attention: String? = {
                    if case .attention(let text) = state { return text }
                    return nil
                }()
                let needsReplacement =
                    renderedApproval != approval || renderedTitle != conversation.title
                    || (attention != nil && attention != renderedAttention)
                lastState = state
                lastApproval = approval
                if needsReplacement {
                    presenting = true
                    let id = presentationID
                    controller.dismissTemplate(animated: false) { [weak self] _, _ in
                        guard let self, self.running, self.presentationID == id else { return }
                        self.voiceTemplate = nil
                        self.presenting = false
                        self.presentVoice {}
                    }
                    return
                }
                template.activateVoiceControlState(withIdentifier: state.identifier)
            }
        }
    }
#endif

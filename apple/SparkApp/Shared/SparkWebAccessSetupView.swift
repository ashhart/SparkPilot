import SparkAPI
import SparkCore
import SparkSecurity
import SwiftUI

/// Changes the selected Spark's policy through the same signed, presence-gated flow as Settings.
@MainActor
struct SparkWebAccessSetupView: View {
    let target: SparkVoiceTarget
    let conversation: SparkChatModel?
    private let onFinish: (() -> Void)?
    @State private var settings: SparkAutomationsModel?
    @State private var errorMessage: String?
    @State private var configuring = false
    @Environment(\.dismiss) private var dismiss

    init(target: SparkChatTarget, conversation: SparkChatModel) {
        self.target = SparkVoiceTarget(target)
        self.conversation = conversation
        self.onFinish = nil
    }

    init(
        target: SparkVoiceTarget,
        settings: SparkAutomationsModel? = nil,
        onFinish: @escaping () -> Void
    ) {
        self.target = target
        self.conversation = nil
        self.onFinish = onFinish
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(target.displayName, systemImage: "desktopcomputer")
                    Text(
                        "Your Spark can search the internet and read pages when you turn on web access for a conversation."
                    )
                    Text(
                        "Search words and page requests leave your Spark, and details you share in a chat may be included in searches."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let settings {
                    if let message = settings.errorMessage {
                        Section { Label(message, systemImage: "exclamationmark.triangle") }
                    }
                    if let current = settings.webAccess {
                        if settings.isOwner || current.policy == .automationsAndChats {
                            Section {
                                if current.policy != .automationsAndChats {
                                    Text(
                                        "This enables web access on your Spark; other chats and automations keep their own switches."
                                    )
                                    .font(.footnote).foregroundStyle(.secondary)
                                }
                                Button(
                                    current.policy == .automationsAndChats
                                        ? (conversation == nil
                                            ? String(localized: "Continue")
                                            : String(localized: "Use web in this chat"))
                                        : String(localized: "Enable web access")
                                ) {
                                    Task { await enable(using: settings) }
                                }
                                .disabled(
                                    settings.isChanging
                                        || conversation?.generationState == .streaming
                                )
                                if settings.isChanging {
                                    ProgressView(
                                        String(localized: "Setting up web access on your Spark…")
                                    )
                                    Text(
                                        "Your Spark may need a few minutes to install its search service."
                                    )
                                    .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if settings.isOwner {
                                Toggle("Configure search", isOn: $configuring)
                                    .disabled(settings.isChanging)
                                if configuring { SparkWebAccessSection(model: settings) }
                            }
                        } else {
                            Section {
                                Label(
                                    "Ask this Spark's owner to enable web access for chats.",
                                    systemImage: "person.crop.circle.badge.checkmark"
                                )
                            }
                        }
                    } else {
                        Button("Try again") { Task { await load() } }
                    }
                } else if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView(String(localized: "Checking internet access on your Spark…"))
                }
            }
            .navigationTitle("Web access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(onFinish == nil ? "Done" : "Not now", action: finish)
                        .disabled(settings?.isChanging == true)
                }
            }
            .interactiveDismissDisabled(settings?.isChanging == true)
            .task { await load() }
            .onChange(of: conversation?.selectedTarget?.id) { _, id in
                if conversation != nil && id != target.id { dismiss() }
            }
        }
    }

    private func enable(using settings: SparkAutomationsModel) async {
        guard let current = settings.webAccess else { return }
        if current.policy != .automationsAndChats {
            guard
                await settings.setWebAccess(
                    policy: .automationsAndChats,
                    harnessAccess: current.harnessAccess,
                    backend: current.searchBackend,
                    braveCredentialID: current.braveCredentialId
                ), settings.webAccess?.policy == .automationsAndChats
            else { return }
        }
        if let conversation {
            guard conversation.selectedTarget?.id == target.id else { return }
            SparkChatWebAccess.shared.setOn(true, for: conversation)
        }
        finish()
    }

    private func finish() {
        dismiss()
        onFinish?()
    }

    private func load() async {
        errorMessage = nil
        do {
            let model: SparkAutomationsModel
            #if DEBUG
                if let settings {
                    model = settings
                } else if conversation?.usesSampleData == true {
                    model = FamilyPreviewWebAccess.model(for: target)
                } else {
                    model = try await Self.settingsModel(for: target)
                }
            #else
                model = try await Self.settingsModel(for: target)
            #endif
            await model.loadWebAccess()
            await model.loadChoices()
            guard !Task.isCancelled else { return }
            settings = model
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = String(
                localized: "Your Spark could not be reached securely; reconnect and try again."
            )
        }
    }

    private static func settingsModel(for target: SparkVoiceTarget) async throws
        -> SparkAutomationsModel
    {
        let api = try await SparkVoiceService().client(for: target)
        let localID = DeviceIdentityStore.loadOrCreateDeviceID().uuidString
        var role: String?
        do {
            role = try await api.devices(route: target.route).first {
                $0.id.caseInsensitiveCompare(localID) == .orderedSame && !$0.revoked
            }?.role.rawValue
        } catch {
            guard (error as? APIError)?.code == "ROLE_FORBIDDEN" else { throw error }
        }
        return SparkAutomationsModel(
            route: target.route,
            targetID: (target.clusterID.map(SparkTargetIdentity.cluster) ?? .node(target.nodeID))
                .description,
            runtime: api,
            localDeviceRole: role
        )
    }
}

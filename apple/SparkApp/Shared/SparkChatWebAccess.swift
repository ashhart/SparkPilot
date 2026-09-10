import Foundation
import Observation
import SparkAPI
import SparkLanguageModel
import SparkSecurity
import SparkTransport
import SwiftUI

public enum SparkChatWebPolicy: Equatable, Sendable {
    case unknown
    case allowed
    case notAllowed
}

/// The per-conversation switch for reading the web, and what one answer drew on.
@MainActor
@Observable
public final class SparkChatWebAccess {
    public static let shared = SparkChatWebAccess()

    private var policies: [String: GeneratedAPI.WebAccessSettingsPolicy] = [:]
    private var reads: [String: UUID] = [:]

    public func policyAllowsChats(for conversation: SparkChatModel) -> Bool {
        chatPermission(for: conversation) == true
    }

    public func chatPermission(for conversation: SparkChatModel) -> Bool? {
        guard let target = conversation.selectedTarget else { return nil }
        return policies[target.id].map { $0 == .automationsAndChats }
    }

    public func updatePolicy(_ policy: GeneratedAPI.WebAccessSettingsPolicy?, targetID: String) {
        reads[targetID] = nil
        policies[targetID] = policy
    }

    public func policy(for conversation: SparkChatModel) -> SparkChatWebPolicy {
        guard let allowed = chatPermission(for: conversation) else { return .unknown }
        return allowed ? .allowed : .notAllowed
    }

    public func record(_ policy: SparkChatWebPolicy, forSpark spark: String) {
        updatePolicy(
            policy == .unknown ? nil : (policy == .allowed ? .automationsAndChats : .automations),
            targetID: spark
        )
    }

    @ObservationIgnored
    public var readPolicy: @Sendable (SparkChatTarget) async -> SparkChatWebPolicy? = {
        await SparkChatWebAccess.pinnedPolicy(for: $0)
    }

    public func refreshPolicy(for conversation: SparkChatModel) async {
        guard let target = conversation.selectedTarget else { return }
        await refresh(for: target)
    }

    /// Read policy from the same authenticated Spark that will receive this conversation.
    public func refresh(for target: SparkChatTarget) async {
        let read = UUID()
        reads[target.id] = read
        let policy = await readPolicy(target)
        guard reads[target.id] == read, !Task.isCancelled else { return }
        record(policy ?? .unknown, forSpark: target.id)
    }

    nonisolated static func pinnedPolicy(for target: SparkChatTarget) async -> SparkChatWebPolicy? {
        do {
            let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
            let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
            let identity = try await api.identity(route: target.route)
            guard identity.nodeID == target.nodeID,
                identity.clusterID == target.clusterID,
                identity.authorityFingerprint == target.authorityFingerprint
            else {
                throw SparkChatConnectionError.identityMismatch
            }
            let settings = try await api.getWebAccessSettings(route: target.route)
            return settings.policy == .automationsAndChats ? .allowed : .notAllowed
        } catch {
            return nil
        }
    }

    /// Set by the agent that owns shared personal context, so the warning needs no edit in either file.
    @ObservationIgnored
    public var personalContextSummary: (@MainActor (SparkChatModel) -> String?)? = {
        $0.personalContextShareDescription
    }

    public init() {}

    public func isOn(_ conversation: SparkChatModel) -> Bool { Self.isOn(conversation) }

    public static func isOn(_ conversation: SparkChatModel) -> Bool {
        conversation.allowsWebAccess
    }

    public func setOn(_ isOn: Bool, for conversation: SparkChatModel) {
        conversation.allowsWebAccess = isOn
    }

    public func sources(for conversation: SparkChatModel) -> [GeneratedAPI.WebSource] {
        conversation.messages.last(where: { $0.role == .assistant })?.sources ?? []
    }

    /// One line about personal context shared with this conversation, when anything is.
    public func personalContextWarning(for conversation: SparkChatModel) -> String? {
        guard isOnNow(conversation), let summary = personalContextSummary?(conversation) else {
            return nil
        }
        return String(localized: .chatWebAndPersonalContext(summary: summary))
    }

    private func isOnNow(_ conversation: SparkChatModel) -> Bool {
        conversation.allowsWebAccess
    }
}

/// Keeps the Spark's own web-access setting current for the conversation on screen.
@MainActor
struct SparkChatWebPolicyReader: ViewModifier {
    let access: SparkChatWebAccess
    let conversation: SparkChatModel
    @Environment(\.scenePhase) private var scenePhase

    private struct ReadIdentity: Equatable {
        let target: SparkChatTarget?
        let phase: ScenePhase
    }

    func body(content: Content) -> some View {
        content.task(id: ReadIdentity(target: conversation.selectedTarget, phase: scenePhase)) {
            guard scenePhase == .active else { return }
            #if DEBUG
                guard !conversation.usesSampleData else { return }
            #endif
            await access.refreshPolicy(for: conversation)
        }
    }
}

extension View {
    func readsWebAccessPolicy(
        access: SparkChatWebAccess = .shared,
        for conversation: SparkChatModel
    ) -> some View {
        modifier(SparkChatWebPolicyReader(access: access, conversation: conversation))
    }
}

/// The consent control, in the composer's plus menu beside the calendar switch.
@MainActor
struct SparkChatWebAccessMenuSection: View {
    @Bindable private var access: SparkChatWebAccess
    let conversation: SparkChatModel
    let configure: () -> Void

    init(
        access: SparkChatWebAccess = .shared,
        conversation: SparkChatModel,
        configure: @escaping () -> Void
    ) {
        self.access = access
        self.conversation = conversation
        self.configure = configure
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { SparkChatWebAccess.isOn(conversation) },
            set: { access.setOn($0, for: conversation) }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                Label("Allow web access", systemImage: "globe")
            }
            .disabled(!access.isOn(conversation) && !access.policyAllowsChats(for: conversation))
            .accessibilityIdentifier("spark.chat.web.toggle")
            if !access.policyAllowsChats(for: conversation) {
                Button(
                    "Set up web access",
                    systemImage: "globe.badge.chevron.backward",
                    action: configure
                )
                .disabled(conversation.selectedTarget == nil)
                .accessibilityIdentifier("spark.chat.web.setup")
            }
        } header: {
            Text(
                SparkChatWebAccessCopy.explanation(
                    policyAllowsChats: access.chatPermission(for: conversation)
                )
            )
        }
    }
}

/// What web access is doing for this conversation, shown only while it is on.
@MainActor
struct SparkChatWebAccessChips: View {
    @Bindable private var access: SparkChatWebAccess
    let conversation: SparkChatModel

    init(access: SparkChatWebAccess = .shared, conversation: SparkChatModel) {
        self.access = access
        self.conversation = conversation
    }

    var body: some View {
        if SparkChatWebAccess.isOn(conversation) {
            VStack(alignment: .leading, spacing: 8) {
                SparkChatChip(
                    title: String(localized: "Web access on"),
                    symbol: "globe",
                    remove: String(localized: "Turn off web access")
                ) {
                    access.setOn(false, for: conversation)
                }
                .accessibilityIdentifier("spark.chat.web.chip")
                if let warning = access.personalContextWarning(for: conversation) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("spark.chat.web.warning")
                }

            }
        }
    }
}

enum SparkChatWebAccessCopy {
    static func explanation(policy: SparkChatWebPolicy) -> String {
        explanation(policyAllowsChats: policy == .unknown ? nil : policy == .allowed)
    }

    static func explanation(policyAllowsChats: Bool?) -> String {
        guard let policyAllowsChats else {
            return String(
                localized:
                    "Connect to your Spark to check whether internet access is available for this chat."
            )
        }
        if policyAllowsChats {
            return String(
                localized:
                    "Your Spark can send search queries based on this conversation to its search provider and open pages on the internet. Shared files and personal details in the conversation may influence those queries."
            )
        }
        return String(
            localized:
                "Web access is off for chats on this Spark. Set it up here, or ask the Spark's owner to enable it."
        )
    }
}

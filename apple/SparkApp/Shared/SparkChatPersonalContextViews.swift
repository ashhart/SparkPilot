import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// What went wrong reading the owner's calendar or reminders, and the way out of it.
struct SparkChatPersonalAccessNotice: Equatable, Sendable {
    let message: String
    let actionTitle: String?
}

enum SparkChatPersonalContextCopy {
    static var explanation: String {
        String(
            localized:
                "This Spark is your own machine. Only titles, times and the calendar or list each item is in are sent, not notes, unless you include an item."
        )
    }
    static var share: String {
        String(localized: "Share my calendar and reminders with this Spark")
    }
    static var includeCalendar: String { String(localized: "Include this week's calendar") }
    static var includeReminders: String { String(localized: "Include open reminders") }
    static var listPromise: String {
        String(
            localized:
                "Nothing here reaches your Spark on its own. Include in request sends one item's title, notes and dates. In a chat, Include this week's calendar and Include open reminders send titles, times and the calendar or list each item is in once, and Share my calendar and reminders with this Spark keeps sending them for that conversation until you turn it off."
        )
    }

    static func included(_ kind: SparkPersonalActionKind) -> String {
        kind == .event
            ? String(localized: "This week's calendar") : String(localized: "Open reminders")
    }

    static func remove(_ kind: SparkPersonalActionKind) -> String {
        kind == .event
            ? String(localized: "Remove this week's calendar from this message")
            : String(localized: "Remove open reminders from this message")
    }

    /// Only a refusal is undone in Settings, so only a refusal is sent there.
    static func accessNotice(message: String, canOpenSettings: Bool)
        -> SparkChatPersonalAccessNotice
    {
        SparkChatPersonalAccessNotice(
            message: message,
            actionTitle: canOpenSettings ? String(localized: "Open Settings") : nil
        )
    }

    /// The privacy pane for this app, in the same words the voice permission screens use.
    static var settingsURL: URL? {
        #if os(iOS)
            return URL(string: UIApplication.openSettingsURLString)
        #else
            return URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            )
        #endif
    }
}

/// Above the composer: what this conversation shares, what one tap added, and what it could add.
@MainActor
struct SparkChatPersonalContextBar: View {
    let model: SparkChatModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.sharesPersonalContext {
                chip(
                    title: String(localized: "Calendar and reminders shared"),
                    symbol: "calendar.badge.clock",
                    remove: String(localized: "Stop sharing calendar and reminders")
                ) {
                    model.sharesPersonalContext = false
                }
                Text(SparkChatPersonalContextCopy.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.personal.included, id: \.self) { kind in
                    chip(
                        title: SparkChatPersonalContextCopy.included(kind),
                        symbol: kind.symbol,
                        remove: SparkChatPersonalContextCopy.remove(kind)
                    ) {
                        model.personal.remove(kind)
                    }
                }
                ForEach(hints) { hint in
                    Button {
                        Task { await model.personal.include(hint.kind) }
                    } label: {
                        Label(hint.title, systemImage: hint.symbol)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(ChatStyle.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(ChatStyle.border))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chat.personal.hint.\(hint.rawValue)")
                }
            }
            if model.personal.isReading {
                ProgressView(String(localized: "Reading your calendar and reminders…"))
                    .font(.caption)
            }
            if let error = model.personal.accessError { accessNotice(error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A refusal that names system settings carries the button that opens them.
    @ViewBuilder private func accessNotice(_ error: String) -> some View {
        let notice = SparkChatPersonalContextCopy.accessNotice(
            message: error,
            canOpenSettings: model.personal.accessDenied
        )
        VStack(alignment: .leading, spacing: 6) {
            Label(notice.message, systemImage: "calendar.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let title = notice.actionTitle, let url = SparkChatPersonalContextCopy.settingsURL {
                Button(title, systemImage: "gear") { openURL(url) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chat.personal.openSettings")
            }
        }
    }

    private var hints: [SparkChatContextHint] {
        SparkChatComposerSuggestions.hints(for: model.draft, already: model.personal.included)
    }

    private func chip(
        title: String,
        symbol: String,
        remove: String,
        action: @escaping () -> Void
    ) -> some View {
        SparkChatChip(title: title, symbol: symbol, remove: remove, action: action)
            .accessibilityIdentifier("chat.personal.chip")
    }
}

/// One removable capsule above the composer: what this message will carry, and the way to drop it.
struct SparkChatChip: View {
    let title: String
    let symbol: String
    let remove: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .padding(.leading, 12)
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(remove)
        }
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .background(ChatStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(ChatStyle.border))
        .accessibilityElement(children: .contain)
    }
}

/// The consent controls, in the composer's plus menu so one tap reaches them from the keyboard.
@MainActor
struct SparkChatPersonalContextMenuSection: View {
    let model: SparkChatModel

    var body: some View {
        Section {
            Toggle(isOn: sharing) {
                Label(
                    SparkChatPersonalContextCopy.share,
                    systemImage: "calendar.badge.clock"
                )
            }
            .accessibilityIdentifier("chat.personal.share")
            Button(SparkChatPersonalContextCopy.includeCalendar, systemImage: "calendar") {
                Task { await model.personal.include(.event) }
            }
            Button(SparkChatPersonalContextCopy.includeReminders, systemImage: "checklist") {
                Task { await model.personal.include(.reminder) }
            }
        } header: {
            Text(SparkChatPersonalContextCopy.explanation)
        }
    }

    private var sharing: Binding<Bool> {
        Binding(
            get: { model.sharesPersonalContext },
            set: { wanted in
                guard wanted else {
                    model.sharesPersonalContext = false
                    return
                }
                Task { await model.startSharingPersonalContext() }
            }
        )
    }
}

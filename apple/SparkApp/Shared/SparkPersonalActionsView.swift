import SwiftUI

@MainActor
struct SparkPersonalActionsView: View {
    let chat: SparkChatModel
    @State private var request = ""
    @State private var context: String
    @State private var planner = SparkPersonalPlanner()
    @State private var review: SparkPersonalAction?
    @State private var dictating = false
    @State private var dictation: SparkChatModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(chat: SparkChatModel, context: String = "", request: String = "") {
        self.chat = chat
        _request = State(initialValue: request)
        _context = State(initialValue: context)
        _dictation = State(initialValue: chat.makeSibling())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What would you like to do?", text: $request, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("personal.request")
                        .disabled(planner.preparing)
                    Button("Dictate request", systemImage: "mic") { dictating = true }.disabled(
                        planner.preparing
                    )
                    if let target = chat.selectedTarget {
                        LabeledContent("Reasoning on") { Text(verbatim: target.displayName) }
                    }
                    if planner.preparing {
                        HStack {
                            ProgressView(String(localized: "Preparing drafts on your Spark…"))
                            Spacer()
                            Button("Stop") { planner.cancel() }
                        }
                    } else {
                        Button("Prepare actions", systemImage: "arrow.up.circle.fill") {
                            planner.prepare(
                                request: request,
                                context: context,
                                target: chat.selectedTarget
                            )
                        }
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("personal.prepare")
                    }
                } header: {
                    Text("Ask your Spark")
                } footer: {
                    Text(
                        "Only this request and the shared text below go to your selected Spark; review each action before carrying it out, and keep this sheet open to retain unsaved drafts."
                    )
                }
                if !context.isEmpty {
                    Section {
                        DisclosureGroup {
                            TextEditor(text: $context).frame(minHeight: 120).disabled(
                                planner.preparing
                            )
                            .accessibilityLabel("Text included with this request")
                            Button("Remove shared text", role: .destructive) { context = "" }
                        } label: {
                            Text("Included text")
                        }
                    }
                }
                if let error = planner.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                }
                if !planner.actions.isEmpty {
                    Section {
                        ForEach(planner.actions) { action in
                            Button {
                                review = action
                            } label: {
                                HStack {
                                    Image(systemName: action.kind.symbol).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: action.kind.title).font(.headline)
                                        Text(
                                            verbatim: action.kind == .reply
                                                ? action.body : action.title
                                        )
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Image(
                                        systemName: planner.reviewedIDs.contains(action.id)
                                            ? "checkmark.circle.fill" : "chevron.right"
                                    )
                                }.padding(.vertical, 6)
                            }
                            .disabled(planner.reviewedIDs.contains(action.id))
                        }
                    } header: {
                        Text("Review each draft")
                    } footer: {
                        Text(
                            "Preparing a draft does not send a message or change Calendar or Reminders."
                        )
                    }
                }
                Section("Get started") {
                    Button("Draft a reply") {
                        request = String(
                            localized: "Draft a helpful reply to the included message."
                        )
                    }
                    Button("Reply and remind me tomorrow") {
                        request = String(
                            localized:
                                "Draft a helpful reply to the included message and remind me tomorrow at 9 am to follow up."
                        )
                    }
                    Button("Plan an event") {
                        request = String(
                            localized: "Prepare a calendar event from the included text."
                        )
                    }
                }
                Section("On this device") {
                    Button("New message draft", systemImage: "message") {
                        review = .init(kind: .reply, body: context)
                    }
                    Button("New reminder", systemImage: "checklist") {
                        review = .init(kind: .reminder)
                    }
                    Button("New calendar event", systemImage: "calendar.badge.plus") {
                        let start = Date().addingTimeInterval(3600)
                        review = .init(
                            kind: .event,
                            start: start,
                            end: start.addingTimeInterval(3600)
                        )
                    }
                    NavigationLink {
                        SparkPersonalLibraryView(kind: .event, include: include)
                    } label: {
                        Label("Calendar", systemImage: "calendar")
                    }
                    NavigationLink {
                        SparkPersonalLibraryView(kind: .reminder, include: include)
                    } label: {
                        Label("Reminders", systemImage: "checklist")
                    }
                    NavigationLink {
                        SparkPersonalShortcutView(text: context)
                    } label: {
                        Label("Run a Shortcut", systemImage: "square.stack.3d.up")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Personal actions")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        planner.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(item: $review) { action in
                SparkPersonalReviewView(action: action) { planner.reviewedIDs.insert(action.id) }
            }
            .sheet(
                isPresented: $dictating,
                onDismiss: {
                    if !dictation.draft.isEmpty {
                        request = dictation.draft
                        dictation.draft = ""
                    }
                }
            ) {
                SparkVoiceChatView(model: dictation, mode: .dictation).modifier(SparkPersonalLock())
            }
        }
        .privacySensitive()
        .modifier(SparkPersonalLock())
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 600, minHeight: 600)
        #endif
        .onDisappear { planner.cancel() }
        .onChange(of: request) { _, _ in planner.clear() }
        .onChange(of: context) { _, _ in planner.clear() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { planner.cancel() }
            if phase == .background { dismiss() }
        }
    }

    private func include(_ item: SparkPersonalItem) {
        context = SparkPersonalContext.text(item)
        request = ""
    }
}

enum SparkPersonalContext {
    static func text(_ item: SparkPersonalItem) -> String {
        // Explicitly selected fields only; no store identifiers, calendar names or attendees.
        var lines = [item.draft.title, item.draft.body]
        if let start = item.draft.start { lines.append(start.ISO8601Format()) }
        if let end = item.draft.end { lines.append(end.ISO8601Format()) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct SparkPersonalAppLockKey: EnvironmentKey {
    static let defaultValue: AppLockModel? = nil
}

extension EnvironmentValues {
    var sparkPersonalAppLock: AppLockModel? {
        get { self[SparkPersonalAppLockKey.self] }
        set { self[SparkPersonalAppLockKey.self] = newValue }
    }
}

/// Gate each presented sheet independently because parent hit-testing restrictions do not cover it.
struct SparkPersonalLock: ViewModifier {
    @Environment(\.sparkPersonalAppLock) private var appLock
    @ViewBuilder func body(content: Content) -> some View {
        if let appLock { AppLockGate(model: appLock) { content } } else { content }
    }
}

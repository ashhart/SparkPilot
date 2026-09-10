import SwiftUI

@MainActor
struct SparkPersonalReviewView: View {
    @State private var action: SparkPersonalAction
    let original: SparkPersonalItem?
    let saved: () -> Void
    @State private var store: any SparkPersonalStoring
    @State private var calendars: [SparkPersonalCalendar] = []
    @State private var calendarID = ""
    @State private var authorized = false
    @State private var working = false
    @State private var finished = false
    @State private var error: String?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var confirmDelete = false
    @State private var messageComposer = false
    @State private var recipient = ""
    @State private var outcome: String?
    @Environment(\.dismiss) private var dismiss

    init(
        action: SparkPersonalAction,
        original: SparkPersonalItem? = nil,
        store: any SparkPersonalStoring = SparkPersonalStore(),
        saved: @escaping () -> Void
    ) {
        _action = State(initialValue: action)
        self.original = original
        self.saved = saved
        _store = State(initialValue: store)
        _hasDueDate = State(initialValue: action.start != nil)
        _dueDate = State(initialValue: action.start ?? Self.tomorrow())
    }

    var body: some View {
        NavigationStack {
            Form {
                if let outcome { Section { Label(outcome, systemImage: "checkmark.circle") } }
                Section {
                    if action.kind != .reply { TextField("Title", text: $action.title) }
                    #if os(iOS)
                        if action.kind == .reply, SparkMessageComposer.available {
                            TextField("Recipient in Messages, optional", text: $recipient)
                                .autocorrectionDisabled()
                        }
                    #endif
                    TextEditor(text: $action.body).frame(minHeight: 130)
                        .accessibilityLabel(
                            action.kind == .reply
                                ? String(localized: "Message draft") : String(localized: "Notes")
                        )
                    if action.kind == .event {
                        DatePicker(
                            selection: Binding(
                                get: { action.start ?? .now },
                                set: { action.start = $0 }
                            )
                        ) { Text("Starts") }
                        DatePicker(
                            selection: Binding(
                                get: { action.end ?? .now },
                                set: { action.end = $0 }
                            )
                        ) { Text("Ends") }
                    }
                    if action.kind != .reply {
                        LabeledContent("Time zone") { Text(verbatim: TimeZone.current.identifier) }
                    }
                    if action.kind == .reminder {
                        Toggle("Remind me at a time", isOn: $hasDueDate)
                        if hasDueDate { DatePicker(selection: $dueDate) { Text("Due") } }
                    }
                } footer: {
                    if action.kind == .event {
                        Text(
                            "Check the date, time and time zone before saving; edits and deletion affect only this occurrence."
                        )
                    } else if action.kind == .reminder {
                        Text(
                            "A new timed reminder includes an alert; delivery depends on your Reminders notification settings."
                        )
                    } else {
                        Text(
                            "You choose the recipient and press Send in Messages; use Share for WhatsApp or another app."
                        )
                    }
                }
                .disabled(finished || working)
                if action.kind == .reply {
                    messageActions
                } else {
                    Section {
                        if !authorized {
                            Button(
                                action.kind == .event
                                    ? String(localized: "Choose calendar access")
                                    : String(localized: "Choose Reminders access")
                            ) {
                                Task { await connect() }
                            }
                        } else {
                            Picker("Save in", selection: $calendarID) {
                                ForEach(calendars) { Text(verbatim: $0.title).tag($0.id) }
                            }
                            Button(
                                original == nil
                                    ? String(localized: "Save new item")
                                    : String(localized: "Save changes")
                            ) { commit() }
                            .disabled(calendarID.isEmpty)
                            if let original {
                                if original.draft.kind == .reminder {
                                    Button("Mark completed") {
                                        mutate(
                                            success: String(localized: "Reminder marked completed.")
                                        ) { try store.complete(original) }
                                    }
                                }
                                Button("Delete item", role: .destructive) { confirmDelete = true }
                            }
                        }
                        if working { ProgressView() }
                    } footer: {
                        Text(
                            "Calendar and reminder changes stay on this device and sync through the account you select; they are not sent to your Spark."
                        )
                    }
                    .disabled(finished || working)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(action.kind.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? String(localized: "Done") : String(localized: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .alert(
                "Delete this item?",
                isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) {
                    if let original {
                        mutate(
                            success: String(localized: "Item deleted from the selected account.")
                        ) { try store.remove(original) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This changes the selected Calendar or Reminders account.")
            }
            #if os(iOS)
                .sheet(isPresented: $messageComposer) {
                    SparkMessageComposer(text: action.body, recipient: recipient) { result in
                        messageComposer = false
                        switch result {
                        case .sent:
                            outcome = String(localized: "Messages reports this message was sent.")
                            finished = true
                            saved()
                        case .cancelled: outcome = nil
                        case .failed:
                            error = String(
                                localized:
                                    "Messages could not send this draft; your text is still here."
                            )
                        }
                    }.modifier(SparkPersonalLock())
                }
            #endif
        }
        .privacySensitive()
        .modifier(SparkPersonalLock())
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 560, minHeight: 520)
        #endif
    }

    private var messageActions: some View {
        Section {
            #if os(iOS)
                if SparkMessageComposer.available {
                    Button("Review in Messages", systemImage: "message") {
                        do {
                            try action.validate()
                            guard recipient.utf8.count <= 300, !recipient.contains("\n"),
                                !recipient.contains("\0")
                            else { throw SparkPersonalError.tooLarge }
                            messageComposer = true
                        } catch { present(error) }
                    }.disabled(
                        finished
                            || action.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                } else {
                    Text(
                        "Messages sending is not available on this device; copy or share the draft instead."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            #endif
            SparkChatCopyButton(
                content: action.body,
                label: String(localized: "Copy draft"),
                showsLabel: true
            )
            .foregroundStyle(.tint)
            ShareLink(item: action.body) {
                Label("Share draft", systemImage: "square.and.arrow.up")
            }
            NavigationLink {
                SparkPersonalShortcutView(text: action.body)
            } label: {
                Text("Use in a Shortcut")
            }
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await store.authorize(action.kind, reading: original != nil)
            calendars = store.calendars(action.kind)
            guard !calendars.isEmpty else { throw SparkPersonalError.noCalendar }
            calendarID =
                calendars.first(where: { $0.id == original?.calendarID })?.id ?? calendars[0].id
            authorized = true
            error = nil
        } catch { present(error) }
    }
    private func commit() {
        if action.kind == .reminder { action.start = hasDueDate ? dueDate : nil }
        mutate(success: String(localized: "Saved on this device.")) {
            try store.save(action, calendarID: calendarID, replacing: original)
        }
    }
    private func mutate(success: String, _ body: () throws -> Void) {
        guard !finished, !working else { return }
        working = true
        defer { working = false }
        do {
            try body()
            finished = true
            outcome = success
            error = nil
            saved()
        } catch { present(error) }
    }
    private func present(_ failure: any Error) {
        error =
            (failure as? SparkPersonalError)?.errorDescription
            ?? String(
                localized:
                    "The change could not be confirmed; check Calendar or Reminders before trying again."
            )
    }
    private static func tomorrow() -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}

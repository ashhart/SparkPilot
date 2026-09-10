import SwiftUI

@MainActor
struct SparkPersonalLibraryView: View {
    let kind: SparkPersonalActionKind
    let include: (SparkPersonalItem) -> Void
    @State private var store = SparkPersonalStore()
    @State private var items: [SparkPersonalItem] = []
    @State private var loading = false
    @State private var connected = false
    @State private var start = Calendar.current.startOfDay(for: .now)
    @State private var error: String?
    @State private var selection: SparkPersonalItem?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(SparkChatPersonalContextCopy.listPromise)
                    .font(.footnote).foregroundStyle(.secondary)
                if kind == .event {
                    DatePicker(selection: $start, displayedComponents: .date) {
                        Text("Week starting")
                    }
                }
                Button(
                    connected
                        ? String(localized: "Refresh items")
                        : String(localized: "Connect and show items")
                ) {
                    Task { await load() }
                }.disabled(loading)
                if loading { ProgressView() }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if connected, items.isEmpty, !loading { Text("No items in this view.") }
            ForEach(items) { item in
                Section {
                    Text(verbatim: item.draft.title).font(.headline)
                    Text(verbatim: item.calendarName).font(.caption).foregroundStyle(.secondary)
                    if let date = item.draft.start {
                        Text(date, format: .dateTime.day().month().hour().minute())
                    }
                    if !item.draft.body.isEmpty { Text(verbatim: item.draft.body).lineLimit(3) }
                    Button("Include in request") {
                        include(item)
                        dismiss()
                    }
                    if item.editable {
                        Button("Review changes") { selection = item }
                    } else {
                        Text("Edit this item in Calendar or Reminders.").font(.footnote)
                    }
                }
            }
            if connected {
                Text(
                    kind == .event
                        ? String(localized: "Up to 200 events in the selected seven days.")
                        : String(localized: "Up to 200 incomplete reminders from your lists.")
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(
            kind == .event ? String(localized: "Calendar") : String(localized: "Reminders")
        )
        .sheet(item: $selection, onDismiss: { if connected { Task { await load() } } }) { item in
            SparkPersonalReviewView(action: item.draft, original: item) {}
        }
        .onDisappear {
            items = []
            connected = false
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        items = []
        defer { loading = false }
        do {
            try await store.authorize(kind, reading: true)
            items = try await store.items(kind, start: start)
            connected = true
            error = nil
        } catch {
            self.error =
                (error as? SparkPersonalError)?.errorDescription
                ?? String(localized: "These items could not be read.")
        }
    }
}

struct SparkPersonalShortcutView: View {
    @State var text: String
    let workflow: String?
    @State private var name = ""
    @State private var confirming = false
    @State private var error: String?
    @Environment(\.openURL) private var openURL
    init(text: String, workflow: String? = nil) {
        _text = State(initialValue: text)
        self.workflow = workflow
    }
    var body: some View {
        Form {
            if let workflow {
                Section("Set up in Shortcuts") {
                    Text(workflow)
                    Link(
                        "Open Shortcuts to create or inspect a workflow",
                        destination: URL(string: "shortcuts://")!
                    )
                }
            }
            Section {
                TextField("Exact name of your Shortcut", text: $name).autocorrectionDisabled()
            }
            // QA-17: the editor had no label, placeholder or hint on screen; its own section names it.
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Text passed to Shortcuts")
                Button("Review Shortcut handoff") { confirming = true }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Text passed to Shortcuts")
            } footer: {
                Text(
                    "Choose a Shortcut you created or trust; it receives the text shown here and can carry out its configured actions using its own permissions."
                )
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section("Build a workflow") {
                Text(
                    "In Shortcuts, combine Ask Spark, Summarise with Spark, Rewrite with Spark, Draft Reply with Spark or Draft Email with Spark with the actions supported by your other apps."
                )
                Text(
                    "SparkPilot cannot read your Messages or WhatsApp history; share or paste the messages you want to use."
                )
            }
        }
        .navigationTitle("Run a Shortcut")
        // An alert, because a popover confirmation drops the cancel button it is given.
        .alert(
            "Run this Shortcut with the displayed text?",
            isPresented: $confirming
        ) {
            Button("Open Shortcuts") {
                do {
                    let url = try SparkPersonalPlan.shortcutURL(name: name, text: text)
                    openURL(url) { accepted in
                        if !accepted {
                            error = String(
                                localized:
                                    "Shortcuts could not be opened; check that it is installed."
                            )
                        }
                    }
                } catch { self.error = (error as? LocalizedError)?.errorDescription }
            }
            Button("Do not run it", role: .cancel) {}
        } message: {
            Text("Opening Shortcuts does not confirm the workflow completed.")
        }
    }
}

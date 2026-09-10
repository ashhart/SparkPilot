import SparkAPI
import SwiftUI

@MainActor
struct SparkHouseholdView: View {
    @State private var model: SparkHouseholdModel
    @State private var draft: SparkHouseholdDraft?
    @State private var memberToChange: GeneratedAPI.HouseholdMember?
    @Environment(\.dismiss) private var dismiss
    private let sparkName: String
    private let include: @MainActor (SparkSharedFile) async -> Void

    init(
        sparkName: String,
        service: any SparkHouseholdProviding,
        include: @escaping @MainActor (SparkSharedFile) async -> Void
    ) {
        self.sparkName = sparkName
        self.include = include
        _model = State(initialValue: SparkHouseholdModel(service: service))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(sparkName, systemImage: "house")
                    Text(
                        "Keep useful notes together: favourite meals, the weekly routine, or how to care for the garden."
                    )
                    Text(
                        "Everyone added to this household can read these notes. Your private chats stay separate."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try again") { Task { await model.refresh() } }
                    }
                }
                if let snapshot = model.snapshot {
                    Section("Notes") {
                        if snapshot.notes.isEmpty {
                            Text("Add your first household note.").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.notes, id: \.id) { note in
                            NavigationLink {
                                noteDetail(note)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(note.title).font(.headline)
                                    Text(note.body).lineLimit(2).foregroundStyle(.secondary)
                                    Text(.householdAuthor(note.authorName)).font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Add a note", systemImage: "plus") { draft = .init() }
                    }
                    Section {
                        ForEach(snapshot.members, id: \.deviceId) { member in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(member.name)
                                    Text(
                                        member.administrator
                                            ? "Administrator"
                                            : member.joined
                                                ? "Household member" : "Model access only"
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if snapshot.canManageMembers, !member.administrator {
                                    Button(member.joined ? "Remove" : "Add") {
                                        memberToChange = member
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    } header: {
                        Text("Who can read these notes")
                    } footer: {
                        Text(
                            "An administrator can add a paired device here. A friend who only shares your model cannot read household notes."
                        )
                    }
                }
                if model.isLoading || model.isChanging {
                    ProgressView(String(localized: "Connecting to your Spark…"))
                }
            }
            .disabled(model.isChanging)
            .navigationTitle("Household notes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .sheet(item: $draft) { value in SparkHouseholdEditor(model: model, initial: value) }
            .alert(
                memberToChange?.joined == true
                    ? "Remove household access?" : "Share household notes?",
                isPresented: Binding(
                    get: { memberToChange != nil },
                    set: { if !$0 { memberToChange = nil } }
                ),
                presenting: memberToChange
            ) { member in
                Button(
                    member.joined ? "Remove access" : "Share with this device",
                    role: member.joined ? .destructive : nil
                ) {
                    Task { await model.setMember(member) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { member in
                Text(
                    member.joined
                        ? LocalizedStringResource.householdRemoval(member.name)
                        : LocalizedStringResource.householdInvitation(member.name)
                )
            }
        }
    }

    private func noteDetail(_ note: GeneratedAPI.HouseholdNote) -> some View {
        List {
            // A refresh or failed access check removes stale text even while this destination is open.
            if let current = model.snapshot?.notes.first(where: { $0.id == note.id }) {
                Section {
                    Text(current.body).textSelection(.enabled)
                    Text(
                        .householdEditors(current.authorName, current.updatedByName)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Add to this chat", systemImage: "text.bubble") {
                        Task {
                            if let file = await model.attachment(for: current) {
                                await include(file)
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.isLoading || model.isChanging)
                    if current.canEdit { Button("Edit note") { draft = .init(note: current) } }
                } footer: {
                    Text(
                        "Adds a copy to your draft for review. Web access, if enabled for the chat, may use its contents in searches."
                    )
                }
            } else {
                Text(model.errorMessage ?? String(localized: "This note is no longer available."))
            }
        }
        .navigationTitle(note.title)
    }
}

@MainActor
private struct SparkHouseholdEditor: View {
    @Bindable var model: SparkHouseholdModel
    @State private var draft: SparkHouseholdDraft
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss

    init(model: SparkHouseholdModel, initial: SparkHouseholdDraft) {
        self.model = model
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextEditor(text: $draft.body).frame(minHeight: 180).accessibilityLabel("Note")
                } footer: {
                    Text(
                        "This note will be visible to everyone in the household, including people added later."
                    )
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                if draft.title.utf8.count > 240 || draft.body.utf8.count > 16_384 {
                    Text(
                        "This note is too long. Shorten the title or split the text into smaller notes."
                    ).foregroundStyle(.red)
                }
                if draft.revision > 0 {
                    Button("Delete note", role: .destructive) { confirmsDelete = true }
                }
            }
            .disabled(model.isChanging)
            .navigationTitle(draft.revision == 0 ? "New household note" : "Edit household note")
            .interactiveDismissDisabled(model.isChanging)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isChanging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await model.save(draft) { dismiss() } } }
                        .disabled(!draft.canSave || model.isChanging)
                }
            }
            .alert("Delete this household note?", isPresented: $confirmsDelete) {
                Button("Delete note", role: .destructive) {
                    Task { if await model.save(draft, delete: true) { dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The note will be removed for everyone. Copies already added to chats remain there."
                )
            }
        }
    }
}

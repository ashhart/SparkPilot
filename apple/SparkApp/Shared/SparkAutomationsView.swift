import SparkAPI
import SparkDesignSystem
import SwiftUI

/// What this Spark does on its own: what is next, what happened last, and whether it is on.
public struct SparkAutomationsView: View {
    @Bindable var model: SparkAutomationsModel
    @State private var editing: SparkAutomationDraft?
    @State private var editingID: String?
    @State private var confirmingDeletion: GeneratedAPI.Automation?
    @State private var didStartCreating = false
    private let sparkName: String?
    private let createOnOpen: Bool

    public init(model: SparkAutomationsModel, sparkName: String? = nil, createOnOpen: Bool = false)
    {
        self.model = model
        self.sparkName = sparkName
        self.createOnOpen = createOnOpen
    }

    public var body: some View {
        List {
            Section {
                if let sparkName { LabeledContent("Runs on", value: sparkName) }
                Text(
                    "Your Spark runs these on its own. This device does not need to be awake, nearby, or on the same network."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(model.webAccessSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Automations") {
                if model.automations.isEmpty {
                    ContentUnavailableView(
                        "No automations yet",
                        systemImage: "clock.badge.checkmark",
                        description: Text(
                            "Add one and your Spark will run it on its own schedule, like a daily brief every morning."
                        )
                    )
                } else {
                    ForEach(model.automations, id: \.id) { automation in
                        row(automation)
                    }
                }
            }
            if model.isOwner {
                SparkWebAccessSection(model: model)
            }
        }
        .navigationTitle("Automations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginCreating()
                } label: {
                    Label("Add automation", systemImage: "plus")
                }
                .disabled(!model.canAdd)
                .accessibilityIdentifier("spark.automations.add")
            }
        }
        .sheet(item: $editing) { draft in
            SparkAutomationEditorView(
                model: model,
                draft: draft,
                automationID: editingID,
                sparkName: sparkName
            ) { editing = nil }
        }
        .alert(
            "Delete this automation?",
            isPresented: Binding(
                get: { confirmingDeletion != nil },
                set: { if !$0 { confirmingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let target = confirmingDeletion else { return }
                confirmingDeletion = nil
                Task { await model.delete(target.id) }
            }
            Button("Keep", role: .cancel) { confirmingDeletion = nil }
        } message: {
            Text("Its run history is deleted with it. This cannot be undone.")
        }
        .task {
            await model.load()
            if createOnOpen, !didStartCreating, model.canAdd {
                didStartCreating = true
                beginCreating()
            }
        }
        .refreshable { await model.load() }
    }

    private func beginCreating() {
        editingID = nil
        var draft = SparkAutomationDraft()
        draft.modelID = model.installedModels.first?.id ?? model.automations.first?.modelId ?? ""
        editing = draft
    }

    @ViewBuilder
    private func row(_ automation: GeneratedAPI.Automation) -> some View {
        NavigationLink {
            SparkAutomationRunsView(model: model, automation: automation) {
                editingID = automation.id
                editing = SparkAutomationDraft.editing(automation)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(automation.name)
                        .font(.headline)
                    Spacer()
                    if automation.webAccess {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Reads the internet")
                    }
                }
                Text(SparkAutomationCopy.nextRun(automation))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(SparkAutomationCopy.lastResult(automation))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                confirmingDeletion = automation
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await model.setEnabled(automation.id, to: !automation.enabled) }
            } label: {
                Label(
                    automation.enabled ? "Pause" : "Resume",
                    systemImage: automation.enabled ? "pause" : "play"
                )
            }
        }
        .accessibilityIdentifier("spark.automations.row.\(automation.id)")
    }
}

extension SparkAutomationDraft: Identifiable {
    public var id: String { name + expression + timezone }
}

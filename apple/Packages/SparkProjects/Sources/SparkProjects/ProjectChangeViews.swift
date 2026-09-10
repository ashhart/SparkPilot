import SparkAPI
import SparkDesignSystem
import SwiftUI

struct ProjectChangesView: View {
    @Bindable var model: ProjectsModel
    @State private var agentTask = ""

    var body: some View {
        List {
            if model.canRunAgent {
                Section("Start an agent task") {
                    TextField("Describe the change", text: $agentTask, axis: .vertical)
                        .lineLimit(2...6)
                    Button("Start Agent", systemImage: "sparkles") {
                        let task = agentTask
                        agentTask = ""
                        Task { _ = await model.startAgent(task: task) }
                    }
                    .disabled(agentTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Changes") {
                if (model.changeState == .idle || model.changeState == .loading)
                    && model.changes.isEmpty
                {
                    ProgressView(String(localized: "Loading changes"))
                } else {
                    switch model.changeState {
                    case .failed(let message):
                        ProjectFailureView(message: message) {
                            await model.refreshProjectContents()
                        }
                    case .empty:
                        ContentUnavailableView(
                            "No changes",
                            systemImage: "arrow.triangle.branch",
                            description: Text("Agent changes waiting for review appear here.")
                        )
                    case .idle, .loading, .loaded:
                        ForEach(model.changes, id: \.id) { change in
                            NavigationLink {
                                ProjectChangeReviewView(model: model, changeID: change.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(change.task).font(.headline).lineLimit(2)
                                    Label(
                                        ProjectPresentation.changeStatus(change.status),
                                        systemImage: change.status == .review ? "eye" : "clock"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Open only the freshly fetched review named by a notification, preserving its confirmation controls.
public struct ProjectChangeNotificationReviewView: View {
    @Bindable private var model: ProjectsModel
    private let targetID: String
    private let projectID: String
    private let changeID: String
    @State private var loading = true
    @State private var available = false

    public init(model: ProjectsModel, targetID: String, projectID: String, changeID: String) {
        self.model = model
        self.targetID = targetID
        self.projectID = projectID
        self.changeID = changeID
    }

    public var body: some View {
        Group {
            if loading {
                ProgressView(String(localized: "Loading review"))
            } else if available && model.selectedTargetID == targetID
                && model.selectedProject?.id == projectID
            {
                ProjectChangeReviewView(model: model, changeID: changeID)
            } else {
                ContentUnavailableView(
                    "Review unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "This change may have been removed or this Spark may be offline."
                    )
                )
            }
        }
        .task(id: "\(targetID).\(projectID).\(changeID)") {
            loading = true
            available = false
            await model.load()
            guard model.targets.contains(where: { $0.id == targetID && $0.status == .available })
            else {
                loading = false
                return
            }
            await model.selectTarget(targetID)
            guard model.selectedTargetID == targetID, !model.isShowingCachedProjects,
                let project = model.projects.first(where: { $0.id == projectID })
            else {
                loading = false
                return
            }
            await model.openProject(project)
            available =
                model.selectedTargetID == targetID && model.selectedProject?.id == projectID
                && model.changeState == .loaded
                && model.changes.contains(where: { $0.id == changeID && $0.projectId == projectID })
            loading = false
        }
    }
}

struct ProjectChangeReviewView: View {
    @Bindable var model: ProjectsModel
    let changeID: String
    @State private var comment = ""
    @State private var confirmingApproval = false

    private var change: GeneratedAPI.ProjectChange? {
        model.changes.first(where: { $0.id == changeID })
    }

    var body: some View {
        List {
            if let change {
                Section("Task") {
                    Text(change.task)
                    LabeledContent("Status", value: ProjectPresentation.changeStatus(change.status))
                    if let digest = change.reviewDigest {
                        LabeledContent("Evidence digest", value: String(digest.prefix(12)))
                            .accessibilityValue(digest)
                    }
                }

                Section("Tests") {
                    if change.testEvidence.isEmpty {
                        Label("No test evidence", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(change.testEvidence.enumerated()), id: \.offset) { _, test in
                        Label {
                            VStack(alignment: .leading) {
                                Text(test.command)
                                Text(
                                    .projectTestEvidence(
                                        exitCode: test.exitCode,
                                        digest: String(test.outputDigest.prefix(12))
                                    )
                                )
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(
                                systemName: test.status == .passed
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(test.status == .passed ? .green : .red)
                        }
                    }
                }

                Section("Tool evidence") {
                    ForEach(change.toolEvidence, id: \.sequence) { item in
                        LabeledContent(
                            String(
                                localized: .projectToolEvidence(
                                    sequence: item.sequence,
                                    tool: ProjectPresentation.tool(item.tool)
                                )
                            ),
                            value: ProjectPresentation.outcome(item.outcome)
                        )
                    }
                }

                ForEach(change.changedFiles, id: \.path) { file in
                    Section(file.path) {
                        Text(
                            .projectChangeCounts(
                                additions: file.additions,
                                deletions: file.deletions
                            )
                        )
                        .font(.caption.monospaced())
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hunk.header).font(.caption.monospaced()).foregroundStyle(
                                    .secondary
                                )
                                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                    Text(ProjectDiffPresentation.visibleLine(line))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(ProjectDiffPresentation.colour(line.kind))
                                        .accessibilityLabel(ProjectAccessibility.diffLine(line))
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(ProjectAccessibility.diffSummary(file))
                }

                if change.status == .review,
                    model.canReviewChanges
                {
                    Section("Decision") {
                        TextField("Review note", text: $comment, axis: .vertical)
                            .lineLimit(2...5)
                        Button {
                            confirmingApproval = true
                        } label: {
                            Text(.projectApproveAndMerge(projectName))
                        }
                        .disabled(!model.canApprove(change))
                        Button {
                            Task { _ = await model.requestChanges(change, comment: comment) }
                        } label: {
                            Text(.projectRequestChanges(projectName))
                        }
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Review Change")
        .confirmationDialog(
            "Merge this exact reviewed change?",
            isPresented: $confirmingApproval,
            titleVisibility: .visible
        ) {
            if let change {
                Button {
                    Task {
                        _ = await model.approve(change, comment: comment.isEmpty ? nil : comment)
                    }
                } label: {
                    Text(.projectApproveAndMerge(projectName))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "SparkPilot sends the full evidence digest shown in this review. If any file or test changed, the Spark refuses the merge."
            )
        }
    }

    private var projectName: String {
        model.selectedProject?.name ?? String(localized: "Project")
    }
}

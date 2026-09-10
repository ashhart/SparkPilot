import SparkAPI
import SparkDesignSystem
import SwiftUI

public enum ProjectAccessibility {
    public static func diffSummary(_ file: GeneratedAPI.ProjectChangedFile) -> String {
        let hunks = String(localized: .diffHunks(file.hunks.count))
        let additions = String(localized: .diffAdditions(file.additions))
        let removals = String(localized: .diffRemovals(file.deletions))
        return String(
            localized: .diffSummaryForFile(
                file: file.path,
                additions: additions,
                removals: removals,
                hunks: hunks
            )
        )
    }

    public static func diffLine(_ line: GeneratedAPI.ProjectDiffLine) -> String {
        switch line.kind {
        case .addition: String(localized: .diffAddedLine(line.content))
        case .deletion: String(localized: .diffRemovedLine(line.content))
        case .context: String(localized: .diffContextLine(line.content))
        }
    }

    public static let terminalTextAlternative = String(
        localized: "Screen reader text shows the same terminal output as selectable text."
    )
}

public struct ProjectsView: View {
    @Bindable private var model: ProjectsModel
    @State private var showingCreate = false
    @State private var deleting: GeneratedAPI.Project?
    @State private var deletionTargetID: String?

    public init(model: ProjectsModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.targets.isEmpty, model.projectState != .loading {
                ContentUnavailableView(
                    "No paired Sparks",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("Add a Spark before creating or opening a project.")
                )
            } else {
                projectList
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Project", systemImage: "plus") { showingCreate = true }
                    .disabled(!model.canCreateProject)
                    .help(
                        model.canCreateProject
                            ? String(localized: "Create a project on this Spark")
                            : String(localized: "This device cannot create projects here")
                    )
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateProjectView(model: model, isPresented: $showingCreate)
        }
        .alert(
            "Delete project from Spark?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            presenting: deleting
        ) { project in
            Button("Delete Project", role: .destructive) {
                guard let targetID = deletionTargetID else { return }
                Task { _ = await model.deleteProject(project, targetID: targetID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(.projectDeletionConfirmation(project.name))
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var projectList: some View {
        List {
            if model.targets.count > 1 {
                Section("Spark") {
                    Picker("Spark", selection: targetSelection) {
                        ForEach(model.targets) { target in
                            // QA-14: the menu said nothing about which Sparks could answer.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name)
                                if let state = ProjectAvailabilityPresentation.shortState(
                                    for: target.status
                                ) {
                                    Text(state)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(target.id)
                        }
                    }
                }
            }

            if let warning = model.warning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if (model.projectState == .idle || model.projectState == .loading)
                    && model.projects.isEmpty
                {
                    loadingRows
                } else {
                    switch model.projectState {
                    case .failed(let message):
                        ProjectFailureView(message: message) { await model.refreshProjects() }
                    case .empty:
                        ContentUnavailableView(
                            "No projects",
                            systemImage: "hammer",
                            description: Text(emptyDescription)
                        )
                    case .idle, .loading, .loaded:
                        ForEach(model.projects, id: \.id) { project in
                            NavigationLink {
                                ProjectDetailView(model: model, project: project)
                            } label: {
                                HStack {
                                    ProjectRow(project: project)
                                    if model.deletingProjectID == project.id {
                                        Spacer()
                                        ProgressView().accessibilityLabel("Deleting project")
                                    }
                                }
                            }
                            .disabled(model.deletingProjectID == project.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if model.canDeleteProject(project) {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        deletionTargetID = model.selectedTargetID
                                        deleting = project
                                    }
                                }
                            }
                            .contextMenu {
                                if model.canDeleteProject(project) {
                                    Button(
                                        "Delete Project",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        deletionTargetID = model.selectedTargetID
                                        deleting = project
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("On this Spark")
                    Spacer()
                    if model.isShowingCachedProjects {
                        Label("Cached", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var targetSelection: Binding<String> {
        Binding(
            get: { model.selectedTargetID ?? "" },
            set: { value in Task { await model.selectTarget(value) } }
        )
    }

    private var emptyDescription: String {
        guard let target = model.selectedTarget else {
            return String(localized: "Choose a paired Spark.")
        }
        switch target.status {
        case .available:
            return model.canCreateProject
                ? String(localized: "Create a project to browse files and run an agent.")
                : String(localized: "No projects have been shared with this device.")
        case .connecting:
            return String(localized: "This Spark is still connecting.")
        case .offline:
            return String(localized: "This Spark is offline.")
        case .identityMismatch:
            return String(localized: "Review this Spark's identity before opening Projects.")
        case .runtimeUpdateRequired:
            return String(localized: "Update Spark Runtime before opening Projects.")
        case .runtimeUnsupported:
            return String(localized: "Update Spark Runtime to use Projects.")
        case .unavailable:
            return String(localized: "Projects are unavailable on this Spark.")
        }
    }

    private var loadingRows: some View {
        ForEach(0..<3, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(
                        width: 120,
                        height: 10
                    )
                }
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading projects")
        }
    }
}

struct ProjectRow: View {
    let project: GeneratedAPI.Project

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                HStack {
                    Text(ProjectPresentation.state(project.state))
                    if let branch = project.defaultBranch { Text(branch) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !(project.harnessUpdates ?? []).isEmpty {
                    Label("Coding agent update available", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "hammer.fill")
                .foregroundStyle(project.state == .ready ? .blue : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CreateProjectView: View {
    @Bindable var model: ProjectsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var repositoryURL = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Repository URL (optional)", text: $repositoryURL)
                        .textContentType(.URL)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                }
                Section {
                    Text(
                        "The Spark creates an isolated worktree. Existing repositories are not overwritten."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        submitting = true
                        Task {
                            let created = await model.createProject(
                                name: name,
                                repositoryURL: repositoryURL.isEmpty ? nil : repositoryURL
                            )
                            submitting = false
                            if created { isPresented = false }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting
                    )
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 300)
        #endif
    }
}

struct ProjectDetailView: View {
    private enum Tool { case files, changes, terminal, preview }
    @State private var tool: Tool = .files
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
        private var compact: Bool { sizeClass == .compact }
    #else
        private var compact: Bool { false }
    #endif

    private func toolButton(_ value: Tool, title: String, icon: String) -> some View {
        Button {
            tool = value
        } label: {
            VStack(spacing: 4) {
                if compact {
                    Image(systemName: icon).font(.body)
                    Text(title).font(.caption.weight(.medium))
                } else {
                    Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                }
            }
            .frame(minWidth: compact ? 48 : nil)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(
                tool == value ? Color.accentColor.opacity(0.14) : Color.clear,
                in: .capsule
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .foregroundStyle(tool == value ? Color.accentColor : .primary)
        .accessibilityAddTraits(tool == value ? .isSelected : [])
    }

    @Bindable var model: ProjectsModel
    let project: GeneratedAPI.Project

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    toolButton(.files, title: String(localized: "Files"), icon: "doc.on.doc")
                    toolButton(
                        .changes,
                        title: String(localized: "Changes"),
                        icon: "arrow.triangle.branch"
                    )
                    toolButton(.terminal, title: String(localized: "Terminal"), icon: "terminal")
                    toolButton(.preview, title: String(localized: "Preview"), icon: "safari")
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("spark.project.tools")
            Group {
                switch tool {
                case .files: ProjectFilesView(model: model)
                case .changes: ProjectChangesView(model: model)
                case .terminal: ProjectTerminalView(model: model)
                case .preview: ProjectPreviewView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project.name)
        .task {
            if model.selectedProject?.id != project.id { await model.openProject(project) }
        }
        .onDisappear { Task { await model.stopTerminal() } }
    }
}

struct ProjectFailureView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await retry() } }
        }
    }
}

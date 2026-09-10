import SparkAPI
import SparkProjects
import SwiftUI

@MainActor
struct SparkDevelopmentSetupView: View {
    let workspace: SparkDevelopmentWorkspace
    let onOpen: (SparkDevelopmentRecord) -> Void
    @State private var targets: [SparkChatTarget]
    @State private var selectionID: String
    @State private var confirmingTargets: Bool
    @State private var preparation: GeneratedAPI.DevelopmentPreparation?
    @State private var projectID = ""
    @State private var newFolder = ""
    @State private var harness: ProjectDevelopmentHarness = .ohMyPi
    @State private var projects: ProjectsModel
    @State private var busy = false
    @State private var selectingSpark = false
    @State private var selectionAttempt = UUID()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let targetProvider: LocalSparkChatTargetProvider

    init(workspace: SparkDevelopmentWorkspace, onOpen: @escaping (SparkDevelopmentRecord) -> Void) {
        self.workspace = workspace
        self.onOpen = onOpen
        let provider = LocalSparkChatTargetProvider(library: workspace.library)
        targetProvider = provider
        // The model each Spark was last seen running shows at once; the live check then confirms or replaces it.
        let live = provider.catalogue().targets
        let initial = live.isEmpty ? provider.rememberedTargets() : live
        _targets = State(initialValue: initial)
        _confirmingTargets = State(initialValue: live.isEmpty)
        _selectionID = State(initialValue: initial.first?.selectionID ?? "")
        let model = ProjectsModel(provider: SignedProjectDataProvider(library: workspace.library))
        model.selectedTargetID = initial.first?.id
        _projects = State(initialValue: model)
    }
    private var selectedTarget: SparkChatTarget? { targets.first { $0.selectionID == selectionID } }
    private var targetID: String? { selectedTarget?.id }

    var body: some View {
        NavigationStack {
            Form {
                SparkDevelopmentHarnessPicker(harness: $harness)
                Section {
                    Picker("Spark and model", selection: $selectionID) {
                        if targets.isEmpty {
                            Text(
                                confirmingTargets ? "Finding running models…" : "No running models"
                            )
                            .tag("")
                        }
                        ForEach(targets, id: \.selectionID) { target in
                            Text(.developmentNames(target.displayName, target.modelName)).tag(
                                target.selectionID
                            )
                        }
                    }
                    if targets.isEmpty, confirmingTargets {
                        SparkSkeletonList(
                            rowCount: 1,
                            accessibilityLabel: String(
                                localized: "Checking your Sparks for a running model"
                            )
                        )
                    }
                    if let target = selectedTarget {
                        Label(
                            target.clusterID == nil
                                ? "Runs on your Spark" : "Uses your Spark cluster",
                            systemImage: "server.rack"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        if confirmingTargets {
                            Label(
                                "Last seen running; confirming with the Spark…",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Compute")
                        SparkTooltipButton(
                            title: String(localized: "Spark and model"),
                            message: String(
                                localized:
                                    "The coding agent sends its requests to this model on this Spark. Only running models are listed; start one from Models and services first."
                            )
                        )
                    }
                } footer: {
                    preparationFooter
                }
                Section {
                    Picker("Working folder", selection: $projectID) {
                        Text("Create a new folder").tag("")
                        ForEach(projects.projects, id: \.id) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    if projectID.isEmpty {
                        TextField("Folder name", text: $newFolder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                                .textInputAutocapitalization(.never)
                            #endif
                    }
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Files stay on this Spark, ready to reopen from your iPhone, iPad or Mac.")
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                if let warning = projects.warning {
                    Section { Text(warning).foregroundStyle(.orange) }
                }
                Section {
                    Button {
                        Task { await open() }
                    } label: {
                        HStack {
                            if busy { ProgressView() } else { Image(systemName: "terminal") }
                            Text(busy ? "Preparing workspace…" : "Open Workspace")
                        }.frame(maxWidth: .infinity)
                    }
                    .disabled(
                        busy || selectingSpark || targetID == nil
                            || projects.selectedTargetID != targetID
                            || (projectID.isEmpty
                                && (newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty || !projects.canCreateProject))
                    )
                }
            }
            .disabled(busy)
            .formStyle(.grouped)
            .navigationTitle("New Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
            .task {
                // Both checks talk to every Spark; neither needs the other's answer.
                async let evidence: Void = targetProvider.refresh()
                async let loaded: Void = projects.load()
                _ = await (evidence, loaded)
                let live = targetProvider.catalogue().targets
                targets = live
                confirmingTargets = false
                if !live.contains(where: { $0.selectionID == selectionID }) {
                    selectionID = live.first?.selectionID ?? ""
                }
                await selectSpark()
                await refreshPreparation()
            }
            .onChange(of: selectionID) { _, _ in
                Task {
                    await selectSpark()
                    await refreshPreparation()
                }
            }
        }
        .frame(idealWidth: 560, idealHeight: 600)
        .interactiveDismissDisabled(busy)
    }

    @ViewBuilder private var preparationFooter: some View {
        if let preparation, let name = selectedTarget?.displayName {
            switch preparation.status {
            case .preparing: Text(.developmentPreparing(name))
            case .ready: Text(.developmentPrepared(name))
            case .failed: Text(.developmentPreparationFailed(name))
            case .idle:
                EmptyView()
            }
        }
    }

    private func selectSpark() async {
        let attempt = UUID()
        selectionAttempt = attempt
        selectingSpark = true
        defer { if selectionAttempt == attempt { selectingSpark = false } }
        projectID = ""
        error = nil
        // The loader already lands on the remembered Spark; only a different choice asks again.
        guard let targetID, projects.selectedTargetID != targetID else { return }
        await projects.selectTarget(targetID)
    }

    /// Asked on every visit: opening this sheet is the moment the Spark's tools should already be ready.
    private func refreshPreparation() async {
        guard let targetID else {
            preparation = nil
            return
        }
        let status = await SparkDevelopmentPreparer.shared.prepare(
            library: workspace.library,
            targetID: targetID,
            force: true
        )
        guard self.targetID == targetID else { return }
        preparation = status
    }
    private func open() async {
        guard !busy, !selectingSpark, let targetID, projects.selectedTargetID == targetID else {
            return
        }
        guard SparkEngineeringMode.isEnabled() else {
            error = String(
                localized:
                    "Engineering Mode is off. Turn it on in Settings before opening a development workspace."
            )
            return
        }
        let nameOfSpark = selectedTarget?.displayName
        let modelID = selectedTarget?.modelID
        let clusterID = selectedTarget?.clusterID?.rawValue.uuidString.lowercased()
        busy = true
        defer { busy = false }
        error = nil
        var project = projects.projects.first { $0.id == projectID }
        if project == nil {
            let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projects.projects.contains(where: { $0.name == name }) else {
                error = String(
                    localized:
                        "A folder with that name exists; select it above or choose another name."
                )
                return
            }
            let previous = Set(projects.projects.map(\.id))
            guard await projects.createProject(name: name, repositoryURL: nil) else {
                error =
                    String(
                        localized:
                            "The workspace folder could not be created; check this Spark's connection and your permissions."
                    )
                return
            }
            for _ in 0..<60 {
                guard !Task.isCancelled, self.targetID == targetID else { return }
                await projects.refreshProjects()
                let matches = projects.projects.filter {
                    !previous.contains($0.id) && $0.name == name
                }
                if matches.count == 1 {
                    project = matches[0]
                    break
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        guard let project else {
            error = String(
                localized:
                    "Folder creation is still running; refresh the folder list before trying again."
            )
            return
        }
        onOpen(
            SparkDevelopmentRecord(
                id: UUID(),
                targetID: targetID,
                projectID: project.id,
                projectName: project.name,
                sparkName: nameOfSpark ?? String(localized: "Spark"),
                selection: ProjectDevelopmentSelection(
                    harness: harness,
                    modelID: modelID ?? "",
                    clusterID: clusterID
                ),
                launchKey: UUID(),
                terminal: nil,
                draft: ""
            )
        )
    }
}

/// The supported choices for new sessions; older Pi records remain decodable and reopenable.
struct SparkDevelopmentHarnessPicker: View {
    static let choices: [ProjectDevelopmentHarness] = [.ohMyPi, .openCode, .claudeCode, .codex]
    @Binding var harness: ProjectDevelopmentHarness

    var body: some View {
        Section {
            Picker("Harness", selection: $harness) {
                ForEach(Self.choices) { choice in
                    Text(choice == .ohMyPi ? String(localized: "Oh My Pi · Default") : choice.name)
                        .tag(choice)
                }
            }
            .accessibilityIdentifier("spark.development.harness")
        } header: {
            Text("Choose your coding agent")
        } footer: {
            Text(
                "Opens the harness's own interactive interface on your Spark, connected to your selected model."
            )
            Text(
                "Leaving SparkPilot disconnects your screen, not the running agent. Reopen the saved workspace to reconnect; the Spark must remain on."
            )
        }
    }
}

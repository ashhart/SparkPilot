#if DEBUG
    import Foundation
    import SparkAPI
    import SparkLibrary
    import SparkProjects
    import SwiftUI

    /// Explicit sample fixtures exercise the real multi-pane terminal view without touching a Spark.
    @MainActor
    struct SparkDevelopmentPreview: View {
        @State private var workspace: SparkDevelopmentWorkspace
        @State private var projectTools = ProjectsModel(
            provider: DevelopmentPreviewProvider(name: String(localized: "Sample project"))
        )
        private let contexts: [UUID: SparkDevelopmentContext]

        init() {
            let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "development-preview-\(UUID()).json"
            )
            let workspace = SparkDevelopmentWorkspace(library: library, archiveURL: url)
            var contexts: [UUID: SparkDevelopmentContext] = [:]
            for (name, model) in [
                (String(localized: "Weather app"), String(localized: "Sample model A")),
                (String(localized: "Personal website"), String(localized: "Sample model B")),
            ] {
                let provider = DevelopmentPreviewProvider(name: name)
                let record = SparkDevelopmentRecord(
                    id: UUID(),
                    targetID: "development-preview",
                    projectID: provider.project.id,
                    projectName: name,
                    sparkName: String(localized: "Sample Spark"),
                    selection: .init(harness: .ohMyPi, modelID: model, clusterID: nil),
                    launchKey: UUID(),
                    terminal: nil,
                    draft: ""
                )
                workspace.update(record)
                contexts[record.id] = SparkDevelopmentContext(
                    record: record,
                    workspace: workspace,
                    provider: provider
                )
            }
            _workspace = State(initialValue: workspace)
            self.contexts = contexts
            try? FileManager.default.removeItem(at: url)
        }
        var body: some View {
            SparkDevelopmentView(previewWorkspace: workspace, contexts: contexts)
                .toolbar {
                    NavigationLink("Project Tools") { ProjectsView(model: projectTools) }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("Preview · sample terminal output · nothing runs on a Spark")
                        .font(.caption).frame(maxWidth: .infinity).padding(8).background(
                            .thinMaterial
                        )
                }
        }
    }

    struct SparkDevelopmentHarnessPreview: View {
        @State private var harness: ProjectDevelopmentHarness = .ohMyPi
        var body: some View {
            Form { SparkDevelopmentHarnessPicker(harness: $harness) }
                .navigationTitle("Harness preview")
        }
    }

    private actor DevelopmentPreviewConnection: ProjectTerminalConnecting {
        let name: String
        var initial = true
        init(name: String) { self.name = name }
        func start() async throws {}
        func send(_ text: String) async throws {}
        func receive() async throws -> String {
            if initial {
                initial = false
                // A steady fixture cursor lets UI tests become idle after focusing the terminal.
                return
                    "\u{1b}[2J\u{1b}[H\u{1b}[2 q  Terminal layout preview · \(name)\r\n\r\n  This is sample output for checking tabs, split panes and keyboard controls.\r\n\r\n  No coding agent is running in this preview.\r\n\r\n  Open a workspace in Develop to use the selected harness on your Spark.\r\n\r\n\u{1b}[32m  Sample ANSI colour\u{1b}[0m\r\n\r\n  > "
            }
            try await Task.sleep(for: .seconds(30))
            return ""
        }
        func cancel() async {}
    }

    @MainActor
    private final class DevelopmentPreviewProvider: SparkDevelopmentProviding {
        var developmentSelection: ProjectDevelopmentSelection?
        var developmentIdempotencyKey = UUID()
        let project: GeneratedAPI.Project
        private var deleted = false
        init(name: String) {
            project = .init(
                id: UUID().uuidString.lowercased(),
                name: name,
                state: .ready,
                defaultBranch: "main",
                capabilities: [.read, .write, .terminal, .delete, .preview],
                createdAt: "2026-09-05T12:00:00Z",
                updatedAt: "2026-09-05T12:00:00Z"
            )
        }
        func targets() async -> [ProjectTarget] {
            [
                .init(
                    id: "development-preview",
                    name: String(localized: "Sample Spark"),
                    status: .available
                )
            ]
        }
        func projects(targetID: String) async throws -> ProjectCollection {
            .init(items: deleted ? [] : [project], canCreate: false)
        }
        func deleteProject(targetID: String, projectID: String) async throws { deleted = true }
        func createProject(targetID: String, name: String, repositoryURL: String?) async throws {
            throw URLError(.unsupportedURL)
        }
        func files(targetID: String, projectID: String) async throws -> [GeneratedAPI
            .ProjectFileEntry]
        {
            [
                .init(
                    path: "Sources/ForecastCard.swift",
                    revision: String(repeating: "a", count: 64),
                    sizeBytes: 42
                )
            ]
        }
        func file(targetID: String, projectID: String, path: String) async throws
            -> GeneratedAPI.ProjectFileContents
        {
            .init(
                path: path,
                content: "// Sample workspace\nimport SwiftUI\n",
                revision: String(repeating: "a", count: 64)
            )
        }
        func saveFile(
            targetID: String,
            projectID: String,
            path: String,
            content: String,
            revision: String
        ) async throws -> ProjectFileSaveOutcome { throw URLError(.unsupportedURL) }
        func changes(targetID: String, projectID: String) async throws -> [GeneratedAPI
            .ProjectChange]
        { [] }
        func preview(targetID: String, projectID: String, port: Int, path: String) async throws
            -> String
        { throw URLError(.unsupportedURL) }
        func startAgent(targetID: String, projectID: String, task: String) async throws {
            throw URLError(.unsupportedURL)
        }
        func approve(
            targetID: String,
            projectID: String,
            changeID: String,
            reviewDigest: String,
            comment: String?
        ) async throws -> GeneratedAPI.ProjectChange { throw URLError(.unsupportedURL) }
        func requestChanges(
            targetID: String,
            projectID: String,
            changeID: String,
            reviewDigest: String,
            comment: String
        ) async throws -> GeneratedAPI.ProjectChange { throw URLError(.unsupportedURL) }
        func createTerminal(targetID: String, projectID: String, shell: ProjectTerminalShell)
            async throws -> (GeneratedAPI.ProjectTerminal, any ProjectTerminalConnecting)
        {
            (
                .init(
                    terminalId: UUID().uuidString.lowercased(),
                    projectId: projectID,
                    state: .running,
                    createdAt: "2026-09-05T12:00:00Z"
                ), DevelopmentPreviewConnection(name: project.name)
            )
        }
        func developmentTerminalState(targetID: String, projectID: String, terminalID: String)
            async throws -> String?
        { "running" }
        func reconnectTerminal(targetID: String, projectID: String, terminalID: String) async throws
            -> any ProjectTerminalConnecting
        { DevelopmentPreviewConnection(name: project.name) }
        func closeTerminal(targetID: String, projectID: String, terminalID: String) async throws {}
    }
#endif

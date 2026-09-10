#if os(macOS)
    import AppKit
    import SparkIntents
    import SparkLibrary
    import SparkProjects
    import SwiftUI

    /// PLAN 41.3: which project, on which Spark, a Mac window was opened for.
    public struct MacProjectWindowRequest: Codable, Hashable, Sendable {
        public let targetID: String
        public let projectID: String
        public let projectName: String
        public let sparkName: String

        public init(targetID: String, projectID: String, projectName: String, sparkName: String) {
            self.targetID = targetID
            self.projectID = projectID
            self.projectName = projectName
            self.sparkName = sparkName
        }

        public var windowTitle: String {
            String(localized: .macProjectWindowTitle(project: projectName, spark: sparkName))
        }
    }

    /// The scene identifiers the menu bar, the commands and the app agree on.
    public enum MacSparkWindowID {
        public static let askSpark = "ask-spark"
        public static let project = "project"
        public static let feedback = "bug-feedback"
    }

    /// PLAN 41.3's menu-bar status item: state without opening a window, and two ways in.
    @MainActor
    public struct MacSparkMenuBarView: View {
        private let library: SparkLibrary
        @Environment(\.openWindow) private var openWindow

        public init(library: SparkLibrary) {
            self.library = library
        }

        private var status: MacMenuBarStatus {
            MacMenuBarStatus.resolve(entries: library.entries)
        }

        public var body: some View {
            let status = status
            Text(verbatim: status.summary)
            if !status.sparks.isEmpty {
                Divider()
                ForEach(status.sparks) { spark in
                    Text(verbatim: MacSparkMenuBarView.line(for: spark))
                }
            }
            Divider()
            Button(String(localized: "Ask Spark…")) { openWindow(id: MacSparkWindowID.askSpark) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button(String(localized: "Open SparkPilot")) {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(String(localized: "Quit SparkPilot")) { NSApplication.shared.terminate(nil) }
        }

        /// One flat line per Spark: colour is never the only carrier of state (§51.1).
        static func line(for spark: MacMenuBarStatus.Spark) -> String {
            guard let detail = spark.detail, !detail.isEmpty else {
                return String(
                    localized: .macMenuBarSpark(name: spark.name, state: spark.state)
                )
            }
            return String(
                localized: .macMenuBarSparkDetail(
                    name: spark.name,
                    state: spark.state,
                    detail: detail
                )
            )
        }
    }

    /// The window behind the global Ask Spark shortcut, which also takes a file from Finder.
    @MainActor
    public struct MacAskSparkWindow: View {
        private let library: SparkLibrary
        @State private var workspace: SparkChatWorkspace
        @State private var droppedFile: URL?

        public init(library: SparkLibrary) {
            self.library = library
            _workspace = State(initialValue: SparkChatWorkspace.shared(library: library))
        }

        public var body: some View {
            SparkIntentActionView(
                action: droppedFile == nil ? .ask : .analyseFile,
                chat: workspace.selected.model,
                droppedFile: droppedFile
            )
            .frame(minWidth: 460, minHeight: 420)
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                droppedFile = first
                return true
            }
        }
    }

    /// A project in its own window, with its own model so two windows do not fight (§41.3).
    @MainActor
    public struct MacProjectWindow: View {
        @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
        private let request: MacProjectWindowRequest?
        private let library: SparkLibrary
        @State private var model: ProjectsModel?

        public init(request: MacProjectWindowRequest?, library: SparkLibrary) {
            self.request = request
            self.library = library
        }

        public var body: some View {
            Group {
                if !engineeringMode {
                    SparkEngineeringModeRequiredView()
                } else if let model {
                    ProjectsView(model: model)
                } else if request == nil {
                    ContentUnavailableView(
                        String(localized: "No project chosen"),
                        systemImage: "folder",
                        description: Text("Open a project from the Projects list.")
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(request?.windowTitle ?? String(localized: "Project"))
            .frame(minWidth: 720, minHeight: 480)
            .task(id: request) { await open() }
            .onChange(of: engineeringMode) { _, enabled in
                Task { if enabled { await open() } else { await model?.detachTerminal() } }
            }
        }

        private func open() async {
            guard engineeringMode, let request else { return }
            let projects = ProjectsModel(
                provider: SignedProjectDataProvider(library: library)
            )
            model = projects
            await projects.load()
            await projects.selectTarget(request.targetID)
            guard let project = projects.projects.first(where: { $0.id == request.projectID })
            else { return }
            await projects.openProject(project)
        }
    }

    /// The status item's own label: one symbol, with the summary spoken beside it.
    @MainActor
    public struct MacSparkMenuBarLabel: View {
        private let library: SparkLibrary?

        public init(library: SparkLibrary?) {
            self.library = library
        }

        public var body: some View {
            let status = library.map { MacMenuBarStatus.resolve(entries: $0.entries) }
            Image(systemName: status?.symbol ?? "server.rack")
                .accessibilityLabel(status?.summary ?? String(localized: "SparkPilot"))
        }
    }

    /// PLAN 41.3's global Ask Spark shortcut, and the New Window command multi-window scenes need.
    public struct MacSparkCommands: Commands {
        @Environment(\.openWindow) private var openWindow

        public init() {}

        public var body: some Commands {
            CommandGroup(after: .newItem) {
                Button(String(localized: "Ask Spark…")) {
                    openWindow(id: MacSparkWindowID.askSpark)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Send feedback…") { openWindow(id: MacSparkWindowID.feedback) }
            }
        }
    }
#endif

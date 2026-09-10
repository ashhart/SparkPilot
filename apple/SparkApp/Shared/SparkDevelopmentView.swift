import SparkAPI
import SparkLibrary
import SparkProjects
import SwiftUI

@MainActor
public struct SparkDevelopmentView: View {
    public static let windowID = "development-workspace"
    @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
    @State private var workspace: SparkDevelopmentWorkspace
    @State private var contexts: [UUID: SparkDevelopmentContext] = [:]
    @State private var selectedID: UUID?
    @State private var splitID: UUID?
    @State private var fullScreenID: UUID?
    @SceneStorage("spark.development.selected") private var savedSelected = ""
    @SceneStorage("spark.development.split") private var savedSplit = ""
    @State private var showingSetup = false
    @State private var closedTabs: Set<UUID> = []
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ProjectDevelopmentPalette { .init(colorScheme) }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    private let initialWorkspaceID: UUID?

    public init(library: SparkLibrary, workspaceID: UUID? = nil) {
        _workspace = State(initialValue: SparkDevelopmentWorkspace.shared(library: library))
        initialWorkspaceID = workspaceID
        _selectedID = State(initialValue: workspaceID)
    }

    #if DEBUG
        init(previewWorkspace: SparkDevelopmentWorkspace, contexts: [UUID: SparkDevelopmentContext])
        {
            _workspace = State(initialValue: previewWorkspace)
            _contexts = State(initialValue: contexts)
            initialWorkspaceID = previewWorkspace.records.first?.id
            _selectedID = State(initialValue: initialWorkspaceID)
        }
    #endif

    public var body: some View {
        Group {
            if engineeringMode {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        tabStrip(wide: geometry.size.width >= 900)
                        if let error = workspace.storageError {
                            Text(error).font(.caption).foregroundStyle(.orange).padding(12)
                        }
                        if let selectedID, let context = contexts[selectedID] {
                            HStack(spacing: 1) {
                                pane(context, id: selectedID)
                                if geometry.size.width >= 900, let splitID, splitID != selectedID,
                                    let second = contexts[splitID]
                                {
                                    Rectangle().fill(.primary.opacity(0.1)).frame(width: 1)
                                    pane(second, id: splitID)
                                }
                            }
                        } else {
                            ContentUnavailableView {
                                Label("A place to build", systemImage: "terminal")
                            } description: {
                                Text(
                                    "Open a folder on your Spark and start coding with Oh My Pi, or choose another coding agent."
                                )
                            } actions: {
                                Button("New Workspace", systemImage: "plus") { showingSetup = true }
                                    .buttonStyle(.borderedProminent).tint(palette.accent)
                                    .foregroundStyle(palette.onAccent)
                            }
                        }
                    }
                    .background(palette.canvas)
                }

            } else {
                SparkEngineeringModeRequiredView()
            }
        }
        .navigationTitle("Develop")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(palette.accent)
        // The Spark readies its image and coding agent while the owner is still choosing a folder.
        .task(id: engineeringMode) {
            guard engineeringMode else { return }
            await SparkDevelopmentPreparer.shared.prepareAll(library: workspace.library)
        }
        #if os(iOS)
            .fullScreenCover(
                isPresented: Binding(
                    get: { fullScreenID != nil },
                    set: { if !$0 { fullScreenID = nil } }
                )
            ) {
                if let id = fullScreenID, let context = contexts[id] {
                    SparkDevelopmentPane(
                        context: context,
                        onOpenWindow: windowAction(id),
                        onRestore: { fullScreenID = nil }
                    )
                    .background(palette.canvas)
                    .interactiveDismissDisabled()
                }
            }
        #endif
        .sheet(isPresented: $showingSetup) {
            SparkDevelopmentSetupView(workspace: workspace) { record in
                workspace.update(record)
                activate(record.id)
                showingSetup = false
            }
        }
        .task {
            guard engineeringMode else { return }
            if let first = initialWorkspaceID ?? UUID(uuidString: savedSelected)
                ?? workspace.records.first?.id
            {
                activate(first)
            }
            if let split = UUID(uuidString: savedSplit), let record = workspace.record(split),
                split != selectedID
            {
                if contexts[split] == nil {
                    contexts[split] = SparkDevelopmentContext(record: record, workspace: workspace)
                }
                splitID = split
            }
        }
        .onChange(of: workspace.records.map(\.id)) { _, ids in
            let removed = Set(contexts.keys).subtracting(ids)
            for id in removed {
                if let context = contexts.removeValue(forKey: id) {
                    Task { await context.detach() }
                }
                if fullScreenID == id { fullScreenID = nil }
                if splitID == id { splitID = nil }
                if selectedID == id { selectedID = nil }
            }
            if selectedID == nil, let next = ids.first { activate(next) }
        }
        .onChange(of: selectedID) { _, id in savedSelected = id?.uuidString ?? "" }
        .onChange(of: splitID) { _, id in savedSplit = id?.uuidString ?? "" }
        .onChange(of: engineeringMode) { _, enabled in
            if !enabled {
                fullScreenID = nil
                for context in contexts.values { Task { await context.detach() } }
            } else if let first = selectedID ?? workspace.records.first?.id {
                activate(first)
            }
        }
    }

    @ViewBuilder
    private func pane(_ context: SparkDevelopmentContext, id: UUID) -> some View {
        if fullScreenID == id {
            // A native terminal view belongs to one UIKit parent at a time.
            Color.clear
        } else {
            SparkDevelopmentPane(
                context: context,
                onOpenWindow: windowAction(id),
                onExpand: expandAction(id)
            ).id(context.id)
        }
    }

    private func expandAction(_ id: UUID) -> (() -> Void)? {
        #if os(iOS)
            return { fullScreenID = id }
        #else
            return nil
        #endif
    }

    private func windowAction(_ id: UUID) -> (() -> Void)? {
        guard supportsMultipleWindows else { return nil }
        return { openWindow(id: Self.windowID, value: id) }
    }
    private func activate(_ id: UUID) {
        guard let record = workspace.record(id) else { return }
        closedTabs.remove(id)
        if contexts[id] == nil {
            contexts[id] = SparkDevelopmentContext(record: record, workspace: workspace)
        }
        if splitID == id { splitID = selectedID }
        selectedID = id
    }
    private func tabStrip(wide: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(workspace.records) { record in
                    Button(
                        String(localized: .developmentNames(record.projectName, record.sparkName))
                    ) { activate(record.id) }
                }
                Divider()
                Button("New Workspace", systemImage: "plus") { showingSetup = true }
            } label: {
                Image(systemName: "square.stack").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Saved workspaces")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.records.filter { !closedTabs.contains($0.id) }) { record in
                        HStack(spacing: 8) {
                            Button {
                                activate(record.id)
                            } label: {
                                Label(record.projectName, systemImage: "terminal")
                                    .lineLimit(1).padding(.vertical, 12).padding(.leading, 12)
                            }
                            Button("Close tab", systemImage: "xmark") {
                                closedTabs.insert(record.id)
                                if splitID == record.id { splitID = nil }
                                if selectedID == record.id {
                                    selectedID = nil
                                    if let next = workspace.records.first(where: {
                                        !closedTabs.contains($0.id)
                                    }) {
                                        activate(next.id)
                                    }
                                }
                            }
                            .labelStyle(.iconOnly).padding(.trailing, 10)
                        }
                        .font(.callout)
                        .foregroundStyle(selectedID == record.id ? palette.accent : .secondary)
                        .background(
                            selectedID == record.id
                                ? palette.accent.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                }
            }
            Button("New Workspace", systemImage: "plus") { showingSetup = true }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
            if wide {
                Menu {
                    if splitID != nil { Button("Close Split") { splitID = nil } }
                    ForEach(workspace.records.filter { $0.id != selectedID }) { record in
                        Button(record.projectName) {
                            if contexts[record.id] == nil {
                                contexts[record.id] = SparkDevelopmentContext(
                                    record: record,
                                    workspace: workspace
                                )
                            }
                            splitID = record.id
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Split workspace")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
        .background(.primary.opacity(0.025))
    }
}

@MainActor
private struct SparkDevelopmentPane: View {
    @Bindable var context: SparkDevelopmentContext
    let onOpenWindow: (() -> Void)?
    var onExpand: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil
    @State private var showingFiles = false
    @State private var confirmingEnd = false
    @State private var consumerID = UUID()
    @FocusState private var draftFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sparkTypingRestriction) private var typingRestriction
    private var palette: ProjectDevelopmentPalette { .init(colorScheme) }
    @Environment(\.scenePhase) private var scenePhase

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            Circle().fill(context.model.terminalState == .loaded ? palette.accent : .secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.record?.projectName ?? String(localized: "Workspace")).font(
                    .callout.weight(.medium)
                )
                Text(
                    .developmentNames(
                        context.record?.sparkName ?? "",
                        context.record?.selection.harness.name ?? ""
                    )
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onExpand {
                Button(
                    "Full screen",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    action: onExpand
                )
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            Button("Files", systemImage: "folder") { showingFiles.toggle() }.labelStyle(.iconOnly)
            actionsMenu
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Full screen gives the whole height to the terminal; what the header row offered floats in one corner.
    private var fullScreenControls: some View {
        HStack(spacing: 0) {
            Button("Files", systemImage: "folder") { showingFiles.toggle() }
                .labelStyle(.iconOnly).frame(width: 36, height: 36)
            actionsMenu
            if let onRestore {
                Button(
                    "Restore layout",
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    action: onRestore
                )
                .labelStyle(.iconOnly).frame(width: 36, height: 36)
            }
        }
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }

    private var actionsMenu: some View {
        Menu {
            Button("Dictate or paste", systemImage: "text.cursor") {
                context.showingInput.toggle()
            }
            Text(context.record?.selection.modelID ?? "")
            Button("Reconnect", systemImage: "arrow.clockwise") {
                Task { await context.reconnect() }
            }
            if let onOpenWindow {
                Button(
                    "Open in New Window",
                    systemImage: "macwindow.on.rectangle",
                    action: onOpenWindow
                )
            }
            Button("End Session", systemImage: "stop.circle", role: .destructive) {
                confirmingEnd = true
            }
            .disabled(
                context.isEnding
                    || (context.model.terminal == nil && context.record?.terminal == nil)
            )
        } label: {
            Image(systemName: "ellipsis").frame(width: 36, height: 36)
        }
        .accessibilityLabel("Workspace actions")
    }

    var body: some View {
        VStack(spacing: 0) {
            if onRestore == nil { sessionHeader }
            if let error = context.openError {
                HStack {
                    Label(error, systemImage: "wifi.exclamationmark").font(.caption)
                    Spacer(minLength: 4)
                    Button("Try Again") { Task { await context.open() } }
                }.foregroundStyle(.orange).padding(12)
            }
            ProjectDevelopmentTerminalView(
                model: context.model,
                dismissKeyboard: { draftFocused = false },
                focusAccessibleInput: {
                    context.showingInput = true
                    draftFocused = true
                },
                onDictate: {
                    context.showingInput = true
                    Task { await context.dictate() }
                },
                isListening: context.isListening,
                onReturn: {
                    if context.showingInput && !context.draft.isEmpty {
                        context.stopVoice()
                        Task { await context.sendDraft(submit: true) }
                    } else {
                        context.model.sendTerminalKeys("\r")
                    }
                },
                typingPaused: typingRestriction.isPaused
            )
            .overlay {
                if context.isEnding {
                    ProgressView(String(localized: "Ending session…")).padding().background(
                        .regularMaterial
                    )
                } else if context.model.terminalState == .loading {
                    VStack(spacing: 8) {
                        ProgressView(String(localized: "Opening workspace…"))
                        Text(
                            "The first session on a Spark also prepares its environment and downloads the coding agent, which can take a few minutes."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if context.model.terminalState == .idle && !context.isEnding {
                    VStack(spacing: 16) {
                        Text(
                            context.record?.automaticallyResume == false
                                ? "Session ended" : "Workspace ready"
                        )
                        .font(.headline)
                        Text("Your project files are saved on the Spark.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Open Session", systemImage: "play.fill") {
                            Task { await context.open() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.canvas)
                }
            }
            .overlay(alignment: .topTrailing) {
                if onRestore != nil { fullScreenControls }
            }
            if typingRestriction.isPaused {
                drivingComposer
            } else if context.showingInput {
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingFiles) {
            ProjectDevelopmentFilesView(model: context.model).frame(
                idealWidth: 600,
                idealHeight: 620
            )
        }
        .alert("End this harness session?", isPresented: $confirmingEnd) {
            Button("End Session", role: .destructive) { Task { await context.end() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This stops the running agent. To leave it working on the Spark, close its tab or return to another part of SparkPilot instead."
            )
        }
        .task { await context.resume(consumer: consumerID) }
        .onDisappear { Task { await context.detach(consumer: consumerID) } }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active {
                    await context.resume(consumer: consumerID)
                } else if phase == .background {
                    await context.detach(consumer: consumerID)
                }
            }
        }
    }
    /// While the car moves the draft is spoken, shown, and sent with one large button.
    private var drivingComposer: some View {
        VStack(spacing: 6) {
            SparkDrivingTypingNotice(restriction: .paused) {
                context.showingInput = true
                Task { await context.dictate() }
            }
            .onAppear { draftFocused = false }
            if !context.draft.isEmpty {
                Text(context.draft).font(.callout).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                Button("Send to session", systemImage: "arrow.up") {
                    context.stopVoice()
                    Task { await context.sendDraft(submit: true) }
                }
                .buttonStyle(.borderedProminent).tint(palette.accent)
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .disabled(context.isInserting || context.model.terminalState != .loaded)
            }
        }
        .padding(10)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = context.voiceError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let error = context.insertError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    Task { await context.dictate() }
                } label: {
                    Image(systemName: context.isListening ? "stop.circle.fill" : "mic")
                        .foregroundStyle(context.isListening ? palette.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(context.isListening ? "Finish dictation" : "Dictate message")
                TextField("Type or dictate…", text: $context.draft, axis: .vertical)
                    .focused($draftFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        context.stopVoice()
                        Task { await context.sendDraft(submit: true) }
                    }
                    .lineLimit(1...5).textFieldStyle(.plain)
                    .padding(.vertical, 12)
                    .accessibilityLabel("Workspace message draft")
                Button("Send", systemImage: "arrow.up") {
                    context.stopVoice()
                    Task { await context.sendDraft(submit: true) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderedProminent).tint(palette.accent)
                .foregroundStyle(palette.onAccent)
                .disabled(
                    context.isInserting || context.draft.isEmpty
                        || context.model.terminalState != .loaded
                )
                .accessibilityLabel("Send message to terminal")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(10)
    }
}

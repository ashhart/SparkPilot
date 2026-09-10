import SparkIntents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SparkIntentActionView: View {
    @State private var model: SparkIntentWorkbench
    @State private var selectingFile = false
    @State private var confirming = false
    @State private var reviewingResult = false
    @Environment(\.scenePhase) private var scenePhase
    let chat: SparkChatModel
    /// 41.3: a file dragged in from Finder, re-read whenever the drop changes.
    private var droppedFile: URL?

    init(action: SparkAppleAction, chat: SparkChatModel, droppedFile: URL? = nil) {
        let workbench = SparkIntentWorkbench(action: action)
        if let droppedFile { workbench.selectFile(droppedFile) }
        _model = State(initialValue: workbench)
        self.chat = chat
        self.droppedFile = droppedFile
    }

    var body: some View {
        Form {
            Section {
                Text(model.action.detail)
                if model.isLoading {
                    ProgressView(String(localized: "Finding your Sparks…"))
                } else if model.targets.isEmpty {
                    Text("Pair a Spark to try this action.").foregroundStyle(.secondary)
                } else {
                    Picker("Spark", selection: $model.targetID) {
                        Text("Choose a Spark").tag("")
                        ForEach(model.targets) { Text(verbatim: $0.displayName).tag($0.id) }
                    }
                    if let target = model.targets.first(where: { $0.id == model.targetID }),
                        !target.allowedActions.contains(model.action.permission)
                    {
                        Text("Your paired role cannot run this action on this Spark.")
                            .foregroundStyle(.secondary)
                    }
                }
                inputs
            }
            .disabled(model.isRunning || confirming)

            Section {
                if model.isRunning {
                    HStack {
                        ProgressView(String(localized: "Running on your Spark…"))
                        Spacer()
                        Button("Stop waiting") { model.cancel() }
                    }
                } else {
                    Button {
                        if model.action.changesModel { confirming = true } else { model.start() }
                    } label: {
                        Label("Run action", systemImage: "play.fill")
                    }
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("apple.action.run")
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                if model.action.requiresText {
                    Text("Only the input you provide here is sent to the selected Spark.")
                }
                if model.action.changesModel || model.action == .analyseFile {
                    Text(
                        "Accepted operations continue on your Spark if you leave this screen or stop waiting."
                    )
                }
            }

            if let result = model.result {
                Section {
                    if model.pendingAnalysis {
                        Text("Analysis is still running on your Spark.")
                    } else if model.action.changesModel {
                        Text("The operation was accepted; check Activity for its progress.")
                    }
                    Text(verbatim: result).textSelection(.enabled)
                        .accessibilityIdentifier("apple.action.result")
                    if model.truncated {
                        Text("This result reached the output limit and may be incomplete.")
                            .foregroundStyle(.secondary)
                    }
                    ShareLink(item: result) {
                        Label("Share result", systemImage: "square.and.arrow.up")
                    }
                    if model.operationID == nil {
                        Button("Prepare Apple app actions from this result") {
                            reviewingResult = true
                        }
                    }
                    if model.pendingAnalysis {
                        NavigationLink {
                            SparkAnalysisCollectionView(
                                jobID: result,
                                targetID: model.targetID,
                                chat: chat
                            )
                        } label: {
                            Text("Check analysis result")
                        }
                    }
                } header: {
                    Text(model.operationID == nil ? "Result" : "Operation ID")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.action.title)
        .task { await model.load() }
        .onChange(of: droppedFile) { _, url in
            if let url { model.selectFile(url) }
        }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.cancel() }
        }
        .alert(model.action.title, isPresented: $confirming) {
            Button("Run action") { model.start(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This changes the model running on the selected Spark and may affect other devices using it."
            )
        }
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: [.text, .json, .yaml]) {
            result in
            if case .success(let url) = result { model.selectFile(url) }
        }
        .sheet(isPresented: $reviewingResult) {
            SparkPersonalActionsView(chat: chat, context: model.result ?? "")
        }
    }

    @ViewBuilder private var inputs: some View {
        if model.action == .loadModel {
            Picker("Model", selection: $model.modelID) {
                Text("Choose an installed model").tag("")
                ForEach(model.availableModels) { Text(verbatim: $0.displayName).tag($0.id) }
            }
        }
        if model.action == .analyseFile {
            Button {
                selectingFile = true
            } label: {
                Label(
                    model.file?.sourceName ?? String(localized: "Choose text file"),
                    systemImage: "doc"
                )
            }
            // 41.3: a Finder drag lands here as well as on the window behind it.
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                model.selectFile(first)
                return true
            }
        }
        if model.action.requiresText {
            TextField(model.action.inputLabel, text: $model.input, axis: .vertical)
                .lineLimit(3...10)
                .accessibilityIdentifier("apple.action.input")
        }
    }
}

@MainActor
private struct SparkAnalysisCollectionView: View {
    let jobID: String
    let targetID: String
    let chat: SparkChatModel

    var body: some View {
        SparkIntentActionView(action: .getAnalysis, chat: chat, jobID: jobID, targetID: targetID)
    }
}

extension SparkIntentActionView {
    fileprivate init(
        action: SparkAppleAction,
        chat: SparkChatModel,
        jobID: String,
        targetID: String
    ) {
        let model = SparkIntentWorkbench(action: action)
        model.input = jobID
        model.targetID = targetID
        _model = State(initialValue: model)
        self.chat = chat
        droppedFile = nil
    }
}

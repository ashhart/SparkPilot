import SparkAPI
import SparkDesignSystem
import SwiftUI

struct ProjectFilesView: View {
    @Bindable var model: ProjectsModel

    var body: some View {
        Group {
            if (model.fileState == .idle || model.fileState == .loading) && model.files.isEmpty {
                ProgressView(String(localized: "Loading files"))
            } else {
                switch model.fileState {
                case .failed(let message):
                    ProjectFailureView(message: message) { await model.refreshProjectContents() }
                case .empty:
                    ContentUnavailableView(
                        "No files",
                        systemImage: "doc",
                        description: Text("This project does not contain any files yet.")
                    )
                case .idle, .loading, .loaded:
                    List(model.files, id: \.path) { file in
                        NavigationLink {
                            ProjectEditorView(model: model, file: file)
                        } label: {
                            Label {
                                LabeledContent(
                                    file.path,
                                    value: ByteCountFormatter.string(
                                        fromByteCount: Int64(file.sizeBytes),
                                        countStyle: .file
                                    )
                                )
                            } icon: {
                                Image(systemName: "doc.text")
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ProjectEditorView: View {
    @Bindable var model: ProjectsModel
    let file: GeneratedAPI.ProjectFileEntry

    var body: some View {
        Group {
            if (model.editorState == .idle || model.editorState == .loading)
                && model.editorPath != file.path
            {
                ProgressView(String(localized: "Opening file"))
            } else if case .failed(let message) = model.editorState {
                ProjectFailureView(message: message) { await model.openFile(file) }
            } else {
                TextEditor(text: $model.editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .disabled(!model.canEditFile)
                    .accessibilityLabel(Text(.projectEditorFor(file.path)))
            }
        }
        .navigationTitle(file.path)
        .toolbar {
            Button("Save", systemImage: "square.and.arrow.down") {
                Task { _ = await model.saveFile() }
            }
            .disabled(!model.canSaveFile)
            .help(String(localized: "Save only if the file has not changed on another device"))
        }
        .task { await model.openFile(file) }
        .sheet(
            isPresented: Binding(
                get: { model.conflict != nil },
                set: { presented in
                    if !presented { model.dismissConflict() }
                }
            )
        ) {
            ProjectFileConflictView(model: model)
        }
    }
}

struct ProjectFileConflictView: View {
    @Bindable var model: ProjectsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedVersion: ConflictVersion = .merged
    @State private var confirmingRemoteVersion = false
    @State private var confirmingLocalVersion = false

    var body: some View {
        NavigationStack {
            Group {
                if let conflict = model.conflict {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(
                            "This file changed on another device",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.title2.bold())
                        .foregroundStyle(.orange)
                        Text(
                            "Merged keeps both sets of edits and marks anything both devices rewrote. Nothing is saved until you use Save."
                        )
                        .foregroundStyle(.secondary)
                        if conflict.merged.conflictCount > 0 {
                            Label {
                                Text(.contestedMergeRegions(conflict.merged.conflictCount))
                            } icon: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }

                        Picker("Version to use", selection: $selectedVersion) {
                            ForEach(ConflictVersion.allCases) { version in
                                Text(version.title).tag(version)
                            }
                        }
                        .pickerStyle(.segmented)

                        if horizontalSizeClass == .compact || selectedVersion == .merged {
                            conflictPane(
                                title: selectedVersion.title,
                                content: content(selectedVersion, conflict)
                            )
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                conflictPane(
                                    title: ConflictVersion.local.title,
                                    content: conflict.localContent
                                )
                                conflictPane(
                                    title: ConflictVersion.remote.title,
                                    content: conflict.remoteContent
                                )
                            }
                        }
                    }
                    .padding(24)
                } else {
                    ContentUnavailableView(
                        "Conflict resolved",
                        systemImage: "checkmark.circle",
                        description: Text("Return to the editor to continue.")
                    )
                }
            }
            .navigationTitle("Revision Conflict")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.dismissConflict() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedVersion.actionTitle) {
                        switch selectedVersion {
                        case .merged: model.mergeConflictVersions()
                        case .local: confirmingLocalVersion = true
                        case .remote: confirmingRemoteVersion = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.conflict == nil)
                }
            }
        }
        .confirmationDialog(
            "Replace your edits with the Spark version?",
            isPresented: $confirmingRemoteVersion,
            titleVisibility: .visible
        ) {
            Button("Use Spark Version", role: .destructive) {
                model.useRemoteConflictVersion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits will leave the editor, but no file will be saved by this choice.")
        }
        .confirmationDialog(
            "Discard the other device's changes?",
            isPresented: $confirmingLocalVersion,
            titleVisibility: .visible
        ) {
            Button("Keep Only My Edits", role: .destructive) {
                model.replaceRemoteWithLocalVersion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Saving after this replaces what the other device saved. Merged keeps both sets of edits instead."
            )
        }
        #if os(macOS)
            .frame(minWidth: 720, minHeight: 520)
        #endif
    }

    private func conflictPane(title: String, content: String) -> some View {
        GroupBox(title) {
            ScrollView([.horizontal, .vertical]) {
                Text(content.isEmpty ? String(localized: "Empty file") : content)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }

    private func content(_ version: ConflictVersion, _ conflict: ProjectFileConflictState)
        -> String
    {
        switch version {
        case .merged: conflict.merged.text
        case .local: conflict.localContent
        case .remote: conflict.remoteContent
        }
    }

    private enum ConflictVersion: String, CaseIterable, Identifiable {
        case merged
        case local
        case remote

        var id: String { rawValue }

        var title: String {
            switch self {
            case .merged: String(localized: "Merged")
            case .local: String(localized: "My Edits")
            case .remote: String(localized: "Spark Version")
            }
        }

        var actionTitle: String {
            switch self {
            case .merged: String(localized: "Return Merged File to Editor")
            case .local: String(localized: "Keep Only My Edits")
            case .remote: String(localized: "Use Spark Version")
            }
        }
    }
}

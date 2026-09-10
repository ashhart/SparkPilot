import Foundation
import Observation
import SparkAPI

/// Own draft revisions and conflicts, rejecting responses after the selected context changes.
@MainActor
@Observable
final class ProjectEditorSession {
    private(set) var editorPath: String?
    var editorText = ""
    private(set) var editorRevision: String?
    private(set) var editorState: ProjectLoadState = .idle
    private(set) var conflict: ProjectFileConflictState?
    @ObservationIgnored var contextIsCurrent: (String, String) -> Bool = { _, _ in false }
    @ObservationIgnored var onSaved: () async -> Void = {}
    private let provider: any ProjectDataProviding
    private var editorSequence = 0
    /// Retain the opened content so a conflict can be merged rather than resolved by discarding a side.
    private var openedContent = ""

    init(provider: any ProjectDataProviding) { self.provider = provider }

    func invalidateRequests() { editorSequence += 1 }

    func clearContents() {
        editorPath = nil
        editorText = ""
        editorRevision = nil
        openedContent = ""
        conflict = nil
    }

    func openFile(
        _ file: GeneratedAPI.ProjectFileEntry,
        targetID: String?,
        projectID: String?,
        available: Bool
    ) async {
        guard available,
            let targetID,
            let projectID
        else {
            editorState = .failed(String(localized: "Reconnect to this Spark to open files."))
            return
        }
        editorSequence += 1
        let sequence = editorSequence
        editorState = .loading
        conflict = nil
        do {
            let contents = try await provider.file(
                targetID: targetID,
                projectID: projectID,
                path: file.path
            )
            guard
                editorRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID
                )
            else { return }
            editorPath = contents.path
            editorText = contents.content
            openedContent = contents.content
            editorRevision = contents.revision
            editorState = .loaded
        } catch {
            guard
                editorRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID
                )
            else { return }
            editorState = .failed(APIError.message(for: error))
        }
    }

    func saveFile(targetID: String?, projectID: String?, permitted: Bool) async -> Bool {
        guard permitted,
            let targetID,
            let projectID,
            let path = editorPath,
            let revision = editorRevision
        else { return false }
        editorSequence += 1
        let sequence = editorSequence
        editorState = .loading
        do {
            let outcome = try await provider.saveFile(
                targetID: targetID,
                projectID: projectID,
                path: path,
                content: editorText,
                revision: revision
            )
            guard
                editorRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID
                ), editorPath == path
            else { return false }
            switch outcome {
            case .saved(let saved):
                editorRevision = saved.revision
                openedContent = editorText
                conflict = nil
                editorState = .loaded
                await onSaved()
                return true
            case .conflict(let response):
                conflict = ProjectFileConflictState(
                    path: path,
                    baseRevision: response.error.baseRevision,
                    currentRevision: response.error.currentRevision,
                    remoteContent: response.error.currentContent,
                    localContent: editorText,
                    baseContent: openedContent
                )
                editorState = .loaded
                return false
            }
        } catch {
            guard
                editorRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID
                ), editorPath == path
            else { return false }
            editorState = .failed(APIError.message(for: error))
            return false
        }
    }

    func useRemoteConflictVersion() {
        guard let conflict else { return }
        editorText = conflict.remoteContent
        openedContent = conflict.remoteContent
        editorRevision = conflict.currentRevision
        self.conflict = nil
        editorState = .loaded
    }

    /// Return both edits merged, because §42.8 forbids resolving a conflict by discarding a side.
    @discardableResult
    func mergeConflictVersions() -> ProjectThreeWayMerge.Result? {
        guard let conflict else { return nil }
        let merged = conflict.merged
        editorText = merged.text
        openedContent = conflict.remoteContent
        editorRevision = conflict.currentRevision
        self.conflict = nil
        editorState = .loaded
        return merged
    }

    /// Keep only this device's edits, which overwrites what the other device saved.
    func replaceRemoteWithLocalVersion() {
        guard let conflict else { return }
        editorText = conflict.localContent
        openedContent = conflict.remoteContent
        editorRevision = conflict.currentRevision
        self.conflict = nil
        editorState = .loaded
    }

    func dismissConflict() {
        conflict = nil
        editorState = .loaded
    }

    private func editorRequestIsCurrent(
        _ sequence: Int,
        targetID: String,
        projectID: String
    ) -> Bool {
        sequence == editorSequence
            && contextIsCurrent(targetID, projectID)
    }

}

import Foundation
import SparkAPI

/// Pass conflict and terminal actions to the session that owns them, keeping the model readable.
@MainActor
extension ProjectsModel {
    public func useRemoteConflictVersion() { editorSession.useRemoteConflictVersion() }

    @discardableResult public func mergeConflictVersions() -> ProjectThreeWayMerge.Result? {
        editorSession.mergeConflictVersions()
    }

    public func replaceRemoteWithLocalVersion() { editorSession.replaceRemoteWithLocalVersion() }

    public func dismissConflict() { editorSession.dismissConflict() }

    public func startTerminal(shell: ProjectTerminalShell, durable: Bool = false) async {
        await terminalSession.startTerminal(
            shell: shell,
            targetID: selectedTargetID,
            projectID: selectedProject?.id,
            permitted: canUseTerminal,
            durable: durable
        )
    }

    public func sendTerminalInput() async { await terminalSession.sendTerminalInput() }

    public func resizeTerminal(columns: Int, rows: Int) async {
        await terminalSession.resizeTerminal(columns: columns, rows: rows)
    }

    @discardableResult public func pasteTerminalText(_ text: String, submit: Bool = false) async
        -> Bool
    {
        // The remote program determines whether paste should be bracketed.
        let bracketed = terminalSession.screen.view.getTerminal().bracketedPasteMode
        let paste = bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        return await terminalSession.enqueueInput(paste + (submit ? "\r" : "")).value
    }
    public func sendTerminalKeys(_ text: String) { terminalSession.enqueueInput(text) }
    public func detachTerminal() async { await terminalSession.detach() }
    public func reconnectTerminal(_ terminal: GeneratedAPI.ProjectTerminal) async {
        guard canUseTerminal, let targetID = selectedTargetID, let projectID = selectedProject?.id
        else { return }
        await terminalSession.reconnect(terminal, targetID: targetID, projectID: projectID)
    }

    public func endDevelopmentTerminal() async {
        await terminalSession.stopTerminal(preserveOnFailure: true)
    }
    public func stopTerminal() async { await terminalSession.stopTerminal() }

    public var previewPort: String {
        get { previewSession.port }
        set { previewSession.port = newValue }
    }

    public var previewPath: String {
        get { previewSession.path }
        set { previewSession.path = newValue }
    }

    public var previewBody: String { previewSession.body }
    public var previewState: ProjectLoadState { previewSession.state }
    public var previewOrigin: String? { previewSession.loadedFrom }

    public func loadPreview() async {
        await previewSession.load(
            targetID: selectedTargetID,
            projectID: selectedProject?.id,
            permitted: canPreview
        )
    }

    public func clearPreview() { previewSession.clear() }

    static func boundedTerminalTranscript(_ transcript: String) -> String {
        ProjectTerminalSession.boundedTerminalTranscript(transcript)
    }
}

extension ProjectsModel {
    public var canCreateProject: Bool {
        selectedTarget?.status == .available && selectedTarget?.permissions.canCreate == true
    }

    public var canSaveFile: Bool {
        canEditFile
            && editorPath != nil && editorRevision != nil && editorState != .loading
    }

    public var canEditFile: Bool {
        selectedTarget?.status == .available
            && selectedProject?.capabilities.contains(.write) == true
    }

    public var canRunAgent: Bool {
        selectedTarget?.status == .available
            && selectedProject?.capabilities.contains(.agentRun) == true
    }

    public var canUseTerminal: Bool {
        selectedTarget?.status == .available
            && selectedProject?.capabilities.contains(.terminal) == true
    }

    /// 42.7's preview pane opens only where the Spark grants project.preview for this project.
    public var canPreview: Bool {
        selectedTarget?.status == .available
            && selectedProject?.capabilities.contains(.preview) == true
    }

    public var canReviewChanges: Bool {
        selectedTarget?.status == .available
            && selectedProject?.capabilities.contains(.review) == true
    }

    public func canApprove(_ change: GeneratedAPI.ProjectChange) -> Bool {
        selectedTarget?.status == .available
            && change.projectId == selectedProject?.id
            && changes.first(where: { $0.id == change.id })?.reviewDigest == change.reviewDigest
            && selectedProject?.capabilities.contains(.review) == true
            && ProjectReviewGate.canApprove(change)
    }

}

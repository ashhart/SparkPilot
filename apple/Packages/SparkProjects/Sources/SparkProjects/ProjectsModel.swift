import Foundation
import Observation
import SparkAPI

@MainActor
@Observable
public final class ProjectsModel {
    public private(set) var targets: [ProjectTarget] = []
    public var selectedTargetID: String?
    public private(set) var projects: [GeneratedAPI.Project] = []
    public private(set) var projectState: ProjectLoadState = .idle
    public private(set) var warning: String?
    public private(set) var isShowingCachedProjects = false
    public private(set) var files: [GeneratedAPI.ProjectFileEntry] = []
    public private(set) var changes: [GeneratedAPI.ProjectChange] = []
    public private(set) var selectedProject: GeneratedAPI.Project?
    public private(set) var fileState: ProjectLoadState = .idle
    public private(set) var changeState: ProjectLoadState = .idle
    public var editorPath: String? { editorSession.editorPath }
    public var editorText: String {
        get { editorSession.editorText }
        set { editorSession.editorText = newValue }
    }
    public var editorRevision: String? { editorSession.editorRevision }
    public var editorState: ProjectLoadState { editorSession.editorState }
    public var conflict: ProjectFileConflictState? { editorSession.conflict }
    public var terminal: GeneratedAPI.ProjectTerminal? { terminalSession.terminal }
    public var terminalTranscript: String { terminalSession.terminalTranscript }
    public var terminalInput: String {
        get { terminalSession.terminalInput }
        set { terminalSession.terminalInput = newValue }
    }
    public var terminalDisplayMode: ProjectTerminalDisplayMode = .terminal
    public var terminalState: ProjectLoadState { terminalSession.terminalState }
    public private(set) var lastOperationMessage: String?

    public private(set) var deletingProjectID: String?

    private let provider: any ProjectDataProviding
    let terminalSession: ProjectTerminalSession
    let editorSession: ProjectEditorSession
    let previewSession: ProjectPreviewSession
    private var projectsCache: [String: [GeneratedAPI.Project]] = [:]
    private var filesCache: [String: [GeneratedAPI.ProjectFileEntry]] = [:]
    private var changesCache: [String: [GeneratedAPI.ProjectChange]] = [:]
    private var loadSequence = 0
    private var projectRefreshSequence = 0
    private var contentRefreshSequence = 0
    private var actionSequence = 0
    private var decisionSequence = 0

    public init(provider: any ProjectDataProviding) {
        self.provider = provider
        terminalSession = ProjectTerminalSession(provider: provider)
        editorSession = ProjectEditorSession(provider: provider)
        previewSession = ProjectPreviewSession(provider: provider)
        terminalSession.contextIsCurrent = { [weak self] targetID, projectID in
            self?.hasCurrentContext(targetID: targetID, projectID: projectID) == true
        }
        editorSession.contextIsCurrent = { [weak self] targetID, projectID in
            self?.hasCurrentContext(targetID: targetID, projectID: projectID) == true
        }
        previewSession.contextIsCurrent = { [weak self] targetID, projectID in
            self?.hasCurrentContext(targetID: targetID, projectID: projectID) == true
        }
        editorSession.onSaved = { [weak self] in
            self?.lastOperationMessage = String(localized: "File saved.")
            await self?.refreshProjectContents()
        }
    }

    public var selectedTarget: ProjectTarget? {
        targets.first(where: { $0.id == selectedTargetID })
    }

    public func load() async {
        loadSequence += 1
        let sequence = loadSequence
        if targets.isEmpty, projects.isEmpty { projectState = .loading }
        let loadedTargets = await provider.targets()
        guard sequence == loadSequence else { return }

        let loadedTargetIDs = Set(loadedTargets.map(\.id))
        for targetID in Set(targets.map(\.id)).subtracting(loadedTargetIDs) {
            clearCaches(targetID: targetID)
        }
        for target in loadedTargets where target.status == .identityMismatch {
            clearCaches(targetID: target.id)
        }

        let previousTargetID = selectedTargetID
        let previousStatus = selectedTarget?.status
        targets = loadedTargets
        guard !loadedTargets.isEmpty else {
            await stopTerminal()
            selectedTargetID = nil
            clearProjectSelection()
            projects = []
            isShowingCachedProjects = false
            projectState = .empty
            return
        }

        // QA-14: open on a Spark that answers rather than the first one alphabetically.
        let selectedID =
            previousTargetID.flatMap { id in loadedTargets.first { $0.id == id }?.id }
            ?? ProjectTargetSelection.preferred(loadedTargets)
        let selectedStatus = loadedTargets.first(where: { $0.id == selectedID })?.status
        if previousTargetID != selectedID
            || (previousStatus == .available && selectedStatus != .available)
        {
            await stopTerminal()
            guard sequence == loadSequence else { return }
        }
        selectedTargetID = selectedID
        if previousTargetID != selectedID || previousStatus != selectedStatus {
            contentRefreshSequence += 1
            editorSession.invalidateRequests()
            actionSequence += 1
            decisionSequence += 1
        }
        if previousTargetID != selectedID || selectedStatus == .identityMismatch {
            selectedProject = nil
            files = []
            changes = []
            editorSession.clearContents()
        }
        await refreshProjects()
        guard sequence == loadSequence, selectedTargetID == selectedID else { return }
        if selectedTarget?.status == .available, selectedProject != nil {
            await refreshProjectContents()
        }
    }

    public func selectTarget(_ id: String) async {
        guard targets.contains(where: { $0.id == id }) else { return }
        await stopTerminal()
        loadSequence += 1
        contentRefreshSequence += 1
        editorSession.invalidateRequests()
        actionSequence += 1
        decisionSequence += 1
        selectedTargetID = id
        selectedProject = nil
        files = []
        changes = []
        editorSession.clearContents()
        await refreshProjects()
    }

    public func refreshProjects() async {
        projectRefreshSequence += 1
        let sequence = projectRefreshSequence
        guard let target = selectedTarget else {
            projectState = .empty
            return
        }
        guard target.status == .available else {
            if target.status == .identityMismatch {
                clearCaches(targetID: target.id)
                projects = []
                isShowingCachedProjects = false
                projectState = .empty
                warning = String(
                    localized: "This Spark's identity changed. Cached projects are hidden."
                )
                return
            }
            projects = projectsCache[target.id] ?? []
            isShowingCachedProjects = !projects.isEmpty
            projectState = projects.isEmpty ? .empty : .loaded
            warning = ProjectAvailabilityPresentation.message(
                for: target.status,
                hasCache: !projects.isEmpty
            )
            return
        }

        let cached = projectsCache[target.id]
        if let cached {
            projects = cached
            isShowingCachedProjects = true
        } else {
            projectState = .loading
        }
        warning = nil
        do {
            let collection = try await provider.projects(targetID: target.id)
            guard sequence == projectRefreshSequence, selectedTargetID == target.id else { return }
            let loaded = collection.items
            projectsCache[target.id] = loaded
            projects = loaded
            if let selectedProject {
                if let refreshed = loaded.first(where: { $0.id == selectedProject.id }) {
                    self.selectedProject = refreshed
                } else {
                    await stopTerminal()
                    guard sequence == projectRefreshSequence, selectedTargetID == target.id else {
                        return
                    }
                    clearProjectSelection()
                }
            }
            if let index = targets.firstIndex(where: { $0.id == target.id }) {
                let current = targets[index]
                targets[index] = ProjectTarget(
                    id: current.id,
                    name: current.name,
                    status: current.status,
                    permissions: ProjectPermissions(
                        canCreate: collection.canCreate,
                        canWrite: current.permissions.canWrite,
                        canRunAgent: current.permissions.canRunAgent,
                        canReview: current.permissions.canReview,
                        canUseTerminal: current.permissions.canUseTerminal
                    )
                )
            }
            isShowingCachedProjects = false
            projectState = loaded.isEmpty ? .empty : .loaded
        } catch is CancellationError {
        } catch {
            guard sequence == projectRefreshSequence, selectedTargetID == target.id else { return }
            if cached != nil {
                projectState = .loaded
                warning = String(localized: "Could not refresh. Cached projects are shown.")
            } else {
                projectState = .failed(Self.message(for: error))
            }
        }
    }

    public func canDeleteProject(_ project: GeneratedAPI.Project) -> Bool {
        selectedTarget?.status == .available && !isShowingCachedProjects
            && projects.contains(where: { $0.id == project.id && $0.capabilities.contains(.delete) }
            )
            && deletingProjectID == nil
    }

    /// Keep the row and its retry identity until the Spark confirms that removal completed.
    public func deleteProject(_ project: GeneratedAPI.Project, targetID: String) async -> Bool {
        guard selectedTargetID == targetID, canDeleteProject(project) else { return false }
        deletingProjectID = project.id
        defer { deletingProjectID = nil }
        warning = nil
        do {
            try await provider.deleteProject(targetID: targetID, projectID: project.id)
            projectsCache[targetID]?.removeAll { $0.id == project.id }
            changesCache.removeValue(forKey: Self.cacheKey(targetID, project.id))
            filesCache.removeValue(forKey: Self.cacheKey(targetID, project.id))
            guard selectedTargetID == targetID else { return true }
            projectRefreshSequence += 1
            projects.removeAll { $0.id == project.id }
            if selectedProject?.id == project.id {
                await detachTerminal()
                guard selectedTargetID == targetID else { return true }
                clearProjectSelection()
            }
            projectState = projects.isEmpty ? .empty : .loaded
            lastOperationMessage = String(localized: "Project deleted from the Spark.")
            return true
        } catch {
            if selectedTargetID == targetID { warning = Self.message(for: error) }
            return false
        }
    }

    public func createProject(name: String, repositoryURL: String?) async -> Bool {
        guard canCreateProject, let targetID = selectedTargetID else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        actionSequence += 1
        let sequence = actionSequence
        projectState = .loading
        do {
            try await provider.createProject(
                targetID: targetID,
                name: trimmed,
                repositoryURL: repositoryURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard actionRequestIsCurrent(sequence, targetID: targetID, projectID: nil) else {
                return false
            }
            await refreshProjects()
            guard actionRequestIsCurrent(sequence, targetID: targetID, projectID: nil) else {
                return false
            }
            lastOperationMessage = String(localized: "Project creation started.")
            return true
        } catch {
            guard actionRequestIsCurrent(sequence, targetID: targetID, projectID: nil) else {
                return false
            }
            projectState = .failed(Self.message(for: error))
            return false
        }
    }

    public func openProject(_ project: GeneratedAPI.Project) async {
        if selectedProject?.id != project.id { await stopTerminal() }
        contentRefreshSequence += 1
        editorSession.invalidateRequests()
        actionSequence += 1
        decisionSequence += 1
        selectedProject = project
        editorSession.clearContents()
        await refreshProjectContents()
    }

    public func refreshProjectContents() async {
        guard let targetID = selectedTargetID, let project = selectedProject else { return }
        contentRefreshSequence += 1
        let sequence = contentRefreshSequence
        let key = Self.cacheKey(targetID, project.id)
        let cachedFiles = filesCache[key]
        let cachedChanges = changesCache[key]
        files = cachedFiles ?? []
        changes = cachedChanges ?? []
        fileState = cachedFiles == nil ? .loading : (files.isEmpty ? .empty : .loaded)
        changeState = cachedChanges == nil ? .loading : (changes.isEmpty ? .empty : .loaded)
        guard selectedTarget?.status == .available else {
            fileState = cachedFiles == nil ? .empty : (files.isEmpty ? .empty : .loaded)
            changeState = cachedChanges == nil ? .empty : (changes.isEmpty ? .empty : .loaded)
            warning = ProjectAvailabilityPresentation.message(
                for: selectedTarget?.status ?? .unavailable,
                hasCache: cachedFiles != nil || cachedChanges != nil
            )
            return
        }
        warning = nil

        do {
            let loadedFiles = try await provider.files(targetID: targetID, projectID: project.id)
            guard contentRequestIsCurrent(sequence, targetID: targetID, projectID: project.id)
            else { return }
            filesCache[key] = loadedFiles
            files = loadedFiles
            fileState = loadedFiles.isEmpty ? .empty : .loaded
        } catch {
            guard contentRequestIsCurrent(sequence, targetID: targetID, projectID: project.id)
            else { return }
            fileState = cachedFiles == nil ? .failed(Self.message(for: error)) : .loaded
            warning = String(localized: "Some project data could not be refreshed.")
        }

        do {
            let loadedChanges = try await provider.changes(
                targetID: targetID,
                projectID: project.id
            )
            guard contentRequestIsCurrent(sequence, targetID: targetID, projectID: project.id)
            else { return }
            changesCache[key] = loadedChanges
            changes = loadedChanges
            changeState = loadedChanges.isEmpty ? .empty : .loaded
        } catch {
            guard contentRequestIsCurrent(sequence, targetID: targetID, projectID: project.id)
            else { return }
            changeState = cachedChanges == nil ? .failed(Self.message(for: error)) : .loaded
            warning = String(localized: "Some project data could not be refreshed.")
        }
    }

    public func startAgent(task: String) async -> Bool {
        guard canRunAgent,
            let targetID = selectedTargetID,
            let projectID = selectedProject?.id
        else { return false }
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return false }
        actionSequence += 1
        let sequence = actionSequence
        do {
            try await provider.startAgent(targetID: targetID, projectID: projectID, task: task)
            guard actionRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) else {
                return false
            }
            lastOperationMessage = String(localized: "Agent task started.")
            return true
        } catch {
            guard actionRequestIsCurrent(sequence, targetID: targetID, projectID: projectID) else {
                return false
            }
            warning = Self.message(for: error)
            return false
        }
    }

    public func approve(_ change: GeneratedAPI.ProjectChange, comment: String?) async -> Bool {
        guard canApprove(change),
            let targetID = selectedTargetID,
            let projectID = selectedProject?.id,
            let digest = change.reviewDigest
        else { return false }
        decisionSequence += 1
        let sequence = decisionSequence
        do {
            let updated = try await provider.approve(
                targetID: targetID,
                projectID: projectID,
                changeID: change.id,
                reviewDigest: digest,
                comment: comment
            )
            guard
                decisionRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID,
                    changeID: change.id,
                    reviewDigest: digest
                ), updated.id == change.id, updated.projectId == projectID,
                updated.reviewDigest == digest
            else { return false }
            replaceChange(updated, targetID: targetID, projectID: projectID)
            lastOperationMessage = String(localized: "Reviewed change merged.")
            return true
        } catch {
            guard
                decisionRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID,
                    changeID: change.id,
                    reviewDigest: digest
                )
            else { return false }
            warning = Self.message(for: error)
            await refreshProjectContents()
            return false
        }
    }

    public func requestChanges(
        _ change: GeneratedAPI.ProjectChange,
        comment: String
    ) async -> Bool {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canReviewChanges,
            change.projectId == selectedProject?.id,
            changes.first(where: { $0.id == change.id })?.reviewDigest == change.reviewDigest,
            change.status == .review,
            let digest = change.reviewDigest,
            ProjectReviewGate.isDigest(digest),
            !comment.isEmpty,
            let targetID = selectedTargetID,
            let projectID = selectedProject?.id
        else { return false }
        decisionSequence += 1
        let sequence = decisionSequence
        do {
            let updated = try await provider.requestChanges(
                targetID: targetID,
                projectID: projectID,
                changeID: change.id,
                reviewDigest: digest,
                comment: comment
            )
            guard
                decisionRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID,
                    changeID: change.id,
                    reviewDigest: digest
                ), updated.id == change.id, updated.projectId == projectID,
                updated.reviewDigest == digest
            else { return false }
            replaceChange(updated, targetID: targetID, projectID: projectID)
            lastOperationMessage = String(localized: "Changes requested.")
            return true
        } catch {
            guard
                decisionRequestIsCurrent(
                    sequence,
                    targetID: targetID,
                    projectID: projectID,
                    changeID: change.id,
                    reviewDigest: digest
                )
            else { return false }
            warning = Self.message(for: error)
            await refreshProjectContents()
            return false
        }
    }

    private func replaceChange(
        _ change: GeneratedAPI.ProjectChange,
        targetID: String,
        projectID: String
    ) {
        guard let index = changes.firstIndex(where: { $0.id == change.id }) else {
            changes.append(change)
            changesCache[Self.cacheKey(targetID, projectID)] = changes
            return
        }
        changes[index] = change
        changesCache[Self.cacheKey(targetID, projectID)] = changes
    }

    private func contentRequestIsCurrent(
        _ sequence: Int,
        targetID: String,
        projectID: String
    ) -> Bool {
        sequence == contentRefreshSequence
            && selectedTarget?.status == .available
            && selectedTargetID == targetID
            && selectedProject?.id == projectID
    }

    private func decisionRequestIsCurrent(
        _ sequence: Int,
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String
    ) -> Bool {
        sequence == decisionSequence
            && selectedTarget?.status == .available
            && selectedTargetID == targetID
            && selectedProject?.id == projectID
            && changes.first(where: { $0.id == changeID })?.reviewDigest == reviewDigest
    }

    private func actionRequestIsCurrent(
        _ sequence: Int,
        targetID: String,
        projectID: String?
    ) -> Bool {
        sequence == actionSequence
            && selectedTarget?.status == .available
            && selectedTargetID == targetID
            && (projectID == nil || selectedProject?.id == projectID)
    }

    private func clearCaches(targetID: String) {
        projectsCache.removeValue(forKey: targetID)
        let prefix = "\(targetID)::"
        filesCache = filesCache.filter { !$0.key.hasPrefix(prefix) }
        changesCache = changesCache.filter { !$0.key.hasPrefix(prefix) }
    }

    private func clearProjectSelection() {
        contentRefreshSequence += 1
        editorSession.invalidateRequests()
        actionSequence += 1
        decisionSequence += 1
        selectedProject = nil
        files = []
        changes = []
        editorSession.clearContents()
    }

    private static func cacheKey(_ targetID: String, _ projectID: String) -> String {
        "\(targetID)::\(projectID)"
    }

    private static func message(for error: any Error) -> String {
        APIError.message(for: error)
    }

    private func hasCurrentContext(targetID: String, projectID: String) -> Bool {
        selectedTarget?.status == .available && selectedTargetID == targetID
            && selectedProject?.id == projectID
    }

    public func openFile(_ file: GeneratedAPI.ProjectFileEntry) async {
        await editorSession.openFile(
            file,
            targetID: selectedTargetID,
            projectID: selectedProject?.id,
            available: selectedTarget?.status == .available
        )
    }

    public func saveFile() async -> Bool {
        await editorSession.saveFile(
            targetID: selectedTargetID,
            projectID: selectedProject?.id,
            permitted: canSaveFile
        )
    }

}

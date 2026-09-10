import Foundation
import SparkAPI
import Testing
@testable import SparkProjects

enum ProjectModelTestProjectTestError: Error {
    case unavailable
}

actor ProjectModelTestTestTerminal: ProjectTerminalConnecting {
    private var first = true
    private(set) var sent: [String] = []
    private(set) var cancelled = false
    /// Let a test drive the exact bytes a project container could return.
    var payload = "ready\n"

    var failsStart = false
    func setFailsStart(_ value: Bool) { failsStart = value }
    func start() async throws {
        if failsStart { throw ProjectModelTestProjectTestError.unavailable }
    }

    func emit(_ text: String) { payload = text }

    private(set) var resizes: [ProjectTerminalGrid.Size] = []

    var resizeContinuation: CheckedContinuation<Void, Never>?
    var delayNextResize = false
    var failNextResize = false
    func delayResize() { delayNextResize = true }
    func failResize() { failNextResize = true }
    func releaseResize() {
        resizeContinuation?.resume()
        resizeContinuation = nil
    }
    var resizing: Bool { resizeContinuation != nil }

    func resize(columns: Int, rows: Int) async throws {
        if delayNextResize {
            delayNextResize = false
            await withCheckedContinuation { resizeContinuation = $0 }
        }
        if failNextResize {
            failNextResize = false
            throw ProjectModelTestProjectTestError.unavailable
        }
        resizes.append(ProjectTerminalGrid.Size(columns: columns, rows: rows))
    }

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> String {
        if first {
            first = false
            return payload
        }
        try await Task.sleep(for: .seconds(30))
        return ""
    }

    func cancel() async { cancelled = true }
}

@MainActor
final class ProjectModelTestTestProvider: ProjectDataProviding {
    var targetValues = [
        ProjectTarget(
            id: "node:1",
            name: "Desk Spark",
            isOnline: true,
            projectsAvailable: true
        )
    ]
    var delaysTargets = false
    var targetContinuation: CheckedContinuation<Void, Never>?
    var collection = ProjectCollection(items: [ProjectModelTestFixtures.project], canCreate: true)
    var collectionsByTarget: [String: ProjectCollection] = [:]
    var delayedProjectTargets: Set<String> = []
    var projectContinuations: [String: CheckedContinuation<ProjectCollection, any Error>] = [:]
    var projectFailure: (any Error)?
    var fileValues = [ProjectModelTestFixtures.fileEntry]
    var fileListRequests = 0
    var changeListRequests = 0
    var previewRequests: [String] = []
    var previewBody = "<html><body>Hello from the project</body></html>"
    var previewFailure: (any Error)?
    var fileContents = ProjectModelTestFixtures.fileContents
    var saveOutcome: ProjectFileSaveOutcome = .saved(
        GeneratedAPI.ProjectFileSave(
            path: "Sources/App.swift",
            revision: ProjectModelTestFixtures.newRevision
        )
    )
    var saveRequests = 0
    var changeValues = [ProjectModelTestFixtures.reviewChange]
    var changesByProject: [String: [GeneratedAPI.ProjectChange]] = [:]
    var approvedDigests: [String] = []
    var requestedComments: [String] = []
    var terminal = ProjectModelTestTestTerminal()
    var delaysApproval = false
    var approvalContinuation: CheckedContinuation<Void, Never>?
    var delaysRequestChanges = false
    var requestChangesContinuation: CheckedContinuation<Void, Never>?
    var deleteFailure: (any Error)?
    var deletedProjects: [String] = []
    var closeFailure: (any Error)?
    var delaysTerminalCreation = false
    var terminalCreationContinuation: CheckedContinuation<Void, Never>?
    var closedTerminals: [String] = []
    var reconnectedTerminals: [String] = []

    func targets() async -> [ProjectTarget] {
        if delaysTargets {
            await withCheckedContinuation { targetContinuation = $0 }
        }
        return targetValues
    }

    func resumeTargets() {
        delaysTargets = false
        targetContinuation?.resume()
        targetContinuation = nil
    }

    func projects(targetID: String) async throws -> ProjectCollection {
        if let projectFailure { throw projectFailure }
        let result = collectionsByTarget[targetID] ?? collection
        guard delayedProjectTargets.contains(targetID) else { return result }
        return try await withCheckedThrowingContinuation { continuation in
            projectContinuations[targetID] = continuation
        }
    }

    func resumeProjects(targetID: String) {
        let result = collectionsByTarget[targetID] ?? collection
        projectContinuations.removeValue(forKey: targetID)?.resume(returning: result)
    }

    func deleteProject(targetID: String, projectID: String) async throws {
        if let deleteFailure { throw deleteFailure }
        deletedProjects.append(targetID + "::" + projectID)
        collection = .init(
            items: collection.items.filter { $0.id != projectID },
            canCreate: collection.canCreate
        )
    }

    func createProject(targetID: String, name: String, repositoryURL: String?) async throws {}

    func files(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectFileEntry]
    {
        fileListRequests += 1
        return fileValues
    }

    func file(targetID: String, projectID: String, path: String) async throws
        -> GeneratedAPI.ProjectFileContents
    {
        fileContents
    }

    func saveFile(
        targetID: String,
        projectID: String,
        path: String,
        content: String,
        revision: String
    ) async throws -> ProjectFileSaveOutcome {
        saveRequests += 1
        return saveOutcome
    }

    func changes(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectChange]
    {
        changeListRequests += 1
        return changesByProject[projectID] ?? changeValues
    }

    func preview(targetID: String, projectID: String, port: Int, path: String) async throws
        -> String
    {
        previewRequests.append("\(port)/\(path)")
        if let previewFailure { throw previewFailure }
        return previewBody
    }

    func startAgent(targetID: String, projectID: String, task: String) async throws {}

    func approve(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String?
    ) async throws -> GeneratedAPI.ProjectChange {
        approvedDigests.append(reviewDigest)
        if delaysApproval {
            await withCheckedContinuation { approvalContinuation = $0 }
        }
        var change = ProjectModelTestFixtures.reviewChange
        change.status = .merged
        return change
    }

    func requestChanges(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String
    ) async throws -> GeneratedAPI.ProjectChange {
        requestedComments.append(comment)
        if delaysRequestChanges {
            await withCheckedContinuation { requestChangesContinuation = $0 }
        }
        var change = ProjectModelTestFixtures.reviewChange
        change.status = .rejected
        return change
    }

    func createTerminal(
        targetID: String,
        projectID: String,
        shell: ProjectTerminalShell
    ) async throws -> (GeneratedAPI.ProjectTerminal, any ProjectTerminalConnecting) {
        if delaysTerminalCreation {
            await withCheckedContinuation { terminalCreationContinuation = $0 }
        }
        return (
            GeneratedAPI.ProjectTerminal(
                terminalId: "20000000-0000-4000-8000-000000000002",
                projectId: projectID,
                state: .running,
                createdAt: "2026-09-01T12:00:00Z"
            ),
            terminal
        )
    }

    func reconnectTerminal(targetID: String, projectID: String, terminalID: String) async throws
        -> any ProjectTerminalConnecting
    {
        reconnectedTerminals.append("\(targetID)::\(projectID)::\(terminalID)")
        terminal = ProjectModelTestTestTerminal()
        return terminal
    }

    func closeTerminal(targetID: String, projectID: String, terminalID: String) async throws {
        if let closeFailure { throw closeFailure }
        closedTerminals.append("\(targetID)::\(projectID)::\(terminalID)")
    }

    func resumeApproval() {
        delaysApproval = false
        approvalContinuation?.resume()
        approvalContinuation = nil
    }

    func resumeRequestChanges() {
        delaysRequestChanges = false
        requestChangesContinuation?.resume()
        requestChangesContinuation = nil
    }

    func resumeTerminalCreation() {
        delaysTerminalCreation = false
        terminalCreationContinuation?.resume()
        terminalCreationContinuation = nil
    }
}

import Foundation
import SparkAPI

public struct ProjectPermissions: Sendable, Equatable {
    public let canCreate: Bool
    public let canWrite: Bool
    public let canRunAgent: Bool
    public let canReview: Bool
    public let canUseTerminal: Bool

    public init(
        canCreate: Bool = false,
        canWrite: Bool = false,
        canRunAgent: Bool = false,
        canReview: Bool = false,
        canUseTerminal: Bool = false
    ) {
        self.canCreate = canCreate
        self.canWrite = canWrite
        self.canRunAgent = canRunAgent
        self.canReview = canReview
        self.canUseTerminal = canUseTerminal
    }

    public static let readOnly = ProjectPermissions()
}

public enum ProjectTargetStatus: Sendable, Equatable {
    case available
    case connecting
    case offline
    case identityMismatch
    case runtimeUpdateRequired
    case runtimeUnsupported
    case unavailable
}

public struct ProjectTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let status: ProjectTargetStatus
    public let permissions: ProjectPermissions

    public var isOnline: Bool {
        switch status {
        case .available, .runtimeUpdateRequired, .runtimeUnsupported: true
        case .connecting, .offline, .identityMismatch, .unavailable:
            false
        }
    }

    public var projectsAvailable: Bool { status == .available }

    public init(
        id: String,
        name: String,
        status: ProjectTargetStatus,
        permissions: ProjectPermissions = .readOnly
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.permissions = permissions
    }

    public init(
        id: String,
        name: String,
        isOnline: Bool,
        projectsAvailable: Bool,
        permissions: ProjectPermissions = .readOnly
    ) {
        self.init(
            id: id,
            name: name,
            status: projectsAvailable ? .available : (isOnline ? .runtimeUnsupported : .offline),
            permissions: permissions
        )
    }
}

public protocol ProjectTerminalConnecting: Sendable {
    func start() async throws
    func send(_ text: String) async throws
    /// Typed resize, so the PTY follows the view rather than staying at its opening size (§42.9).
    func resize(columns: Int, rows: Int) async throws
    func receive() async throws -> String
    func cancel() async
}

extension ProjectTerminalConnecting {
    public func resize(columns: Int, rows: Int) async throws {}
}

@MainActor
public protocol ProjectDataProviding: AnyObject {
    func targets() async -> [ProjectTarget]
    func projects(targetID: String) async throws -> ProjectCollection
    func deleteProject(targetID: String, projectID: String) async throws
    func createProject(targetID: String, name: String, repositoryURL: String?) async throws
    func files(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectFileEntry]
    func file(targetID: String, projectID: String, path: String) async throws
        -> GeneratedAPI.ProjectFileContents
    func saveFile(
        targetID: String,
        projectID: String,
        path: String,
        content: String,
        revision: String
    ) async throws -> ProjectFileSaveOutcome
    func changes(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectChange]
    /// PLAN 42.10: the project's own dev server, read through the authenticated proxy.
    func preview(targetID: String, projectID: String, port: Int, path: String) async throws
        -> String
    func startAgent(targetID: String, projectID: String, task: String) async throws
    func approve(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String?
    ) async throws -> GeneratedAPI.ProjectChange
    func requestChanges(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String
    ) async throws -> GeneratedAPI.ProjectChange
    func createTerminal(
        targetID: String,
        projectID: String,
        shell: ProjectTerminalShell
    ) async throws -> (GeneratedAPI.ProjectTerminal, any ProjectTerminalConnecting)
    func reconnectTerminal(targetID: String, projectID: String, terminalID: String) async throws
        -> any ProjectTerminalConnecting
    func closeTerminal(targetID: String, projectID: String, terminalID: String) async throws
}

public enum ProjectLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

public struct ProjectFileConflictState: Sendable, Equatable {
    public let path: String
    public let baseRevision: String
    public let currentRevision: String
    public let remoteContent: String
    public let localContent: String
    /// The content this editor opened at `baseRevision`, so both edits can be merged (§42.8).
    public let baseContent: String

    /// Merge both edits against the revision they share.
    public var merged: ProjectThreeWayMerge.Result {
        ProjectThreeWayMerge.merge(base: baseContent, mine: localContent, theirs: remoteContent)
    }
}

public enum ProjectTerminalDisplayMode: String, CaseIterable, Sendable {
    case terminal
    case accessibleText

    public var title: String {
        switch self {
        case .terminal: String(localized: "Terminal")
        case .accessibleText: String(localized: "Screen reader text")
        }
    }
}

public enum ProjectReviewGate {
    public static func canApprove(_ change: GeneratedAPI.ProjectChange) -> Bool {
        guard change.status == .review,
            change.evidenceComplete,
            let head = change.headCommit,
            let protectedHead = change.protectedHeadCommit,
            let digest = change.reviewDigest,
            isObjectID(change.baseCommit),
            isObjectID(head),
            isObjectID(protectedHead),
            change.baseCommit == protectedHead,
            change.baseCommit != head,
            isDigest(digest),
            !change.changedFiles.isEmpty,
            !change.testEvidence.isEmpty,
            !change.toolEvidence.isEmpty
        else { return false }
        guard
            change.testEvidence.allSatisfy({
                $0.status == .passed && $0.exitCode == 0 && isDigest($0.outputDigest)
            })
        else { return false }
        return change.toolEvidence.enumerated().allSatisfy { index, item in
            item.outcome == .ok && item.sequence == index + 1
        }
    }

    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (40...64).contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension ProjectDataProviding {
    public func deleteProject(targetID: String, projectID: String) async throws {
        throw APIError(
            .local(message: String(localized: "Update Spark Runtime to delete projects."))
        )
    }

    public func reconnectTerminal(targetID: String, projectID: String, terminalID: String)
        async throws -> any ProjectTerminalConnecting
    {
        throw APIError(
            .local(message: String(localized: "This Spark cannot reconnect this terminal."))
        )
    }
}

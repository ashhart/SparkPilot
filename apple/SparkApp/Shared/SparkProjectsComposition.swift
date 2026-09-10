import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkProjects
import SparkSecurity
import SparkTransport
import SwiftUI

struct ProjectsWorkspaceView: View {
    private enum Surface: CaseIterable, Identifiable {
        case work
        case builds

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .work:
                let title: LocalizedStringResource = "Projects"
                return title
            case .builds:
                let title: LocalizedStringResource = "Builds"
                return title
            }
        }
    }

    let projects: ProjectsModel
    let builds: BuildProjectModel
    @State private var surface = Surface.work
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Picker("Projects", selection: $surface) {
                ForEach(Surface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            switch surface {
            case .work:
                ProjectsView(model: projects)
            case .builds:
                BuildProjectView(model: builds)
            }
        }
        .toolbar { projectWindowButton }
    }

    #if os(macOS)
        /// 41.3: a project can leave the sidebar and get a window of its own.
        @ToolbarContentBuilder private var projectWindowButton: some ToolbarContent {
            ToolbarItem(placement: .automatic) {
                if let project = projects.selectedProject, let target = projects.selectedTarget {
                    Button(
                        String(localized: "Open in New Window"),
                        systemImage: "macwindow.on.rectangle"
                    ) {
                        openWindow(
                            id: MacSparkWindowID.project,
                            value: MacProjectWindowRequest(
                                targetID: target.id,
                                projectID: project.id,
                                projectName: project.name,
                                sparkName: target.name
                            )
                        )
                    }
                    .help(String(localized: "Open this project in its own window"))
                }
            }
        }
    #else
        @ToolbarContentBuilder private var projectWindowButton: some ToolbarContent {
            ToolbarItem(placement: .automatic) { EmptyView() }
        }
    #endif
}
@MainActor
final class SignedProjectDataProvider: SparkDevelopmentProviding {
    private let library: SparkLibrary
    var developmentSelection: ProjectDevelopmentSelection?
    var developmentIdempotencyKey = UUID()
    private var deletionKeys: [String: UUID] = [:]
    private var reviewableProjects: [String: Set<String>] = [:]

    init(library: SparkLibrary) {
        self.library = library
    }

    /// Every Spark is asked at the same time, so one slow or absent Spark cannot hold up the others.
    func targets() async -> [ProjectTarget] {
        let entries = library.entries.sorted(by: { $0.displayName < $1.displayName })
        let statuses = await withTaskGroup(
            of: (Int, ProjectTargetStatus).self,
            returning: [Int: ProjectTargetStatus].self
        ) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, await self.projectStatus(for: entry)) }
            }
            var statuses: [Int: ProjectTargetStatus] = [:]
            for await (index, status) in group { statuses[index] = status }
            return statuses
        }
        return entries.enumerated().map { index, entry in
            ProjectTarget(
                id: entry.id,
                name: entry.displayName,
                status: statuses[index] ?? .unavailable
            )
        }
    }

    func projects(targetID: String) async throws -> ProjectCollection {
        let connection = try connection(targetID: targetID)
        let collection = try await connection.api.projects(route: connection.route)
        reviewableProjects[targetID] = Set(
            collection.items.filter { $0.capabilities.contains(.review) }.map(\.id)
        )
        return collection
    }

    func createProject(targetID: String, name: String, repositoryURL: String?) async throws {
        let connection = try connection(targetID: targetID)
        _ = try await connection.api.createProject(
            route: connection.route,
            request: GeneratedAPI.CreateProject(
                name: name,
                repositoryUrl: repositoryURL,
                revision: nil,
                templateId: nil
            )
        )
    }

    func deleteProject(targetID: String, projectID: String) async throws {
        let connection = try connection(targetID: targetID)
        let key = targetID + "::" + projectID
        let idempotency = deletionKeys[key] ?? UUID()
        deletionKeys[key] = idempotency
        var operation = try await connection.api.deleteProject(
            route: connection.route,
            projectID: projectID,
            idempotencyKey: idempotency
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while operation.state != .succeeded {
            if operation.state == .failed || operation.state == .cancelled {
                deletionKeys.removeValue(forKey: key)
                if operation.errorCode == "PROJECT_BUSY" {
                    throw APIError(
                        .local(
                            message: String(
                                localized:
                                    "This project is still preparing a workspace or running a build or task; let it finish and try deleting again."
                            )
                        )
                    )
                }
                throw APIError(
                    .local(
                        message: String(
                            localized:
                                "The Spark could not finish deleting this project; check its connection and available storage, then try again."
                        )
                    )
                )
            }
            guard ContinuousClock.now < deadline else {
                throw APIError(
                    .local(
                        message: String(
                            localized:
                                "Deletion is still running on the Spark; refresh Projects to check its progress."
                        )
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(500))
            operation = try await connection.api.operation(
                route: connection.route,
                id: operation.id
            )
        }
        deletionKeys.removeValue(forKey: key)
        SparkDevelopmentWorkspace.shared(library: library).removeProject(
            targetID: targetID,
            projectID: projectID
        )
    }

    func files(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectFileEntry]
    {
        let connection = try connection(targetID: targetID)
        return try await connection.api.projectFiles(
            route: connection.route,
            projectID: projectID,
            development: developmentSelection != nil
        )
    }

    func file(targetID: String, projectID: String, path: String) async throws
        -> GeneratedAPI.ProjectFileContents
    {
        let connection = try connection(targetID: targetID)
        return try await connection.api.projectFile(
            route: connection.route,
            projectID: projectID,
            path: path,
            development: developmentSelection != nil
        )
    }

    func saveFile(
        targetID: String,
        projectID: String,
        path: String,
        content: String,
        revision: String
    ) async throws -> ProjectFileSaveOutcome {
        let connection = try connection(targetID: targetID)
        return try await connection.api.saveProjectFile(
            route: connection.route,
            projectID: projectID,
            path: path,
            content: content,
            revision: revision,
            development: developmentSelection != nil
        )
    }

    func preview(targetID: String, projectID: String, port: Int, path: String) async throws
        -> String
    {
        let connection = try connection(targetID: targetID)
        return try await connection.api.projectPreview(
            route: connection.route,
            projectID: projectID,
            port: port,
            path: path
        )
    }

    func changes(targetID: String, projectID: String) async throws
        -> [GeneratedAPI.ProjectChange]
    {
        let connection = try connection(targetID: targetID)
        let changes = try await connection.api.projectChanges(
            route: connection.route,
            projectID: projectID
        )
        if reviewableProjects[targetID]?.contains(projectID) == true {
            NotificationCenter.default.post(
                name: .sparkAgentApprovalObservation,
                object: SparkAgentApprovalObservation(
                    targetID: targetID,
                    projectID: projectID,
                    candidates: changes.filter { $0.projectId == projectID }.map {
                        SparkAgentApprovalCandidate(
                            changeID: $0.id,
                            reviewDigest: $0.reviewDigest,
                            needsReview: $0.status == .review && $0.evidenceComplete
                        )
                    },
                    observedAt: Date()
                )
            )
        }
        return changes
    }

    func managedServiceObservation(targetID: String) async throws -> SparkManagedServiceObservation
    {
        let connection = try connection(targetID: targetID)
        let service = try await connection.api.openWebUIStatus(route: connection.route)
        let state: SparkManagedServiceHealth
        if service.ownershipVerified != true {
            state = .unknown
        } else if !service.installed || !service.running {
            state = .stopped
        } else if service.healthy {
            state = .healthy
        } else if service.repairAvailable == true {
            state = .unhealthy
        } else {
            state = .starting
        }
        return SparkManagedServiceObservation(
            targetID: targetID,
            serviceID: "open-webui",
            state: state,
            observedAt: Date()
        )
    }

    func startAgent(targetID: String, projectID: String, task: String) async throws {
        let connection = try connection(targetID: targetID)
        _ = try await connection.api.startProjectAgent(
            route: connection.route,
            projectID: projectID,
            request: GeneratedAPI.StartProjectAgentRequest(task: task)
        )
    }

    func approve(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String?
    ) async throws -> GeneratedAPI.ProjectChange {
        let connection = try connection(targetID: targetID)
        return try await connection.api.approveProjectChange(
            route: connection.route,
            projectID: projectID,
            changeID: changeID,
            reviewDigest: reviewDigest,
            comment: comment
        ).change
    }

    func requestChanges(
        targetID: String,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String
    ) async throws -> GeneratedAPI.ProjectChange {
        let connection = try connection(targetID: targetID)
        return try await connection.api.requestProjectChangeUpdates(
            route: connection.route,
            projectID: projectID,
            changeID: changeID,
            reviewDigest: reviewDigest,
            comment: comment
        ).change
    }

    func createTerminal(
        targetID: String,
        projectID: String,
        shell: ProjectTerminalShell
    ) async throws -> (GeneratedAPI.ProjectTerminal, any ProjectTerminalConnecting) {
        let connection = try connection(targetID: targetID)
        let terminal: GeneratedAPI.ProjectTerminal
        if var developmentSelection {
            developmentSelection.thinkingTokenBudget = SparkModelDefaults.thinkingBudget(
                targetID: targetID,
                modelID: developmentSelection.modelID
            )
            terminal = try await connection.api.createDevelopmentTerminal(
                route: connection.route,
                projectID: projectID,
                selection: developmentSelection,
                idempotencyKey: developmentIdempotencyKey
            )
        } else {
            terminal = try await connection.api.createProjectTerminal(
                route: connection.route,
                projectID: projectID,
                shell: shell
            )
        }
        do {
            let socket = try await connection.api.projectTerminalSocket(
                route: connection.route,
                projectID: projectID,
                terminalID: terminal.terminalId
            )
            let readiness: (@MainActor @Sendable () async throws -> Void)?
            if developmentSelection != nil {
                readiness = {
                    for _ in 0..<600 {
                        let state = try await connection.api.projectTerminalState(
                            route: connection.route,
                            projectID: projectID,
                            terminalID: terminal.terminalId
                        )
                        if state == "running" { return }
                        guard state == "starting" else {
                            throw APIError(
                                .local(
                                    message:
                                        String(
                                            localized:
                                                "The Spark could not start this session; reopen the workspace to try again."
                                        )
                                )
                            )
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    throw APIError(
                        .local(
                            message:
                                String(
                                    localized:
                                        "The Spark is still preparing this session; reconnect in a moment."
                                )
                        )
                    )
                }
            } else {
                readiness = nil
            }
            return (terminal, SignedProjectTerminalConnection(socket: socket, readiness: readiness))
        } catch {
            if developmentSelection == nil {
                try? await connection.api.closeProjectTerminal(
                    route: connection.route,
                    projectID: projectID,
                    terminalID: terminal.terminalId
                )
            }
            throw error
        }
    }

    func developmentTerminalState(targetID: String, projectID: String, terminalID: String)
        async throws -> String?
    {
        let connection = try connection(targetID: targetID)
        return try await connection.api.projectTerminalState(
            route: connection.route,
            projectID: projectID,
            terminalID: terminalID
        )
    }

    func reconnectTerminal(targetID: String, projectID: String, terminalID: String) async throws
        -> any ProjectTerminalConnecting
    {
        let connection = try connection(targetID: targetID)
        return SignedProjectTerminalConnection(
            socket: try await connection.api.projectTerminalSocket(
                route: connection.route,
                projectID: projectID,
                terminalID: terminalID
            )
        )
    }

    func closeTerminal(targetID: String, projectID: String, terminalID: String) async throws {
        let connection = try connection(targetID: targetID)
        try await connection.api.closeProjectTerminal(
            route: connection.route,
            projectID: projectID,
            terminalID: terminalID
        )
    }

    private func projectStatus(for entry: LibraryEntry) async -> ProjectTargetStatus {
        if entry.issue == .identityMismatch || entry.connectionState == .identityMismatch {
            return .identityMismatch
        }
        if entry.externalClusterRegistration != nil { return .unavailable }
        switch entry.connectionState {
        case .connectedWiFi, .connectedDirect, .connectedRemote:
            guard let connection = try? connection(targetID: entry.id) else {
                return .unavailable
            }
            return await runtimeProjectStatus(connection)
        case .connecting, .discovering:
            return .connecting
        case .updateRequired:
            return .runtimeUpdateRequired
        case .offlineCached:
            return .offline
        case .foundUnpaired:
            return .unavailable
        case .identityMismatch:
            return .identityMismatch
        }
    }

    private func runtimeProjectStatus(_ connection: SparkSignedProjectConnection) async
        -> ProjectTargetStatus
    {
        do {
            async let capabilities = connection.api.capabilities(route: connection.route)
            async let identity = connection.api.identity(route: connection.route)
            let result = try await (capabilities, identity)
            guard result.1.nodeID == connection.expectedNodeID,
                result.1.authorityFingerprint.lowercased()
                    == connection.expectedAuthorityFingerprint.lowercased()
            else { return .identityMismatch }
            return result.0.isEnabled(
                developmentSelection == nil ? "projects" : "development_workspaces"
            ) ? .available : .runtimeUnsupported
        } catch PinnedTransportError.certificateRejected {
            return .identityMismatch
        } catch {
            return .offline
        }
    }

    private func connection(targetID: String) throws -> SparkSignedProjectConnection {
        try SparkSignedProjectConnection.make(library: library, targetID: targetID)
    }
}

private struct SignedProjectTerminalConnection: ProjectTerminalConnecting {
    let socket: ProjectTerminalSocket
    var readiness: (@MainActor @Sendable () async throws -> Void)? = nil

    func start() async throws {
        try await readiness?()
        await socket.start()
        try await socket.waitUntilConnected()
    }
    func send(_ text: String) async throws { try await socket.send(text) }
    func resize(columns: Int, rows: Int) async throws {
        try await socket.resize(columns: columns, rows: rows)
    }
    func receive() async throws -> String { try await socket.receive() }
    func cancel() async { await socket.cancel() }
}

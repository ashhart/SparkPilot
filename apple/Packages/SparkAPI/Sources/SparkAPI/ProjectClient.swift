import Foundation
@_spi(SparkInternal) import SparkTransport

public enum ProjectFileSaveOutcome: Sendable, Equatable {
    case saved(GeneratedAPI.ProjectFileSave)
    case conflict(GeneratedAPI.ProjectFileConflict)
}

public struct ProjectCollection: Sendable, Equatable {
    public let items: [GeneratedAPI.Project]
    public let canCreate: Bool

    public init(items: [GeneratedAPI.Project], canCreate: Bool) {
        self.items = items
        self.canCreate = canCreate
    }
}

public enum ProjectTerminalShell: String, CaseIterable, Sendable {
    case login
    case bash
    case python
}

extension SparkAPIClient {
    public func projects(route base: URL) async throws -> ProjectCollection {
        let response: GeneratedAPI.ListProjectsResponse200 = try await get(
            endpoint(base, "api", "v1", "projects")
        )
        return ProjectCollection(
            items: response.items,
            canCreate: response.capabilities.contains(.create)
        )
    }

    /// Only an authenticated TERMINAL_NOT_FOUND response proves that a saved process is gone.
    public func projectTerminalState(route base: URL, projectID: String, terminalID: String)
        async throws -> String?
    {
        struct StateResponse: Decodable { let state: String }
        do {
            let response: StateResponse = try await get(
                endpoint(base, "api", "v1", "projects", projectID, "terminals", terminalID),
                timeoutInterval: Self.projectMutationTimeout
            )
            guard ["starting", "running", "stopped", "failed"].contains(response.state) else {
                throw APIError(.malformedResponse)
            }
            return response.state
        } catch let error as APIError
            where error.statusCode == 404 && error.code == "TERMINAL_NOT_FOUND"
        {
            return nil
        }
    }

    /// A Spark busy with a model download answers slowly; the transport's presence timeout is for cards, not for this.
    public static let projectMutationTimeout: TimeInterval = 60
    /// Terminal creation may start the project container on first use.
    public static let terminalCreationTimeout: TimeInterval = 120

    public func createProject(
        route base: URL,
        request: GeneratedAPI.CreateProject,
        idempotencyKey: UUID = UUID()
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "projects"),
            body: request,
            idempotencyKey: idempotencyKey,
            timeoutInterval: Self.projectMutationTimeout
        )
    }

    /// Ask the Spark to pull its development image and cache the coding agent; it starts one host-wide job or reports the running one.
    public func prepareDevelopment(route base: URL) async throws
        -> GeneratedAPI.DevelopmentPreparation
    {
        try await post(
            endpoint(base, "api", "v1", "development", "preparation"),
            body: Optional<EmptyRequestBody>.none,
            idempotencyKey: UUID(),
            timeoutInterval: Self.projectMutationTimeout
        )
    }

    public func developmentPreparation(route base: URL) async throws
        -> GeneratedAPI.DevelopmentPreparation
    {
        try await get(
            endpoint(base, "api", "v1", "development", "preparation"),
            timeoutInterval: Self.projectMutationTimeout
        )
    }

    /// Delete the remote project through a durable operation; acceptance alone is not completion.
    public func deleteProject(route base: URL, projectID: String, idempotencyKey: UUID = UUID())
        async throws -> Operation
    {
        var probe = URLRequest(url: endpoint(base, "api", "v1", "projects"))
        probe.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(probe, body: nil, retry: retryPolicy)
        try validate(http: response, data: data)
        guard response.value(forHTTPHeaderField: "X-Spark-Project-Deletion") == "complete-v1" else {
            throw APIError(
                .local(
                    message: String(
                        localized:
                            "Update Spark Runtime before deleting projects so their workspaces and sessions are removed too."
                    )
                )
            )
        }
        return try await delete(
            endpoint(base, "api", "v1", "projects", projectID),
            body: [String: String](),
            idempotencyKey: idempotencyKey,
            userPresence: nil
        )
    }

    public func project(
        route base: URL,
        projectID: String
    ) async throws -> GeneratedAPI.Project {
        try await get(endpoint(base, "api", "v1", "projects", projectID))
    }

    public func projectFiles(
        route base: URL,
        projectID: String,
        development: Bool = false
    ) async throws -> [GeneratedAPI.ProjectFileEntry] {
        let response: GeneratedAPI.ListProjectFilesResponse200 = try await get(
            workspaceURL(
                endpoint(base, "api", "v1", "projects", projectID, "files"),
                development: development
            )
        )
        return response.items
    }

    public func projectFile(
        route base: URL,
        projectID: String,
        path: String,
        development: Bool = false
    ) async throws -> GeneratedAPI.ProjectFileContents {
        try await get(
            workspaceURL(
                endpoint(base, "api", "v1", "projects", projectID, "files", path),
                development: development
            )
        )
    }

    public func saveProjectFile(
        route base: URL,
        projectID: String,
        path: String,
        content: String,
        revision: String,
        development: Bool = false,
        idempotencyKey: UUID = UUID()
    ) async throws -> ProjectFileSaveOutcome {
        var request = URLRequest(
            url: workspaceURL(
                endpoint(base, "api", "v1", "projects", projectID, "files", path),
                development: development
            )
        )
        request.httpMethod = "PUT"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(revision, forHTTPHeaderField: "If-Match")
        let body = Data(content.utf8)
        request.httpBody = body
        try applySigning(to: &request, body: body)

        let (data, http) = try await transport.perform(request)
        switch http.statusCode {
        case 200:
            return .saved(try decode(GeneratedAPI.ProjectFileSave.self, data: data, http: http))
        case 409:
            return .conflict(
                try decode(GeneratedAPI.ProjectFileConflict.self, data: data, http: http)
            )
        default:
            try validate(http: http, data: data)
            throw APIError(.unexpectedStatus, statusCode: http.statusCode)
        }
    }

    /// PLAN 42.10 and 54.6: the preview reaches the project's dev server through sparkd, signed.
    public func projectPreview(
        route base: URL,
        projectID: String,
        port: Int,
        path: String
    ) async throws -> String {
        guard (1...65_535).contains(port) else {
            throw APIError(.local(message: String(localized: "That is not a port number.")))
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(
            url: endpoint(
                base,
                "api",
                "v1",
                "projects",
                projectID,
                "preview",
                String(port),
                trimmed.isEmpty ? "index.html" : trimmed
            )
        )
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        try applySigning(to: &request, body: Data())

        let (data, http) = try await transport.perform(request)
        try validate(http: http, data: data)
        guard http.statusCode == 200 else {
            throw APIError(.unexpectedStatus, statusCode: http.statusCode)
        }
        guard data.count <= ProjectPreview.maximumBytes,
            let text = String(data: data, encoding: .utf8)
        else { throw APIError(.malformedResponse, statusCode: http.statusCode) }
        return text
    }

    public func projectChanges(
        route base: URL,
        projectID: String
    ) async throws -> [GeneratedAPI.ProjectChange] {
        let response: GeneratedAPI.ListProjectChangesResponse200 = try await get(
            endpoint(base, "api", "v1", "projects", projectID, "changes")
        )
        return response.items
    }

    public func startProjectAgent(
        route base: URL,
        projectID: String,
        request: GeneratedAPI.StartProjectAgentRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "projects", projectID, "agents"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func approveProjectChange(
        route base: URL,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String? = nil,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ProjectChangeDecision {
        try await post(
            endpoint(base, "api", "v1", "projects", projectID, "changes", changeID, "approve"),
            body: GeneratedAPI.ApproveChangeRequest(
                reviewDigest: reviewDigest,
                comment: comment
            ),
            idempotencyKey: idempotencyKey
        )
    }

    public func requestProjectChangeUpdates(
        route base: URL,
        projectID: String,
        changeID: String,
        reviewDigest: String,
        comment: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ProjectChangeDecision {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "projects",
                projectID,
                "changes",
                changeID,
                "request-changes"
            ),
            body: GeneratedAPI.RequestProjectChangeUpdatesRequest(
                reviewDigest: reviewDigest,
                comment: comment
            ),
            idempotencyKey: idempotencyKey
        )
    }

    public func createProjectTerminal(
        route base: URL,
        projectID: String,
        shell: ProjectTerminalShell = .login,
        columns: Int = 120,
        rows: Int = 40,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.ProjectTerminal {
        try await post(
            endpoint(base, "api", "v1", "projects", projectID, "terminals"),
            body: GeneratedAPI.CreateTerminalRequest(
                shell: GeneratedAPI.CreateTerminalRequestShell(rawValue: shell.rawValue),
                cols: min(max(columns, 10), 500),
                rows: min(max(rows, 5), 250)
            ),
            idempotencyKey: idempotencyKey,
            timeoutInterval: Self.terminalCreationTimeout
        )
    }

    public func createDevelopmentTerminal(
        route base: URL,
        projectID: String,
        selection: ProjectDevelopmentSelection,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ProjectTerminal {
        struct Request: Encodable {
            let shell = "development"
            let development: ProjectDevelopmentSelection
            let cols = 120
            let rows = 40
        }
        return try await post(
            endpoint(base, "api", "v1", "projects", projectID, "terminals"),
            body: Request(development: selection),
            idempotencyKey: idempotencyKey,
            timeoutInterval: Self.terminalCreationTimeout
        )
    }

    public func closeProjectTerminal(
        route base: URL,
        projectID: String,
        terminalID: String,
        idempotencyKey: UUID = UUID()
    ) async throws {
        struct ClosedTerminal: Decodable {
            let state: String
        }
        let result: ClosedTerminal
        do {
            result = try await mutation(
                method: "DELETE",
                url: endpoint(base, "api", "v1", "projects", projectID, "terminals", terminalID),
                body: NoBody?.none,
                idempotencyKey: idempotencyKey,
                userPresence: nil
            )
        } catch let error as APIError
            where error.statusCode == 404 && error.code == "TERMINAL_NOT_FOUND"
        {
            return  // The authenticated Spark confirms that this session no longer exists.
        }
        guard result.state == "closed" else {
            throw APIError(.malformedResponse)
        }
    }

    public func projectTerminalSocket(
        route base: URL,
        projectID: String,
        terminalID: String
    ) throws -> ProjectTerminalSocket {
        guard let signer else {
            throw APIError(.local(message: String(localized: "This device is not paired.")))
        }
        return try ProjectTerminalSocket(
            baseURL: base,
            pin: transport.pin,
            signer: signer,
            projectID: projectID,
            terminalID: terminalID
        )
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        data: Data,
        http: HTTPURLResponse
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError(
                .malformedResponse,
                statusCode: http.statusCode,
                diagnosticDetail: "decode failed: \(error)"
            )
        }
    }
}

/// What the preview proxy will hand to a view, so a runaway page cannot fill the device.
public enum ProjectPreview {
    public static let maximumBytes = 1_048_576
}

private func workspaceURL(_ url: URL, development: Bool) -> URL {
    development
        ? url.appending(queryItems: [URLQueryItem(name: "workspace", value: "development")]) : url
}

public enum ProjectDevelopmentHarness: String, CaseIterable, Codable, Sendable, Identifiable {
    case ohMyPi = "oh_my_pi"
    case openCode = "open_code"
    case pi
    case claudeCode = "claude_code"
    case codex
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .ohMyPi: String(localized: "Oh My Pi")
        case .openCode: String(localized: "OpenCode")
        case .pi: String(localized: "Pi")
        case .claudeCode: String(localized: "Claude Code")
        case .codex: String(localized: "Codex")
        }
    }
    public var usesSparkModel: Bool { true }
}

public struct ProjectDevelopmentSelection: Codable, Equatable, Sendable {
    public let harness: ProjectDevelopmentHarness
    public let modelID: String
    public let clusterID: String?
    public let workspaceSessionID: UUID
    public var thinkingTokenBudget: Int?
    public init(
        harness: ProjectDevelopmentHarness,
        modelID: String,
        clusterID: String?,
        workspaceSessionID: UUID = UUID()
    ) {
        self.harness = harness
        self.modelID = modelID
        self.clusterID = clusterID
        self.workspaceSessionID = workspaceSessionID
    }
    enum CodingKeys: String, CodingKey {
        case harness
        case modelID = "model_id"
        case clusterID = "cluster_id"
        case workspaceSessionID = "workspace_session_id"
        case thinkingTokenBudget = "thinking_token_budget"
    }
}

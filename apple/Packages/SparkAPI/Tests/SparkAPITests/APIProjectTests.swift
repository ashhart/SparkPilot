import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func deletionRequiresCompleteCleanupSupportAndReturnsTheDurableOperation() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let path = "/api/v1/projects/\(projectID)"
        let operationID = UUID()
        MockURLProtocol.responses = [
            "/api/v1/projects": .success(Data("{\"items\":[],\"capabilities\":[]}".utf8)),
            path: .success(
                Data(
                    "{\"id\":\"\(operationID)\",\"kind\":\"project.delete\",\"state\":\"queued\",\"cancellable\":false}"
                        .utf8
                )
            ),
        ]
        MockURLProtocol.extraHeaders = [:]
        defer { MockURLProtocol.extraHeaders = [:] }
        MockURLProtocol.requestsMade = []
        MockURLProtocol.statusCodes[path] = 202
        let client = try makeClient(signer: APIUserPresenceSigner())
        let route = URL(string: "https://spark.local:7443")!
        do {
            _ = try await client.deleteProject(route: route, projectID: projectID)
            Issue.record("An older runtime must not receive a destructive request")
        } catch let error as APIError {
            #expect(APIError.message(for: error).contains("Update Spark Runtime"))
        }
        #expect(!MockURLProtocol.requestsMade.contains(path))
        MockURLProtocol.extraHeaders["/api/v1/projects"] = [
            "X-Spark-Project-Deletion": "complete-v1"
        ]
        let key = UUID()
        let operation = try await client.deleteProject(
            route: route,
            projectID: projectID,
            idempotencyKey: key
        )
        #expect(operation.id == operationID)
        #expect(operation.state == .queued)
        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
                == key.uuidString
        )
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
    }

    @Test func projectFileSaveSendsRevisionAndReturnsTypedConflict() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let path = "/api/v1/projects/\(projectID)/files/Sources/App/Main.swift"
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    """
                    {"error":{"code":"FILE_CONFLICT","base_revision":"\(oldRevision)","current_revision":"\(newRevision)","current_content":"let answer = 43\\n"}}
                    """.utf8
                )
            )
        ]
        MockURLProtocol.statusCodes[path] = 409
        let client = try makeClient(signer: APIUserPresenceSigner())
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        let outcome = try await client.saveProjectFile(
            route: URL(string: "https://spark.local:7443")!,
            projectID: projectID,
            path: "Sources/App/Main.swift",
            content: "let answer = 42\n",
            revision: oldRevision,
            idempotencyKey: key
        )

        guard case .conflict(let conflict) = outcome else {
            Issue.record("Expected a revision conflict")
            return
        }
        #expect(conflict.error.currentRevision == newRevision)
        #expect(MockURLProtocol.lastRequest?.httpMethod == "PUT")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "If-Match") == oldRevision)
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
                == key.uuidString
        )
        #expect(MockURLProtocol.lastBody == Data("let answer = 42\n".utf8))
        let encodedPath = MockURLProtocol.lastRequest?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        #expect(
            encodedPath
                == "/api/v1/projects/\(projectID)/files/Sources%2FApp%2FMain.swift"
        )
    }

    /// PLAN 42.10 and 54.6: the preview goes through the Spark's own signed proxy.
    @Test func previewIsReadThroughTheSignedProxyAtTheContractPath() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let path = "/api/v1/projects/\(projectID)/preview/5173/app/index.html"
        MockURLProtocol.responses = [path: .success(Data("<html>ok</html>".utf8))]
        MockURLProtocol.statusCodes[path] = 200
        let client = try makeClient(signer: APIUserPresenceSigner())

        let body = try await client.projectPreview(
            route: URL(string: "https://spark.local:7443")!,
            projectID: projectID,
            port: 5_173,
            path: "app/index.html"
        )

        #expect(body == "<html>ok</html>")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
    }

    /// An empty path is the service's own root, and a port that is not a port never leaves.
    @Test func previewDefaultsToTheServiceRootAndRefusesAnImpossiblePort() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let path = "/api/v1/projects/\(projectID)/preview/3000/index.html"
        MockURLProtocol.responses = [path: .success(Data("root".utf8))]
        MockURLProtocol.statusCodes[path] = 200
        let client = try makeClient(signer: APIUserPresenceSigner())
        let route = URL(string: "https://spark.local:7443")!

        let body = try await client.projectPreview(
            route: route,
            projectID: projectID,
            port: 3_000,
            path: ""
        )
        #expect(body == "root")

        MockURLProtocol.lastRequest = nil
        await #expect(throws: APIError.self) {
            _ = try await client.projectPreview(
                route: route,
                projectID: projectID,
                port: 70_000,
                path: "index.html"
            )
        }
        #expect(MockURLProtocol.lastRequest == nil, "nothing is sent for an impossible port")
    }

    @Test func projectApprovalCarriesTheExactReviewedDigest() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let changeID = "30000000-0000-4000-8000-000000000003"
        let path = "/api/v1/projects/\(projectID)/changes/\(changeID)/approve"
        let digest = String(repeating: "c", count: 64)
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    """
                    {"change":{"id":"\(changeID)","project_id":"\(projectID)","status":"merged","task":"Correct the answer","base_commit":"dddddddddddddddddddddddddddddddddddddddd","head_commit":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","protected_head_commit":"ffffffffffffffffffffffffffffffffffffffff","review_digest":"\(digest)","branch":"agent/correct-answer","changed_files":[],"test_evidence":[],"tool_evidence":[],"evidence_complete":true,"created_at":"2026-09-01T12:00:00Z","updated_at":"2026-09-01T12:01:00Z"}}
                    """.utf8
                )
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())

        _ = try await client.approveProjectChange(
            route: URL(string: "https://spark.local:7443")!,
            projectID: projectID,
            changeID: changeID,
            reviewDigest: digest,
            comment: "Reviewed on iPad"
        )

        let body = try #require(MockURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["review_digest"] as? String == digest)
        #expect(json["comment"] as? String == "Reviewed on iPad")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
    }

    @Test func projectTerminalCreationUsesOnlyBoundedContractShellsAndDimensions() async throws {
        let projectID = "10000000-0000-4000-8000-000000000001"
        let path = "/api/v1/projects/\(projectID)/terminals"
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    """
                    {"terminal_id":"20000000-0000-4000-8000-000000000002","project_id":"\(projectID)","state":"running","created_at":"2026-09-01T12:00:00Z"}
                    """.utf8
                )
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())

        _ = try await client.createProjectTerminal(
            route: URL(string: "https://spark.local:7443")!,
            projectID: projectID,
            shell: .python,
            columns: 5_000,
            rows: 1
        )

        let body = try #require(MockURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["shell"] as? String == "python")
        #expect(json["cols"] as? Int == 500)
        #expect(json["rows"] as? Int == 5)
        // A first session may start the project container; the 3-second presence timeout would report it failed.
        #expect((MockURLProtocol.lastRequest?.timeoutInterval ?? 0) >= 60)
    }

    @Test func creatingAFolderWaitsForABusySparkInsteadOfReportingAFailure() async throws {
        MockURLProtocol.responses = [
            "/api/v1/projects": .success(
                Data(
                    """
                    {"id":"30000000-0000-4000-8000-000000000003","kind":"project.create","state":"queued","created_at":"2026-09-07T12:00:00Z","updated_at":"2026-09-07T12:00:00Z"}
                    """.utf8
                )
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())

        _ = try? await client.createProject(
            route: URL(string: "https://spark.local:7443")!,
            request: GeneratedAPI.CreateProject(name: "lightning-notes")
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.path == "/api/v1/projects")
        #expect(
            request.timeoutInterval >= 30,
            "a Spark mid-download answers in seconds, not within 3"
        )
    }

    @Test func projectTerminalFramesMatchTheRuntimeProtocolAndBounds() throws {
        let encoded = try ProjectTerminalFrameCodec.input("pwd\n")
        let input = try #require(
            JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String]
        )
        #expect(input == ["type": "input", "data": "pwd\n"])

        let output = Data(#"{"type":"output","data":"/workspace\n"}"#.utf8)
        #expect(try ProjectTerminalFrameCodec.output(from: output) == "/workspace\n")
        #expect(
            throws: (any Error).self,
            performing: {
                try ProjectTerminalFrameCodec.input(
                    String(repeating: "a", count: ProjectTerminalFrameCodec.maximumInputBytes + 1)
                )
            }
        )
        let oversized = try JSONEncoder().encode([
            "type": "output",
            "data": String(
                repeating: "b",
                count: ProjectTerminalFrameCodec.maximumOutputBytes + 1
            ),
        ])
        #expect(
            throws: (any Error).self,
            performing: { try ProjectTerminalFrameCodec.output(from: oversized) }
        )
        #expect(
            throws: (any Error).self,
            performing: { try ProjectTerminalFrameCodec.output(from: Data("raw output".utf8)) }
        )
    }
}

#if os(macOS)
    import Foundation
    import SparkCore
    import Testing
    import Synchronization
    @testable import SparkAppComposition

    @MainActor
    private final class DeveloperToolTargetProvider: SparkChatTargetProviding {
        var value: SparkChatTargetCatalogue

        init(_ targets: [SparkChatTarget]) {
            value = SparkChatTargetCatalogue(targets: targets, pairedTargetCount: targets.count)
        }

        func catalogue() -> SparkChatTargetCatalogue { value }
    }

    @MainActor
    private final class RecordingDeveloperToolLauncher: SparkDeveloperToolLaunching {
        var launches: [(SparkDeveloperTool, SparkChatTarget)] = []
        var failure: (any Error)?

        func launch(_ tool: SparkDeveloperTool, target: SparkChatTarget) async throws {
            if let failure { throw failure }
            launches.append((tool, target))
        }
    }

    private func developerToolTarget(
        id: String = "desk-spark",
        modelID: String = "open/example-32b",
        clusterID: SparkClusterID? = nil,
        contextLength: Int? = 131_072
    ) -> SparkChatTarget {
        SparkChatTarget(
            id: id,
            displayName: "Desk Spark",
            nodeID: SparkNodeID(
                rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
            ),
            clusterID: clusterID,
            route: URL(string: "https://desk-spark.local:8443")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: modelID,
            modelName: "Example 32B",
            contextLength: contextLength
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class RecordingEndpointGateway: SparkIntegrationGatewayServing, Sendable {
        private let stops = Mutex(0)
        let operation: @Sendable () async throws -> SparkIntegrationEndpoint
        var stopCount: Int { stops.withLock { $0 } }

        init(
            operation: @escaping @Sendable () async throws -> SparkIntegrationEndpoint = {
                SparkIntegrationEndpoint(
                    baseURL: URL(string: "http://127.0.0.1:19001")!,
                    token: "test-token"
                )
            }
        ) {
            self.operation = operation
        }

        func start() async throws -> SparkIntegrationEndpoint { try await operation() }
        func stop() { stops.withLock { $0 += 1 } }
    }

    private actor EndpointStartGate {
        var continuation: CheckedContinuation<SparkIntegrationEndpoint, any Error>?
        func wait() async throws -> SparkIntegrationEndpoint {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        var waiting: Bool { continuation != nil }
        func finish() {
            continuation?.resume(
                returning: SparkIntegrationEndpoint(
                    baseURL: URL(string: "http://127.0.0.1:19001")!,
                    token: "obsolete-token"
                )
            )
            continuation = nil
        }
    }

    @Suite("Spark developer tools")
    struct SparkDeveloperToolsTests {
        @Test func launcherMatchesTheFiveSupportedApps() {
            #expect(
                SparkDeveloperTool.allCases
                    == [.claudeCode, .codexApp, .hermesAgent, .ohMyPi, .openCode]
            )
        }

        @Test @MainActor func modelSelectsAReadyTargetAndLaunchesAgainstIt() async {
            let target = developerToolTarget()
            let provider = DeveloperToolTargetProvider([target])
            let launcher = RecordingDeveloperToolLauncher()
            let model = SparkDeveloperToolsModel(targetProvider: provider, launcher: launcher)

            #expect(model.selectedTargetID == target.id)
            await model.launch(.openCode)

            #expect(launcher.launches.count == 1)
            #expect(launcher.launches.first?.0 == .openCode)
            #expect(launcher.launches.first?.1 == target)
            #expect(model.state(for: .openCode) == .launched)

            model.selectedTargetID = nil
            #expect(model.state(for: .openCode) == .idle)
        }

        @Test @MainActor func refreshPreservesAStillValidSelection() {
            let first = developerToolTarget(id: "first")
            let second = developerToolTarget(id: "second")
            let provider = DeveloperToolTargetProvider([first, second])
            let launcher = RecordingDeveloperToolLauncher()
            let model = SparkDeveloperToolsModel(targetProvider: provider, launcher: launcher)
            model.selectedTargetID = second.id

            provider.value = SparkChatTargetCatalogue(
                targets: [second, first],
                pairedTargetCount: 2
            )
            model.refresh()

            #expect(model.selectedTargetID == second.id)
        }

        @Test @MainActor func endpointStartsForTheSelectedClusterAndStopsOnSelectionChange() async {
            let cluster = developerToolTarget(
                id: "cluster",
                clusterID: SparkClusterID(rawValue: UUID())
            )
            let provider = DeveloperToolTargetProvider([cluster, developerToolTarget(id: "other")])
            let gateway = RecordingEndpointGateway()
            var captured: SparkChatTarget?
            let model = SparkDeveloperToolsModel(
                targetProvider: provider,
                launcher: RecordingDeveloperToolLauncher(),
                gatewayFactory: {
                    captured = $0
                    return gateway
                }
            )
            await model.startEndpoint()
            #expect(captured == cluster)
            #expect(model.endpoint?.apiURL.absoluteString == "http://127.0.0.1:19001/v1")
            #expect(model.endpoint?.port == 19001)
            #expect(!model.endpointStarting)
            model.selectedTargetID = "other"
            #expect(model.endpoint == nil)
            #expect(gateway.stopCount == 1)
        }

        @Test @MainActor func aModelChangeOnTheSameTargetInvalidatesCredentials() async {
            let provider = DeveloperToolTargetProvider([developerToolTarget()])
            let gateway = RecordingEndpointGateway()
            let model = SparkDeveloperToolsModel(
                targetProvider: provider,
                launcher: RecordingDeveloperToolLauncher(),
                gatewayFactory: { _ in gateway }
            )
            await model.startEndpoint()
            provider.value = SparkChatTargetCatalogue(
                targets: [developerToolTarget(modelID: "open/new-model")],
                pairedTargetCount: 1
            )
            model.refresh()
            #expect(model.selectedTargetID == "desk-spark")
            #expect(model.endpoint == nil)
            #expect(gateway.stopCount == 1)
        }

        @Test @MainActor func unavailableTargetsCannotStartAndInvalidateAnExistingEndpoint() async {
            let provider = DeveloperToolTargetProvider([developerToolTarget()])
            let gateway = RecordingEndpointGateway()
            var starts = 0
            let model = SparkDeveloperToolsModel(
                targetProvider: provider,
                launcher: RecordingDeveloperToolLauncher(),
                gatewayFactory: { _ in
                    starts += 1
                    return gateway
                }
            )
            await model.startEndpoint()
            provider.value = .empty
            model.refresh()
            await model.startEndpoint()
            #expect(starts == 1)
            #expect(model.endpoint == nil)
            #expect(!model.endpointStarting)
            #expect(gateway.stopCount == 1)
        }

        @Test @MainActor func startupFailureCleansUpAndCanBeRetried() async {
            let provider = DeveloperToolTargetProvider([developerToolTarget()])
            let failed = RecordingEndpointGateway {
                throw SparkDeveloperToolLaunchError.identityMismatch
            }
            let recovered = RecordingEndpointGateway()
            var attempts = 0
            let model = SparkDeveloperToolsModel(
                targetProvider: provider,
                launcher: RecordingDeveloperToolLauncher(),
                gatewayFactory: { _ in
                    attempts += 1
                    return attempts == 1 ? failed : recovered
                }
            )
            await model.startEndpoint()
            #expect(model.endpoint == nil)
            #expect(model.endpointError != nil)
            #expect(!model.endpointStarting)
            #expect(failed.stopCount == 1)
            await model.startEndpoint()
            #expect(model.endpoint != nil)
            #expect(model.endpointError == nil)
        }

        @Test @MainActor func cancelledStartupCannotReplaceANewerConnection() async {
            let provider = DeveloperToolTargetProvider([developerToolTarget()])
            let gate = EndpointStartGate()
            let old = RecordingEndpointGateway { try await gate.wait() }
            let new = RecordingEndpointGateway()
            var attempts = 0
            let model = SparkDeveloperToolsModel(
                targetProvider: provider,
                launcher: RecordingDeveloperToolLauncher(),
                gatewayFactory: { _ in
                    attempts += 1
                    return attempts == 1 ? old : new
                }
            )
            let pending = Task { await model.startEndpoint() }
            while !(await gate.waiting) { await Task.yield() }
            await model.startEndpoint()
            #expect(attempts == 1)
            model.stopEndpoint()
            await model.startEndpoint()
            await gate.finish()
            await pending.value
            #expect(model.endpoint?.token == "test-token")
            #expect(old.stopCount >= 1)
            #expect(new.stopCount == 0)
        }

        @Test func copiedCommandsPreserveLiteralCredentialsAndModelIDs() throws {
            let token = "test' token; $(false) `false`"
            let modelID = "org/model'$(false)"
            let endpoint = SparkIntegrationEndpoint(
                baseURL: URL(string: "http://127.0.0.1:19001")!,
                token: token
            )
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f"]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            let script =
                endpoint.environmentCommand(modelID: modelID)
                + "\nprintf '%s\\n' \"$OPENAI_BASE_URL\" \"$OPENAI_API_KEY\" \"$OPENAI_MODEL\"\n"
                + "function curl() { printf '%s\\n' \"$@\"; }\n"
                + endpoint.modelsCommand + "\n"
            input.fileHandleForWriting.write(Data(script.utf8))
            try input.fileHandleForWriting.close()
            let result = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(
                result.components(separatedBy: "\n") == [
                    "http://127.0.0.1:19001/v1", token, modelID,
                    "--fail-with-body", "http://127.0.0.1:19001/v1/models", "-H",
                    "Authorization: Bearer " + token, "",
                ]
            )
        }

        @Test func anthropicRequestsBecomeAllowlistedChatRequests() throws {
            let input = Data(
                """
                {
                  "model":"claude-sonnet",
                  "system":[{"type":"text","text":"Be precise"}],
                  "messages":[
                    {"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"read_file","input":{"path":"README.md"}}]},
                    {"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"hello"},{"type":"text","text":"Continue"}]}
                  ],
                  "tools":[{"name":"read_file","description":"Reads a file","input_schema":{"type":"object"}}],
                  "max_tokens":4096,
                  "stream":true
                }
                """.utf8
            )

            let body = try SparkIntegrationRequestAdapter.requestBody(
                input,
                path: "/v1/messages",
                modelID: "open/example-32b"
            )
            let output = try jsonObject(body)
            let messages = try #require(output["messages"] as? [[String: Any]])
            let tools = try #require(output["tools"] as? [[String: Any]])

            #expect(output["model"] as? String == "open/example-32b")
            #expect(output["stream"] as? Bool == true)
            // A4: tool results follow the assistant turn that called them, before any later user text.
            #expect(
                messages.map { $0["role"] as? String } == ["system", "assistant", "tool", "user"]
            )
            #expect(
                (messages[1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1"
            )
            #expect(messages[2]["tool_call_id"] as? String == "call_1")
            #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "read_file")
        }

        @Test func openAIResponsesBecomeAnthropicMessages() throws {
            let source = Data(
                """
                {"id":"chatcmpl_1","model":"open/example-32b","choices":[{"finish_reason":"tool_calls","message":{"content":"Checking","tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":\\"README.md\\"}"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
                """.utf8
            )

            let output = try jsonObject(
                try AnthropicResponseAdapter.responseBody(source, modelID: "open/example-32b")
            )
            let content = try #require(output["content"] as? [[String: Any]])

            #expect(output["type"] as? String == "message")
            #expect(output["stop_reason"] as? String == "tool_use")
            #expect(content.map { $0["type"] as? String } == ["text", "tool_use"])
            #expect((content[1]["input"] as? [String: Any])?["path"] as? String == "README.md")
        }

        @Test func streamedChatBecomesAnthropicServerSentEvents() throws {
            let adapter = AnthropicStreamAdapter(modelID: "open/example-32b")
            let first = try adapter.append(
                Data(
                    "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}\n\n"
                        .utf8
                )
            )
            let last = try adapter.append(
                Data(
                    "data: {\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
                        .utf8
                )
            )
            let text = String(decoding: first + last, as: UTF8.self)

            #expect(text.contains("event: message_start"))
            #expect(text.contains("event: content_block_delta"))
            #expect(text.contains("\"text\":\"Hello\""))
            #expect(text.contains("event: message_stop"))
        }

        @Test @MainActor func generatedLaunchCommandsUseTemporaryOverrides() throws {
            let target = developerToolTarget()
            let endpoint = SparkIntegrationEndpoint(
                baseURL: URL(string: "http://127.0.0.1:19001")!,
                token: "temporary-token"
            )
            let codex = try MacSparkDeveloperToolLauncher.script(
                tool: .codexApp,
                target: target,
                endpoint: endpoint,
                executable: "/Applications/Codex.app/Contents/Resources/codex"
            )
            let hermes = try MacSparkDeveloperToolLauncher.script(
                tool: .hermesAgent,
                target: target,
                endpoint: endpoint,
                executable: "/Users/test/.local/bin/hermes"
            )

            #expect(codex.contains("wire_api=\"responses\""))
            #expect(codex.contains("app -c 'model=\"open/example-32b\"'"))
            #expect(!codex.contains("status=$?"))
            #expect(hermes.contains("trap spark_restore_hermes EXIT"))
            #expect(hermes.contains("--provider spark"))

            for tool in SparkDeveloperTool.allCases {
                let script = try MacSparkDeveloperToolLauncher.script(
                    tool: tool,
                    target: target,
                    endpoint: endpoint,
                    executable: "/tmp/\(tool.rawValue)"
                )
                let process = Process()
                let input = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-n"]
                process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(Data(script.utf8))
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "Invalid \(tool.name) launch script")
            }
        }
    }
#endif

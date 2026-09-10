#if os(macOS)
    import AppKit
    import CryptoKit
    import Foundation
    import Network
    import Observation
    import SparkAPI
    import SparkCore
    import SparkSecurity
    @_spi(SparkInternal) import SparkTransport

    @MainActor
    public final class MacSparkDeveloperToolLauncher: SparkDeveloperToolLaunching {
        private struct LaunchKey: Hashable {
            let tool: SparkDeveloperTool
            let target: String
        }

        // One gateway per tool and target, so launching another Spark never stops an earlier session's bridge.
        private var gateways: [LaunchKey: SparkIntegrationGateway] = [:]

        public init() {}

        public func launch(_ tool: SparkDeveloperTool, target: SparkChatTarget) async throws {
            guard let executable = Self.executablePath(for: tool) else {
                throw SparkDeveloperToolLaunchError.appNotInstalled(tool)
            }
            if tool == .hermesAgent, let contextLength = target.contextLength,
                contextLength < 64_000
            {
                throw SparkDeveloperToolLaunchError.incompatibleModel(
                    String(
                        localized: .hermesContextTooSmall(contextLength.formatted())
                    )
                )
            }
            let gateway = SparkIntegrationGateway(target: target)
            let endpoint = try await gateway.start()
            let script = try Self.script(
                tool: tool,
                target: target,
                endpoint: endpoint,
                executable: executable
            )
            let scriptURL = try Self.writeScript(script, tool: tool)
            guard NSWorkspace.shared.open(scriptURL) else {
                gateway.stop()
                throw SparkDeveloperToolLaunchError.terminalUnavailable
            }
            let key = LaunchKey(tool: tool, target: target.selectionID)
            gateways.removeValue(forKey: key)?.stop()
            gateways[key] = gateway
        }

        private static func executablePath(for tool: SparkDeveloperTool) -> String? {
            switch tool {
            case .codexApp:
                if let command = executable(named: "codex") { return command }
                let bundles = [
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
                    URL(fileURLWithPath: "/Applications/Codex.app"),
                    URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                ].compactMap { $0 }
                return
                    bundles
                    .map { $0.appendingPathComponent("Contents/Resources/codex").path }
                    .first { FileManager.default.isExecutableFile(atPath: $0) }
            case .claudeCode: return executable(named: "claude")
            case .hermesAgent: return executable(named: "hermes")
            case .ohMyPi: return executable(named: "omp")
            case .openCode: return executable(named: "opencode")
            }
        }

        private static func executable(named name: String) -> String? {
            let candidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/\(name)").path,
            ]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        static func script(
            tool: SparkDeveloperTool,
            target: SparkChatTarget,
            endpoint: SparkIntegrationEndpoint,
            executable: String
        ) throws -> String {
            let baseURL = endpoint.baseURL.absoluteString
            let apiURL = endpoint.baseURL.appendingPathComponent("v1").absoluteString
            let token = shellQuote(endpoint.token)
            // Runtime-supplied names are data: strip control characters, then quote every interpolation.
            let modelID = terminalSafe(target.modelID)
            let model = shellQuote(modelID)
            let binary = shellQuote(executable)
            let path = "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
            let profileDirectory = SHA256.hash(data: Data(target.selectionID.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            let command: String
            switch tool {
            case .claudeCode:
                command =
                    "ANTHROPIC_BASE_URL=\(shellQuote(baseURL)) ANTHROPIC_AUTH_TOKEN=\(token) ANTHROPIC_API_KEY='' ANTHROPIC_DEFAULT_OPUS_MODEL=\(model) ANTHROPIC_DEFAULT_SONNET_MODEL=\(model) ANTHROPIC_DEFAULT_HAIKU_MODEL=\(model) API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \(binary) --model \(model)"
            case .codexApp:
                command =
                    "SPARK_API_KEY=\(token) \(binary) app -c \(shellQuote("model=\"\(modelID)\"")) -c 'model_provider=\"spark\"' -c 'model_providers.spark.name=\"Spark\"' -c \(shellQuote("model_providers.spark.base_url=\"\(apiURL)\"")) -c 'model_providers.spark.env_key=\"SPARK_API_KEY\"' -c 'model_providers.spark.wire_api=\"responses\"'"
            case .openCode:
                let config = try JSONSerialization.data(
                    withJSONObject: [
                        "model": "spark/\(target.modelID)",
                        "provider": [
                            "spark": [
                                "npm": "@ai-sdk/openai-compatible",
                                "name": "Spark",
                                "options": ["baseURL": apiURL, "apiKey": endpoint.token],
                                "models": [target.modelID: ["name": target.modelName]],
                            ]
                        ],
                    ],
                    options: [.sortedKeys]
                )
                let configText = String(decoding: config, as: UTF8.self)
                command = "OPENCODE_CONFIG_CONTENT=\(shellQuote(configText)) \(binary)"
            case .ohMyPi:
                let config = try JSONSerialization.data(
                    withJSONObject: [
                        "providers": [
                            "spark": [
                                "baseUrl": apiURL, "api": "openai-completions",
                                "apiKey": "SPARK_API_KEY", "authHeader": true,
                                "models": [
                                    [
                                        "id": target.modelID, "name": target.modelName,
                                        "contextWindow": target.contextLength ?? 32768,
                                        "maxTokens": min(8192, (target.contextLength ?? 32768) / 4),
                                    ]
                                ],
                            ]
                        ]
                    ],
                    options: [.sortedKeys]
                )
                let configText = String(decoding: config, as: UTF8.self)
                command = """
                    umask 077
                    export PI_CODING_AGENT_DIR="$HOME/Library/Application Support/SparkPilot/OhMyPi/\(profileDirectory)"
                    mkdir -p "$PI_CODING_AGENT_DIR" || exit $?
                    printf '%s\\n' \(shellQuote(configText)) > "$PI_CODING_AGENT_DIR/models.yml" || exit $?
                    SPARK_API_KEY=\(token) \(binary) --provider spark --model \(model)
                    """
            case .hermesAgent:
                command = """
                    spark_hermes_config="$(\(binary) config path 2>/dev/null | tail -1)"
                    spark_hermes_backup="$TMPDIR/spark-hermes-$PPID-$$.yaml"
                    spark_had_hermes_config=0
                    if [ -n "$spark_hermes_config" ] && [ -f "$spark_hermes_config" ]; then
                      cp -p "$spark_hermes_config" "$spark_hermes_backup"
                      spark_had_hermes_config=1
                    fi
                    spark_restore_hermes() {
                      if [ "$spark_had_hermes_config" = 1 ]; then cp -p "$spark_hermes_backup" "$spark_hermes_config"; rm -f "$spark_hermes_backup"
                      elif [ -n "$spark_hermes_config" ]; then rm -f "$spark_hermes_config"; fi
                    }
                    trap spark_restore_hermes EXIT
                    \(binary) config set --force providers.spark.name Spark >/dev/null || exit $?
                    \(binary) config set --force providers.spark.base_url \(shellQuote(apiURL)) >/dev/null || exit $?
                    \(binary) config set --force providers.spark.api_key \(token) >/dev/null || exit $?
                    \(binary) config set --force providers.spark.api_mode chat_completions >/dev/null || exit $?
                    \(binary) config set --force providers.spark.default_model \(model) >/dev/null || exit $?
                    \(binary) config set --force model.provider spark >/dev/null || exit $?
                    \(binary) config set --force model.default \(model) >/dev/null || exit $?
                    \(binary) chat --tui --provider spark -m \(model)
                    """
            }
            return """
                #!/bin/zsh
                export PATH=\"\(path)\"
                printf '\\033]0;%s\\007' \(shellQuote(terminalSafe("Spark · \(tool.name) · \(target.displayName)")))
                \(command)
                spark_exit=$?
                if [ $spark_exit -ne 0 ]; then
                  printf '\\nLaunch failed with status %d. Press Return to close.\\n' $spark_exit
                  read
                fi
                exit $spark_exit
                """
        }

        private static func writeScript(_ contents: String, tool: SparkDeveloperTool) throws -> URL
        {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SparkLaunchers", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sweepStaleLaunchers(in: root, olderThan: Date().addingTimeInterval(-3600))
            let url = root.appendingPathComponent("\(tool.rawValue)-\(UUID().uuidString).command")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
            return url
        }

        private static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }

        /// Drop control characters so a runtime-supplied name cannot carry terminal escape sequences into the launcher.
        static func terminalSafe(_ value: String) -> String {
            let scalars = value.unicodeScalars.filter { scalar in
                let control = scalar.value < 0x20 || scalar.value == 0x7f
                return !(control || (0x80...0x9f).contains(scalar.value))
            }
            return String(String.UnicodeScalarView(scalars))
        }

        /// Terminal reads a launch script once; remove scripts older than the cutoff so the directory does not accumulate.
        static func sweepStaleLaunchers(in root: URL, olderThan cutoff: Date) {
            let items =
                (try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
            for item in items where item.pathExtension == "command" {
                let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if let modified, modified < cutoff {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
    }

    public struct SparkIntegrationEndpoint: Sendable {
        public let baseURL: URL
        public let token: String

        public var apiURL: URL { baseURL.appendingPathComponent("v1") }
        public var port: Int? { baseURL.port }

        /// Paste into the shell that runs the external harness.
        public func environmentCommand(modelID: String) -> String {
            """
            export OPENAI_BASE_URL=\(Self.shellQuote(apiURL.absoluteString))
            export OPENAI_API_KEY=\(Self.shellQuote(token))
            export OPENAI_MODEL=\(Self.shellQuote(modelID))
            """
        }

        public var modelsCommand: String {
            "curl --fail-with-body \(Self.shellQuote(apiURL.appendingPathComponent("models").absoluteString)) -H \(Self.shellQuote("Authorization: Bearer " + token))"
        }

        private static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
    }

#endif

#if os(macOS)
    import Foundation
    import SparkAPI
    import SparkCore
    import Testing
    @testable import SparkAppComposition

    @MainActor
    struct MacSparkDeveloperToolLauncherTests {
        private let tools: [SparkDeveloperTool] = [
            .claudeCode, .codexApp, .openCode, .ohMyPi, .hermesAgent,
        ]

        private func target(displayName: String, modelID: String) -> SparkChatTarget {
            SparkChatTarget(
                id: "node:launcher",
                displayName: displayName,
                nodeID: SparkNodeID(rawValue: UUID()),
                route: URL(string: "https://spark.local:7443")!,
                tlsFingerprint: String(repeating: "a", count: 64),
                authorityFingerprint: String(repeating: "b", count: 64),
                modelID: modelID,
                modelName: "Model",
                contextLength: 128_000
            )
        }

        /// A quote, escape or control character in a runtime-supplied name must never leave its quoted string (A1).
        @Test func runtimeSuppliedNamesStayInsideTheirQuotes() throws {
            let hostileName = "x'; touch /tmp/pwned; echo '\u{1B}]0;evil\u{07}"
            let hostileModel = "m'; id; echo '"
            let endpoint = SparkIntegrationEndpoint(
                baseURL: URL(string: "http://127.0.0.1:4242")!,
                token: "tok'en"
            )
            for tool in tools {
                let script = try MacSparkDeveloperToolLauncher.script(
                    tool: tool,
                    target: target(displayName: hostileName, modelID: hostileModel),
                    endpoint: endpoint,
                    executable: "/usr/local/bin/tool"
                )
                #expect(!script.contains("x'; touch"), "\(tool): the name left its quotes")
                #expect(!script.contains("m'; id"), "\(tool): the model id left its quotes")
                #expect(!script.contains("\u{1B}"), "\(tool): a terminal escape reached the script")
                #expect(!script.contains("\u{07}"), "\(tool): a bell reached the script")
                #expect(script.contains("touch /tmp/pwned"), "\(tool): the name is kept as data")
            }
        }

        @Test func controlCharactersAreStrippedAndTextIsKept() {
            #expect(
                MacSparkDeveloperToolLauncher.terminalSafe("Spark · Alex's \u{1B}[31mbox\u{07}\n")
                    == "Spark · Alex's [31mbox"
            )
        }

        /// Launch scripts older than the cutoff are swept; fresh ones stay (A10).
        @Test func staleLaunchScriptsAreSwept() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = root.appendingPathComponent("claudeCode-old.command")
            try Data("#!/bin/zsh".utf8).write(to: old)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7200)],
                ofItemAtPath: old.path
            )
            let fresh = root.appendingPathComponent("claudeCode-fresh.command")
            try Data("#!/bin/zsh".utf8).write(to: fresh)
            MacSparkDeveloperToolLauncher.sweepStaleLaunchers(
                in: root,
                olderThan: Date().addingTimeInterval(-3600)
            )
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: fresh.path))
        }
    }
#endif

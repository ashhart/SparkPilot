import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

#if os(macOS)
    public struct XcodeBuildExecutor: TypedBuildExecuting {
        private let runner: any FixedBuildProcessRunning

        public init(runner: any FixedBuildProcessRunning = FoundationFixedBuildProcessRunner()) {
            self.runner = runner
        }

        public func execute(
            recipe: GeneratedAPI.BuildRecipePayload,
            sourceDirectory: URL
        ) async throws -> BuildExecutionOutcome {
            try validate(recipe)
            let resultURL = sourceDirectory.deletingLastPathComponent()
                .appendingPathComponent("Result.xcresult")
            var arguments = [
                "-scheme", recipe.scheme,
                "-configuration", recipe.configuration,
                "-destination", recipe.destination,
                "-resultBundlePath", resultURL.path,
            ]
            arguments.append(contentsOf: recipe.actions.map(\.rawValue))
            let output = try await runner.run(
                tool: .xcodebuild,
                arguments: arguments,
                directory: sourceDirectory,
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": sourceDirectory.deletingLastPathComponent().path,
                    "LANG": "C",
                    "NSUnbufferedIO": "YES",
                    "TMPDIR": sourceDirectory.deletingLastPathComponent().path,
                ],
                timeoutSeconds: recipe.timeoutSeconds,
                outputLimit: 1024 * 1024,
                monitoredDirectory: sourceDirectory.deletingLastPathComponent(),
                byteLimit: 8 * 1024 * 1024 * 1024
            )
            let raw = String(decoding: output.output, as: UTF8.self)
            let text = BuildOutputRedactor.redact(raw)
            // 43.5: read the locations before redaction removes them, then redact each message.
            let parsed = BuildOutputParser.parse(raw, sourceDirectory: sourceDirectory)
            let artifacts = try await collectArtifacts(
                resultURL: resultURL,
                parent: sourceDirectory.deletingLastPathComponent()
            )
            return BuildExecutionOutcome(
                exitState: output.status == 0 ? .succeeded : .failed,
                output: text,
                testFailures: parsed.failures,
                diagnostics: parsed.diagnostics,
                artifacts: artifacts
            )
        }

        private func validate(_ recipe: GeneratedAPI.BuildRecipePayload) throws {
            for (name, value, limit) in [
                ("scheme", recipe.scheme, 200),
                ("configuration", recipe.configuration, 100),
                ("destination", recipe.destination, 500),
            ]
            where value.isEmpty || value.utf8.count > limit
                || value.contains(where: { $0.isNewline })
            {
                throw BuildWorkerExecutionError.invalidRecipeField(name)
            }
            guard !recipe.actions.isEmpty,
                recipe.actions.allSatisfy({ $0 == .build || $0 == .test })
            else { throw BuildWorkerExecutionError.invalidRecipeField("actions") }
        }

        private func collectArtifacts(
            resultURL: URL,
            parent: URL
        ) async throws -> [BuildExecutionArtifact] {
            guard FileManager.default.fileExists(atPath: resultURL.path) else { return [] }
            guard try artifactTreeContainsNoSymlinks(resultURL) else {
                throw BuildWorkerExecutionError.unsafeArtifact
            }
            var artifacts: [BuildExecutionArtifact] = []
            let attachments = parent.appendingPathComponent("attachments", isDirectory: true)
            try FileManager.default.createDirectory(
                at: attachments,
                withIntermediateDirectories: true
            )
            let export = try await runner.run(
                tool: .xcresulttool,
                arguments: [
                    "xcresulttool", "export", "attachments", "--path", resultURL.path,
                    "--output-path", attachments.path,
                ],
                directory: parent,
                environment: [
                    "PATH": "/usr/bin:/bin", "LANG": "C", "TMPDIR": parent.path,
                ],
                timeoutSeconds: 60,
                outputLimit: 64 * 1024,
                monitoredDirectory: attachments,
                byteLimit: 32 * 1024 * 1024
            )
            if export.status == 0 {
                artifacts.append(contentsOf: try screenshotArtifacts(in: attachments))
            }
            let archiveStaging = parent.appendingPathComponent(
                "artifact-staging",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: archiveStaging.path) {
                try FileManager.default.removeItem(at: archiveStaging)
            }
            try FileManager.default.createDirectory(
                at: archiveStaging,
                withIntermediateDirectories: true
            )
            let archive = archiveStaging.appendingPathComponent("Result.xcresult.zip")
            let result = try await runner.run(
                tool: .ditto,
                arguments: ["-c", "-k", "--sequesterRsrc", resultURL.path, archive.path],
                directory: parent,
                environment: [
                    "PATH": "/usr/bin:/bin", "LANG": "C", "TMPDIR": parent.path,
                ],
                timeoutSeconds: 60,
                outputLimit: 64 * 1024,
                monitoredDirectory: archiveStaging,
                byteLimit: 9 * 1024 * 1024
            )
            guard result.status == 0,
                let bytes = try? Data(contentsOf: archive), bytes.count <= 8 * 1024 * 1024
            else { return artifacts }
            artifacts.insert(
                BuildExecutionArtifact(
                    kind: .xcresult,
                    relativePath: "Result.xcresult.zip",
                    bytes: bytes
                ),
                at: 0
            )
            return Array(artifacts.prefix(16))
        }

        private func artifactTreeContainsNoSymlinks(_ directory: URL) throws -> Bool {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey]
                )
            else { return false }
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    return false
                }
            }
            return true
        }

        private func screenshotArtifacts(in directory: URL) throws -> [BuildExecutionArtifact] {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            else { return [] }
            var artifacts: [BuildExecutionArtifact] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard ["png", "jpg", "jpeg", "heic"].contains(file.pathExtension.lowercased())
                else {
                    continue
                }
                let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard bytes.count <= 8 * 1024 * 1024 else { continue }
                artifacts.append(
                    BuildExecutionArtifact(
                        kind: .screenshot,
                        relativePath: "screenshots/\(file.lastPathComponent)",
                        bytes: bytes
                    )
                )
                if artifacts.count == 15 { break }
            }
            return artifacts
        }
    }

#endif

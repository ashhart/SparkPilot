import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

#if os(macOS)
    public struct GitBuildSourceFetcher: BuildSourceFetching {
        private let runner: any FixedBuildProcessRunning

        public init(runner: any FixedBuildProcessRunning = FoundationFixedBuildProcessRunner()) {
            self.runner = runner
        }

        public func fetch(
            ticket: GeneratedAPI.BuildSourceTicket,
            into directory: URL
        ) async throws -> URL {
            guard let raw = ticket.repositoryUrl, let repository = URL(string: raw) else {
                throw BuildWorkerExecutionError.repositoryMissing
            }
            guard repository.scheme?.lowercased() == "https",
                repository.user == nil, repository.password == nil,
                repository.query == nil, repository.fragment == nil
            else { throw BuildWorkerExecutionError.repositoryURLRefused }
            guard ticket.commit.isBuildLowercaseHex(count: 40),
                ticket.sourceSha256.isBuildLowercaseHex(count: 64)
            else { throw BuildWorkerExecutionError.checkoutMismatch }
            let source = directory.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": directory.path,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_SSH_COMMAND": "/usr/bin/false",
                "LANG": "C",
                "TMPDIR": directory.path,
            ]
            try await checked(.git, ["init", source.path], directory, environment, ticket)
            try await checked(
                .git,
                ["-C", source.path, "remote", "add", "origin", repository.absoluteString],
                directory,
                environment,
                ticket
            )
            try await checked(
                .git,
                ["-C", source.path, "fetch", "--depth=1", "--no-tags", "origin", ticket.commit],
                directory,
                environment,
                ticket
            )
            try await checked(
                .git,
                ["-C", source.path, "checkout", "--detach", ticket.commit],
                directory,
                environment,
                ticket
            )
            let head = try await runner.run(
                tool: .git,
                arguments: ["-C", source.path, "rev-parse", "HEAD"],
                directory: directory,
                environment: environment,
                timeoutSeconds: 30,
                outputLimit: 256,
                monitoredDirectory: source,
                byteLimit: ticket.maxBytes
            )
            guard head.status == 0,
                String(decoding: head.output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == ticket.commit
            else { throw BuildWorkerExecutionError.checkoutMismatch }
            guard
                try BuildSourceDigest.hex(of: source, byteLimit: ticket.maxBytes)
                    == ticket.sourceSha256
            else { throw BuildWorkerExecutionError.sourceDigestMismatch }
            return source
        }

        private func checked(
            _ tool: FixedBuildTool,
            _ arguments: [String],
            _ directory: URL,
            _ environment: [String: String],
            _ ticket: GeneratedAPI.BuildSourceTicket
        ) async throws {
            let result = try await runner.run(
                tool: tool,
                arguments: arguments,
                directory: directory,
                environment: environment,
                timeoutSeconds: 300,
                outputLimit: 1024 * 1024,
                monitoredDirectory: directory,
                byteLimit: ticket.maxBytes
            )
            guard result.status == 0 else {
                throw BuildWorkerExecutionError.toolFailed("git", result.status)
            }
        }
    }

#endif

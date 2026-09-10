import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

#if os(macOS)
    public enum FixedBuildTool: Sendable, Equatable {
        case git
        case xcodebuild
        case xcresulttool
        case simctl
        case ditto

        fileprivate var executable: URL {
            switch self {
            case .git: URL(fileURLWithPath: "/usr/bin/git")
            case .xcodebuild: URL(fileURLWithPath: "/usr/bin/xcodebuild")
            case .xcresulttool, .simctl: URL(fileURLWithPath: "/usr/bin/xcrun")
            case .ditto: URL(fileURLWithPath: "/usr/bin/ditto")
            }
        }
    }

    public struct FixedProcessOutput: Sendable, Equatable {
        public let status: Int32
        public let output: Data
    }

    public protocol FixedBuildProcessRunning: Sendable {
        func run(
            tool: FixedBuildTool,
            arguments: [String],
            directory: URL,
            environment: [String: String],
            timeoutSeconds: Int,
            outputLimit: Int,
            monitoredDirectory: URL?,
            byteLimit: Int?
        ) async throws -> FixedProcessOutput
    }

    public actor FoundationFixedBuildProcessRunner: FixedBuildProcessRunning {
        public init() {}

        public func run(
            tool: FixedBuildTool,
            arguments: [String],
            directory: URL,
            environment: [String: String],
            timeoutSeconds: Int,
            outputLimit: Int,
            monitoredDirectory: URL?,
            byteLimit: Int?
        ) async throws -> FixedProcessOutput {
            let outputURL = directory.appendingPathComponent(
                ".spark-build-output-\(UUID().uuidString)"
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? outputHandle.close()
                try? FileManager.default.removeItem(at: outputURL)
            }
            let processID = try spawn(
                executable: tool.executable,
                arguments: arguments,
                directory: directory,
                environment: environment,
                outputDescriptor: outputHandle.fileDescriptor
            )
            let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
            var waitStatus: Int32 = 0
            var reaped = false
            do {
                while !reaped {
                    let waited = Darwin.waitpid(processID, &waitStatus, WNOHANG)
                    if waited == processID {
                        reaped = true
                        break
                    }
                    if waited == -1 {
                        if errno == EINTR { continue }
                        throw BuildWorkerExecutionError.unsupportedPlatform
                    }
                    if Task.isCancelled { throw CancellationError() }
                    if ContinuousClock.now >= deadline {
                        throw BuildWorkerExecutionError.timedOut
                    }
                    if let monitoredDirectory, let byteLimit,
                        try BuildSourceDigest.allocatedBytes(in: monitoredDirectory) > byteLimit
                    {
                        throw BuildWorkerExecutionError.sourceTooLarge
                    }
                    if (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                        as? Int)
                        .flatMap({ $0 }) ?? 0 > outputLimit
                    {
                        throw BuildWorkerExecutionError.outputTooLarge
                    }
                    // Inspect cancellation on each short poll while allowing cleanup to run after a cancelled sleep.
                    try? await Task.sleep(for: .milliseconds(100))
                }
                terminateProcessGroup(processID)
                try outputHandle.synchronize()
                let output = try Data(contentsOf: outputURL)
                guard output.count <= outputLimit else {
                    throw BuildWorkerExecutionError.outputTooLarge
                }
                return FixedProcessOutput(status: exitCode(waitStatus), output: output)
            } catch {
                if !reaped { stopProcessGroup(processID) }
                throw error
            }
        }

        private func spawn(
            executable: URL,
            arguments: [String],
            directory: URL,
            environment: [String: String],
            outputDescriptor: Int32
        ) throws -> pid_t {
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                throw BuildWorkerExecutionError.unsupportedPlatform
            }
            defer { posix_spawn_file_actions_destroy(&actions) }
            let changeDirectoryResult =
                if #available(macOS 26.0, *) {
                    posix_spawn_file_actions_addchdir(&actions, directory.path)
                } else {
                    posix_spawn_file_actions_addchdir_np(&actions, directory.path)
                }
            guard changeDirectoryResult == 0,
                posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDOUT_FILENO) == 0,
                posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDERR_FILENO) == 0
            else { throw BuildWorkerExecutionError.unsupportedPlatform }

            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else {
                throw BuildWorkerExecutionError.unsupportedPlatform
            }
            defer { posix_spawnattr_destroy(&attributes) }
            let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            guard posix_spawnattr_setflags(&attributes, flags) == 0,
                posix_spawnattr_setpgroup(&attributes, 0) == 0
            else { throw BuildWorkerExecutionError.unsupportedPlatform }

            let argv = ([executable.path] + arguments).map { strdup($0) }
            let envp = environment.sorted(by: { $0.key < $1.key }).map {
                strdup("\($0.key)=\($0.value)")
            }
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var terminatedArgv = argv + [nil]
            var terminatedEnvp = envp + [nil]
            var processID: pid_t = 0
            let result = terminatedArgv.withUnsafeMutableBufferPointer { argvBuffer in
                terminatedEnvp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &processID,
                        executable.path,
                        &actions,
                        &attributes,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
            guard result == 0, processID > 0 else {
                throw BuildWorkerExecutionError.toolFailed(executable.lastPathComponent, result)
            }
            return processID
        }

        private func stopProcessGroup(_ processID: pid_t) {
            terminateProcessGroup(processID)
            var status: Int32 = 0
            while Darwin.waitpid(processID, &status, 0) == -1 && errno == EINTR {}
        }

        private func terminateProcessGroup(_ processID: pid_t) {
            guard Darwin.kill(-processID, 0) == 0 else { return }
            Darwin.kill(-processID, SIGTERM)
            Darwin.usleep(100_000)
            Darwin.kill(-processID, SIGKILL)
        }

        private func exitCode(_ waitStatus: Int32) -> Int32 {
            let signal = waitStatus & 0x7f
            return signal == 0 ? (waitStatus >> 8) & 0xff : signal
        }
    }

#endif

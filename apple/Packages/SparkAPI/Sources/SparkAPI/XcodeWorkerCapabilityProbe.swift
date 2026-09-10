import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

#if os(macOS)
    public struct XcodeWorkerCapabilityProbe: Sendable {
        private let runner: any FixedBuildProcessRunning

        public init(runner: any FixedBuildProcessRunning = FoundationFixedBuildProcessRunner()) {
            self.runner = runner
        }

        public func load() async throws -> BuildWorkerCapabilities {
            guard Self.isAppSandboxed else {
                throw BuildWorkerExecutionError.unsupportedPlatform
            }
            let directory = FileManager.default.temporaryDirectory
            let environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "TMPDIR": directory.path,
            ]
            let version = try await runner.run(
                tool: .xcodebuild,
                arguments: ["-version"],
                directory: directory,
                environment: environment,
                timeoutSeconds: 30,
                outputLimit: 16 * 1024,
                monitoredDirectory: nil,
                byteLimit: nil
            )
            guard version.status == 0 else {
                throw BuildWorkerExecutionError.toolFailed("xcodebuild", version.status)
            }
            let versionText = String(decoding: version.output, as: UTF8.self)
            let xcodeVersion =
                versionText.split(separator: "\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
            let sdks = try await runner.run(
                tool: .xcodebuild,
                arguments: ["-showsdks"],
                directory: directory,
                environment: environment,
                timeoutSeconds: 30,
                outputLimit: 128 * 1024,
                monitoredDirectory: nil,
                byteLimit: nil
            )
            let sdkNames = String(decoding: sdks.output, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard let range = line.range(of: "-sdk ") else { return nil }
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            let simulators = try await runner.run(
                tool: .simctl,
                arguments: ["simctl", "list", "devices", "available", "-j"],
                directory: directory,
                environment: environment,
                timeoutSeconds: 30,
                outputLimit: 512 * 1024,
                monitoredDirectory: nil,
                byteLimit: nil
            )
            return BuildWorkerCapabilities(
                xcodeVersion: xcodeVersion,
                sdkVersions: Array(Set(sdkNames)).sorted(),
                architectures: ["arm64"],
                simulators: simulators.status == 0
                    ? Self.simulatorNames(from: simulators.output) : [],
                signingAvailable: false,
                maxConcurrentJobs: 1
            )
        }

        /// PLAN 43.3: the simulators `simctl` can boot, named with their runtime, at most the contract's 128.
        static func simulatorNames(from simctlJSON: Data) -> [String] {
            struct Device: Decodable {
                let name: String
                let isAvailable: Bool?
            }
            struct Listing: Decodable {
                let devices: [String: [Device]]
            }
            guard let listing = try? JSONDecoder().decode(Listing.self, from: simctlJSON) else {
                return []
            }
            var names: Set<String> = []
            for (runtime, devices) in listing.devices {
                let platform = runtime.split(separator: ".").last.map(String.init) ?? runtime
                for device in devices where device.isAvailable ?? true {
                    names.insert("\(device.name) (\(Self.runtimeLabel(platform)))")
                }
            }
            return Array(names.sorted().prefix(128))
        }

        /// `iOS-26-5` reads as `iOS 26.5`; anything else is shown as the runtime named it.
        static func runtimeLabel(_ platform: String) -> String {
            let parts = platform.split(separator: "-")
            guard parts.count >= 2 else { return platform }
            return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
        }

        private static var isAppSandboxed: Bool {
            guard let task = SecTaskCreateFromSelf(nil),
                let value = SecTaskCopyValueForEntitlement(
                    task,
                    "com.apple.security.app-sandbox" as CFString,
                    nil
                )
            else { return false }
            return (value as? Bool) == true
        }
    }
#endif

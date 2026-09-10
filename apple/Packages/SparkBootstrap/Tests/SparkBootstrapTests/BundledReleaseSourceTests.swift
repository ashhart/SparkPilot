import Foundation
import Testing

@testable import SparkBootstrap

struct BundledReleaseSourceTests {
    @Test func encodedArchiveRestoresTheOriginalSignedBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("!<arch>\noriginal signed Debian archive".utf8)
        let package = directory.appendingPathComponent("runtime.deb.b64")
        let signature = directory.appendingPathComponent("runtime.deb.sig")
        try bytes.base64EncodedData().write(to: package)
        try Data("signature".utf8).write(to: signature)
        let source = BundledReleaseSource(
            manifestURL: directory.appendingPathComponent("manifest.json"),
            packageURL: package,
            signatureURL: signature
        )
        let artifact = ReleaseArtifact(
            name: "runtime.deb",
            architecture: "aarch64",
            url: URL(string: "https://offline.invalid/package")!,
            size: Int64(bytes.count),
            sha256: String(repeating: "a", count: 64),
            signatureURL: URL(string: "https://offline.invalid/signature")!
        )
        #expect(try await source.artifact(artifact) == bytes)
        #expect(try await source.detachedSignature(artifact) == Data("signature".utf8))
        for invalid in [Data("not base64!".utf8), Data(repeating: 65, count: 80)] {
            try invalid.write(to: package)
            await #expect(throws: ReleaseSourceError.self) {
                _ = try await source.artifact(artifact)
            }
        }
    }

    @Test func bundledReleaseWorksWithoutANetworkURL() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("manifest.json")
        let package = directory.appendingPathComponent("spark-runtime_0.1.0-7_arm64.deb")
        let signature = directory.appendingPathComponent("spark-runtime_0.1.0-7_arm64.deb.sig")
        try Data("manifest".utf8).write(to: manifest)
        try Data("package".utf8).write(to: package)
        try Data("signature".utf8).write(to: signature)

        let source = BundledReleaseSource(
            manifestURL: manifest,
            packageURL: package,
            signatureURL: signature
        )
        let artifact = ReleaseArtifact(
            name: package.lastPathComponent,
            architecture: "aarch64",
            url: URL(string: "https://offline.invalid/package")!,
            size: 7,
            sha256: String(repeating: "a", count: 64),
            signatureURL: URL(string: "https://offline.invalid/signature")!
        )

        #expect(try await source.manifest() == Data("manifest".utf8))
        #expect(try await source.artifact(artifact) == Data("package".utf8))
        #expect(try await source.detachedSignature(artifact) == Data("signature".utf8))
    }

    @Test func aDifferentManifestArtifactCannotSelectAnotherBundledFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("manifest.json")
        let package = directory.appendingPathComponent("runtime.deb")
        let signature = directory.appendingPathComponent("runtime.deb.sig")
        for url in [manifest, package, signature] { try Data([1]).write(to: url) }
        let source = BundledReleaseSource(
            manifestURL: manifest,
            packageURL: package,
            signatureURL: signature
        )
        let artifact = ReleaseArtifact(
            name: "another.deb",
            architecture: "aarch64",
            url: URL(string: "https://offline.invalid/package")!,
            size: 1,
            sha256: String(repeating: "a", count: 64),
            signatureURL: URL(string: "https://offline.invalid/signature")!
        )
        await #expect(throws: ReleaseSourceError.self) {
            _ = try await source.artifact(artifact)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spark-bundled-release-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

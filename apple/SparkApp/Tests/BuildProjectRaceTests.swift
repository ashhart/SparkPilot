import Foundation
import CryptoKit
@testable import SparkAppComposition
import Testing
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
private enum ProbeError: Error { case stop }
private actor ProjectClientProbe: BuildProjectNetworking {
    let name: String
    let fail: Bool
    let id = UUID().uuidString.lowercased()
    var pending: CheckedContinuation<Void, Never>?
    init(name: String, fail: Bool = false) {
        self.name = name
        self.fail = fail
    }
    func projects() async throws -> [GeneratedAPI.Project] {
        if name == "A" { await withCheckedContinuation { pending = $0 } }
        if fail { throw ProbeError.stop }
        return [
            .init(
                id: id,
                name: "Project \(name)",
                state: .ready,
                defaultBranch: "main",
                capabilities: [.read],
                createdAt: "2026-09-01T12:00:00Z",
                updatedAt: "2026-09-01T12:00:00Z"
            )
        ]
    }
    func waiting() -> Bool { pending != nil }
    func finish() {
        pending?.resume()
        pending = nil
    }
    func submitTracked(_ request: GeneratedAPI.BuildJobRequest, idempotencyKey: UUID) async throws
        -> BuildClient.Submission
    { throw ProbeError.stop }
    func job(buildID: String) async throws -> GeneratedAPI.BuildJob { throw ProbeError.stop }
    func artifact(buildID: String, artifactID: String, expectedSHA256: String) async throws -> Data
    { throw ProbeError.stop }
}
private struct ClientFactory: BuildClientCreating {
    let a: ProjectClientProbe
    let b: ProjectClientProbe
    @MainActor func client(for target: BuildTarget) throws -> any BuildProjectNetworking {
        target.name == "A" ? a : b
    }
}
@MainActor
@Test(arguments: [false, true]) func staleProjectResponseCannotOverwriteCurrentSpark(fail: Bool)
    async throws
{
    let library = SparkLibrary(store: MemoryLibraryStore())
    let store = NodeTrustStore(store: InMemoryStore())
    let authority = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    let fingerprint = SHA256Digest.hex(authority)
    let keyHex = authority.map { String(format: "%02x", $0) }.joined()
    for name in ["A", "B"] {
        let id = SparkNodeID(rawValue: UUID())
        library.reconcile(
            AuthenticatedTarget(
                nodeID: id,
                clusterID: nil,
                name: name,
                role: .standalone,
                authorityFingerprint: fingerprint,
                displayName: name,
                routes: [
                    CachedRoute(
                        baseURL: URL(string: "https://\(name.lowercased()).invalid:7443")!,
                        kind: .localWiFi,
                        lastSuccess: .now
                    )
                ],
                reachedAt: .now
            )
        )
        try store.remember(
            NodeTrust(
                nodeID: id.rawValue.uuidString.lowercased(),
                nodeName: name,
                tlsFingerprint: String(repeating: "a", count: 64),
                authorityFingerprint: fingerprint,
                authorityPublicKey: keyHex,
                pairedAt: .now,
                localDeviceRole: "owner"
            )
        )
    }
    let suite = "SparkAudit.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let a = ProjectClientProbe(name: "A", fail: fail), b = ProjectClientProbe(name: "B")
    let model = BuildProjectModel(
        library: library,
        clients: ClientFactory(a: a, b: b),
        trustStore: store,
        defaults: defaults
    )
    let first = model.targets.first { $0.name == "A" }!
    let second = model.targets.first { $0.name == "B" }!
    model.selectedTargetID = first.id
    let firstLoad = Task { await model.refreshProjects() }
    while !(await a.waiting()) { await Task.yield() }
    await model.selectTarget(second.id)
    await a.finish()
    await firstLoad.value
    #expect(model.selectedTargetID == second.id)
    #expect(model.projects.map(\.name) == ["Project B"])
    #expect(model.selectedProjectID == b.id)
    #expect(!model.isLoading)
    #expect(model.problem == nil)
}

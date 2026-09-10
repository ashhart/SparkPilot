#if os(macOS)
    import Foundation
    import CryptoKit
    @testable import SparkAppComposition
    import Testing
    import SparkAPI
    import SparkCore
    import SparkLibrary
    import SparkSecurity

    private enum ProbeError: Error { case stop }
    private actor NetworkProbe: BuildWorkerNetworking {
        var registrations = 0
        func register(_ registration: GeneratedAPI.BuildWorkerRegistration, idempotencyKey: UUID)
            async throws
        {
            registrations += 1
            throw ProbeError.stop
        }
        func heartbeat(workerID: UUID, idempotencyKey: UUID) async throws
            -> GeneratedAPI.BuildWorkerHeartbeat
        { throw ProbeError.stop }
        func claim(workerID: UUID, idempotencyKey: UUID) async throws -> GeneratedAPI.BuildClaim? {
            throw ProbeError.stop
        }
        func renew(buildID: String, claimToken: String, idempotencyKey: UUID) async throws
            -> GeneratedAPI.BuildLeaseRenewal
        { throw ProbeError.stop }
        func upload(
            buildID: String,
            claimToken: String,
            artifactToken: String,
            evidence: GeneratedAPI.BuildArtifactEvidence,
            bytes: Data,
            idempotencyKey: UUID
        ) async throws { throw ProbeError.stop }
        func report(
            buildID: String,
            claimToken: String,
            result: GeneratedAPI.SignedBuildResult,
            idempotencyKey: UUID
        ) async throws -> GeneratedAPI.BuildJob { throw ProbeError.stop }
    }
    @MainActor private final class DelayedFactory: BuildWorkerControllerCreating {
        var pending: CheckedContinuation<Void, Never>?
        var controller: BuildWorkerController?
        let network = NetworkProbe()
        func make(
            target: BuildTarget,
            workerID: UUID,
            snapshot: @escaping BuildWorkerController.SnapshotHandler
        ) async throws -> BuildWorkerController {
            await withCheckedContinuation { pending = $0 }
            let created = BuildWorkerController(
                nodeID: target.nodeID,
                workerID: workerID,
                client: network,
                trust: BuildWorkerTrust(
                    authorityPublicKey: target.authorityPublicKey,
                    authorityFingerprint: target.authorityFingerprint,
                    workerID: workerID,
                    allowedProjectIDs: []
                ),
                capabilities: BuildWorkerCapabilities(xcodeVersion: "26"),
                sourceFetcher: GitBuildSourceFetcher(),
                executor: XcodeBuildExecutor(),
                evidenceSigner: BuildEvidenceSigner(key: SoftwareSigner()),
                workspaceRoot: URL(fileURLWithPath: "/tmp/spark-apple-review/worker"),
                runsContinuously: false,
                snapshotHandler: snapshot
            )
            controller = created
            return created
        }
    }
    @MainActor
    @Test(arguments: [true, false]) func obsoleteWorkerPreparationCannotEnableOrPublish(
        switchTarget: Bool
    ) async throws {
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
        let factory = DelayedFactory()
        let model = BuildWorkerSettingsModel(
            library: library,
            trustStore: store,
            factory: factory,
            defaults: defaults
        )
        let original = model.selectedTargetID!
        let other = model.targets.first { $0.id != original }!
        let enable = Task { await model.setEnabled(true) }
        while factory.pending == nil { await Task.yield() }
        if switchTarget {
            await model.selectTarget(other.id)
        } else {
            await model.setEnabled(false)
        }
        factory.pending!.resume()
        await enable.value
        await factory.controller!.runOneCycle()
        #expect(await factory.network.registrations == 0)
        #expect(!model.isEnabled)
        #expect(!model.isPreparing)
        #expect(model.snapshot == nil)
        await factory.controller!.setEnabled(false)
    }

#endif
